-- A fake stdio MCP server, run as `nvim -l stdio_server.lua <mode>`.
--   modern  answers server/discover; tools/call asks for input once (MRTR)
--   legacy  rejects server/discover; after the handshake it asks the client
--           for roots/list and reports the answer as a notification
--   silent  a legacy server that ignores requests sent before `initialize`
--   crash   a legacy server that exits with status 3 on tools/call
local mode = arg[1]

local function send(message)
  message.jsonrpc = "2.0"
  io.stdout:write(vim.json.encode(message) .. "\n")
  io.stdout:flush()
end

local initialized = false

local function legacy(message)
  if message.method == "initialize" then
    return send({
      id = message.id,
      result = {
        protocolVersion = "2025-06-18",
        capabilities = { tools = {} },
        serverInfo = { name = "fake-stdio-" .. mode, version = "1.0.0" },
      },
    })
  end
  if message.method == "notifications/initialized" then
    initialized = true
    return send({ id = "roots-1", method = "roots/list" })
  end
  if message.id == "roots-1" then
    return send({ method = "notifications/message", params = { level = "info", data = message.result } })
  end
  if not initialized then
    if mode ~= "silent" then
      send({ id = message.id, error = { code = -32601, message = "Method not found" } })
    end
    return
  end
  if message.method == "tools/call" and mode == "crash" then
    io.stderr:write("boom: crashing on purpose\n")
    os.exit(3)
  end
  if message.method == "tools/list" then
    return send({ id = message.id, result = { tools = { { name = "echo" } } } })
  end
  send({ id = message.id, result = { content = { { type = "text", text = "legacy-ok" } } } })
end

local function modern(message)
  local meta = message.params and message.params._meta or {}
  if meta["io.modelcontextprotocol/protocolVersion"] ~= "2026-07-28" then
    return send({ id = message.id, error = { code = -32022, message = "Unsupported protocol version" } })
  end
  if message.method == "server/discover" then
    return send({
      id = message.id,
      result = {
        resultType = "complete",
        supportedVersions = { "2026-07-28" },
        capabilities = { tools = {} },
        _meta = { ["io.modelcontextprotocol/serverInfo"] = { name = "fake-stdio-modern", version = "1.0.0" } },
      },
    })
  end
  if message.method == "tools/call" then
    local responses = message.params.inputResponses
    if not responses then
      return send({
        id = message.id,
        result = {
          resultType = "input_required",
          inputRequests = { where = { method = "roots/list" } },
          requestState = "opaque-state",
        },
      })
    end
    return send({
      id = message.id,
      result = {
        resultType = "complete",
        content = {
          { type = "text", text = vim.json.encode({ state = message.params.requestState, responses = responses }) },
        },
      },
    })
  end
  send({ id = message.id, result = { resultType = "complete", tools = {} } })
end

while true do
  local line = io.read("l")
  if not line then
    break
  end
  local ok, message = pcall(vim.json.decode, line)
  if ok then
    if mode == "modern" then
      modern(message)
    else
      legacy(message)
    end
  end
end
