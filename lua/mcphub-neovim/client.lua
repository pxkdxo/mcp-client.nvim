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
local token_store = require("mcphub-neovim.auth.token_store")
local refresh = require("mcphub-neovim.auth.refresh")
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
			-- MCP requires `capabilities` to be a JSON *object*. An empty Lua
			-- table `{}` serializes to a JSON *array* `[]` via vim.json.encode,
			-- which a strict real hub (e.g. ravitemer/mcp-hub) rejects with HTTP
			-- 400 "Invalid message". Use vim.empty_dict() so the empty case
			-- serializes as `{}`. (Local test doubles echo regardless of shape,
			-- so this only bites against a real hub -- surfaced by U9.)
			capabilities = config.capabilities or vim.empty_dict(),
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

--- Close a transport client intentionally: tag its long-lived stream Job with
--- the intentional-close flag *before* closing so the exit hook we registered on
--- it (hook_stream_job) recognises the resulting stream-end as our own teardown
--- and does NOT drive on_drop. Without the tag, closing a transport whose exit
--- hook is still registered -- e.g. an intermediate, adopted-then-superseded
--- transport being reaped by a later adoption -- would spuriously fire on_drop
--- against a client that has already moved on to a different transport. Swallows
--- any error; a no-op when the client is nil or exposes no close.
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

