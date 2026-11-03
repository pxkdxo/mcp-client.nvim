local FakeServer = require("tests.helpers.fake_mcp_server")
local wait_for = require("tests.helpers.wait")
local client = require("mcp-client.client")
local rpc = require("mcp-client.rpc")

local function connect(config)
  local outcome
  client.connect(config, {
    on_connect = function(c, err)
      outcome = { client = c, err = err }
    end,
  })
  assert.is_true(wait_for(function()
    return outcome ~= nil
  end, 4000))
  assert.is_nil(outcome.err)
  return outcome.client
end

local function request(c, method, params)
  local reply
  c:request({ jsonrpc = "2.0", id = rpc.next_id(), method = method, params = params or {} }, function(err, result)
    reply = { err = err, result = result }
  end)
  assert.is_true(wait_for(function()
    return reply ~= nil
  end, 4000))
  return reply
end

local function header(head, name)
  return head and head:match("\r\n" .. name .. ":%s*([^\r\n]+)")
end

local function sse_frame(message)
  return "data: " .. vim.json.encode(message) .. "\r\n\r\n"
end

describe("client protocol behavior over HTTP", function()
  local server
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
    if server then
      server:stop()
      server = nil
    end
  end)

  describe("modern era", function()
    it("declares the revision in _meta and mirrors method and name into headers", function()
      server = FakeServer.new({
        era = "modern",
        handle = function()
          return { resultType = "complete", content = {} }
        end,
      })
      local c = connect({ url = server.url })

      assert.is_nil(request(c, "tools/call", { name = "météo", arguments = {} }).err)
      local call = server:last("tools/call")
      assert.are.equal("2026-07-28", call.message.params._meta["io.modelcontextprotocol/protocolVersion"])
      assert.are.equal("tools/call", header(call.head, "Mcp%-Method"))
      assert.are.equal("=?base64?" .. vim.base64.encode("météo") .. "?=", header(call.head, "Mcp%-Name"))
      assert.is_nil(header(call.head, "Mcp%-Session%-Id"))
    end)

    it("answers input_required through the handlers and retries with the responses and request state", function()
      local elicited
      server = FakeServer.new({
        era = "modern",
        handle = function(message)
          if not message.params.inputResponses then
            return {
              resultType = "input_required",
              inputRequests = {
                login = {
                  method = "elicitation/create",
                  params = { mode = "form", message = "Who are you?", requestedSchema = { type = "object" } },
                },
              },
              requestState = "state-1",
            }
          end
          return { resultType = "complete", content = { { type = "text", text = "done" } } }
        end,
      })
      local c = connect({
        url = server.url,
        name = "mrtr",
        handlers = {
          elicitation = function(params, ctx, respond)
            elicited = { params = params, ctx = ctx }
            respond(nil, { action = "accept", content = { name = "octocat" } })
          end,
        },
      })

      local reply = request(c, "tools/call", { name = "whoami", arguments = { verbose = true } })

      assert.is_nil(reply.err)
      assert.are.equal("done", reply.result.result.content[1].text)
      assert.are.equal("Who are you?", elicited.params.message)
      assert.are.equal("mrtr", elicited.ctx.server)

      local calls = {}
      for _, entry in ipairs(server.received) do
        if entry.message and entry.message.method == "tools/call" then
          table.insert(calls, entry.message)
        end
      end
      assert.are.equal(2, #calls)
      assert.are_not.equal(calls[1].id, calls[2].id)
      assert.is_nil(calls[1].params.requestState)
      assert.are.equal("state-1", calls[2].params.requestState)
      assert.are.same({ login = { action = "accept", content = { name = "octocat" } } }, calls[2].params.inputResponses)
      assert.are.same({ verbose = true }, calls[2].params.arguments)
    end)

    it("rejects a result whose resultType it does not recognize", function()
      server = FakeServer.new({
        era = "modern",
        handle = function()
          return { resultType = "task_started" }
        end,
      })
      local c = connect({ url = server.url })
      assert.matches('unrecognized resultType "task_started"', request(c, "tools/call", { name = "x" }).err)
    end)

    it("drops tools with invalid x-mcp-header annotations and mirrors valid ones on tools/call", function()
      local warned = {}
      local notify = vim.notify
      vim.notify = function(msg)
        table.insert(warned, msg)
      end
      server = FakeServer.new({
        era = "modern",
        handle = function(message)
          if message.method == "tools/list" then
            return {
              resultType = "complete",
              tools = {
                {
                  name = "execute_sql",
                  inputSchema = {
                    type = "object",
                    properties = {
                      region = { type = "string", ["x-mcp-header"] = "Region" },
                      limit = { type = "integer", ["x-mcp-header"] = "Limit" },
                      query = { type = "string" },
                    },
                  },
                },
                {
                  name = "broken",
                  inputSchema = {
                    type = "object",
                    properties = { ratio = { type = "number", ["x-mcp-header"] = "Ratio" } },
                  },
                },
              },
            }
          end
          return { resultType = "complete", content = {} }
        end,
      })
      local c = connect({ url = server.url })

      local listed = request(c, "tools/list").result.result.tools
      assert.are.equal(1, #listed)
      assert.are.equal("execute_sql", listed[1].name)
      assert.is_true(wait_for(function()
        return #warned > 0
      end))
      vim.notify = notify
      assert.matches('"broken"', warned[1])

      request(
        c,
        "tools/call",
        { name = "execute_sql", arguments = { region = "us-west1", limit = 5, query = "SELECT 1" } }
      )
      local call = server:last("tools/call")
      assert.are.equal("us-west1", header(call.head, "Mcp%-Param%-Region"))
      assert.are.equal("5", header(call.head, "Mcp%-Param%-Limit"))
    end)

    it("opens subscriptions/listen for changeable lists and surfaces its notifications as MCPNotify", function()
      local notified = collect("MCPNotify")
      server = FakeServer.new({ era = "modern", capabilities = { tools = { listChanged = true }, prompts = {} } })
      local route = server._route
      server._route = function(self, method, path, message, head)
        if message and message.method == "subscriptions/listen" then
          local meta = { ["io.modelcontextprotocol/subscriptionId"] = message.id }
          return {
            status = 200,
            sse = {
              {
                data = vim.json.encode({
                  jsonrpc = "2.0",
                  method = "notifications/subscriptions/acknowledged",
                  params = { _meta = meta, notifications = message.params.notifications },
                }),
              },
              {
                data = vim.json.encode({
                  jsonrpc = "2.0",
                  method = "notifications/tools/list_changed",
                  params = { _meta = meta },
                }),
              },
            },
          }
        end
        return route(self, method, path, message, head)
      end

      local c = connect({ url = server.url, name = "subscriber" })

      assert.is_true(wait_for(function()
        return #notified > 0
      end, 3000))
      assert.are.same({ toolsListChanged = true }, server:last("subscriptions/listen").message.params.notifications)
      assert.are.equal(1, #notified)
      assert.are.equal("notifications/tools/list_changed", notified[1].method)
      assert.are.equal("subscriber", notified[1].server)
      assert.are.equal(c.id, notified[1].client_id)
    end)
  end)

  describe("legacy era", function()
    it("answers a server request sent mid-stream on a POST response, before that request completes", function()
      local stream
      server = FakeServer.new({ era = "legacy" })
      local route = server._route
      server._route = function(self, method, path, message, head)
        if message and message.method == "tools/call" then
          return {
            status = 200,
            sse = {
              { data = vim.json.encode({ jsonrpc = "2.0", id = "srv-1", method = "roots/list" }) },
            },
            on_stream = function(socket)
              stream = { socket = socket, call_id = message.id }
            end,
          }
        end
        if message and message.id == "srv-1" and message.method == nil then
          stream.answer = message
          stream.socket:write(sse_frame({ jsonrpc = "2.0", id = stream.call_id, result = { content = {} } }))
          stream.socket:close()
          return { status = 202, body = "" }
        end
        return route(self, method, path, message, head)
      end

      local c = connect({
        url = server.url,
        handlers = {
          roots = function()
            return { { uri = "file:///here" } }
          end,
        },
      })
      local reply = request(c, "tools/call", { name = "list_roots" })

      assert.is_nil(reply.err)
      assert.are.same({ roots = { { uri = "file:///here" } } }, stream.answer.result)
      assert.are.equal("fake-session", header(server:last("tools/call").head, "Mcp%-Session%-Id"))
    end)

    it("receives notifications and requests on the GET stream and fires MCPNotify with their content", function()
      local notified = collect("MCPNotify")
      server = FakeServer.new({ era = "legacy", get_stream = true })
      connect({ url = server.url, name = "listener", handlers = { elicitation = false } })

      assert.is_true(wait_for(function()
        return server.sse._socket ~= nil
      end))
      server.sse:push_message({ jsonrpc = "2.0", method = "notifications/resources/list_changed" })
      server.sse:push_message({ jsonrpc = "2.0", id = 41, method = "elicitation/create", params = {} })

      assert.is_true(wait_for(function()
        return #notified > 0
      end))
      assert.are.equal("notifications/resources/list_changed", notified[1].method)
      assert.are.equal("listener", notified[1].server)

      local answer
      assert.is_true(wait_for(function()
        for _, entry in ipairs(server.received) do
          if entry.message and entry.message.id == 41 then
            answer = entry.message
          end
        end
        return answer ~= nil
      end))
      -- Elicitation is disabled for this server, so the request is refused.
      assert.are.equal(-32601, answer.error.code)
      assert.are.equal("fake-session", header(server:last("notifications/initialized").head, "Mcp%-Session%-Id"))
    end)

    it("declares only the capabilities its handlers provide", function()
      server = FakeServer.new({ era = "legacy" })
      connect({
        url = server.url,
        handlers = {
          roots = false,
          sampling = function(_, _, respond)
            respond(nil, {})
          end,
        },
      })
      local capabilities = server:last("initialize").message.params.capabilities
      assert.is_nil(capabilities.roots)
      assert.is_table(capabilities.sampling)
      assert.is_table(capabilities.elicitation)
    end)
  end)
end)
