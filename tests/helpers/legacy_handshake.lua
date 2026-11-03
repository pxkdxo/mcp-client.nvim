--- The HttpDouble response a legacy Streamable HTTP server gives to
--- handshake traffic -- the modern `server/discover` probe (rejected, so the
--- client falls back), `initialize`, and `notifications/initialized` -- or nil
--- for any other message, which the calling double answers itself.
return function(message)
  if type(message) ~= "table" then
    return nil
  end
  if message.method == "server/discover" then
    return { status = 400, body = "" }
  end
  if message.method == "initialize" then
    return {
      status = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = vim.json.encode({
        jsonrpc = "2.0",
        id = message.id,
        result = {
          protocolVersion = "2025-11-25",
          capabilities = {},
          serverInfo = { name = "legacy-test", version = "0.0.1" },
        },
      }),
    }
  end
  if message.method == "notifications/initialized" then
    return { status = 202, body = "" }
  end
  return nil
end
