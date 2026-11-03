local wait_for = require("tests.helpers.wait")
local client = require("mcp-client.client")
local rpc = require("mcp-client.rpc")

local FIXTURE = vim.fn.fnamemodify("tests/fixtures/stdio_server.lua", ":p")

local function stdio_config(mode, extra)
  return vim.tbl_extend("force", {
    name = "stdio-" .. mode,
    command = vim.v.progpath,
    args = { "--clean", "-l", FIXTURE, mode },
  }, extra or {})
end

local function connect(config)
  local outcome
  client.connect(config, {
    on_connect = function(c, err)
      outcome = { client = c, err = err }
    end,
  })
  assert.is_true(wait_for(function()
    return outcome ~= nil
  end, 8000))
  return outcome.client, outcome.err
end

local function request(c, method, params)
  local reply
  c:request({ jsonrpc = "2.0", id = rpc.next_id(), method = method, params = params or {} }, function(err, result)
    reply = { err = err, result = result }
  end)
  assert.is_true(wait_for(function()
    return reply ~= nil
  end, 5000))
  return reply
end

local function process_alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

describe("transport.stdio", function()
  local autocmds = {}

  local function collect(pattern)
    local seen = {}
    table.insert(
      autocmds,
      vim.api.nvim_create_autocmd("User", {
        pattern = pattern,
        callback = function(ev)
          table.insert(seen, ev.data)
        end,
      })
    )
    return seen
  end

  after_each(function()
    client._reset_registry()
    vim.wait(50, function()
      return false
    end)
    for _, id in ipairs(autocmds) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    autocmds = {}
  end)

  it("speaks the modern era to a server that answers server/discover, including multi round-trip input", function()
    local c, err = connect(stdio_config("modern", {
      handlers = {
        roots = function(ctx)
          return { { uri = "file:///work", name = ctx.server } }
        end,
      },
    }))
    assert.is_nil(err)
    assert.are.equal("stdio", c.transport)
    assert.are.equal("modern", c.era)
    assert.are.equal("fake-stdio-modern", c.server_info.name)

    local reply = request(c, "tools/call", { name = "where", arguments = {} })
    assert.is_nil(reply.err)
    local echoed = vim.json.decode(reply.result.result.content[1].text)
    assert.are.equal("opaque-state", echoed.state)
    assert.are.same({ roots = { { uri = "file:///work", name = "stdio-modern" } } }, echoed.responses.where)
  end)

  it("falls back to the legacy handshake and answers the server's own requests", function()
    local notified = collect("MCPNotify")
    local c, err = connect(stdio_config("legacy", {
      handlers = {
        roots = function()
          return { { uri = "file:///legacy" } }
        end,
      },
    }))
    assert.is_nil(err)
    assert.are.equal("legacy", c.era)
    assert.are.equal("2025-06-18", c.protocol_version)

    assert.is_true(wait_for(function()
      return #notified > 0
    end, 5000))
    assert.are.equal("notifications/message", notified[1].method)
    assert.are.equal("stdio-legacy", notified[1].server)
    assert.are.same({ roots = { { uri = "file:///legacy" } } }, notified[1].params.data)
    assert.are.equal("legacy-ok", request(c, "tools/call", { name = "echo" }).result.result.content[1].text)
  end)

  it("treats a server that never answers the discovery probe as legacy", function()
    local c, err = connect(stdio_config("silent", { discover_timeout = 200 }))
    assert.is_nil(err)
    assert.are.equal("legacy", c.era)
  end)

  it("fails pending requests with the server's stderr when it crashes, then restarts it", function()
    local attached = collect("MCPAttach")
    local c, err = connect(stdio_config("crash", { reconnect = { initial_delay = 20, max_attempts = 2 } }))
    assert.is_nil(err)

    local reply = request(c, "tools/call", { name = "echo" })
    assert.matches("exited with code 3", reply.err)
    assert.matches("boom: crashing on purpose", reply.err)

    assert.is_true(wait_for(function()
      return #attached >= 2
    end, 8000))
    assert.are.equal("connected", c:state())
    assert.are.equal("echo", request(c, "tools/list").result.result.tools[1].name)
  end)

  it("reports a command that cannot be started", function()
    local c, err = connect({ name = "missing", command = "mcp-client-no-such-binary" })
    assert.is_nil(c)
    assert.matches("failed to start", err)
  end)

  it("stops the server process on disconnect", function()
    local c = connect(stdio_config("legacy"))
    local pid = c.pid
    assert.is_number(pid)
    assert.is_true(process_alive(pid))

    c:disconnect()
    assert.is_true(wait_for(function()
      return not process_alive(pid)
    end, 5000))
  end)
end)
