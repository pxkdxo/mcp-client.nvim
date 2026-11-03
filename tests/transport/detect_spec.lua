local HttpDouble = require("tests.helpers.http_double")
local FakeServer = require("tests.helpers.fake_mcp_server")
local wait_for = require("tests.helpers.wait")

local detect = require("mcp-client.transport.detect")

local function connect(url)
  local outcome
  detect.connect({ url = url, timeout = 2000 }, function(result, err)
    outcome = { result = result, err = err }
  end)
  assert.is_true(wait_for(function()
    return outcome ~= nil
  end, 4000))
  return outcome.result, outcome.err
end

local function header(head, name)
  return head and head:match("\r\n" .. name .. ":%s*([^\r\n]+)")
end

describe("transport.detect", function()
  local server, double

  after_each(function()
    if server then
      server:stop()
      server = nil
    end
    if double then
      double:stop()
      double = nil
    end
  end)

  it("connects to a modern server with server/discover and no handshake", function()
    server = FakeServer.new({ era = "modern" })
    local result, err = connect(server.url)

    assert.is_nil(err)
    assert.are.equal("modern", result.era)
    assert.are.equal("streamable_http", result.transport)
    assert.are.equal("2026-07-28", result.protocol_version)
    assert.are.equal("fake-modern", result.description.server_info.name)
    assert.are.same({ "server/discover" }, server:methods())

    local discover = server:last("server/discover")
    assert.are.equal("2026-07-28", header(discover.head, "MCP%-Protocol%-Version"))
    assert.are.equal("server/discover", header(discover.head, "Mcp%-Method"))
    local meta = discover.message.params._meta
    assert.are.equal("2026-07-28", meta["io.modelcontextprotocol/protocolVersion"])
    assert.are.equal("mcp-client.nvim", meta["io.modelcontextprotocol/clientInfo"].name)
    assert.is_table(meta["io.modelcontextprotocol/clientCapabilities"].elicitation)
    result.client:close()
  end)

  it("falls back to the legacy handshake on a legacy Streamable HTTP server", function()
    server = FakeServer.new({ era = "legacy" })
    local result, err = connect(server.url)

    assert.is_nil(err)
    assert.are.equal("legacy", result.era)
    assert.are.equal("streamable_http", result.transport)
    assert.are.equal("2025-11-25", result.protocol_version)
    assert.are.equal("fake-session", result.session_id)
    -- notifications/initialized is delivered before the connection is handed back.
    assert.are.same({ "server/discover", "initialize", "notifications/initialized" }, server:methods())
    assert.are.equal("2025-11-25", server:last("initialize").message.params.protocolVersion)

    local initialized = server:last("notifications/initialized")
    assert.are.equal("fake-session", header(initialized.head, "Mcp%-Session%-Id"))
    assert.are.equal("2025-11-25", header(initialized.head, "MCP%-Protocol%-Version"))
    result.client:close()
  end)

  it("refuses a legacy server that negotiates a revision this client does not speak", function()
    server = FakeServer.new({ era = "legacy", legacy_version = "2023-01-01" })
    local result, err = connect(server.url)

    assert.is_nil(result)
    assert.matches("unsupported protocol version", err)
    assert.is_nil(server:last("notifications/initialized"))
  end)

  for _, status in ipairs({ 400, 404, 405 }) do
    it("falls back to legacy HTTP+SSE and initializes over it when POST returns " .. status, function()
      server = FakeServer.new({ era = "legacy_sse", legacy_version = "2024-11-05" })
      local post_status = status
      local route = server._route
      server._route = function(self, method, path, message, head)
        if path == "/mcp" and method == "POST" then
          return { status = post_status, body = "" }
        end
        return route(self, method, path, message, head)
      end

      local result, err = connect(server.url)

      assert.is_nil(err)
      assert.are.equal("legacy_sse", result.transport)
      assert.are.equal("legacy", result.era)
      assert.are.equal("2024-11-05", result.protocol_version)
      assert.are.equal(server.double.url .. "/messages?sessionId=fake-session", result.endpoint)
      assert.are.same({ "server/discover", "initialize", "initialize", "notifications/initialized" }, server:methods())
      assert.is_true(server.initialized)
      result.client:close()
    end)
  end

  describe("legacy SSE discovery that never completes", function()
    --- A server that answers GET with `get`, accepts but never answers POSTs to
    --- its message endpoint, and 404s every other POST.
    local function sse_only(get)
      double = HttpDouble.new({
        on_request = function(method, path, rest)
          if method == "GET" then
            return get(rest)
          end
          if path:match("^/messages") then
            return { status = 202, body = "" }
          end
          return { status = 404, body = "" }
        end,
      })
      return double.url .. "/mcp"
    end

    local function connect_within(url, ms)
      local outcome
      detect.connect({ url = url, timeout = ms }, function(result, err)
        outcome = { result = result, err = err }
      end)
      assert.is_true(wait_for(function()
        return outcome ~= nil
      end, ms + 2000))
      return outcome.result, outcome.err
    end

    it("fails when the GET returns without an endpoint event", function()
      local result, err = connect_within(
        sse_only(function()
          return { status = 200, body = "" }
        end),
        5000
      )
      assert.is_nil(result)
      assert.matches("stream ended %(status 200%)", err)
    end)

    it("fails within the timeout when the stream stays open without an endpoint event", function()
      local result, err = connect_within(
        sse_only(function()
          return { status = 200, sse = {} }
        end),
        300
      )
      assert.is_nil(result)
      assert.matches("did not send an endpoint event within 300 ms", err)
    end)

    it("reports a timeout when initialize is never answered over the stream", function()
      local result, err = connect_within(
        sse_only(function()
          return { status = 200, sse = { { event = "endpoint", data = "/messages" } } }
        end),
        300
      )
      assert.is_nil(result)
      assert.matches("did not complete the handshake within 300 ms", err)
    end)
  end)

  it("reports a modern server that supports none of this client's revisions", function()
    server = FakeServer.new({ era = "modern", supported = { "2099-01-01" } })
    local result, err = connect(server.url)

    assert.is_nil(result)
    assert.matches("2099%-01%-01", err)
    assert.are.same({ "server/discover" }, server:methods())
  end)

  it("uses the legacy handshake when a modern error lists only legacy revisions", function()
    server = FakeServer.new({ era = "modern", supported = { "2025-11-25" } })
    local route = server._route
    server._route = function(self, method, path, message, head)
      if message and message.method == "initialize" then
        return {
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = vim.json.encode(self:_initialize_result(message)),
        }
      end
      return route(self, method, path, message, head)
    end

    local result, err = connect(server.url)

    assert.is_nil(err)
    assert.are.equal("legacy", result.era)
    assert.are.same({ "server/discover", "initialize", "notifications/initialized" }, server:methods())
    result.client:close()
  end)

  it("decodes a DiscoverResult delivered as an SSE response stream", function()
    double = HttpDouble.new({
      on_request = function(_, _, rest)
        local message = vim.json.decode(rest)
        local data = vim.json.encode({
          jsonrpc = "2.0",
          id = message.id,
          result = { resultType = "complete", supportedVersions = { "2026-07-28" }, capabilities = {} },
        })
        return {
          status = 200,
          headers = { ["Content-Type"] = "text/event-stream" },
          body = "event: message\ndata: " .. data .. "\n\n",
        }
      end,
    })

    local result, err = connect(double.url .. "/mcp")

    assert.is_nil(err)
    assert.are.equal("modern", result.era)
    result.client:close()
  end)

  it("sends an Accept header naming both response shapes the spec allows", function()
    server = FakeServer.new({ era = "modern" })
    local result = connect(server.url)
    assert.matches("Accept:%s*application/json,%s*text/event%-stream", server:last("server/discover").head)
    result.client:close()
  end)

  it("surfaces a clear error when the server is unreachable", function()
    local probe = vim.uv.new_tcp()
    probe:bind("127.0.0.1", 0)
    local port = probe:getsockname().port
    probe:close()

    local result, err = connect(string.format("http://127.0.0.1:%d/mcp", port))
    assert.is_nil(result)
    assert.matches("could not connect", err)
  end)

  for _, status in ipairs({ 401, 500 }) do
    it("fails on status " .. status .. " instead of guessing an era", function()
      double = HttpDouble.new({
        on_request = function()
          return { status = status, body = "nope" }
        end,
      })
      local result, err = connect(double.url .. "/mcp")
      assert.is_nil(result)
      assert.matches("status " .. status, err)
    end)
  end
end)
