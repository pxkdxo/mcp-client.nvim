--- The client layer: composes the transport (U1), the session
--- id/protocol-version + 404-reinitialize lifecycle (session.lua), and the
--- bounded-backoff reconnect machine (reconnect.lua) into the public,
--- Neovim-native API this plugin exposes -- `get_clients(filter)` plus a
--- client object with `id`, `name`, `config`, `is_stopped()`,
--- `request`/`notify`, and `disconnect()` -- and fires the
--- `MCPAttach`/`MCPDetach`/`MCPNotify` `User` autocmds.
---
--- The correctness-critical mechanism lives here: distinguishing an
--- intentional close (our own reconnect teardown, or a caller disconnect)
--- from a real stream drop. Both surface identically -- the long-lived curl
--- GET Job serving the legacy SSE stream exits -- so we tag our own kills
--- with `job.user_data.intentional_close = true` *before* signalling the
--- process, and the exit handler (attached via `job:add_on_exit_callback`)
--- checks that flag first. If it is set, the exit is expected and no
--- reconnect is scheduled; only an untagged exit drives the reconnect path.
--- This is the fix for the original mcphub.nvim crash-loop, where a teardown
--- and a real failure were indistinguishable and a teardown re-triggered a
--- connect that tore down again.

local detect = require("mcphub-neovim.transport.detect")
local tls = require("mcphub-neovim.transport.tls")
local Session = require("mcphub-neovim.session")
local Reconnect = require("mcphub-neovim.reconnect")

local M = {}

local PROTOCOL_VERSION = "2025-03-26"

--- The live client registry. `get_clients(filter)` reads from it; every
--- state transition keeps it current so an adapter polling right after
--- `MCPDetach` observes `is_stopped() == true`.
local registry = {}
local next_id = 0

local function new_id()
	next_id = next_id + 1
	return "mcphub-client-" .. next_id
end

local function build_initialize_request(config)
	return {
		jsonrpc = "2.0",
		id = 1,
		method = "initialize",
		params = {
			protocolVersion = PROTOCOL_VERSION,
			capabilities = config.capabilities or {},
			clientInfo = {
				name = config.name or "mcphub-neovim",
				version = config.client_version or "0.1.0",
			},
		},
	}
end

--- Fire an `MCPAttach`/`MCPDetach`/`MCPNotify` User autocmd carrying the
--- client id, scheduled onto the main loop so it is safe to call from any
--- callback context (curl callbacks are already vim.schedule_wrap'd, but
--- exit handlers and timers may not be).
local function fire_event(pattern, client_id)
	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = pattern,
			data = { client_id = client_id },
		})
	end)
end

--- @class Client
--- @field id string
--- @field name string
--- @field config table
--- @field transport string  "streamable_http" | "legacy_sse"

--- Attach the stream-end exit hook to a transport's long-lived stream Job
--- (legacy SSE only; streamable_http returns nil and is a no-op). On exit,
--- check the intentional-close flag first: a tagged exit is our own
--- teardown and must not reconnect; an untagged exit is a real drop and
--- drives `reconnect:on_drop()`.
local function hook_stream_job(entry, transport_client)
	local job = transport_client.get_stream_job and transport_client:get_stream_job()
	entry._job = job
	entry._transport_for_job = transport_client
	if not job then
		return
	end
	job:add_on_exit_callback(function(exited_job)
		-- The single most important check in the plugin: an intentional
		-- close (our reconnect teardown or a caller disconnect) tagged this
		-- job before killing it, so this exit is expected -- never reconnect.
		if exited_job.user_data and exited_job.user_data.intentional_close then
			return
		end
		-- A real, unexpected stream-end: drive the reconnect machine, honoring
		-- any SSE `retry:` hint the server sent on this stream over the
		-- machine's computed backoff.
		local hint
		if transport_client.get_retry_hint then
			local retry_ms = transport_client:get_retry_hint()
			if retry_ms then
				hint = { retry_ms = retry_ms }
			end
		end
		vim.schedule(function()
			entry.reconnect:on_drop(hint)
		end)
	end)
end

