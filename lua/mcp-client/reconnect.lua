--- Bounded-backoff reconnection state machine.
---
--- An intentional close is a terminal transition to `disconnected` that can
--- never be undone by a subsequently-observed stream-end, and every
--- reconnect path is guarded on the current state so a late drop cannot
--- resurrect a torn-down client.
---
--- Pure state machine -- no network, no real timer, no autocmds. Time is
--- injected via `schedule`/`cancel`, the actual connect work via `attempt`,
--- and side effects on state transitions via `on_connected`/
--- `on_disconnected`. `client.lua` wires those to plenary.curl, vim.uv, and
--- Neovim autocmds.
---
--- Three states:
---   connected     -- a live session; the steady state.
---   reconnecting  -- a drop was observed and an attempt is scheduled or in
---                    flight; bounded by `max_attempts`.
---   disconnected  -- terminal: attempts exhausted, or an intentional close.
---
--- A server-sent SSE `retry:` hint overrides the computed backoff delay for
--- the next attempt. `max_attempts` defaults to 2, matching the MCP
--- reference TypeScript SDK.

local Reconnect = {}
Reconnect.__index = Reconnect

local DEFAULTS = {
	initial_delay = 1000,
	max_delay = 30000,
	growth_factor = 1.5,
	max_attempts = 2,
}

--- @param opts table
---   initial_delay   (number|nil) first backoff delay in ms (default 1000)
---   max_delay       (number|nil) backoff ceiling in ms (default 30000)
---   growth_factor   (number|nil) multiplicative growth per attempt (default 1.5)
---   max_attempts    (number|nil) attempts before giving up (default 2)
---   schedule        (fun(delay_ms, fn) -> handle) run fn after delay_ms
---   cancel          (fun(handle)) cancel a pending scheduled fn
---   attempt         (fun()) perform one reconnection attempt
---   on_connected    (fun()|nil) fired on any transition into `connected`
---   on_disconnected (fun()|nil) fired on the transition into `disconnected`
function Reconnect.new(opts)
	opts = opts or {}
	return setmetatable({
		initial_delay = opts.initial_delay or DEFAULTS.initial_delay,
		max_delay = opts.max_delay or DEFAULTS.max_delay,
		growth_factor = opts.growth_factor or DEFAULTS.growth_factor,
		max_attempts = opts.max_attempts or DEFAULTS.max_attempts,
		_schedule = opts.schedule or function() end,
		_cancel = opts.cancel or function() end,
		_attempt = opts.attempt or function() end,
		_on_connected = opts.on_connected,
		_on_disconnected = opts.on_disconnected,
		_state = "connected",
		_attempts = 0,
		_pending = nil,
	}, Reconnect)
end

function Reconnect:state()
	return self._state
end

--- The computed (pre-hint) backoff delay for the 1-based attempt number:
--- initial_delay * growth_factor^(n-1), clamped to max_delay.
function Reconnect:delay_for_attempt(n)
	local delay = self.initial_delay * (self.growth_factor ^ (n - 1))
	if delay > self.max_delay then
		return self.max_delay
	end
	return math.floor(delay + 0.5)
end

--- Schedule the next reconnection attempt, honoring a server-sent `retry:`
--- hint over the computed backoff when present.
function Reconnect:_schedule_attempt(hint)
	self._attempts = self._attempts + 1
	local delay
	if hint and hint.retry_ms then
		delay = hint.retry_ms
	else
		delay = self:delay_for_attempt(self._attempts)
	end
	self._pending = self._schedule(delay, function()
		self._pending = nil
		-- Guard: a state change (intentional close, or a successful
		-- reconnect) between scheduling and firing must win.
		if self._state ~= "reconnecting" then
			return
		end
		self._attempt()
	end)
end

--- Observe a dropped/ended stream that was *not* an intentional close.
--- From `connected`, begins reconnecting. From `reconnecting`, counts the
--- just-failed attempt and either schedules the next one or -- once the
--- bounded attempts are exhausted -- transitions to `disconnected`. From
--- `disconnected` (terminal, e.g. after an intentional close), does nothing:
--- a late drop must never resurrect the reconnect path.
--- @param hint table|nil  { retry_ms = number } from an SSE `retry:` field
function Reconnect:on_drop(hint)
	if self._state == "disconnected" then
		return
	end

	if self._state == "connected" then
		self._state = "reconnecting"
		self._attempts = 0
		self:_schedule_attempt(hint)
		return
	end

	-- state == "reconnecting": the just-fired attempt failed.
	if self._attempts >= self.max_attempts then
		self:_to_disconnected()
		return
	end
	self:_schedule_attempt(hint)
end

--- A reconnection attempt succeeded (or an initial connect completed):
--- return to the steady `connected` state and fire the attach side effect.
function Reconnect:on_connected()
	if self._state == "disconnected" then
		-- Terminal; ignore. Nothing should reconnect a client the caller
		-- (or exhaustion) has already torn down.
		return
	end
	self:_cancel_pending()
	self._state = "connected"
	self._attempts = 0
	if self._on_connected then
		self._on_connected()
	end
end

--- The caller (or this unit's own teardown) intentionally closed the
--- connection. Terminal: transition straight to `disconnected` and cancel
--- any pending attempt, without scheduling a retry. After this, `on_drop`
--- is a no-op.
function Reconnect:on_intentional_close()
	if self._state == "disconnected" then
		return
	end
	self:_to_disconnected()
end

function Reconnect:_cancel_pending()
	if self._pending then
		self._cancel(self._pending)
		self._pending = nil
	end
end

function Reconnect:_to_disconnected()
	self:_cancel_pending()
	self._state = "disconnected"
	if self._on_disconnected then
		self._on_disconnected()
	end
end

return Reconnect
