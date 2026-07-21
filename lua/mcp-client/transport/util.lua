--- Shared helpers for transport modules.
local M = {}

--- plenary.curl returns headers as an array of raw "Key: Value" lines
--- (not a table), since curl dumps them verbatim. Find a header by name,
--- case-insensitively, returning its value with surrounding whitespace
--- trimmed, or nil if absent.
function M.find_header(headers, name)
	if not headers then
		return nil
	end
	local lowered_name = name:lower()
	for _, line in ipairs(headers) do
		local key, value = line:match("^([^:]+):%s*(.*)$")
		if key and key:lower() == lowered_name then
			return (value:gsub("%s+$", ""))
		end
	end
	return nil
end

--- Incrementally parse Server-Sent Events delivered one line at a time --
--- matching plenary.job's `on_stdout`/`stream` callback contract, which
--- already splits on "\n" and strips "\r" before invoking the callback.
--- Feed each line via :feed_line(line); it calls
--- on_event({event=..., data=...}) for each complete event as soon as its
--- terminating blank line arrives. Shared by the legacy SSE transport's
--- long-lived stream and the Streamable HTTP transport's single-shot
--- SSE-framed response bodies.
local SseParser = {}
SseParser.__index = SseParser

function SseParser.new(on_event)
	return setmetatable({ _event_name = nil, _data_lines = {}, _retry = nil, _on_event = on_event }, SseParser)
end

function SseParser:feed_line(line)
	if line == "" then
		if #self._data_lines > 0 or self._event_name or self._retry ~= nil then
			self._on_event({
				event = self._event_name,
				data = table.concat(self._data_lines, "\n"),
				retry = self._retry,
			})
		end
		self._event_name = nil
		self._data_lines = {}
		self._retry = nil
		return
	end

	local field, value = line:match("^(%a+):%s?(.*)$")
	if field == "event" then
		self._event_name = value
	elseif field == "data" then
		table.insert(self._data_lines, value)
	elseif field == "retry" then
		-- Reconnection hint: the server's requested delay, in ms, for the
		-- next reconnect attempt. Ignore a malformed non-integer value.
		local ms = tonumber(value)
		if ms then
			self._retry = math.floor(ms)
		end
	end
	-- Other fields (id:, comments starting with ":") are ignored.
end

M.SseParser = SseParser

--- Decode a JSON-RPC message from a complete (non-streaming) SSE-framed
--- response body -- the Streamable HTTP spec's other sanctioned response
--- mode: a server may answer a POST with a direct `application/json` body
--- OR by opening a single-event `text/event-stream` response carrying the
--- JSON-RPC message in its `data:` field. Returns the decoded first event's
--- data as JSON, or nil plus an error string if the body has no complete
--- SSE event or its data isn't valid JSON.
--- @param body string
--- @return table|nil decoded
--- @return string|nil err
function M.decode_json_from_sse_body(body)
	local data
	local parser = SseParser.new(function(evt)
		data = data or evt.data
	end)
	for line in (body .. "\n"):gmatch("([^\n]*)\n") do
		parser:feed_line((line:gsub("\r$", "")))
	end
	if not data then
		return nil, "no complete SSE event found in response body"
	end
	local ok, decoded = pcall(vim.json.decode, data)
	if not ok then
		return nil, "invalid JSON in SSE event data: " .. tostring(decoded)
	end
	return decoded, nil
end

return M
