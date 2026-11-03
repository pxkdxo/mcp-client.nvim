--- Client-layer concurrency specs: the `attempt_reconnect` (stream-drop ->
--- reconnect machine) and `make_reinitializer` (session 404 -> session.lua)
--- handshake-dialing paths firing concurrently against the same client entry,
--- plus the request-settling double-invoke guard. Unlike client_spec.lua these
--- do NOT go over a real socket: they inject a fully controllable
--- `mcp-client.transport.detect` double so a handshake can be held pending
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
--- it never replies, modeling an in-flight request that outlives a reconnect
--- exhaustion.
local function transport_double(opts)
  opts = opts or {}
  local self
  self = {
    label = opts.label,
    closed = false,
    hook_count = 0, -- how many times hook_stream_job registered an exit hook on us
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
      end
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
    saved_detect = package.loaded["mcp-client.transport.detect"]
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
    }
    package.loaded["mcp-client.transport.detect"] = detect_stub
    -- Reload the client so its module-top require binds to the stub.
    package.loaded["mcp-client.client"] = nil
    client = require("mcp-client.client")
  end)

  after_each(function()
    pcall(function()
      client._reset_registry()
    end)
    package.loaded["mcp-client.client"] = nil
    package.loaded["mcp-client.transport.detect"] = saved_detect
  end)

  --- Connect a client backed by a controllable initial transport. Returns the
  --- client object plus the initial transport double.
  local function connect_client(cfg)
    local initial = transport_double({ label = "initial" })
    local obj
    client.connect(vim.tbl_extend("force", { url = "http://127.0.0.1:1/mcp", name = "server" }, cfg or {}), {
      on_connect = function(c)
        obj = c
      end,
    })
    -- The initial connect is itself a handshake dial; resolve it with our
    -- controllable transport so the client is up.
    detect_stub.resolve(1, { transport = "legacy_sse", client = initial, session_id = "sess-1" })
    assert(obj, "client did not connect")
    return obj, initial
  end

  it("coalesces a concurrent reconnect + reinitialize onto a single handshake dial", function()
    -- Short backoff so the reconnect attempt's handshake dial fires within
    -- the same brief window as the reinitialize handshake, making the two
    -- genuinely concurrent instead of serialized apart.
    local obj, initial = connect_client({ reconnect = { initial_delay = 5, max_attempts = 3 } })

    -- The initial connect consumed dial #1. Baseline the counter.
    local dials_after_connect = detect_stub.dials

    -- Trigger both handshake paths close together, before either resolves:
    -- an in-flight request 404s into make_reinitializer's dial, and the
    -- stream drop below schedules attempt_reconnect's dial.
    local reply
    initial:set_responder(function()
      return "server returned status 404: session expired", nil, { status = 404 }
    end)
    obj:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
      reply = { err = err, result = result }
    end)

    -- Fire the stream drop; on_drop + the reconnect schedule are deferred,
    -- so wait long enough for the (short-backoff) reconnect attempt to run.
    initial.fire_exit()
    vim.wait(150, function()
      -- Stop early only if a second new dial appears, so a correctly
      -- coalescing implementation still waits the full window.
      return detect_stub.dials >= dials_after_connect + 2
    end)

    -- Exactly one new handshake dial for the two concurrent triggers: the
    -- reconnect trigger must coalesce onto the reinitialize dial.
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
    -- exactly once: adoption ran once for the coalesced result, not once
    -- per waiter.
    assert.are.equal(1, fresh.hook_count, "stream-exit hook must be registered exactly once on the adopted transport")
    assert.is_false(fresh.closed, "the adopted transport must stay open")

    assert.is_not_nil(reply, "the reinitialize retry must resolve the original request")
    assert.is_nil(reply.err)
    assert.are.same({ pong = true }, reply.result)

    assert.is_false(obj:is_stopped())
  end)

  it("invokes a request callback exactly once when reconnect-exhaust and a reinitialize retry race", function()
    -- A request is in flight; the reconnect machine exhausts to disconnected
    -- and fail_in_flight resolves the callback with a disconnect error.
    -- Meanwhile a reinitialize handshake for the same original request is
    -- still pending and later completes, driving a retry against the same
    -- callback. This targets obj:request's settle idempotency guard: the
    -- caller's callback must fire exactly once even though two independent
    -- paths race to settle it.
    local obj, initial = connect_client({
      reconnect = { initial_delay = 5, max_attempts = 1 },
      attempt_timeout = 30,
    })

    -- The in-flight request 404s, starting a reinitialize handshake we HOLD
    -- pending (never resolve until the very end).
    initial:set_responder(function()
      return "server returned status 404: session expired", nil, { status = 404 }
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

    -- Drop the stream: on_drop -> reconnecting -> attempt_reconnect. Drive
    -- the machine to exhaustion without ever resolving the held reinit dial.
    initial.fire_exit()
    vim.wait(400, function()
      -- If a distinct reconnect dial appears, fail it to count the attempt
      -- so the machine (max_attempts=1) exhausts. Never touch the held
      -- reinit dial at reinit_index.
      if #detect_stub.pending > reinit_index then
        detect_stub.resolve(#detect_stub.pending, nil, "reconnect handshake failed")
      end
      return reply_count >= 1 and obj:is_stopped()
    end)
    assert.is_true(reply_count >= 1, "fail_in_flight should have resolved the in-flight request once")
    assert.is_true(obj:is_stopped(), "reconnect should have exhausted to disconnected")

    -- Now complete the still-pending reinitialize handshake with a success,
    -- which drives session.lua's retry of the original request.
    local retry_transport = transport_double({ label = "retry" })
    retry_transport:set_responder(function()
      return nil, { pong = true }
    end)
    detect_stub.resolve(reinit_index, { transport = "legacy_sse", client = retry_transport, session_id = "sess-2" })
    vim.wait(200, function()
      return false
    end)

    assert.are.equal(
      1,
      reply_count,
      "the caller's callback must fire EXACTLY once, never twice with contradictory results"
    )
    -- The single invocation is the disconnect error from fail_in_flight, not
    -- the late reinit success -- the caller must not be handed a second,
    -- contradictory result.
    assert.is_not_nil(seen[1] and seen[1].err, "the single resolution is the disconnect error")
  end)

  it("closes a handshake that resolves after the client was intentionally closed", function()
    -- A reinitialize handshake is in flight when the caller disconnects the
    -- client. When that now-superseded handshake resolves successfully, its
    -- freshly-opened transport must be closed, never adopted into the
    -- torn-down client nor left leaked.
    local obj, initial = connect_client()

    -- Start a reinitialize handshake (404 request) and hold it pending.
    initial:set_responder(function()
      return "server returned status 404: session expired", nil, { status = 404 }
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

  it("closes a handshake that resolves after its own attempt timed out and a later attempt superseded it", function()
    -- A reconnect attempt's handshake dial (D1) times out mid-backoff while
    -- the machine is still `reconnecting` (more attempts remain), so it
    -- schedules the next attempt. D1 then resolves late, before attempt #2
    -- dials: since the client is non-terminal, its transport (T1) would be
    -- adopted. Attempt #2 (D2) then fires and adopts a different transport
    -- (T2), superseding T1. T1 must be closed, not left leaked with a live
    -- stream-exit hook that could spuriously drive reconnect later.
    --
    -- A small per-attempt timeout (10ms) fires D1's timeout, which schedules
    -- attempt #2 on a longer backoff (initial_delay=80ms); we resolve D1
    -- inside that window, then let attempt #2 fire and resolve D2 -- the
    -- ordering is forced by construction, not wall-clock racing.
    local obj, initial = connect_client({
      reconnect = { initial_delay = 80, max_attempts = 3 },
      attempt_timeout = 10,
    })
    local dials_after_connect = detect_stub.dials

    -- Drop the stream: on_drop -> reconnecting -> schedule attempt #1 (fires
    -- after ~80ms). Wait for attempt #1's handshake dial (D1) to appear.
    initial.fire_exit()
    vim.wait(300, function()
      return detect_stub.dials >= dials_after_connect + 1
    end)
    assert.are.equal(
      dials_after_connect + 1,
      detect_stub.dials,
      "attempt #1 should have started its handshake dial (D1)"
    )
    local d1_index = #detect_stub.pending

    -- Attempt #1's per-attempt timeout (10ms) fires while D1 is still pending:
    -- the machine counts the failed attempt and (max_attempts=3, still
    -- reconnecting) schedules attempt #2. The machine must NOT be disconnected.
    vim.wait(60, function()
      return detect_stub.dials >= dials_after_connect + 2
    end)
    assert.is_false(obj:is_stopped(), "the machine must still be reconnecting, not disconnected")
    -- attempt #2 has not dialed yet (still in its 80ms backoff), so no new dial.
    assert.are.equal(
      dials_after_connect + 1,
      detect_stub.dials,
      "attempt #2 must not have dialed yet -- D1 is the only handshake dial so far"
    )

    -- Now D1 resolves late (after its own attempt timed out, before attempt
    -- #2 dials). The client is non-terminal (still reconnecting), so
    -- perform_handshake adopts T1 as the live transport.
    local t1 = transport_double({ label = "t1-late" })
    detect_stub.resolve(d1_index, { transport = "legacy_sse", client = t1, session_id = "sess-t1" })

    -- Let attempt #2's backoff elapse so it fires, dials (D2), and we resolve
    -- it with a DIFFERENT transport (T2), which supersedes T1.
    vim.wait(300, function()
      return detect_stub.dials >= dials_after_connect + 2
    end)
    assert.are.equal(
      dials_after_connect + 2,
      detect_stub.dials,
      "attempt #2 should have started a second, distinct handshake dial (D2)"
    )
    local d2_index = #detect_stub.pending
    local t2 = transport_double({ label = "t2" })
    detect_stub.resolve(d2_index, { transport = "legacy_sse", client = t2, session_id = "sess-t2" })
    vim.wait(100, function()
      return not obj:is_stopped() and t1.closed
    end)

    -- T1, adopted by the intermediate already-abandoned attempt and then
    -- superseded by T2, must be closed rather than silently overwritten
    -- and leaked (with its live process and stale stream-exit hook).
    assert.is_true(
      t1.closed,
      "a handshake adopted by a timed-out attempt and then superseded by a later attempt must be closed, not leaked"
    )
    -- T2 is the live transport and stays open.
    assert.is_false(t2.closed, "the superseding transport (T2) must stay open")
    -- T2's stream-exit hook is registered exactly once (adopted once).
    assert.are.equal(1, t2.hook_count, "the superseding transport must be adopted/hooked exactly once")
    -- The client converged back to connected on the surviving transport.
    assert.is_false(obj:is_stopped(), "the client should be connected again on the surviving transport")

    -- Reaping T1 tags its job intentional_close, so its stale stream-exit
    -- hook firing later is a no-op and must not drive the client back into
    -- reconnecting/disconnected on a stream it has already abandoned.
    t1.fire_exit()
    vim.wait(60, function()
      return obj:is_stopped()
    end)
    assert.is_false(
      obj:is_stopped(),
      "the abandoned transport's stale stream-exit hook must not drive reconnect against the live client"
    )
  end)

  it("abandons a wedged reconnect dial: frees the slot, times out coalesced waiters, closes a late result", function()
    -- regression: a reconnect attempt's handshake dial (D1) is dispatched but
    -- its underlying detect.connect never calls back (a server that accepts
    -- the connection but hangs the MCP handshake with no response and no
    -- clean exit -- exactly what ATTEMPT_TIMEOUT_MS exists to bound). A
    -- reinitialize (a 404 request) coalesces onto D1 before the guard fires,
    -- joining its waiter list.
    --
    -- On the guard timeout, because D1 is still the current dial,
    -- attempt_reconnect must actively abandon it: drain and clear
    -- entry._handshake's waiter list (freeing the slot), bump
    -- entry._handshake_gen (so a late D1 result is recognized as stale), and
    -- notify every drained waiter with a clear timeout error. Attempt #2 then
    -- dials fresh (D2), and if D1's detect.connect ever does resolve, its
    -- result must be closed, not adopted.
    --
    -- A small per-attempt timeout (10ms) fires D1's guard while D1 is held
    -- pending; attempt #2 fires after a longer backoff (initial_delay=80).
    -- The reinitialize is issued before the guard fires so it coalesces onto D1.
    local obj, initial = connect_client({
      reconnect = { initial_delay = 80, max_attempts = 3 },
      attempt_timeout = 10,
    })
    local dials_after_connect = detect_stub.dials

    -- Drop the stream: on_drop -> reconnecting -> schedule attempt #1 (fires
    -- after ~80ms). Wait for attempt #1's handshake dial (D1) to appear.
    initial.fire_exit()
    vim.wait(300, function()
      return detect_stub.dials >= dials_after_connect + 1
    end)
    assert.are.equal(
      dials_after_connect + 1,
      detect_stub.dials,
      "attempt #1 should have started its handshake dial (D1)"
    )
    local d1_index = #detect_stub.pending

    -- While D1 is still pending (before its 10ms guard fires), fire a 404 request
    -- so the reinitialize path COALESCES onto D1's waiter list rather than
    -- starting its own dial. Its callback (the on_done session.lua awaits) is
    -- what must be notified with a timeout error when we abandon D1.
    initial:set_responder(function()
      return "server returned status 404: session expired", nil, { status = 404 }
    end)
    local reinit_reply
    obj:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
      reinit_reply = { err = err, result = result }
    end)
    -- The reinitialize must have JOINED D1 (coalesced), not opened a new dial.
    assert.are.equal(
      dials_after_connect + 1,
      detect_stub.dials,
      "the reinitialize must coalesce onto the pending D1 dial, not open a new one"
    )

    -- Attempt #1's per-attempt guard timeout (10ms) fires while D1 is still
    -- pending and unresolved. This must abandon D1: the slot frees, the
    -- coalesced reinitialize waiter is notified with a timeout error, and the
    -- machine (max_attempts=3, still reconnecting) schedules attempt #2.
    vim.wait(200, function()
      return reinit_reply ~= nil and detect_stub.dials >= dials_after_connect + 2
    end)
    assert.is_false(obj:is_stopped(), "the machine must still be reconnecting, not disconnected")

    -- The coalesced reinitialize waiter got its own callback with a clear
    -- timeout error, not a hang.
    assert.is_not_nil(
      reinit_reply,
      "a caller coalesced onto the wedged dial must be notified when the dial is abandoned, not hang forever"
    )
    assert.is_not_nil(
      reinit_reply.err,
      "the coalesced waiter's notification must carry a timeout error, not a phantom success"
    )

    -- The slot is genuinely freed: attempt #2 dialed fresh, not joining D1.
    assert.are.equal(
      dials_after_connect + 2,
      detect_stub.dials,
      "attempt #2 must dial FRESH after the wedged D1 is abandoned, not join the dead waiter list"
    )
    local d2_index = #detect_stub.pending
    assert.is_true(d2_index > d1_index, "attempt #2's dial (D2) must be a new, distinct dial from D1")

    -- Resolve D2 successfully so the client converges back to connected on D2.
    local t2 = transport_double({ label = "t2" })
    detect_stub.resolve(d2_index, { transport = "legacy_sse", client = t2, session_id = "sess-t2" })
    vim.wait(100, function()
      return not obj:is_stopped()
    end)
    assert.is_false(obj:is_stopped(), "the client should be connected again on the fresh D2 transport")
    assert.are.equal(1, t2.hook_count, "the fresh D2 transport must be adopted/hooked exactly once")

    -- The originally-wedged D1's detect.connect finally calls back, very
    -- late, after D1 was abandoned and D2 adopted. Its result must be
    -- recognized as stale (generation bumped on abandon) and closed, never
    -- adopted into the client that has moved on to D2.
    local t1_late = transport_double({ label = "t1-late" })
    detect_stub.resolve(d1_index, { transport = "legacy_sse", client = t1_late, session_id = "sess-t1" })
    vim.wait(60, function()
      return t1_late.closed
    end)
    assert.is_true(
      t1_late.closed,
      "a wedged dial that resolves after being abandoned and superseded must be closed, not adopted"
    )
    assert.are.equal(0, t1_late.hook_count, "the abandoned late result must never be hooked/adopted")
    -- T2 remains the live transport; the late D1 result did not disturb it.
    assert.is_false(t2.closed, "the live D2 transport must stay open when the abandoned D1 resolves late")
    assert.is_false(obj:is_stopped(), "the client stays connected on D2 despite the late abandoned D1 result")
  end)

  it("times out a reinitialize-only wedged dial with no concurrent reconnect activity", function()
    -- regression: `entry.reconnect:state()` stays "connected" throughout (no
    -- stream drop, so attempt_reconnect's guard never runs). A 404 request
    -- drives make_reinitializer straight into perform_handshake as the sole
    -- caller; it dispatches one dial that never calls back (a server that
    -- accepts the TCP connection but hangs the MCP handshake forever).
    --
    -- make_reinitializer must own its own guard (default ATTEMPT_TIMEOUT_MS,
    -- overridable via `entry.config.reinit_timeout`). On timeout it abandons
    -- the wedged dial (freeing entry._handshake for a future caller) and
    -- resolves the original request's callback with a clear timeout error,
    -- without touching entry.reconnect -- a 404-reinitialize is
    -- session-scoped, not connection-scoped.
    local obj, initial = connect_client({ reinit_timeout = 10 })
    local dials_after_connect = detect_stub.dials

    initial:set_responder(function()
      return "server returned status 404: session expired", nil, { status = 404 }
    end)
    local reply
    obj:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
      reply = { err = err, result = result }
    end)

    -- The reinitialize dispatched exactly one dial (it is the sole, first caller;
    -- no concurrent reconnect activity exists to coalesce with).
    assert.are.equal(
      dials_after_connect + 1,
      detect_stub.dials,
      "the reinitialize should have dispatched its own handshake dial"
    )
    local d1_index = #detect_stub.pending

    -- Bounded wait: without a guard, `reply` never becomes non-nil, so this
    -- wait times out at its bound rather than hanging the test suite -- the
    -- bound itself is the point, not a race to shrink.
    vim.wait(200, function()
      return reply ~= nil
    end)

    -- The caller's request callback resolves within the bound, with a clear
    -- timeout error -- never silently, never with a phantom success.
    assert.is_not_nil(
      reply,
      "a reinit-only wedged dial with no concurrent reconnect activity must still resolve the caller, not hang forever"
    )
    assert.is_not_nil(reply.err, "the resolution must carry a timeout-shaped error, not a phantom success")

    -- The reconnect machine must be entirely untouched by a session-scoped
    -- reinitialize timeout: still "connected", no attempt counted, no MCPDetach.
    assert.is_false(obj:is_stopped(), "a 404-reinitialize timeout must not perturb the reconnect machine's state")

    -- The slot is genuinely freed: a follow-up reinitialize dials FRESH rather
    -- than joining the abandoned dial's dead waiter list.
    initial:set_responder(function()
      return "server returned status 404: session expired", nil, { status = 404 }
    end)
    local reply2
    obj:request({ jsonrpc = "2.0", id = 2, method = "ping" }, function(err, result)
      reply2 = { err = err, result = result }
    end)
    assert.are.equal(
      dials_after_connect + 2,
      detect_stub.dials,
      "a follow-up reinitialize must dial fresh after the wedged dial is abandoned, not join the dead waiter list"
    )
    local d2_index = #detect_stub.pending
    assert.is_true(d2_index > d1_index, "the follow-up dial must be a new, distinct dial from the abandoned one")

    -- Resolve the follow-up dial successfully so the retry completes.
    local fresh = transport_double({ label = "fresh" })
    fresh:set_responder(function()
      return nil, { pong = true }
    end)
    detect_stub.resolve(d2_index, { transport = "legacy_sse", client = fresh, session_id = "sess-2" })
    vim.wait(100, function()
      return reply2 ~= nil
    end)
    assert.is_not_nil(reply2, "the follow-up reinitialize must resolve the second request")
    assert.is_nil(reply2.err)
    assert.are.same({ pong = true }, reply2.result)

    -- A very-late result from the FIRST (abandoned) dial must be closed, not
    -- adopted -- it is stale by generation once the follow-up dial superseded it.
    local t1_late = transport_double({ label = "t1-late" })
    detect_stub.resolve(d1_index, { transport = "legacy_sse", client = t1_late, session_id = "sess-t1" })
    vim.wait(60, function()
      return t1_late.closed
    end)
    assert.is_true(t1_late.closed, "the abandoned dial's very-late result must be closed, not adopted")
    assert.are.equal(0, t1_late.hook_count, "the abandoned dial's very-late result must never be hooked/adopted")
    assert.is_false(fresh.closed, "the live, adopted transport must stay open despite the late abandoned result")
  end)
end)
