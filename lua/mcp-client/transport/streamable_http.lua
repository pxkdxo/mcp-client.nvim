--- Single-endpoint "Streamable HTTP" MCP transport, in either protocol era.
---
--- Every client message is its own POST. The server answers a request with
--- either a JSON body or an SSE stream scoped to that request; the stream is
--- parsed line by line as it arrives, so notifications (and, from a legacy
--- server, server-to-client requests) that precede the final response reach
--- the message handler immediately.
---
--- Era-specific behavior:
---   * modern: `Mcp-Method` / `Mcp-Name` headers mirror the body; no sessions.
---   * legacy: the server may assign an `Mcp-Session-Id`, echoed on every
---     request and released with DELETE on close; `start_listening()` opens
---     the standalone GET stream for server-initiated messages.
local curl = require("plenary.curl")
local transport_util = require("mcp-client.transport.util")

local SseParser = transport_util.SseParser

local StreamableHttp = {}
StreamableHttp.__index = StreamableHttp

local NOTIFY_TIMEOUT_MS = 30000
local LISTEN_RETRY_MS = 1000
local LISTEN_MAX_IDLE_REOPENS = 5

--- Methods whose `params.name` / `params.uri` is mirrored into `Mcp-Name`.
local NAME_PARAM = {
  ["tools/call"] = "name",
  ["prompts/get"] = "name",
  ["resources/read"] = "uri",
}

--- @param opts table
---   url              (string) the MCP endpoint
---   era              ("modern"|"legacy")
---   protocol_version (string|nil) sent as MCP-Protocol-Version
---   session_id       (string|nil) legacy Mcp-Session-Id
---   headers          (table|nil) extra headers merged into every request
function StreamableHttp.new(opts)
  return setmetatable({
    url = assert(opts.url, "url is required"),
    era = opts.era or "legacy",
    protocol_version = opts.protocol_version,
    session_id = opts.session_id,
    headers = opts.headers or {},
    _closed = false,
    _long_lived = {},
    _listener = nil,
    _on_message = nil,
  }, StreamableHttp)
end

--- Handler for every server message that is not the response to the request
--- that carried it: notifications and server-to-client requests.
function StreamableHttp:set_on_message(fn)
  self._on_message = fn
end

function StreamableHttp:_dispatch(message)
  if self._on_message and not self._closed then
    self._on_message(message)
  end
end

function StreamableHttp:_headers(message, extra)
  local headers = vim.tbl_extend(
    "force",
    { ["Content-Type"] = "application/json", ["Accept"] = "application/json, text/event-stream" },
    self.headers
  )
  if self.protocol_version then
    headers["MCP-Protocol-Version"] = self.protocol_version
  end
  if self.era == "legacy" and self.session_id then
    headers["Mcp-Session-Id"] = self.session_id
  end
  if self.era == "modern" and message and message.method then
    headers["Mcp-Method"] = message.method
    local name_field = NAME_PARAM[message.method]
    local name = name_field and type(message.params) == "table" and message.params[name_field]
    if name ~= nil then
      headers["Mcp-Name"] = transport_util.encode_header_value(name)
    end
  end
  return vim.tbl_extend("force", headers, extra or {})
end

function StreamableHttp:_track_session(response)
  local session_header = transport_util.find_header(response.headers, "Mcp-Session-Id")
  if session_header and self.era == "legacy" then
    self.session_id = session_header
  end
end