--- Adopt a freshly-handshaken transport into `entry` -- the entry-state
--- mutation that must happen EXACTLY ONCE per resolved handshake, even when
--- several triggers coalesced onto it (see perform_handshake). Sets the live
--- transport fields and (re-)registers the stream-exit and notification hooks
--- on the new transport. Calling hook_stream_job twice against the same result
--- would double-register the exit hook, so this is deliberately the single
--- adoption point both handshake-driven paths share.
---
--- Before installing the new transport it CLOSES the one it replaces (when
--- distinct). A successful new handshake always abandons the previous transport,
--- so this is the point that guarantees the old one is not leaked. In the normal
--- reconnect case the previous transport's stream already exited, so close() is a
--- harmless no-op; the case that matters is the intermediate-timeout supersede
--- leak: a reconnect attempt that timed out mid-backoff can still have its dial
--- resolve late and get adopted (the client is non-terminal -- more bounded
--- attempts remain), and the machine's next attempt then adopts a DIFFERENT
--- transport in its place. Closing the replaced transport here reaps that
--- otherwise-leaked, still-live transport (and stops its stale stream-exit hook
--- from later firing on_drop against a client that has moved on).
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
--- Both handshake-dialing paths -- the reconnect path (attempt_reconnect,
--- driven by an unexpected stream drop) and the session-reinitialize path
--- (make_reinitializer, driven by a session-scoped 404) -- go through here
--- rather than calling detect.connect directly. A real hub restart fires both
--- at once (the restart both kills the legacy SSE GET stream Job AND makes the
--- next request 404), so without coordination they would open two independent
--- handshakes against the same entry: whichever resolved last would silently
--- win and the loser's freshly-opened transport would leak.
---
--- Single-flight per entry (the same shape U7 uses for token refresh):
---   * `entry._handshake` is a list of waiter callbacks while a dial is in
---     flight, and nil when idle. Its non-nil-ness is the in-flight flag.
---   * The FIRST caller seeds the queue with its own `on_settled` and dispatches
---     the one physical detect.connect. Any caller that arrives while a dial is
---     in flight simply JOINS the queue -- it never starts a second dial.
---   * When the single dial resolves, the queue is captured and cleared (so a
---     *later* trigger can start a fresh cycle), the entry-state mutation is
---     applied EXACTLY ONCE via adopt_transport (not once per waiter), and then
---     every waiter is notified with the same `(result, err)` so each can run
---     its own path-specific follow-up (reconnect: on_connected; reinitialize:
---     hand `{transport, session_id}` back to session.lua's _adopt).
---
--- Superseded/orphaned cleanup: if the entry was intentionally closed while the
--- dial was in flight, a now-irrelevant successful handshake is CLOSED rather
--- than adopted or leaked, and its waiters are notified with an error so none
--- adopts it -- mirroring attempt_reconnect's original timeout-vs-late-success
--- guard, generalized to the close case.
---
--- Race-safety within Lua's single-threaded, cooperative model: the
--- check-and-set of `entry._handshake` is synchronous and completes before
--- detect.connect yields (it is an async curl call), so no second trigger can
--- slip past the flag between the check and the dispatch.
---
--- Returns the generation number of the dial this call started-or-joined, so a
--- caller with its own timeout guard (attempt_reconnect) can later check whether
--- that specific dial is still the current one -- i.e. whether it should actively
--- abandon a still-in-flight (wedged) dial on timeout, or leave it alone because a
--- newer dial has already superseded it (meaning this one already resolved via the
--- normal path). A coalesced waiter joining an in-flight dial gets that dial's
--- generation; the first caller that dispatches a dial gets the fresh generation it
--- just claimed.
local function perform_handshake(entry, on_settled)
	if entry._handshake then
		-- A dial is already in flight: join it, do NOT start a second one. A
		-- coalesced waiter shares the in-flight dial's generation implicitly (it
		-- never starts its own), so it always sees that one dial's single adopted
		-- result -- it is NOT a superseded, later dial.
		table.insert(entry._handshake, on_settled)
		return entry._handshake_gen
	end

	-- Each call that actually STARTS a dial (as opposed to joining one as a
	-- waiter above) claims a fresh monotonic generation. This lets a dial detect,
	-- when it resolves, whether a NEWER dial has since started -- i.e. whether its
	-- own caller already gave up on it and moved on -- so a stale late result is
	-- closed rather than adopted. (Coalesced waiters do not bump this: they join
	-- the one dial and are not a distinct, superseding cycle.)
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
			-- Superseded if the client became terminal while this dial was in
			-- flight -- either an explicit caller disconnect (`_closed`) or the
			-- reconnect machine exhausting its bounded attempts to `disconnected`.
			-- In both cases no handshake result may be adopted (adopting into a
			-- terminal client would resurrect a torn-down connection). Close the
			-- now-orphaned transport rather than leak it, and fail every waiter so
			-- none adopts it -- generalizing attempt_reconnect's original
			-- timeout-vs-late-success cleanup to the terminal-client case.
			local terminal = entry._closed or entry.reconnect:state() == "disconnected"
			-- Superseded if a NEWER dial has already started since this one (my_gen
			-- is no longer the current generation). This catches the ordering where
			-- this dial's own attempt timed out, the machine started a fresh dial,
			-- and only THEN did this one resolve: its result is stale -- a different,
			-- later dial owns the connection now -- so close it instead of adopting.
			-- A coalesced waiter is unaffected: it never started its own dial, so it
			-- is never the one whose generation went stale here.
			local stale = my_gen ~= entry._handshake_gen
			if terminal or stale then
				close_transport(result.client)
				err = "client is closed"
				result = nil
			else
				-- Apply the shared entry-state mutation exactly once, before any
				-- waiter's path-specific follow-up runs. adopt_transport also closes
				-- the transport it replaces, reaping an intermediate, already-adopted
				-- result that this later dial supersedes.
				adopt_transport(entry, result)
			end
		end

		for _, waiter in ipairs(waiters) do
			waiter(result, err)
		end
	end)

	-- Report back the generation of the dial this call dispatched, so a caller
	-- with its own timeout guard can later tell whether this specific dial is
	-- still current (and thus a wedged one it should abandon) or has already been
	-- superseded by a newer dial.
	return my_gen
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
---
--- The timeout does more than count the attempt: if the underlying detect.connect
--- dial genuinely never calls back (the pathological hangs-the-handshake hub), the
--- single-flight slot (entry._handshake) would otherwise stay populated FOREVER --
--- every future reconnect attempt or reinitialize would just JOIN the same dead
--- waiter list instead of dialing fresh, and any caller that coalesced onto the
--- wedged dial would hang indefinitely. So on timeout we actively ABANDON the
--- wedged dial (see abandon_wedged_dial below), but only if it is still the dial
--- this attempt is waiting on -- if a newer dial has since superseded it, it
--- already resolved via the normal path and needs no intervention.
local ATTEMPT_TIMEOUT_MS = 10000

