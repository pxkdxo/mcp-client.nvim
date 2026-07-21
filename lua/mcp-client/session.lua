--- MCP session lifecycle: the `Mcp-Session-Id` / `MCP-Protocol-Version`
--- header pair, and the one status the brief singles out for special
--- handling -- a session-scoped 404.
---
--- Per the MCP spec, once a server has assigned a session id, a later 404 on a
--- request means "that session no longer exists" (the server was restarted,
--- the session was GC'd, etc.). The correct behavior is not to surface an
--- error to the caller but to transparently reinitialize a fresh session and
--- retry the original request against it -- the caller only ever observes
--- the successful retry. Every other non-2xx status is a genuine error and
--- is surfaced unchanged.
---
--- The transport's `request(msg, cb)` reports errors as `cb(err_string,
--- nil, response)`, where `response` (when present) carries `.status`. We
--- key the 404 detection on that status when available and fall back to the
--- error string otherwise, so the special case fires regardless of which
--- transport produced it.
---
--- Reinitialization is injected (`reinitialize(on_done)`), not performed
--- here: the actual re-handshake belongs to the connect layer. This keeps
--- the session unit pure and testable without the network.

local Session = {}
Session.__index = Session

--- @param opts table
---   transport        (table) the current transport client (request/notify/close)
---   session_id       (string|nil) the current Mcp-Session-Id, if assigned
---   protocol_version (string|nil) the negotiated MCP-Protocol-Version
---   reinitialize     (fun(on_done: fun(err, result)) ) re-handshake a new
---     session; on success calls on_done(nil, { transport = <new>,
---     session_id = <new-id>, protocol_version = <new-version|nil> }).
function Session.new(opts)
	return setmetatable({
		transport = assert(opts.transport, "transport is required"),
		session_id = opts.session_id,
		protocol_version = opts.protocol_version,
		_reinitialize = opts.reinitialize or function(on_done)
			on_done("no reinitialize handler configured", nil)
		end,
	}, Session)
end

--- Does this failed request look like a session-scoped 404, as opposed to
--- any other error? Prefer the response status; fall back to the error text.
local function is_session_404(err, response)
	if response and response.status == 404 then
		return true
	end
	if type(err) == "string" and err:match("status 404") then
		return true
	end
	return false
end

--- Swap in a freshly-reinitialized session's transport/id/version.
function Session:_adopt(new_session)
	self.transport = new_session.transport or self.transport
	if new_session.session_id ~= nil then
		self.session_id = new_session.session_id
	end
	if new_session.protocol_version ~= nil then
		self.protocol_version = new_session.protocol_version
	end
end

--- Send a JSON-RPC request through the current transport. On a session 404,
--- reinitialize transparently and retry `rpc_message` once against the new
--- session before reporting back to `callback`. Any other error is passed
--- through unchanged.
function Session:request(rpc_message, callback)
	self.transport:request(rpc_message, function(err, result, response)
		if err and is_session_404(err, response) then
			self._reinitialize(function(reinit_err, new_session)
				if reinit_err then
					-- Re-handshake failed: surface the original failure path.
					return callback(err, nil, response)
				end
				self:_adopt(new_session)
				-- Retry the caller's original request against the new session.
				self.transport:request(rpc_message, callback)
			end)
			return
		end
		callback(err, result, response)
	end)
end

--- Send a JSON-RPC notification (no response, no 404 recovery).
function Session:notify(rpc_message)
	return self.transport:notify(rpc_message)
end

return Session