--- Wire the transport's server-notification hook to fire an MCPNotify
--- autocmd for this client. Re-applied whenever we adopt a new transport
--- (initial connect, reconnect, reinitialize) so notifications keep flowing
--- across a transparent session change.
local function hook_notifications(entry, transport_client)
	if transport_client.set_on_notification then
		transport_client:set_on_notification(function(_)
			fire_event("MCPNotify", entry.id)
		end)
	end
end

--- Reject every request still in flight when the client gives up, so a
--- caller waiting on a reply resolves with an error instead of hanging
--- forever (R11). Called on the transition into `disconnected`.
local function fail_in_flight(entry, message)
	local pending = entry._in_flight
	entry._in_flight = {}
	for _, cb in pairs(pending) do
		pcall(cb, message, nil, nil)
	end
end

--- Perform one reconnection attempt: a fresh transport handshake. On
--- success, adopt the new transport, re-hook its stream Job, and tell the
--- reconnect machine we are connected again (which fires MCPAttach). On
--- failure, feed the failure back into the machine as another drop so it
--- either schedules the next bounded attempt or exhausts to disconnected.
---
--- Crucially the attempt is itself bounded by a timeout: a hub that accepts
--- the connection but never completes the handshake (e.g. the legacy GET
--- returns a non-endpoint 5xx and curl exits cleanly with no `endpoint`
--- event) would otherwise leave `detect.connect` pending forever, wedging
--- the machine in `reconnecting`. The timeout converts that silent stall
--- into a counted failure so the machine can still exhaust to disconnected
--- rather than hang -- the R11 "never leave a caller hanging" guarantee.
local ATTEMPT_TIMEOUT_MS = 10000

local function attempt_reconnect(entry)
	local settled = false
	local function settle(fn)
		if settled then
			return
		end
		settled = true
		fn()
	end

	local guard = vim.uv.new_timer()
	guard:start(entry.config.attempt_timeout or ATTEMPT_TIMEOUT_MS, 0, function()
		guard:stop()
		guard:close()
		vim.schedule(function()
			settle(function()
				entry.reconnect:on_drop()
			end)
		end)
	end)

	detect.connect({
		url = entry.config.url,
		request = build_initialize_request(entry.config),
		headers = entry.config.headers,
		timeout = entry.config.timeout,
	}, function(result, err)
		if not guard:is_closing() then
			guard:stop()
			guard:close()
		end
		if settled then
			-- The timeout already counted this attempt as failed. A late,
			-- now-orphaned successful handshake would otherwise leak its stream;
			-- close it rather than adopt it out of band.
			if not err and result and result.client and result.client.close then
				pcall(function()
					result.client:close()
				end)
			end
			return
		end
		settle(function()
			if err then
				-- Attempt failed; let the machine count it and decide.
				entry.reconnect:on_drop()
				return
			end
			entry.transport_client = result.client
			entry.transport = result.transport
			entry.session.transport = result.client
			if result.session_id then
				entry.session.session_id = result.session_id
			end
			hook_stream_job(entry, result.client)
			hook_notifications(entry, result.client)
			entry.reconnect:on_connected()
		end)
	end)
end

--- Build the reinitialize handler the session unit calls on a 404: a fresh
--- handshake yielding a new transport + session id, without disturbing the
--- reconnect machine (a 404 is a session-level, not a connection-level,
--- event).
local function make_reinitializer(entry)
	return function(on_done)
		detect.connect({
			url = entry.config.url,
			request = build_initialize_request(entry.config),
			headers = entry.config.headers,
			timeout = entry.config.timeout,
		}, function(result, err)
			if err then
				return on_done(err, nil)
			end
			entry.transport_client = result.client
			entry.transport = result.transport
			hook_stream_job(entry, result.client)
			hook_notifications(entry, result.client)
			on_done(nil, {
				transport = result.client,
				session_id = result.session_id,
			})
		end)
	end
end

