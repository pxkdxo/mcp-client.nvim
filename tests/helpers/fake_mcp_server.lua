--- A protocol-level fake MCP server on HttpDouble, serving one era:
---   "modern"      2026-07-28 Streamable HTTP: answers server/discover, checks
---                 the per-request _meta version, rejects GET with 405.
---   "legacy"      legacy Streamable HTTP: rejects requests before
---                 `initialize`, assigns a session id, optionally holds a GET
---                 stream open (`get_stream = true`).
---   "legacy_sse"  2024-11-05 HTTP+SSE: 404s the POST endpoint, serves the
---                 `endpoint` event on GET, and answers over the stream.
---
--- `opts.handle(message, server)` answers every other request: return a result
--- table, `{ error = {...} }` for a JSON-RPC error, or nil to send nothing.
--- Every received message is recorded in `server.received` as
--- `{ http_method, message, head }`.
local HttpDouble = require("tests.helpers.http_double")
local ControllableSse = require("tests.helpers.controllable_sse")

local FakeServer = {}
FakeServer.__index = FakeServer

local MODERN = "2026-07-28"

function FakeServer.new(opts)
  local self = setmetatable({
    era = opts.era,
    supported = opts.supported or { MODERN },
    legacy_version = opts.legacy_version or "2025-11-25",
    capabilities = opts.capabilities or { tools = {} },
    session_id = opts.session_id or "fake-session",
    handle = opts.handle or function() end,
    received = {},
    sse = ControllableSse.new(),
    get_stream = opts.get_stream,
    initialized = false,
  }, FakeServer)

  self.double = HttpDouble.new({
    on_request = function(method, path, rest, head)
      local ok, message = pcall(vim.json.decode, rest)
      message = ok and type(message) == "table" and message or nil
      table.insert(self.received, { http_method = method, path = path, message = message, head = head })
      return self:_route(method, path, message, head)
    end,
  })
  self.url = self.double.url .. "/mcp"
  return self
end

function FakeServer:stop()
  self.sse:drop()
  self.double:stop()
end

--- Received JSON-RPC methods, in order.
function FakeServer:methods()
  local methods = {}
  for _, entry in ipairs(self.received) do
    if entry.message and entry.message.method then
      table.insert(methods, entry.message.method)
    end
  end
  return methods
end

--- The most recent received entry for `rpc_method`.
function FakeServer:last(rpc_method)
  for i = #self.received, 1, -1 do
    local entry = self.received[i]
    if entry.message and entry.message.method == rpc_method then
      return entry
    end
  end
end

local function json(status, body, headers)
  return {
    status = status,
    headers = vim.tbl_extend("force", { ["Content-Type"] = "application/json" }, headers or {}),
    body = vim.json.encode(body),
  }
end

function FakeServer:_answer(message)
  local result = self.handle(message, self)
  if result == nil then
    return nil
  end
  if result.error then
    return { jsonrpc = "2.0", id = message.id, error = result.error }
  end
  return { jsonrpc = "2.0", id = message.id, result = result }
end

function FakeServer:_initialize_result(message)
  return {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      protocolVersion = self.legacy_version,
      capabilities = self.capabilities,
      serverInfo = { name = "fake-" .. self.era, version = "1.0.0" },
    },
  }
end

function FakeServer:_route(method, path, message, head)
  if self.era == "modern" then
    if method ~= "POST" then
      return { status = 405, body = "" }
    end
    if message.id == nil then
      return { status = 202, body = "" }
    end
    local version = message.params
      and message.params._meta
      and message.params._meta["io.modelcontextprotocol/protocolVersion"]
    if not vim.tbl_contains(self.supported, version) then
      return json(400, {
        jsonrpc = "2.0",
        id = message.id,
        error = {
          code = -32022,
          message = "Unsupported protocol version",
          data = { supported = self.supported, requested = version },
        },
      })
    end
    if message.method == "server/discover" then
      return json(200, {
        jsonrpc = "2.0",
        id = message.id,
        result = {
          resultType = "complete",
          supportedVersions = self.supported,
          capabilities = self.capabilities,
          _meta = { ["io.modelcontextprotocol/serverInfo"] = { name = "fake-modern", version = "1.0.0" } },
        },
      })
    end
    local reply = self:_answer(message)
    return reply and json(200, reply) or json(200, { jsonrpc = "2.0", id = message.id, result = {} })
  end

  if self.era == "legacy" then
    if method == "GET" then
      if self.get_stream then
        return self.sse:stream_handler()
      end
      return { status = 405, body = "" }
    end
    if method == "DELETE" then
      return { status = 200, body = "" }
    end
    if message.method == "initialize" then
      return json(200, self:_initialize_result(message), { ["Mcp-Session-Id"] = self.session_id })
    end
    if message.method == "notifications/initialized" then
      self.initialized = true
      return { status = 202, body = "" }
    end
    if not self.initialized then
      return json(
        400,
        { jsonrpc = "2.0", id = message.id, error = { code = -32000, message = "Bad Request: Server not initialized" } }
      )
    end
    if message.id == nil or message.method == nil then
      return { status = 202, body = "" }
    end
    local reply = self:_answer(message)
    return reply and json(200, reply) or { status = 202, body = "" }
  end

  -- legacy_sse
  if path == "/mcp" and method == "GET" then
    return self.sse:sse_handler("/messages?sessionId=" .. self.session_id)
  end
  if path == "/mcp" then
    return { status = 404, body = "" }
  end
  if message and message.method == "initialize" then
    self.sse:push_message(self:_initialize_result(message))
  elseif message and message.method == "notifications/initialized" then
    self.initialized = true
  elseif message and message.id ~= nil and message.method ~= nil then
    local reply = self:_answer(message)
    if reply then
      self.sse:push_message(reply)
    end
  end
  return { status = 202, body = "" }
end

return FakeServer
