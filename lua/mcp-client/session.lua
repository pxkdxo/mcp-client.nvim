--- MCP session lifecycle: tracks the `Mcp-Session-Id` / `MCP-Protocol-Version`
--- header pair and recovers transparently from a session-scoped 404.
---
--- Per the MCP spec, once a server has assigned a session id, a later 404 on a
--- request means "that session no longer exists" (the server was restarted,
--- the session was GC'd, etc.). Renew the session, but automatically retry
--- only read-only discovery requests. Tool calls and unknown methods are
--- never replayed: their caller receives an explicit error after renewal.
---
--- Reinitialization is injected (`reinitialize(on_done)`) rather than
--- performed here: the actual re-handshake belongs to the connect layer,
--- keeping this unit pure and testable without the network.

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
	if response and response.status ~= nil then
		return response.status == 404
	end
	if type(err) == "string" and err:match("status 404") then
		return true
	end
	return false
end

--- Swap in a freshly-reinitialized session's transport/id/version.
function Session:_adopt(new_session)
	self.transport = new_session.transport or self.transport
	self.session_id = new_session.session_id
	if new_session.protocol_version ~= nil then
		self.protocol_version = new_session.protocol_version
	end
end

-- Only explicitly read-only discovery/health requests may be replayed.
local replayable = {
	["ping"] = true,
	["tools/list"] = true,
	["resources/list"] = true,
	["resources/templates/list"] = true,
	["prompts/list"] = true,
}

--- Renew an expired assigned session. Retry discovery once; never replay
--- tools/call or unrecognized methods, even after a successful renewal.
function Session:request(rpc_message, callback)
	self.transport:request(rpc_message, function(err, result, response)
		if err and self.session_id ~= nil and is_session_404(err, response) then
			self._reinitialize(function(reinit_err, new_session)
				if reinit_err then
					-- Re-handshake failed: surface the original failure path.
					return callback(err, nil, response)
				end
				self:_adopt(new_session)
				if replayable[rpc_message.method] then
					return self.transport:request(rpc_message, callback)
				end
				callback("MCP session expired and was renewed; request was not replayed. "
					.. "Verify the operation outcome before retrying.", nil, response)
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
