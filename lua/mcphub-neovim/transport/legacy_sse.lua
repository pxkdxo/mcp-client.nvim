--- Legacy two-endpoint HTTP+SSE MCP transport (2024-11-05 revision).
---
--- A long-lived GET request opens an SSE stream that first delivers an
--- `endpoint` event naming the URL to POST JSON-RPC messages to; further
--- JSON-RPC responses/notifications arrive asynchronously over that same
--- stream rather than in the POST's own response body. All hub network
--- I/O goes through plenary.curl: the GET stream is one long-lived curl
--- process (raw = {"-N"} to disable curl's buffering, fed incrementally
--- via the `stream` callback), never re-invoked per message.
local curl = require("plenary.curl")

local LegacySse = {}
LegacySse.__index = LegacySse

--- Incrementally parse Server-Sent Events delivered one line at a time --
--- matching plenary.job's `on_stdout`/`stream` callback contract, which
--- already splits on "\n" and strips "\r" before invoking the callback.
--- Feed each line via :feed_line(line); it calls
--- on_event({event=..., data=...}) for each complete event as soon as its
--- terminating blank line arrives.
local SseParser = {}
SseParser.__index = SseParser

function SseParser.new(on_event)
	return setmetatable({ _event_name = nil, _data_lines = {}, _on_event = on_event }, SseParser)
end

function SseParser:feed_line(line)
	if line == "" then
		if #self._data_lines > 0 or self._event_name then
			self._on_event({ event = self._event_name, data = table.concat(self._data_lines, "\n") })
		end
		self._event_name = nil
		self._data_lines = {}
		return
	end

	local field, value = line:match("^(%a+):%s?(.*)$")
	if field == "event" then
		self._event_name = value
	elseif field == "data" then
		table.insert(self._data_lines, value)
	end
	-- Other fields (id:, retry:, comments starting with ":") are ignored by
	-- U1; reconnection hinting via `retry:` is U2's concern.
end

--- @param opts table
---   stream_url (string) the GET endpoint the SSE stream is opened on
---   endpoint   (string) the POST endpoint discovered via the `endpoint` event
---   job        (Job|nil) the already-running curl job serving the SSE stream
---   headers    (table|nil) extra headers merged into every POST
function LegacySse.new(opts)
	return setmetatable({
		stream_url = assert(opts.stream_url, "stream_url is required"),
		endpoint = assert(opts.endpoint, "endpoint is required"),
		headers = opts.headers or {},
		_job = opts.job,
		_pending = {},
		_closed = false,
	}, LegacySse)
end

--- Route an incoming SSE event to whichever pending request its JSON-RPC
--- `id` matches (if any) and forward it as an unsolicited message
--- otherwise. Not used directly by U1 (no session/notification routing
--- is implemented yet), but kept small and here so streamable delivery
--- has somewhere to go once U2 needs it.
function LegacySse:_handle_message(decoded)
	if decoded.id ~= nil and self._pending[decoded.id] then
		local callback = self._pending[decoded.id]
		self._pending[decoded.id] = nil
		if decoded.error then
			callback(decoded.error.message or "hub returned an error", nil, decoded)
		else
			callback(nil, decoded.result, decoded)
		end
	end
end

function LegacySse:_on_sse_event(event)
	if event.event == "message" or event.event == nil then
		local ok, decoded = pcall(vim.json.decode, event.data)
		if ok and type(decoded) == "table" then
			self:_handle_message(decoded)
		end
	end
end

--- Attach this transport's stream parser to an already-open curl Job's
--- stdout, so callers that discovered the endpoint via detect.lua can
--- reuse the same long-lived process rather than opening a second one.
function LegacySse:attach_parser()
	self._parser = SseParser.new(function(event)
		self:_on_sse_event(event)
	end)
end

function LegacySse:feed_line(line)
	if self._parser then
		self._parser:feed_line(line)
	end
end

--- Send a JSON-RPC request. The legacy transport POSTs to the discovered
--- endpoint (expecting 202 Accepted with no body) and the actual result
--- arrives later over the SSE stream, dispatched via feed()/_handle_message.
function LegacySse:request(rpc_message, callback)
	if self._closed then
		return callback("transport is closed", nil, nil)
	end

	if rpc_message.id ~= nil then
		self._pending[rpc_message.id] = callback
	end

	curl.post(self.endpoint, {
		headers = vim.tbl_extend("force", { ["Content-Type"] = "application/json" }, self.headers),
		body = vim.json.encode(rpc_message),
		timeout = 30000,
		callback = vim.schedule_wrap(function(response)
			if not response or response.status < 200 or response.status >= 300 then
				self._pending[rpc_message.id] = nil
				return callback(
					string.format(
						"hub returned status %d posting to legacy endpoint",
						response and response.status or -1
					),
					nil,
					response
				)
			end
			-- 2xx with no body: the real response arrives over the SSE stream.
			-- If the POST body itself already carries the JSON-RPC result
			-- (some servers reply inline), handle it directly too.
			if response.body and response.body ~= "" then
				local ok, decoded = pcall(vim.json.decode, response.body)
				if ok and type(decoded) == "table" then
					self:_handle_message(decoded)
				end
			end
		end),
		on_error = vim.schedule_wrap(function(err)
			self._pending[rpc_message.id] = nil
			callback(err.message or "request failed", nil, nil)
		end),
	})
end

function LegacySse:notify(rpc_message)
	if self._closed then
		return
	end
	curl.post(self.endpoint, {
		headers = vim.tbl_extend("force", { ["Content-Type"] = "application/json" }, self.headers),
		body = vim.json.encode(rpc_message),
		timeout = 30000,
		callback = function() end,
		on_error = function() end,
	})
end

function LegacySse:close()
	self._closed = true
	if self._job then
		self._job:shutdown()
	end
end

LegacySse.SseParser = SseParser

return LegacySse
