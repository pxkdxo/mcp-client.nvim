--- Client-layer concurrency specs (Task 15).
---
--- These exercise the two handshake-dialing paths -- `attempt_reconnect`
--- (stream-drop -> reconnect machine) and `make_reinitializer` (session 404 ->
--- session.lua) -- when they fire concurrently against the same client entry,
--- plus the request-settling double-invoke guard. Unlike client_spec.lua these
--- do NOT go over a real socket: they inject a fully controllable
--- `mcphub-neovim.transport.detect` double so a handshake can be held pending
--- and resolved deterministically, which is the only way to force the
--- otherwise timing-dependent race reproducibly.
---
--- The double is installed via `package.loaded` *before* the client module is
--- (re)loaded, so `client.lua`'s module-top `require("...detect")` binds to the
--- double rather than the real network transport.

--- A controllable transport-client double implementing the common transport
--- interface the client layer hooks (request/notify/close/get_stream_job/
--- set_on_notification/get_retry_hint). `request` routes to a per-instance
--- `responder(msg)` returning (err, result, response); if no responder is set
--- it never replies (a hung request), which we use to model an in-flight
--- request that outlives a reconnect exhaustion.
local function transport_double(opts)
	opts = opts or {}
	local self
	self = {
		label = opts.label,
		closed = false,
		hook_count = 0, -- how many times hook_stream_job registered an exit hook on us
		_exit_callbacks = {},
		_responder = opts.responder,
		set_responder = function(_, fn)
			self._responder = fn
		end,
		request = function(_, msg, cb)
			if self._responder then
				local err, result, response = self._responder(msg)
				if err ~= nil or result ~= nil or response ~= nil then
					return cb(err, result, response)
				end
				-- responder returned all-nil: model a request that never replies.
				return
			end
			-- No responder: never reply (a hung request).
		end,
		notify = function() end,
		close = function()
			self.closed = true
		end,
		-- A fake long-lived stream Job: hook_stream_job registers an exit hook
		-- here; we can fire it to model a stream drop.
		get_stream_job = function()
			return self._job
		end,
		set_on_notification = function() end,
		get_retry_hint = function()
			return nil
		end,
	}
	-- The job double: add_on_exit_callback appends; fire_exit invokes them.
	self._job = {
		user_data = {},
		_cbs = {},
		add_on_exit_callback = function(job, fn)
			self.hook_count = self.hook_count + 1
			table.insert(job._cbs, fn)
		end,
		pid = 12345,
	}
	self.fire_exit = function()
		for _, fn in ipairs(self._job._cbs) do
			fn(self._job)
		end
	end
	return self
end