--- Construct the public client object exposed to callers, backed by a
--- registry `entry`.
local function make_client_object(entry)
	local obj = {
		id = entry.id,
		name = entry.name,
		config = entry.config,
	}
	-- `transport` is read through a metatable so callers always see the
	-- current transport even after a transparent reconnect/reinitialize.
	setmetatable(obj, {
		__index = function(_, key)
			if key == "transport" then
				return entry.transport
			end
		end,
	})

	-- Methods are defined with `:` so callers use `client:request(...)`,
	-- matching the transport layer's convention. They ignore the implicit
	-- self and close over `entry` for their state.
	function obj:is_stopped()
		return entry.reconnect:state() == "disconnected"
	end

	--- Send a JSON-RPC request. Tracks it as in-flight so it can be failed
	--- (rather than hung) if the client transitions to disconnected before a
	--- reply arrives. Routes through the session layer for transparent 404
	--- reinitialize.
	function obj:request(rpc_message, callback)
		if entry.reconnect:state() == "disconnected" then
			return callback("client is disconnected", nil, nil)
		end
		local key = rpc_message.id
		if key ~= nil then
			entry._in_flight[key] = callback
		end
		entry.session:request(rpc_message, function(err, result, response)
			if key ~= nil then
				entry._in_flight[key] = nil
			end
			callback(err, result, response)
		end)
	end

	function obj:notify(rpc_message)
		return entry.session:notify(rpc_message)
	end

	--- Explicit caller-initiated disconnect: an intentional close. Drives
	--- the reconnect machine straight to `disconnected` (terminal), which
	--- fires MCPDetach, then tears down the transport with the
	--- intentional-close flag set so the resulting stream-end never
	--- reconnects.
	function obj:disconnect()
		entry:intentional_close()
	end

	return obj
end

