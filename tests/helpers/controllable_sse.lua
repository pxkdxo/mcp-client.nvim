--- A live, controllable legacy-SSE stream fixture, layered on HttpDouble.
---
--- Unlike a static HttpDouble frame list, this exposes the open socket so a
--- test can push JSON-RPC messages after the handshake and drop the
--- connection on demand to simulate a server-side loss.
local ControllableSse = {}
ControllableSse.__index = ControllableSse

function ControllableSse.new()
	return setmetatable({ _socket = nil, _closed = false }, ControllableSse)
end

--- Build an HttpDouble SSE handler that emits the `endpoint` event and then
--- hands us the live socket for later push/drop.
function ControllableSse:sse_handler(endpoint)
	return {
		status = 200,
		sse = { { event = "endpoint", data = endpoint } },
		on_stream = function(socket)
			self._socket = socket
			self._closed = false
		end,
	}
end

--- Push a JSON-RPC message to the client over the open SSE stream as a
--- `message` event.
function ControllableSse:push_message(msg)
	if not self._socket or self._closed then
		return
	end
	local data = vim.json.encode(msg)
	local frame = "event: message\r\n"
	for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
		frame = frame .. "data: " .. line .. "\r\n"
	end
	frame = frame .. "\r\n"
	self._socket:write(frame)
end

--- Push a bare SSE `retry:` hint frame (ms) to the client, the server's
--- requested delay before the next reconnect attempt.
function ControllableSse:push_retry(ms)
	if not self._socket or self._closed then
		return
	end
	self._socket:write("retry: " .. tostring(ms) .. "\r\n\r\n")
end

--- Drop the stream from the server side. Closing the socket makes curl's
--- long-lived GET exit 0 (silent stream-end, not an error) -- the case the
--- client's reconnect path must detect and act on.
function ControllableSse:drop()
	self._closed = true
	if self._socket and not self._socket:is_closing() then
		self._socket:close()
		self._socket = nil
	end
end

return ControllableSse