--- Send a JSON-RPC request; `callback(err, envelope, response)` fires once
--- with the response envelope (and `err` set to its error message for a
--- JSON-RPC error) plus the HTTP response when one completed.
---
--- @param opts table|nil
---   headers    (table|nil) extra headers for this request only
---   timeout    (number|nil) whole-request bound in ms (default: unbounded)
---   long_lived (boolean|nil) the request is killed on close()
function StreamableHttp:request(message, callback, opts)
  opts = opts or {}
  if self._closed then
    return callback("transport is closed", nil, nil)
  end

  local resolved = false
  local function resolve(err, envelope, response)
    if resolved then
      return
    end
    resolved = true
    callback(err, envelope, response)
  end

  local function accept_response(envelope, response)
    resolve(transport_util.rpc_error_message(envelope), envelope, response)
  end

  -- A response stream may interleave notifications and server requests with
  -- the response itself; route each message as soon as its event completes.
  local streamed_any = false
  local parser = SseParser.new(function(event)
    local ok, decoded = pcall(vim.json.decode, event.data)
    if not ok or type(decoded) ~= "table" then
      return
    end
    if decoded.method ~= nil then
      self:_dispatch(decoded)
    elseif decoded.id == message.id then
      accept_response(decoded, nil)
    end
  end)

  local raw = { "-N" }
  if opts.timeout then
    vim.list_extend(raw, transport_util.max_time_args(opts.timeout))
  end

  local job
  job = curl.post(self.url, {
    headers = self:_headers(message, opts.headers),
    body = vim.json.encode(message),
    raw = raw,
    stream = vim.schedule_wrap(function(_, line)
      if line ~= nil then
        streamed_any = true
        parser:feed_line(line)
      end
    end),
    callback = vim.schedule_wrap(function(response)
      self._long_lived[job] = nil
      self:_track_session(response)
      parser:feed_line("")
      if resolved then
        return
      end

      -- The POST carries exactly one response, so a response envelope in the
      -- body answers this request even if its id was not matched mid-stream.
      local messages = transport_util.decode_messages(response.body)
      local envelope
      for _, decoded in ipairs(messages) do
        if decoded.method ~= nil then
          if not streamed_any then
            self:_dispatch(decoded)
          end
        elseif envelope == nil or decoded.id == message.id then
          envelope = decoded
        end
      end

      if response.status < 200 or response.status >= 300 then
        local detail = transport_util.rpc_error_message(envelope) or response.body or ""
        return resolve(string.format("server returned status %d: %s", response.status, detail), envelope, response)
      end
      if envelope then
        return accept_response(envelope, response)
      end
      if #messages == 0 and response.body ~= nil and response.body ~= "" then
        return resolve("failed to decode server response: " .. response.body, nil, response)
      end
      resolve("server closed the response without a JSON-RPC response", nil, response)
    end),
    on_error = vim.schedule_wrap(function(err)
      self._long_lived[job] = nil
      resolve(transport_util.describe_curl_error(err), nil, nil)
    end),
  })
  if opts.long_lived then
    self._long_lived[job] = true
  end
end

--- POST a message that expects no JSON-RPC reply (a notification, or a
--- response to a server request). `on_done(err)` fires when the server has
--- accepted it.
function StreamableHttp:notify(message, on_done)
  on_done = on_done or function() end
  if self._closed then
    return on_done("transport is closed")
  end
  curl.post(self.url, {
    headers = self:_headers(message),
    body = vim.json.encode(message),
    raw = transport_util.max_time_args(NOTIFY_TIMEOUT_MS),
    callback = vim.schedule_wrap(function(response)
      if response.status < 200 or response.status >= 300 then
        return on_done(string.format("server returned status %d: %s", response.status, response.body or ""))
      end
      on_done(nil)
    end),
    on_error = vim.schedule_wrap(function(err)
      on_done(transport_util.describe_curl_error(err))
    end),
  })
end

--- Answer a server-to-client request.
function StreamableHttp:respond(message)
  self:notify(message)
end

--- Legacy only: hold the standalone GET stream open for server-initiated
--- messages, reopening it when the server ends it. A server without the
--- stream (405) or one that rejects it is left alone; a server that keeps
--- closing the stream without sending anything stops being re-polled after
--- a few attempts.
function StreamableHttp:start_listening()
  if self.era ~= "legacy" or self._closed or self._listener then
    return
  end
  local idle_reopens = 0

  local function open()
    if self._closed then
      return
    end
    local retry_ms
    local received = false
    local parser = SseParser.new(function(event)
      if event.retry then
        retry_ms = event.retry
      end
      local ok, decoded = pcall(vim.json.decode, event.data)
      if ok and type(decoded) == "table" and decoded.method ~= nil then
        received = true
        self:_dispatch(decoded)
      end
    end)
    local headers = self:_headers(nil, { ["Accept"] = "text/event-stream" })
    headers["Content-Type"] = nil
    self._listener = curl.get(self.url, {
      headers = headers,
      raw = { "-N" },
      stream = vim.schedule_wrap(function(_, line)
        if line ~= nil then
          parser:feed_line(line)
        end
      end),
      callback = vim.schedule_wrap(function(response)
        self._listener = nil
        if self._closed or response.status < 200 or response.status >= 300 then
          return
        end
        idle_reopens = received and 0 or idle_reopens + 1
        if idle_reopens > LISTEN_MAX_IDLE_REOPENS then
          return
        end
        vim.defer_fn(open, retry_ms or LISTEN_RETRY_MS)
      end),
      on_error = vim.schedule_wrap(function()
        self._listener = nil
      end),
    })
  end

  open()
end

--- This transport keeps no stream whose exit signals a lost connection.
function StreamableHttp:get_stream_job()
  return nil
end

function StreamableHttp:close()
  if self._closed then
    return
  end
  self._closed = true
  if self._listener then
    pcall(function()
      self._listener:shutdown()
    end)
    self._listener = nil
  end
  for job in pairs(self._long_lived) do
    pcall(function()
      job:shutdown()
    end)
  end
  self._long_lived = {}
  if self.era == "legacy" and self.session_id then
    curl.delete(self.url, {
      headers = self:_headers(),
      raw = transport_util.max_time_args(5000),
      callback = function() end,
      on_error = function() end,
    })
  end
end

return StreamableHttp
