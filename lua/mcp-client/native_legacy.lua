-- Compatibility for synchronous mcphub-style Lua handlers; no hub dependency.
-- Deliberately limited to tools, static resources and prompts. Resource
-- templates and asynchronous response builders are not silently emulated.
local M = {}
local function wrap(item, kind)
  return function(arguments)
    local response = { content = {}, messages = {}, role = "user" }
    function response:user() self.role = "user"; return self end
    function response:llm() self.role = "assistant"; return self end
    function response:text(text)
      local content = { type = "text", text = tostring(text) }
      if kind == "prompts" then
        table.insert(self.messages, { role = self.role, content = content })
      else
        table.insert(self.content, content)
      end
      return self
    end
    function response:send()
      if kind == "prompts" then return { messages = self.messages } end
      if kind == "resources" then
        local contents = {}
        for _, content in ipairs(self.content) do
          table.insert(contents, { uri = item.uri, mimeType = item.mimeType or "text/plain", text = content.text })
        end
        return { contents = contents }
      end
      return { content = self.content, isError = self.isError or nil }
    end
    function response:error(message)
      if kind ~= "tools" then error(tostring(message)) end
      self.isError = true
      return self:text(message):send()
    end
    local result = item.handler({ params = arguments or {} }, response)
    assert(result ~= nil, "legacy native handler must return a synchronous response")
    return result
  end
end

function M.convert(server)
  assert(type(server) == "table" and type(server.name) == "string", "named server required")
  local converted = { name = server.name }
  local capabilities = server.capabilities or {}
  for _, kind in ipairs({ "tools", "resources", "prompts" }) do
    local meta_key = ({ tools = "tool_meta", resources = "resource_meta", prompts = "prompt_meta" })[kind]
    converted[kind], converted[meta_key] = {}, {}
    for _, item in ipairs(capabilities[kind] or {}) do
      local key = kind == "resources" and item.uri or item.name
      assert(type(key) == "string" and type(item.handler) == "function", "invalid legacy " .. kind)
      local metadata = vim.deepcopy(item)
      metadata.handler = nil
      converted[kind][key] = wrap(item, kind)
      converted[meta_key][key] = metadata
    end
  end
  -- Explicitly expose what migration does not support to the caller.
  return converted, #(capabilities.resourceTemplates or {}) > 0
end
return M
