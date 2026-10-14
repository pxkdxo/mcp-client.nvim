local native = require("mcp-client.native")
local client = require("mcp-client.client")
local legacy = require("mcp-client.native_legacy")
local function call(c, method, params)
  local result, failure
  c:request({method=method,params=params}, function(err,value) failure=err; result=value end)
  assert.is_nil(failure)
  return result
end
describe("legacy native bridge", function()
  after_each(function() client._reset_registry() end)
  it("preserves tool schema, arguments, chained text and tool errors", function()
    local converted = legacy.convert({name="legacy", capabilities={tools={
      {name="echo", inputSchema={type="object"}, handler=function(req,res)
        return res:text(req.params.text):text("suffix"):send()
      end},
      {name="fail", handler=function(_,res) return res:error("failed") end},
    }}})
    local c=native.register(converted)
    assert.are.equal("object", call(c,"tools/list",{}).tools[1].inputSchema.type)
    assert.are.same({{type="text",text="hello"},{type="text",text="suffix"}},
      call(c,"tools/call",{name="echo",arguments={text="hello"}}).content)
    assert.is_true(call(c,"tools/call",{name="fail"}).isError)
  end)
  it("preserves resource URI and prompt roles, and reports omitted templates", function()
    local converted, omitted=legacy.convert({name="legacy",capabilities={
      resources={{name="state",uri="state://active",handler=function(_,res) return res:text("state"):send() end}},
      resourceTemplates={{uriTemplate="state://{id}"}},
      prompts={{name="plan",arguments={{name="task"}},handler=function(req,res)
        return res:user():text(req.params.task):llm():text("ready"):send()
      end}},
    }})
    assert.is_true(omitted)
    local c=native.register(converted)
    assert.are.equal("state://active",call(c,"resources/read",{uri="state://active"}).contents[1].uri)
    local messages=call(c,"prompts/get",{name="plan",arguments={task="work"}}).messages
    assert.are.equal("user",messages[1].role)
    assert.are.equal("work",messages[1].content.text)
    assert.are.equal("assistant",messages[2].role)
  end)
end)
