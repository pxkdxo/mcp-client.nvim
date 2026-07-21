--- Modern single-endpoint "Streamable HTTP" MCP transport.
---
--- One URL handles both directions: JSON-RPC requests/notifications are
--- POSTed to it, and the server may optionally push messages back over an
--- SSE stream opened with GET on the same URL. All server network I/O goes
--- through plenary.curl -- never a hand-rolled vim.uv socket.
local curl = require("plenary.curl")
local transport_util = require("mcp-client.transport.util")

local StreamableHttp = {}
StreamableHttp.__index = StreamableHttp

--- @param opts table
---   url        (string) the single MCP endpoint
---   session_id (string|nil) Mcp-Session-Id, if the server assigned one
---   headers    (table|nil) extra headers merged into every request
function StreamableHttp.new(opts)
	return setmetatable({
		url = assert(opts.url, "url is required"),
		session_id = opts.session_id,
		headers = opts.headers or {},
		protocol_version = opts.protocol_version,
		_closed = false,
	}, StreamableHttp)
end

function StreamableHttp:_headers()
	local headers = vim.tbl_extend(
		"force",
		{ ["Content-Type"] = "application/json", ["Accept"] = "application/json, text/event-stream" },
		self.headers
	)
	if self.session_id then
		headers["Mcp-Session-Id"] = self.session_id
	end
	if self.protocol_version then
		headers["MCP-Protocol-Version"] = self.protocol_version
	end
	return headers
end

--- Send a JSON-RPC request and invoke callback(err, result, response) once
--- the server replies. Fire-and-forget async: does not block the caller.
function StreamableHttp:request(rpc_message, callback)
	if self._closed then
		return callback("transport is closed", nil, nil)
	end

	curl.post(self.url, {
		headers = self:_headers(),
		body = vim.json.encode(rpc_message),
		timeout = 30000,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return callback("no response from server", nil, nil)
			end

			local session_header = transport_util.find_header(response.headers, "Mcp-Session-Id")
			if session_header then
				self.session_id = session_header
			end

			if response.status < 200 or response.status >= 300 then
				return callback(
					string.format("server returned status %d: %s", response.status, response.body or ""),
					nil,
					response
				)
			end

			-- A server may answer with a plain JSON body or a single-event
			-- text/event-stream response; try both decodings.
			local ok, decoded = pcall(vim.json.decode, response.body)
			if not ok then
				local sse_decoded, sse_err = transport_util.decode_json_from_sse_body(response.body)
				if not sse_decoded then
					return callback(
						"failed to decode server response as JSON: "
							.. tostring(decoded)
							.. " (also tried SSE framing: "
							.. tostring(sse_err)
							.. ")",
						nil,
						response
					)
				end
				decoded = sse_decoded
			end

			callback(nil, decoded, response)
		end),
		on_error = vim.schedule_wrap(function(err)
			callback(err.message or "request failed", nil, nil)
		end),
	})
end

--- Send a JSON-RPC notification (no response expected).
function StreamableHttp:notify(rpc_message)
	if self._closed then
		return
	end
	curl.post(self.url, {
		headers = self:_headers(),
		body = vim.json.encode(rpc_message),
		timeout = 30000,
		callback = function() end,
		on_error = function() end,
	})
end

--- This transport POSTs per request and holds no long-lived stream job, so
--- there is nothing for the session/reconnect layer to hook or kill here.
function StreamableHttp:get_stream_job()
	return nil
end

--- Interface parity with the legacy transport's notification hook. No
--- unsolicited messages arrive on this transport, so the handler is
--- accepted but never fired.
function StreamableHttp:set_on_notification(_)
	-- no-op
end

function StreamableHttp:close()
	self._closed = true
end

return StreamableHttp
