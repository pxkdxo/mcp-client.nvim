local Reconnect = require("mcp-client.reconnect")

--- Fake scheduler capturing (delay_ms, callback) pairs so a test can fire
--- them synchronously instead of waiting on a real timer.
local function scheduler_double()
  local scheduled = {}
  return {
    schedule = function(delay_ms, fn)
      local entry = { delay = delay_ms, fn = fn, cancelled = false }
      table.insert(scheduled, entry)
      return entry
    end,
    cancel = function(entry)
      if entry then
        entry.cancelled = true
      end
    end,
    fire_next = function(scheduled_list)
      for _, entry in ipairs(scheduled_list) do
        if not entry.fired and not entry.cancelled then
          entry.fired = true
          entry.fn()
          return entry
        end
      end
    end,
    scheduled = scheduled,
  }
end

describe("reconnect (bounded-backoff state machine)", function()
  it("starts in the connected state", function()
    local rc = Reconnect.new({})
    assert.are.equal("connected", rc:state())
  end)

  it("computes an exponential backoff series capped at the ceiling", function()
    -- Initial 1000ms, 1.5x growth, cap 30000ms.
    local rc = Reconnect.new({})
    assert.are.equal(1000, rc:delay_for_attempt(1))
    assert.are.equal(1500, rc:delay_for_attempt(2))
    assert.are.equal(2250, rc:delay_for_attempt(3))
    -- Far out, it saturates at the cap rather than growing unbounded.
    assert.are.equal(30000, rc:delay_for_attempt(50))
  end)

  it("moves connected -> reconnecting and schedules an attempt on a drop", function()
    local sched = scheduler_double()
    local attempts = 0
    local rc = Reconnect.new({
      schedule = sched.schedule,
      cancel = sched.cancel,
      attempt = function()
        attempts = attempts + 1
      end,
    })

    rc:on_drop()

    assert.are.equal("reconnecting", rc:state())
    assert.are.equal(1, #sched.scheduled)
    assert.are.equal(1000, sched.scheduled[1].delay)
    assert.are.equal(0, attempts) -- not yet fired

    sched.fire_next(sched.scheduled)
    assert.are.equal(1, attempts)
  end)

  it("honors a server-sent SSE retry: hint over the computed delay", function()
    local sched = scheduler_double()
    local rc = Reconnect.new({
      schedule = sched.schedule,
      cancel = sched.cancel,
      attempt = function() end,
    })

    rc:on_drop({ retry_ms = 7777 })

    assert.are.equal(7777, sched.scheduled[1].delay)
  end)

  it("transitions to disconnected once the bounded attempts are exhausted", function()
    local sched = scheduler_double()
    local detached = false
    local rc = Reconnect.new({
      max_attempts = 2,
      schedule = sched.schedule,
      cancel = sched.cancel,
      attempt = function() end,
      on_disconnected = function()
        detached = true
      end,
    })

    -- Drop #1 -> reconnecting, schedule attempt 1.
    rc:on_drop()
    assert.are.equal("reconnecting", rc:state())
    sched.fire_next(sched.scheduled)

    -- Attempt 1 fails (still reconnecting), schedule attempt 2.
    rc:on_drop()
    assert.are.equal("reconnecting", rc:state())
    sched.fire_next(sched.scheduled)

    -- Attempt 2 fails: attempts exhausted -> disconnected, fires detach.
    rc:on_drop()
    assert.are.equal("disconnected", rc:state())
    assert.is_true(detached)
  end)

  it("returns to connected and fires attach on a successful reconnect", function()
    local sched = scheduler_double()
    local attached = 0
    local rc = Reconnect.new({
      schedule = sched.schedule,
      cancel = sched.cancel,
      attempt = function() end,
      on_connected = function()
        attached = attached + 1
      end,
    })

    rc:on_drop()
    assert.are.equal("reconnecting", rc:state())

    rc:on_connected()
    assert.are.equal("connected", rc:state())
    assert.are.equal(1, attached)
  end)

  it("an intentional close goes straight to disconnected without scheduling a retry", function()
    local sched = scheduler_double()
    local rc = Reconnect.new({
      schedule = sched.schedule,
      cancel = sched.cancel,
      attempt = function() end,
    })

    rc:on_intentional_close()

    assert.are.equal("disconnected", rc:state())
    assert.are.equal(0, #sched.scheduled)
  end)

  it("suppresses a reconnect scheduled from a drop after an intentional close", function()
    local sched = scheduler_double()
    local attempts = 0
    local rc = Reconnect.new({
      schedule = sched.schedule,
      cancel = sched.cancel,
      attempt = function()
        attempts = attempts + 1
      end,
    })

    rc:on_intentional_close()
    -- A late stream-end drop arriving after teardown must not resurrect
    -- the reconnect path.
    rc:on_drop()

    assert.are.equal("disconnected", rc:state())
    assert.are.equal(0, #sched.scheduled)
    assert.are.equal(0, attempts)
  end)
end)
