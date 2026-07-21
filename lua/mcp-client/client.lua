--- The client layer: composes the transport, the session id/protocol-version
--- + 404-reinitialize lifecycle (session.lua), and the bounded-backoff
--- reconnect machine (reconnect.lua) into the public, Neovim-native API this
--- plugin exposes -- `get_clients(filter)` plus a client object with `id`,
--- `name`, `config`, `is_stopped()`, `request`/`notify`, and `disconnect()`
--- -- and fires the `MCPAttach`/`MCPDetach`/`MCPNotify` `User` autocmds.
---
--- Distinguishing an intentional close (our own reconnect teardown, or a
--- caller disconnect) from a real stream drop is correctness-critical: both
--- surface identically as the long-lived curl GET Job serving the legacy SSE
--- stream exiting. We tag our own kills with `job.user_data.intentional_close
--- = true` *before* signalling the process, and the exit handler (attached
--- via `job:add_on_exit_callback`) checks that flag first. If it is set, the
--- exit is expected and no reconnect is scheduled; only an untagged exit
--- drives the reconnect path.

local detect = require("mcp-client.transport.detect")
local tls = require("mcp-client.transport.tls")
local token_store = require("mcp-client.auth.token_store")
local refresh = require("mcp-client.auth.refresh")
local Session = require("mcp-client.session")
local Reconnect = require("mcp-client.reconnect")

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
			-- MCP requires `capabilities` to be a JSON *object*. An empty Lua
			-- table `{}` serializes to a JSON *array* `[]` via vim.json.encode,
			-- which a strict server rejects with HTTP 400 "Invalid message".
			-- vim.empty_dict() forces the empty case to serialize as `{}`.
			capabilities = config.capabilities or vim.empty_dict(),
			clientInfo = {
				name = config.name or "mcp-client",
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
--- @field config table  a live-computed, read-only snapshot of the connection
---   config (url, name, timeout, reconnect, ...); `headers` is a redacted
---   copy with any credential-bearing header (e.g. Authorization) replaced by
---   a fixed placeholder -- see build_exposed_config. Never the real secret.
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
		-- An intentional close (our reconnect teardown or a caller disconnect)
		-- tagged this job before killing it, so this exit is expected -- never
		-- reconnect.
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
--- forever. Called on the transition into `disconnected`.
local function fail_in_flight(entry, message)
	local pending = entry._in_flight
	entry._in_flight = {}
	for _, cb in pairs(pending) do
		pcall(cb, message, nil, nil)
	end
end

--- Close a transport client intentionally: tag its stream Job with the
--- intentional-close flag *before* closing, so the exit hook registered on it
--- (hook_stream_job) recognises the resulting stream-end as our own teardown
--- and does not drive on_drop. Swallows any error; a no-op when the client is
--- nil or exposes no close.
local function close_transport(transport_client)
	if not transport_client then
		return
	end
	local ok, job = pcall(function()
		return transport_client.get_stream_job and transport_client:get_stream_job()
	end)
	if ok and job then
		job.user_data = job.user_data or {}
		job.user_data.intentional_close = true
	end
	if transport_client.close then
		pcall(function()
			transport_client:close()
		end)
	end
end

--- Adopt a freshly-handshaken transport into `entry`: the entry-state mutation
--- that must happen exactly once per resolved handshake, even when several
--- triggers coalesced onto it (see perform_handshake). Sets the live transport
--- fields and (re-)registers the stream-exit and notification hooks on the new
--- transport; this is the single adoption point both handshake-driven paths
--- share, so the exit hook is never double-registered.
---
--- Closes the transport it replaces (when distinct) before installing the new
--- one, so a reconnect attempt that timed out but later resolves late and gets
--- superseded by a newer attempt does not leak its transport or leave a stale
--- stream-exit hook that could fire on_drop against a client that has moved on.
local function adopt_transport(entry, result)
	local previous = entry.transport_client
	if previous ~= nil and previous ~= result.client then
		close_transport(previous)
	end
	entry.transport_client = result.client
	entry.transport = result.transport
	hook_stream_job(entry, result.client)
	hook_notifications(entry, result.client)
end

--- Coalesce concurrent transport-handshake dials against a single `entry`.
---
--- Both handshake-dialing paths -- reconnect (attempt_reconnect, driven by an
--- unexpected stream drop) and session-reinitialize (make_reinitializer,
--- driven by a session-scoped 404) -- go through here rather than calling
--- detect.connect directly. A server restart can trigger both at once (it
--- kills the legacy SSE stream Job and also 404s the next request), and
--- without coordination they would race two independent handshakes against
--- the same entry, leaking whichever transport lost.
---
--- Single-flight per entry: `entry._handshake` is a list of waiter callbacks
--- while a dial is in flight, nil when idle. The first caller dispatches the
--- one physical detect.connect; any caller that arrives while it is in flight
--- joins the queue instead of starting a second dial. When the dial resolves,
--- the queue is captured and cleared, adopt_transport is applied exactly once,
--- and every waiter is notified with the same `(result, err)` to run its own
--- follow-up (reconnect: on_connected; reinitialize: hand `{transport,
--- session_id}` back to session.lua's _adopt).
---
--- A successful result is superseded -- closed rather than adopted -- if the
--- client became terminal while the dial was in flight (explicit disconnect,
--- or the reconnect machine exhausting to `disconnected`), or if a newer dial
--- has since started for this entry (this one resolved late, after being
--- effectively abandoned). Every waiter in that case is notified with an
--- error instead.
---
--- Returns the generation number of the dial this call started or joined, so
--- a caller with its own timeout guard (attempt_reconnect) can later tell
--- whether that dial is still current -- and thus a wedged dial it should
--- actively abandon -- or already superseded.
local function perform_handshake(entry, on_settled)
	if entry._handshake then
		table.insert(entry._handshake, on_settled)
		return entry._handshake_gen
	end

	-- Each dispatched dial claims a fresh monotonic generation, so a result
	-- that resolves after a newer dial has started (my_gen no longer current)
	-- is recognized as stale and closed rather than adopted.
	entry._handshake_gen = (entry._handshake_gen or 0) + 1
	local my_gen = entry._handshake_gen
	entry._handshake = { on_settled }

	detect.connect({
		url = entry.config.url,
		request = build_initialize_request(entry.config),
		headers = entry.config.headers,
		timeout = entry.config.timeout,
	}, function(result, err)
		-- Capture and clear the queue first so a follow-up trigger fired from a
		-- waiter's callback starts a fresh cycle rather than joining this one.
		local waiters = entry._handshake or {}
		entry._handshake = nil

		if not err and result then
			local terminal = entry._closed or entry.reconnect:state() == "disconnected"
			local stale = my_gen ~= entry._handshake_gen
			if terminal or stale then
				close_transport(result.client)
				err = "client is closed"
				result = nil
			else
				adopt_transport(entry, result)
			end
		end

		for _, waiter in ipairs(waiters) do
			waiter(result, err)
		end
	end)

	return my_gen
end

--- Perform one reconnection attempt: a fresh transport handshake. On
--- success, adopt the new transport, re-hook its stream Job, and tell the
--- reconnect machine we are connected again (which fires MCPAttach). On
--- failure, feed the failure back into the machine as another drop so it
--- either schedules the next bounded attempt or exhausts to disconnected.
---
--- The attempt is bounded by a timeout: a server that accepts the connection
--- but never completes the handshake would otherwise leave detect.connect
--- pending forever, wedging the machine in `reconnecting`. On timeout we
--- count the attempt as failed AND actively abandon the wedged dial (see
--- abandon_wedged_dial) so the single-flight slot does not stay stuck
--- forever -- otherwise every later attempt/reinitialize would just join the
--- same dead waiter list and hang too.
local ATTEMPT_TIMEOUT_MS = 10000

--- Actively abandon a wedged (never-resolving) handshake dial of generation
--- `gen`, called from a guard timeout when that dial is still current. Frees
--- the single-flight slot so the next dial starts fresh, notifies every
--- coalesced waiter with a timeout error, and bumps the generation so that if
--- the abandoned dial's result ever does arrive, perform_handshake treats it
--- as stale and closes it instead of adopting it.
local function abandon_wedged_dial(entry, gen)
	-- If a newer dial has since started, this one already resolved via the
	-- normal path before the guard fired; leave entry._handshake alone.
	if not entry._handshake or entry._handshake_gen ~= gen then
		return
	end
	local waiters = entry._handshake
	entry._handshake = nil
	entry._handshake_gen = (entry._handshake_gen or 0) + 1
	for _, waiter in ipairs(waiters) do
		waiter(nil, "handshake attempt timed out")
	end
end

local function attempt_reconnect(entry)
	local settled = false
	local function settle(fn)
		if settled then
			return
		end
		settled = true
		fn()
	end

	-- Generation of the dial this attempt started or joined, so the guard below
	-- can tell whether a timed-out dial is still current (abandon it) or
	-- already superseded.
	local my_gen

	local guard = vim.uv.new_timer()
	guard:start(entry.config.attempt_timeout or ATTEMPT_TIMEOUT_MS, 0, function()
		guard:stop()
		guard:close()
		vim.schedule(function()
			settle(function()
				abandon_wedged_dial(entry, my_gen)
				entry.reconnect:on_drop()
			end)
		end)
	end)

	my_gen = perform_handshake(entry, function(result, err)
		if not guard:is_closing() then
			guard:stop()
			guard:close()
		end
		if settled then
			-- The guard already counted this attempt as failed and drove the
			-- machine. perform_handshake owns the result's lifecycle either way
			-- (adopted if non-terminal, closed if terminal/superseded), so there
			-- is nothing left for this waiter to do.
			return
		end
		settle(function()
			if err then
				entry.reconnect:on_drop()
				return
			end
			-- adopt_transport already ran in perform_handshake; converge the
			-- session onto the new transport and tell the machine we are
			-- connected again.
			entry.session.transport = result.client
			if result.session_id then
				entry.session.session_id = result.session_id
			end
			entry.reconnect:on_connected()
		end)
	end)
end

--- Build the reinitialize handler the session unit calls on a 404: a fresh
--- handshake yielding a new transport + session id, without disturbing the
--- reconnect machine (a 404 is a session-level, not a connection-level,
--- event).
---
--- Bounded by its own guard timeout (default ATTEMPT_TIMEOUT_MS, overridable
--- via `entry.config.reinit_timeout`, a key distinct from attempt_reconnect's
--- `attempt_timeout`): a reinitialize with no concurrent reconnect attempt in
--- flight has no other timeout in its call chain, so a wedged dial would
--- otherwise hang `on_done` -- and the original request's callback -- forever.
---
--- On timeout this calls `on_done(err, nil)` directly and does NOT call
--- `entry.reconnect:on_drop()`: a 404-reinitialize is session-scoped, not
--- connection-scoped, so it must never perturb the reconnect machine's state
--- or attempt counter.
local function make_reinitializer(entry)
	return function(on_done)
		local settled = false
		local function settle(fn)
			if settled then
				return
			end
			settled = true
			fn()
		end

		local my_gen
		local guard = vim.uv.new_timer()
		guard:start(entry.config.reinit_timeout or ATTEMPT_TIMEOUT_MS, 0, function()
			guard:stop()
			guard:close()
			vim.schedule(function()
				settle(function()
					abandon_wedged_dial(entry, my_gen)
					on_done("handshake attempt timed out", nil)
				end)
			end)
		end)

		my_gen = perform_handshake(entry, function(result, err)
			if not guard:is_closing() then
				guard:stop()
				guard:close()
			end
			if settled then
				-- The guard already timed out and resolved on_done; perform_handshake
				-- is the single owner of the handshake result's lifecycle, so there is
				-- nothing orphaned for this waiter to clean up here.
				return
			end
			settle(function()
				if err then
					return on_done(err, nil)
				end
				-- adopt_transport already ran exactly once in perform_handshake; the
				-- reinitialize-specific follow-up is to hand the new transport/session
				-- id back to session.lua's _adopt.
				on_done(nil, {
					transport = result.client,
					session_id = result.session_id,
				})
			end)
		end)
	end
end

--- Ensure the configured token is fresh before a request goes out, refreshing
--- transparently at most once if it has expired. With no `config.auth.token_store`
--- configured, this is a zero-overhead pass-through to `proceed()`.
---
--- When a store is configured and its access token is expired, it runs the
--- refresh-token grant exactly once: on success it persists the (possibly
--- rotated) token, mutates the shared `config.headers` table in place via
--- `token_store.apply_to_headers`, then calls `proceed()`; on failure it
--- surfaces the error to `on_error(err)` without sending the request, so a
--- revoked refresh token yields a terminal error rather than an unbounded retry.
---
--- Single-flight coalescing, keyed per connection `entry`: concurrent requests
--- that all observe an expired token before any refresh completes queue onto
--- `entry._refresh_waiters` and are resolved together by the one in-flight
--- grant. This matters because OAuth refresh tokens rotate -- firing N
--- concurrent grants would let the first rotate the token and leave the rest
--- presenting a now-stale refresh token, which the auth server's
--- reuse-detection rejects with `invalid_grant`.
local function ensure_fresh_token(entry, proceed, on_error)
	local store = entry._token_store
	if not store then
		return proceed()
	end
	local status = store:status()
	if not status.has_token or not status.expired then
		-- No stored token, or it is still valid: nothing to refresh.
		return proceed()
	end

	-- A refresh is already in flight for this entry: join the queue and let the
	-- single in-flight grant resolve us. Do NOT start a second grant.
	if entry._refreshing then
		table.insert(entry._refresh_waiters, { proceed = proceed, on_error = on_error })
		return
	end

	-- We are the first: mark in flight and seed the queue with our own pair.
	entry._refreshing = true
	entry._refresh_waiters = { { proceed = proceed, on_error = on_error } }

	refresh.refresh(store:load(), function(new_token, err)
		-- Drain the ENTIRE queue (every joined caller, including the originator)
		-- with this single outcome, then clear the in-flight state so a *later*
		-- expiry can trigger a fresh single-flight cycle.
		local waiters = entry._refresh_waiters
		entry._refresh_waiters = {}
		entry._refreshing = false

		if err then
			-- Terminal for this batch: refresh failed (revoked token, network
			-- failure, or no refresh token). Surface it to every caller; never
			-- retry in a loop.
			for _, waiter in ipairs(waiters) do
				waiter.on_error(err)
			end
			return
		end

		-- Persist and reapply headers exactly once (the mutation is idempotent on
		-- the shared table, but there is no reason to repeat it per caller), then
		-- release every queued caller.
		store:save(new_token)
		-- Mutate the shared headers table in place so this request -- and every
		-- subsequent one, across reconnects -- carries the refreshed bearer.
		token_store.apply_to_headers(entry.config.headers, new_token)
		for _, waiter in ipairs(waiters) do
			waiter.proceed()
		end
	end)
end

--- Headers whose value is credential material and must never be exposed in
--- cleartext through the public client object.
local REDACTED_HEADER_KEYS = {
	["Authorization"] = true,
}

local REDACTED_PLACEHOLDER = "[redacted]"

--- Build a redacted copy of a headers table: every credential-bearing key
--- (REDACTED_HEADER_KEYS) is replaced with a fixed placeholder; every other
--- header is preserved verbatim so introspection/debugging still shows what
--- headers exist. Returns nil when given nil (no headers configured).
local function redact_headers(headers)
	if not headers then
		return nil
	end
	local out = {}
	for k, v in pairs(headers) do
		out[k] = REDACTED_HEADER_KEYS[k] and REDACTED_PLACEHOLDER or v
	end
	return out
end

--- Build the exposed `.config` snapshot for the public client object: a
--- shallow copy of `entry.config` with a freshly redacted copy of `headers`.
---
--- Computed on every access (via the metatable `__index` below) rather than
--- cached at construction time, because `entry.config.headers` is mutated in
--- place on every token refresh -- a cached snapshot would either go stale
--- or, if it captured the live table by reference, leak a token added later.
local function build_exposed_config(entry)
	local exposed = vim.tbl_extend("force", {}, entry.config)
	exposed.headers = redact_headers(entry.config.headers)
	return exposed
end

--- Construct the public client object exposed to callers, backed by a
--- registry `entry`.
local function make_client_object(entry)
	local obj = {
		id = entry.id,
		name = entry.name,
	}
	-- `transport` and `config` are read through a metatable so callers always
	-- see the current transport (after a transparent reconnect/reinitialize)
	-- and a freshly redacted config (after a transparent token refresh),
	-- rather than a value frozen at construction time.
	setmetatable(obj, {
		__index = function(_, key)
			if key == "transport" then
				return entry.transport
			end
			if key == "config" then
				return build_exposed_config(entry)
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
		-- The caller's callback must fire at most once. fail_in_flight can settle
		-- this request with a disconnect error while a concurrently-pending
		-- reinitialize retry for the same request later resolves too; guarding on
		-- _in_flight alone is not enough since fail_in_flight already cleared it.
		local resolved = false
		local function settle(err, result, response)
			if resolved then
				return
			end
			resolved = true
			if key ~= nil then
				entry._in_flight[key] = nil
			end
			callback(err, result, response)
		end
		-- Register the guarded settle (not the raw callback) so fail_in_flight
		-- also resolves through the same once-only guard.
		if key ~= nil then
			entry._in_flight[key] = settle
		end
		-- Refresh an expired configured token transparently (at most once) before
		-- dispatching; with no token_store this is an immediate pass-through.
		ensure_fresh_token(entry, function()
			entry.session:request(rpc_message, settle)
		end, function(refresh_err)
			settle(refresh_err, nil, nil)
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
			-- plenary.job sets `self.pid` to the numeric pid once started, which
			-- shadows the `Job:pid()` method of the same name (calling `job:pid()`
			-- then errors). Read the field directly, falling back to the method
			-- only if it is not yet a number (e.g. before start / a test double).
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

--- Dial the server and, on success, build and register the managed client entry.
--- Split out from `M.connect` so the caller can refresh a stored-but-expired
--- token first (see `M.connect` below) and only then run the actual dial --
--- by the time this runs, `store:load()` (if any) is assumed already current.
---
--- @param config table  see `M.connect`
--- @param opts table  on_connect(client|nil, err|nil)
--- @param store table|nil  the resolved TokenStore, already refreshed if it
---   was expired -- passed through rather than re-read from `config.auth` so
---   the refresh-then-dial sequencing in `M.connect` has exactly one place
---   that decides which store applies.
local function do_connect(config, opts, store)
	-- Seed the shared config.headers table with the currently-stored bearer so
	-- the initialize handshake, the TLS gate below, and every request see it.
	-- Mutating it in place keeps auth current across reconnects.
	if store then
		config.headers = config.headers or {}
		token_store.apply_to_headers(config.headers, store:load())
	end

	-- Fail-closed gate: before opening any connection, refuse a non-localhost
	-- server that lacks TLS (https://) or a configured credential. Must run
	-- before detect.connect so we never emit an unauthenticated request to a
	-- non-localhost server.
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
			-- The optional OAuth identity: when set, obj:request consults it to
			-- transparently refresh an expired token before dispatching.
			_token_store = store,
			-- Single-flight refresh coalescing state (see ensure_fresh_token):
			-- `_refreshing` is the in-flight flag; `_refresh_waiters` is the queue of
			-- `{ proceed, on_error }` pairs resolved together when that grant settles.
			_refreshing = false,
			_refresh_waiters = {},
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

--- Connect to a server and register a managed client. Mirrors init.connect's
--- config/opts split, but returns the richer, reconnecting client object.
---
--- @param config table  url, name, client_version, capabilities, headers,
---   timeout, an optional `reconnect` sub-table (initial_delay, max_delay,
---   growth_factor, max_attempts) forwarded to the machine, and an optional
---   `auth` sub-table `{ token_store = <TokenStore> }`: when present, the stored
---   bearer token is attached to every request and refreshed transparently on
---   expiry (see ensure_fresh_token). Consistent with how `headers`/`reconnect`
---   are optional sub-tables; absent it is the zero-overhead non-OAuth path.
--- @param opts table  on_connect(client|nil, err|nil)
function M.connect(config, opts)
	assert(type(config) == "table", "config table is required")
	assert(type(config.url) == "string" and config.url ~= "", "config.url is required")
	opts = opts or {}
	assert(type(opts.on_connect) == "function", "opts.on_connect is required")

	local store = config.auth and config.auth.token_store or nil

	-- Refresh a stored-but-expired token before dialing: dialing with an
	-- expired token as-is gets a 401 that surfaces as a bare, unrecoverable
	-- connect failure, even though the refresh token here would likely work.
	if store then
		local status = store:status()
		if status.has_token and status.expired then
			return refresh.refresh(store:load(), function(new_token, err)
				if err then
					return opts.on_connect(
						nil,
						string.format("stored token is expired and refresh failed: %s", tostring(err))
					)
				end
				store:save(new_token)
				do_connect(config, opts, store)
			end)
		end
	end

	do_connect(config, opts, store)
end

--- Register a non-remote (e.g. native, in-process) client object into the
--- exact same registry `get_clients()` reads from, so `M.connect`-built remote
--- clients and any other registration entry point are indistinguishable to a
--- caller of `get_clients()`.
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

--- Disconnect and clear every registered client. Used by tests between specs
--- so state does not leak, and by `config.setup()` so a repeated `setup()`
--- call replaces the prior client roster instead of accumulating duplicates
--- alongside it. Deliberately does *not* reset `next_id`: ids stay globally
--- monotonic so a deferred autocmd from a torn-down client can never collide
--- with a freshly-registered one afterward.
function M._reset_registry()
	for id, entry in pairs(registry) do
		pcall(function()
			entry:intentional_close()
		end)
		registry[id] = nil
	end
end

--- Fully remove one already-disconnected entry from the registry by id, so
--- `get_clients()` no longer returns it at all.
---
--- `intentional_close()`/`obj:disconnect()` alone deliberately leave a
--- stopped entry queryable -- see the doc comment above and
--- `_reset_registry` above it -- so a caller that disconnects and replaces a
--- single *named* client (rather than every client, like `_reset_registry`
--- does on a repeated `setup()`) needs this to avoid `get_clients({name=...})`
--- returning both the stale, already-disconnected entry and the freshly-
--- connected replacement -- which pick order between the two would be
--- undefined to a caller like `health.lua`'s `matches[1]`.
--- @param id string  a client id already disconnected via `:disconnect()`
function M._forget(id)
	registry[id] = nil
end

return M