--- Tear down the transport intentionally. Sets the intentional-close flag on
--- the stream Job *before* killing it so the exit handler recognises this as
--- our own teardown, then signals the process. Idempotent.
local function make_entry_methods(entry)
	function entry:intentional_close()
		if self._closed then
			return
		end
		self._closed = true
		-- Terminal transition first: fires MCPDetach, cancels any pending
		-- reconnect, and makes is_stopped() true immediately.
		self.reconnect:on_intentional_close()

		local job = self._job
		if job then
			job.user_data = job.user_data or {}
			job.user_data.intentional_close = true
			-- plenary.job sets `self.pid` to the numeric pid once the process
			-- starts, which shadows the `Job:pid()` method of the same name
			-- (calling `job:pid()` then errors with "attempt to call a number
			-- value"). Read the field directly, falling back to the method only
			-- if the field is not a number (e.g. before start / a test double).
			local pid = job.pid
			if type(pid) ~= "number" then
				local ok, resolved = pcall(function()
					return job:pid()
				end)
				pid = ok and resolved or nil
			end
			if type(pid) == "number" then
				pcall(vim.uv.kill, pid, "sigterm")
			end
		end
		-- Also close the transport object (idempotent; no-op if already down).
		if self.transport_client and self.transport_client.close then
			pcall(function()
				self.transport_client:close()
			end)
		end
	end
end

--- Connect to a hub and register a managed client. Mirrors init.connect's
--- config/opts split, but returns the richer, reconnecting client object.
---
--- @param config table  url, name, client_version, capabilities, headers,
---   timeout, and an optional `reconnect` sub-table (initial_delay,
---   max_delay, growth_factor, max_attempts) forwarded to the machine.
--- @param opts table  on_connect(client|nil, err|nil)
function M.connect(config, opts)
	assert(type(config) == "table", "config table is required")
	assert(type(config.url) == "string" and config.url ~= "", "config.url is required")
	opts = opts or {}
	assert(type(opts.on_connect) == "function", "opts.on_connect is required")

	-- R12 fail-closed gate: before opening ANY connection, refuse a
	-- non-localhost hub that lacks TLS (https://) or a configured credential.
	-- A configured token is surfaced as an Authorization header in
	-- config.headers (token_store.apply_to_headers puts it there); its presence
	-- is the "auth is configured" signal. A localhost hub is exempt entirely.
	-- This must run before detect.connect so we never emit an unauthenticated
	-- request to a non-localhost hub.
	local allowed, refusal = tls.check_connection_allowed(config.url, {
		has_token = config.headers ~= nil and config.headers["Authorization"] ~= nil,
	})
	if not allowed then
		return opts.on_connect(nil, refusal)
	end

	detect.connect({
		url = config.url,
		request = build_initialize_request(config),
		headers = config.headers,
		timeout = config.timeout,
	}, function(result, err)
		if err then
			return opts.on_connect(nil, err)
		end

		local id = new_id()
		local entry = {
			id = id,
			name = config.name or id,
			config = config,
			transport = result.transport,
			transport_client = result.client,
			_in_flight = {},
			_closed = false,
		}

		-- Caller-supplied tuning (initial_delay/max_delay/growth_factor/
		-- max_attempts) is merged *under* the internal wiring, so a caller can
		-- never accidentally clobber the schedule/attempt/event callbacks by
		-- putting same-named keys in their `reconnect` table.
		entry.reconnect = Reconnect.new(vim.tbl_extend("force", config.reconnect or {}, {
			schedule = function(delay_ms, fn)
				local timer = vim.uv.new_timer()
				timer:start(delay_ms, 0, function()
					timer:stop()
					timer:close()
					vim.schedule(fn)
				end)
				return timer
			end,
			cancel = function(timer)
				if timer and not timer:is_closing() then
					timer:stop()
					timer:close()
				end
			end,
			attempt = function()
				attempt_reconnect(entry)
			end,
			on_connected = function()
				fire_event("MCPAttach", id)
			end,
			on_disconnected = function()
				fail_in_flight(entry, "client disconnected: reconnect attempts exhausted")
				fire_event("MCPDetach", id)
			end,
		}))

		entry.session = Session.new({
			transport = result.client,
			session_id = result.session_id,
			protocol_version = PROTOCOL_VERSION,
			reinitialize = make_reinitializer(entry),
		})

		make_entry_methods(entry)
		hook_stream_job(entry, result.client)
		hook_notifications(entry, result.client)

		local client_object = make_client_object(entry)
		entry.object = client_object
		registry[id] = entry

		-- Initial connect is a transition into `connected`; fire MCPAttach.
		fire_event("MCPAttach", id)

		opts.on_connect(client_object, nil)
	end)
end

--- Register a non-remote (e.g. native, in-process) client object into the
--- exact same registry `get_clients()` reads from, so `M.connect`-built remote
--- clients and any other registration entry point are indistinguishable to a
--- caller of `get_clients()`. This is the one small hook a non-remote
--- registrant (native.lua, U3) needs: the registry itself is module-local and
--- otherwise only ever written to by `M.connect`.
---
--- @param client_object table  a fully-built client object already shaped
---   like `Client` (`id`, `name`, `is_stopped()`, `request`, `notify`, and
---   optionally `disconnect()`). If `client_object.id` is nil, a fresh id is
---   assigned and set on the object.
--- @return table the same `client_object`, registered.
function M.register_native(client_object)
	assert(type(client_object) == "table", "client_object table is required")
	if client_object.id == nil then
		client_object.id = new_id()
	end
	registry[client_object.id] = {
		id = client_object.id,
		name = client_object.name,
		object = client_object,
		-- `_reset_registry` calls `entry:intentional_close()` unconditionally
		-- on every registered entry; a native entry has no transport/job to
		-- tear down, so route it through the object's own `disconnect()` (a
		-- no-op-safe method every client object -- native or remote -- must
		-- expose) instead of assuming remote-only teardown internals.
		intentional_close = function(self)
			if client_object.disconnect then
				client_object:disconnect()
			end
		end,
	}
	return client_object
end

--- Return the currently-registered client objects, optionally filtered.
--- @param filter table|nil  { id = string } and/or { name = string }
--- @return Client[] list of matching client objects
function M.get_clients(filter)
	filter = filter or {}
	local out = {}
	for _, entry in pairs(registry) do
		local ok = true
		if filter.id ~= nil and entry.id ~= filter.id then
			ok = false
		end
		if filter.name ~= nil and entry.name ~= filter.name then
			ok = false
		end
		if ok then
			table.insert(out, entry.object)
		end
	end
	return out
end

--- Test-only: clear the registry between specs so state does not leak.
--- Deliberately does *not* reset `next_id`: ids stay globally monotonic so a
--- deferred autocmd from a torn-down client can never collide with a
--- freshly-registered one in the following spec.
function M._reset_registry()
	for id, entry in pairs(registry) do
		pcall(function()
			entry:intentional_close()
		end)
		registry[id] = nil
	end
end

return M