--- Actively abandon a wedged (never-resolving) handshake dial of generation `gen`,
--- called from attempt_reconnect's guard timeout when that dial is still the
--- current one. Frees the single-flight slot so the next attempt/reinitialize
--- dials fresh, and notifies every coalesced waiter with a clear timeout error so
--- none hangs. Bumping the generation makes the abandoned dial's own late result
--- (if detect.connect ever DOES call back) fail perform_handshake's staleness
--- check, so it is closed via close_transport rather than adopted -- reusing the
--- exact mechanism round 2 built for the "resolves after a newer dial started"
--- ordering, now reachable via an explicit abandon too.
---
--- Fully synchronous: under Lua's cooperative model the whole capture/clear/bump
--- sequence completes before yielding, so nothing can interleave between "still the
--- current dial?" and the abandon.
local function abandon_wedged_dial(entry, gen)
	-- Only abandon if this is still the current, in-flight dial. If a newer dial
	-- has since started (generation moved on), this one already resolved via the
	-- normal path before the guard fired -- a harmless near-simultaneous race that
	-- perform_handshake already handled; touching entry._handshake now would
	-- corrupt the newer dial's waiter list.
	if not entry._handshake or entry._handshake_gen ~= gen then
		return
	end
	-- Capture and clear the waiter list, freeing the slot for a fresh dial.
	local waiters = entry._handshake
	entry._handshake = nil
	-- Bump the generation so the abandoned dial's late result (should it ever
	-- arrive) is recognized as stale by perform_handshake and closed, not adopted.
	entry._handshake_gen = (entry._handshake_gen or 0) + 1
	-- Notify every coalesced waiter with a clear, stage-labeled timeout error so a
	-- reinitialize (or a second reconnect attempt) that joined this wedged dial is
	-- resolved promptly rather than depending on the reconnect machine's eventual
	-- exhaustion to incidentally save it.
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

	-- The generation of the dial this attempt started-or-joined via
	-- perform_handshake, captured below. The guard uses it to tell whether a
	-- timed-out dial is still current (wedged -> abandon it) or already superseded.
	local my_gen

	local guard = vim.uv.new_timer()
	guard:start(entry.config.attempt_timeout or ATTEMPT_TIMEOUT_MS, 0, function()
		guard:stop()
		guard:close()
		vim.schedule(function()
			settle(function()
				-- Actively free a still-wedged dial before counting the attempt, so
				-- the slot is available for the next attempt/reinitialize to dial
				-- fresh and any coalesced waiter is notified rather than stranded.
				abandon_wedged_dial(entry, my_gen)
				-- Unchanged: a per-attempt timeout is always a failed attempt for the
				-- machine's bookkeeping -- schedule the next one or exhaust.
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
			-- The per-attempt timeout already counted this attempt as failed and
			-- drove the machine (another attempt, or exhaustion). We must NOT run
			-- the success follow-up (on_connected) now. Crucially we also do NOT
			-- close result.client here: perform_handshake is the single owner of
			-- the handshake result's lifecycle -- it has either already adopted a
			-- non-terminal success as the entry's live transport (which a coalesced
			-- reinitialize waiter still legitimately uses -- closing it would sever
			-- a live connection) or already closed a terminal/superseded one. So
			-- there is nothing orphaned for this waiter to clean up.
			return
		end
		settle(function()
			if err then
				-- Attempt failed; let the machine count it and decide.
				entry.reconnect:on_drop()
				return
			end
			-- adopt_transport (transport_client/transport/hook_stream_job/
			-- hook_notifications) already ran exactly once in perform_handshake.
			-- Only the reconnect-specific follow-up remains: converge the session
			-- onto the new transport and tell the machine we are connected again.
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
--- via `entry.config.reinit_timeout` -- a dedicated key, deliberately not
--- `attempt_timeout`, which is attempt_reconnect's own per-attempt knob; the
--- two are semantically distinct paths and must not share one config value).
---
--- Without this guard, a 404-triggered reinitialize that is the sole trigger
--- on `entry._handshake` (no concurrent reconnect attempt in flight to
--- contribute attempt_reconnect's own guard) has no timeout anywhere in its
--- call chain: if the underlying detect.connect dial wedges (a hub that
--- accepts the connection but never completes or cleanly fails the
--- handshake), `on_done` -- and therefore the original request's callback --
--- would hang forever, an unconditional R11 violation. This is a structural
--- copy of attempt_reconnect's guard/settle/dispatch shape, deliberately
--- duplicated rather than shared: attempt_reconnect's own logic has survived
--- three independent adversarial review rounds and is pinned by the existing
--- race tests, so this guard is kept entirely outside perform_handshake and
--- attempt_reconnect, touching zero lines of that three-times-fragile
--- mechanism.
---
--- Divergence from attempt_reconnect's guard that must be preserved: on
--- timeout this calls `on_done(err, nil)` directly and does NOT call
--- `entry.reconnect:on_drop()` -- a 404-reinitialize is session-scoped, not
--- connection-scoped (see the docstring above), so it must never perturb the
--- reconnect machine's state or attempt counter.
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
					-- Actively free a still-wedged dial (see abandon_wedged_dial), so
					-- the slot is available for a future attempt/reinitialize to dial
					-- fresh and any coalesced waiter is notified rather than stranded.
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
--- transparently at most once if it has expired -- the token-refresh analogue of
--- session.lua's single 404-reinitialize retry, one layer up.
---
--- With no `config.auth.token_store` configured (`entry._token_store` nil), this
--- is a zero-overhead pass-through: it invokes `proceed()` immediately, so every
--- non-OAuth client behaves exactly as before this wiring existed.
---
--- When a store IS configured and its access token is expired, it runs the
--- refresh-token grant EXACTLY once:
---   * success -> persist the (possibly rotated) token, mutate the shared
---     config.headers table in place via token_store.apply_to_headers (the same
---     mechanism the transports read on their next request), then `proceed()`;
---   * failure -> surface the refresh error to `on_error(err)` and DO NOT send
---     the request, so a revoked refresh token yields a terminal
---     "re-authentication required" error rather than an unbounded retry.
--- It never loops: exactly one refresh attempt per request, and the refresh
--- error string (from refresh.lua) is already secret-free.
---
--- Single-flight coalescing (keyed per connection `entry`). When several requests
--- are issued concurrently against the same client while its token is expired --
--- which happens in practice: an adapter's resource fan-out (codecompanion.lua)
--- fires a tight loop of `request(...)` calls without awaiting each callback, so
--- every one independently observes `status().expired == true` before any refresh
--- has completed -- only the FIRST starts a `refresh.refresh(...)` grant. The rest
--- queue their `(proceed, on_error)` pair onto `entry._refresh_waiters` and are
--- resolved together when that single in-flight grant settles. This is essential
--- because OAuth refresh tokens rotate: firing N concurrent grants would let the
--- first rotate the token and leave the other N-1 presenting an already-stale
--- refresh token, which the AS's reuse-detection rejects with `invalid_grant` --
--- spuriously forcing most of the batch into re-authentication even though a
--- sibling refreshed successfully. Coalescing collapses the batch onto one grant.
---
--- Race-safety within Lua's single-threaded, cooperative model: the check-and-set
--- of the in-flight flag (`entry._refreshing`) is synchronous and completes before
--- `refresh.refresh` yields control (it is an async curl call), so no second
--- caller can slip past the flag between the check and the dispatch.
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
		-- Idempotency guard: a caller's callback must fire AT MOST ONCE, no
		-- matter how the request is resolved. Without this, a request whose
		-- callback was already invoked by fail_in_flight (reconnect exhausted to
		-- disconnected -> the whole _in_flight table is cleared and each entry
		-- fired with a disconnect error) could fire a SECOND time if a
		-- concurrently-pending session-reinitialize retry for the same original
		-- request later completes and calls settle again with a contradictory
		-- (now-successful) result. Guarding on the _in_flight bookkeeping table
		-- alone is insufficient: fail_in_flight clears that table, so the second
		-- settle sees `key already nil` yet would still call `callback`. This is
		-- the same "settled once" pattern attempt_reconnect uses internally.
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
		-- Register the GUARDED settle (not the raw callback) as the in-flight
		-- entry, so fail_in_flight resolves through the same idempotency guard:
		-- once it fires settle, a later reinitialize-retry settle for the same
		-- request is a no-op instead of a second, contradictory invocation.
		if key ~= nil then
			entry._in_flight[key] = settle
		end
		-- Refresh an expired configured token transparently (at most once) before
		-- dispatching; with no token_store this is an immediate pass-through.
		ensure_fresh_token(entry, function()
			entry.session:request(rpc_message, settle)
		end, function(refresh_err)
			-- Refresh failed terminally: resolve the caller with a clear error
			-- instead of sending a request we know is unauthenticated.
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

	-- Optional OAuth identity: a TokenStore the client consults and updates. When
	-- configured, seed the shared config.headers table with the currently-stored
	-- bearer so the initialize handshake, the R12 gate below, and every request
	-- see it. (config.headers is the one table threaded verbatim into every
	-- transport (re)construction, so mutating it in place keeps auth current
	-- across reconnects -- the same mechanism a later refresh reuses.)
	local store = config.auth and config.auth.token_store or nil
	if store then
		config.headers = config.headers or {}
		token_store.apply_to_headers(config.headers, store:load())
	end

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
