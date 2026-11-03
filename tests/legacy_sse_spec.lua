local LegacySse = require("mcp-client.transport.legacy_sse")

--- Covers server-notification routing and the SSE `retry:` reconnection
--- hint by feeding raw SSE lines to the parser directly -- no socket, no
--- network.

describe("transport.legacy_sse", function()
  local function client_with_lines(lines)
    local c = LegacySse.new({ stream_url = "http://x/mcp", endpoint = "http://x/messages" })
    c:attach_parser()
    for _, line in ipairs(lines) do
      c:feed_line(line)
    end
    return c
  end

  it("routes a server-originated notification to the notification handler", function()
    local seen
    local c = LegacySse.new({ stream_url = "http://x/mcp", endpoint = "http://x/messages" })
    c:set_on_message(function(msg)
      seen = msg
    end)
    c:attach_parser()

    c:feed_line("event: message")
    c:feed_line('data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}')
    c:feed_line("")

    assert.is_not_nil(seen)
    assert.are.equal("notifications/message", seen.method)
  end)

  it("routes a server request whose id equals a pending request id to the message handler", function()
    local seen, response
    local c = LegacySse.new({ stream_url = "http://x/mcp", endpoint = "http://x/messages" })
    c:set_on_message(function(msg)
      seen = msg
    end)
    c._pending[7] = function(...)
      response = { ... }
    end
    c:attach_parser()

    c:feed_line('data: {"jsonrpc":"2.0","id":7,"method":"roots/list"}')
    c:feed_line("")

    assert.are.equal("roots/list", seen.method)
    assert.is_nil(response)
    assert.is_function(c._pending[7])
  end)

  it("captures the most recent SSE retry: hint as a reconnect delay", function()
    local c = client_with_lines({
      "retry: 4200",
      "",
    })
    assert.are.equal(4200, c:get_retry_hint())
  end)

  it("has no retry hint before the server sends one", function()
    local c = client_with_lines({})
    assert.is_nil(c:get_retry_hint())
  end)
end)
