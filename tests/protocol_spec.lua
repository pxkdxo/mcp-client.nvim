local protocol = require("mcp-client.protocol")

describe("protocol", function()
  it("regression: capabilities with every handler disabled encode as a JSON object, not an array", function()
    local config = { handlers = { roots = false, elicitation = false } }
    local wire = vim.json.encode(protocol.initialize_request(config, 1))
    assert.is_not_nil(wire:find('"capabilities":{}', 1, true))
    local discover = vim.json.encode(protocol.discover_request(config, 2))
    assert.is_not_nil(discover:find('"io.modelcontextprotocol/clientCapabilities":{}', 1, true))
  end)

  it("adds request metadata without dropping the caller's params or _meta keys", function()
    local message = {
      jsonrpc = "2.0",
      id = 9,
      method = "tools/call",
      params = { name = "t", _meta = { progressToken = "p1" } },
    }
    local decorated = protocol.with_meta(message, {}, "2026-07-28")
    assert.are.equal("t", decorated.params.name)
    assert.are.equal("p1", decorated.params._meta.progressToken)
    assert.are.equal("2026-07-28", decorated.params._meta["io.modelcontextprotocol/protocolVersion"])
    assert.is_nil(message.params._meta["io.modelcontextprotocol/protocolVersion"])
  end)
end)
