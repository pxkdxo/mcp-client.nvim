--- Legacy two-endpoint HTTP+SSE MCP transport (2024-11-05 revision).
---
--- A long-lived GET request opens an SSE stream that first delivers an
--- `endpoint` event naming the URL to POST JSON-RPC messages to; further
--- JSON-RPC responses/notifications arrive asynchronously over that same
--- stream rather than in the POST's own response body. The GET stream is
--- one long-lived curl process (raw = {"-N"} to disable curl's buffering),
--- fed incrementally via the `stream` callback rather than re-invoked per
--- message.
local curl = require("plenary.curl")
local transport_util = require("mcp-client.transport.util")

local LegacySse = {}
LegacySse.__index = LegacySse

--- Incrementally parses SSE lines matching plenary.job's `on_stdout`/
--- `stream` contract (already split on "\n", "\r" stripped). Feed lines via
--- :feed_line(line); it invokes on_event({event=..., data=...}) once each
--- event's terminating blank line arrives. Shared with the Streamable HTTP
--- transport (transport/util.lua).
local SseParser = transport_util.SseParser

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
		_retry_hint = nil,
	}, LegacySse)
end

--- Register a handler for server-originated messages that do not match a
--- pending request -- i.e. server notifications (a `method`, no id we sent).
--- The client layer wires this to fire an `MCPNotify` autocmd. Optional; if
--- unset such messages are simply ignored.
function LegacySse:set_on_notification(fn)
	self._on_notification = fn
end

--- The most recent SSE `retry:` hint (ms) the server has sent on this
--- stream, or nil if none. The reconnect layer prefers this over its
--- computed backoff for the next attempt.
function LegacySse:get_retry_hint()
	return self._retry_hint
end

--- Route an incoming SSE event to whichever pending request its JSON-RPC
--- `id` matches (if any); otherwise, if it carries a `method`, treat it as a
--- server-originated notification and hand it to the notification handler.
function LegacySse:_handle_message(decoded)
	if decoded.id ~= nil and self._pending[decoded.id] then
		local callback = self._pending[decoded.id]
		self._pending[decoded.id] = nil
		if decoded.error then
			callback(decoded.error.message or "server returned an error", nil, decoded)
		else
			-- Pass the full decoded JSON-RPC object as the result, matching
			-- streamable_http's `callback(nil, decoded, response)` shape so the
			-- session/client layer sees one transport-agnostic result form
			-- (`result.result` is the JSON-RPC `result` field either way).
			callback(nil, decoded, decoded)
		end
		return
	end

	-- No matching pending request. A message with a `method` is a
	-- server-originated notification/request; surface it to the client layer.
	if decoded.method ~= nil and self._on_notification then
		self._on_notification(decoded)
	end
end

function LegacySse:_on_sse_event(event)
	if event.retry ~= nil then
		self._retry_hint = event.retry
	end
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
				if rpc_message.id ~= nil then
					self._pending[rpc_message.id] = nil
				end
				return callback(
					string.format(
						"server returned status %d posting to legacy endpoint",
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
			if rpc_message.id ~= nil then
				self._pending[rpc_message.id] = nil
			end
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

--- Expose the long-lived curl GET Job serving the SSE stream, so the
--- session/reconnect layer can hook its exit (to detect a dropped stream)
--- and drive the intentional-close mechanism (set
--- `job.user_data.intentional_close` before `vim.uv.kill(job:pid(), ...)`).
--- Returns nil if no job was handed in (e.g. a unit test constructing the
--- transport without a real stream).
function LegacySse:get_stream_job()
	return self._job
end

function LegacySse:close()
	self._closed = true
	if self._job then
		self._job:shutdown()
	end
end

LegacySse.SseParser = SseParser

return LegacySse