describe("client concurrency (reconnect vs reinitialize race)", function()
	local detect_stub
	local client
	local saved_detect

	before_each(function()
		saved_detect = package.loaded["mcphub-neovim.transport.detect"]
		-- Build a fresh controllable detect stub per test.
		local pending = {}
		detect_stub = {
			dials = 0,
			pending = pending,
			connect = function(opts, on_done)
				detect_stub.dials = detect_stub.dials + 1
				table.insert(pending, { opts = opts, on_done = on_done })
			end,
			resolve = function(index, result, err)
				local p = pending[index]
				assert(p, "no pending dial at index " .. tostring(index))
				p.on_done(result, err)
			end,
			latest = function()
				return #pending
			end,
		}
		package.loaded["mcphub-neovim.transport.detect"] = detect_stub
		-- Reload the client so its module-top require binds to the stub.
		package.loaded["mcphub-neovim.client"] = nil
		client = require("mcphub-neovim.client")
	end)

	after_each(function()
		pcall(function()
			client._reset_registry()
		end)
		package.loaded["mcphub-neovim.client"] = nil
		package.loaded["mcphub-neovim.transport.detect"] = saved_detect
	end)

	--- Connect a client backed by a controllable initial transport. Returns the
	--- client object plus the initial transport double.
	local function connect_client(cfg)
		local initial = transport_double({ label = "initial" })
		local obj
		client.connect(
			vim.tbl_extend("force", { url = "http://127.0.0.1:1/mcp", name = "hub" }, cfg or {}),
			{
				on_connect = function(c)
					obj = c
				end,
			}
		)
		-- The initial connect is itself a handshake dial; resolve it with our
		-- controllable transport so the client is up.
		detect_stub.resolve(1, { transport = "legacy_sse", client = initial, session_id = "sess-1" })
		assert(obj, "client did not connect")
		return obj, initial
	end

	it("coalesces a concurrent reconnect + reinitialize onto a single handshake dial", function()
		-- A short reconnect backoff so the reconnect attempt's handshake dial
		-- fires within the same brief window as the reinitialize handshake --
		-- i.e. they are genuinely concurrent (the real hub-restart race), not
		-- serialized far apart by the default 1000ms backoff.
		local obj, initial = connect_client({ reconnect = { initial_delay = 5, max_attempts = 3 } })

		-- The initial connect consumed dial #1. Baseline the counter.
		local dials_after_connect = detect_stub.dials

		-- Trigger BOTH handshake paths close together, before either resolves:
		--   (1) reinitialize path: an in-flight request 404s -> session.lua ->
		--       make_reinitializer's dial.
		--   (2) reconnect path: the stream drops (untagged exit) -> on_drop ->
		--       reconnect machine schedules attempt_reconnect's dial.
		local reply
		initial:set_responder(function()
			return "hub returned status 404: session expired", nil, { status = 404 }
		end)
		obj:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
			reply = { err = err, result = result }
		end)

		-- Now fire the stream drop; on_drop + the reconnect schedule are deferred,
		-- so wait long enough for the (short-backoff) reconnect attempt to run.
		initial.fire_exit()
		vim.wait(150, function()
			-- Stop early only once a *second* new dial appears (the bug), so a
			-- correctly-coalescing implementation still waits the full window.
			return detect_stub.dials >= dials_after_connect + 2
		end)

		-- CORE ASSERTION: exactly ONE new handshake dial for the two concurrent
		-- triggers. Pre-fix this is 2 (reinit dial + reconnect dial racing
		-- independently); post-fix the second trigger coalesces onto the first.
		assert.are.equal(
			dials_after_connect + 1,
			detect_stub.dials,
			"concurrent reconnect + reinitialize must coalesce onto a single detect.connect dial"
		)

		-- Resolve the single coalesced handshake with a fresh transport.
		local fresh = transport_double({ label = "fresh" })
		fresh:set_responder(function()
			return nil, { pong = true }
		end)
		detect_stub.resolve(#detect_stub.pending, { transport = "legacy_sse", client = fresh, session_id = "sess-2" })
		vim.wait(100, function()
			return reply ~= nil
		end)

		-- The stream-exit hook was registered on the single fresh transport
		-- EXACTLY ONCE -- proving adopt_transport ran once for the coalesced
		-- result, not once per waiter (which would double-register the hook).
		assert.are.equal(
			1,
			fresh.hook_count,
			"stream-exit hook must be registered exactly once on the adopted transport"
		)
		-- No orphaned/leaked transport: the single adopted transport stays open
		-- (and there is no second transport, since there was only one dial).
		assert.is_false(fresh.closed, "the adopted transport must stay open")

		-- Consistent final state, observed behaviorally: the entry adopted `fresh`
		-- (both the session's transport, via _adopt, and the reconnect follow-up
		-- converged onto it), so the reinitialize retry of the original request
		-- ran against `fresh` and the caller saw its `pong` reply exactly once.
		assert.is_not_nil(reply, "the reinitialize retry must resolve the original request")
		assert.is_nil(reply.err)
		assert.are.same({ pong = true }, reply.result)

		-- And the client is back in the steady connected state (the reconnect
		-- waiter's on_connected fired), not stuck reconnecting or disconnected.
		assert.is_false(obj:is_stopped())
	end)

	it("invokes a request callback exactly once when reconnect-exhaust and a reinitialize retry race", function()
		-- Scenario (brief item 5): a request is in flight; the reconnect machine
		-- exhausts to disconnected -> fail_in_flight resolves the callback with a
		-- disconnect error (invocation #1). Meanwhile a reinitialize handshake for
		-- the SAME original request is still pending and later completes -> its
		-- retry settles the request again (invocation #2, ABSENT the guard). The
		-- caller's callback must fire EXACTLY ONCE.
		--
		-- This targets obj:request's settle idempotency guard directly. It is
		-- written to reach the exactly-once assertion regardless of the coalescing
		-- fix: whether the reconnect attempt opens its OWN dial (pre-fix -- which
		-- we then fail to drive exhaustion) or COALESCES onto the pending reinit
		-- dial and exhausts via its bounded per-attempt timeout (post-fix). Either
		-- way fail_in_flight fires while the reinit handshake is still pending,
		-- and completing it afterward must not re-invoke the caller's callback.
		local obj, initial = connect_client({
			reconnect = { initial_delay = 5, max_attempts = 1 },
			attempt_timeout = 30,
		})

		-- The in-flight request 404s, starting a reinitialize handshake we HOLD
		-- pending (never resolve until the very end).
		initial:set_responder(function()
			return "hub returned status 404: session expired", nil, { status = 404 }
		end)

		local reply_count = 0
		local seen = {}
		obj:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
			reply_count = reply_count + 1
			table.insert(seen, { err = err, result = result })
		end)

		-- A reinitialize dial is now pending (held). Record its index.
		assert.is_true(detect_stub.dials >= 2, "reinitialize should have started a handshake dial")
		local reinit_index = #detect_stub.pending

		-- Drop the stream: on_drop -> reconnecting -> attempt_reconnect. Pre-fix
		-- this opens a distinct reconnect dial; post-fix it coalesces onto the
		-- pending reinit dial and relies on its bounded 30ms timeout. Drive the
		-- machine to exhaustion either way, WITHOUT resolving the reinit dial.
		initial.fire_exit()
		vim.wait(400, function()
			-- Pre-fix: a separate reconnect dial appears; fail it to count the
			-- attempt so the machine (max_attempts=1) exhausts. Never touch the
			-- held reinit dial at reinit_index.
			if #detect_stub.pending > reinit_index then
				detect_stub.resolve(#detect_stub.pending, nil, "reconnect handshake failed")
			end
			return reply_count >= 1 and obj:is_stopped()
		end)
		assert.is_true(reply_count >= 1, "fail_in_flight should have resolved the in-flight request once")
		assert.is_true(obj:is_stopped(), "reconnect should have exhausted to disconnected")

		-- Now complete the still-pending reinitialize handshake with a success,
		-- which drives session.lua's retry of the ORIGINAL request. Pre-fix, this
		-- calls settle() again for the same callback -> a SECOND invocation.
		local retry_transport = transport_double({ label = "retry" })
		retry_transport:set_responder(function()
			return nil, { pong = true }
		end)
		detect_stub.resolve(
			reinit_index,
			{ transport = "legacy_sse", client = retry_transport, session_id = "sess-2" }
		)
		vim.wait(200, function()
			return false
		end)

		-- CORE ASSERTION: the caller's callback fired EXACTLY once. Pre-fix this
		-- is 2 (fail_in_flight + the reinit retry's contradictory late success).
		assert.are.equal(
			1,
			reply_count,
			"the caller's callback must fire EXACTLY once, never twice with contradictory results"
		)
		-- The single invocation is the disconnect error from fail_in_flight, not a
		-- late success -- the caller acted on the first result and must not be
		-- handed a contradictory second one.
		assert.is_not_nil(seen[1] and seen[1].err, "the single resolution is the disconnect error")
	end)

	it("closes a handshake that resolves after the client was intentionally closed", function()
		-- A reinitialize handshake is in flight when the caller disconnects the
		-- client. When that now-superseded handshake resolves successfully, its
		-- freshly-opened transport must be CLOSED (cleaned up), never adopted into
		-- the torn-down client nor left leaked -- item 2 of the fix.
		local obj, initial = connect_client()

		-- Start a reinitialize handshake (404 request) and hold it pending.
		initial:set_responder(function()
			return "hub returned status 404: session expired", nil, { status = 404 }
		end)
		local reply
		obj:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
			reply = { err = err, result = result }
		end)
		local reinit_index = #detect_stub.pending
		assert.is_true(detect_stub.dials >= 2, "reinitialize should have started a handshake dial")

		-- The caller intentionally disconnects while the handshake is pending.
		obj:disconnect()
		vim.wait(50, function()
			return obj:is_stopped()
		end)
		assert.is_true(obj:is_stopped())

		-- Now the pending handshake resolves successfully. It is superseded.
		local orphan = transport_double({ label = "orphan" })
		detect_stub.resolve(reinit_index, { transport = "legacy_sse", client = orphan, session_id = "sess-2" })
		vim.wait(50, function()
			return orphan.closed
		end)

		-- The orphaned transport was closed, not adopted or leaked.
		assert.is_true(orphan.closed, "a handshake resolving after intentional close must be closed, not leaked")
		-- Its stream-exit hook was never registered (it was never adopted).
		assert.are.equal(0, orphan.hook_count, "a superseded handshake transport must not be hooked/adopted")
	end)
end)
