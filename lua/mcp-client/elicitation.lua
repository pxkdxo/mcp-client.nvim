--- Default `elicitation/create` handler, built on `vim.ui.select` and
--- `vim.ui.input` so any UI override (telescope, fzf-lua, snacks, ...) applies.
---
--- Form mode asks for each field of the flat `requestedSchema`, then shows a
--- review step before submitting. URL mode shows the full URL and its host
--- and opens it only on explicit consent. Escaping any prompt answers
--- `cancel`; choosing "Decline" answers `decline`.
local M = {}

local function label(name, prop)
  local text = prop.title or name
  if prop.description then
    text = text .. " (" .. prop.description .. ")"
  end
  return text
end

--- `{ value, title }` choices for an enum-like schema, or nil.
local function enum_options(schema)
  if type(schema.enum) == "table" then
    return vim.tbl_map(function(value)
      return { value = value, title = tostring(value) }
    end, schema.enum)
  end
  local alternatives = schema.oneOf or schema.anyOf
  if type(alternatives) == "table" then
    return vim.tbl_map(function(alt)
      return { value = alt.const, title = alt.title or tostring(alt.const) }
    end, alternatives)
  end
  return nil
end

local function display(value)
  if type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), ", ")
  end
  return tostring(value)
end

local SKIP = {}

--- Validate one text answer against a primitive or multi-select schema.
--- @return any value, string|nil err  `SKIP` for an omitted optional field
local function parse(prop, text, required)
  if text == "" then
    if required then
      return nil, "a value is required"
    end
    return SKIP, nil
  end

  if prop.type == "number" or prop.type == "integer" then
    local number = tonumber(text)
    if not number then
      return nil, "not a number"
    end
    if prop.type == "integer" and number % 1 ~= 0 then
      return nil, "not an integer"
    end
    if prop.minimum and number < prop.minimum then
      return nil, "must be at least " .. prop.minimum
    end
    if prop.maximum and number > prop.maximum then
      return nil, "must be at most " .. prop.maximum
    end
    return number, nil
  end

  if prop.type == "array" then
    local options = enum_options(prop.items or {}) or {}
    local allowed = {}
    for _, option in ipairs(options) do
      allowed[tostring(option.value)] = option.value
    end
    local values = {}
    for _, part in ipairs(vim.split(text, ",", { trimempty = true })) do
      local key = vim.trim(part)
      if #options > 0 and allowed[key] == nil then
        return nil, string.format("%q is not one of the allowed values", key)
      end
      table.insert(values, allowed[key] ~= nil and allowed[key] or key)
    end
    if prop.minItems and #values < prop.minItems then
      return nil, "choose at least " .. prop.minItems
    end
    if prop.maxItems and #values > prop.maxItems then
      return nil, "choose at most " .. prop.maxItems
    end
    return values, nil
  end

  if prop.minLength and #text < prop.minLength then
    return nil, "must be at least " .. prop.minLength .. " characters"
  end
  if prop.maxLength and #text > prop.maxLength then
    return nil, "must be at most " .. prop.maxLength .. " characters"
  end
  return text, nil
end

--- Ask for one field. `on_value(value)` receives the answer (`SKIP` for an
--- omitted optional field); `on_cancel()` fires when the user escapes.
local function ask_field(server, name, prop, required, current, on_value, on_cancel)
  local prompt = string.format("[%s] %s%s", server, label(name, prop), required and " *" or "")
  local options = prop.type ~= "array" and enum_options(prop)
  if prop.type == "boolean" then
    options = { { value = true, title = "true" }, { value = false, title = "false" } }
  end

  if options then
    local items = vim.list_extend({}, options)
    if not required then
      table.insert(items, { value = SKIP, title = "(leave empty)" })
    end
    return vim.ui.select(items, {
      prompt = prompt,
      format_item = function(item)
        return item.title
      end,
    }, function(choice)
      if choice == nil then
        return on_cancel()
      end
      on_value(choice.value)
    end)
  end

  local default = current
  if default == nil or default == SKIP then
    default = prop.default
  end
  vim.ui.input({ prompt = prompt .. ": ", default = default ~= nil and display(default) or nil }, function(text)
    if text == nil then
      return on_cancel()
    end
    local value, err = parse(prop, text, required)
    if err then
      vim.notify(string.format("mcp-client: %s: %s", label(name, prop), err), vim.log.levels.WARN)
      return ask_field(server, name, prop, required, current, on_value, on_cancel)
    end
    on_value(value)
  end)
end

local function prompt_form(params, ctx, respond)
  local schema = type(params.requestedSchema) == "table" and params.requestedSchema or {}
  local properties = type(schema.properties) == "table" and schema.properties or {}
  local required = {}
  for _, name in ipairs(schema.required or {}) do
    required[name] = true
  end
  local names = vim.tbl_keys(properties)
  table.sort(names)

  local values = {}
  local function cancel()
    respond(nil, { action = "cancel" })
  end

  local review

  local function collect(index)
    local name = names[index]
    if name == nil then
      return review()
    end
    ask_field(ctx.server, name, properties[name], required[name], values[name], function(value)
      values[name] = value
      collect(index + 1)
    end, cancel)
  end

  function review()
    local content = {}
    local lines = { string.format("[%s] Send this response?", ctx.server) }
    for _, name in ipairs(names) do
      local value = values[name]
      if value ~= SKIP and value ~= nil then
        content[name] = value
        table.insert(lines, string.format("  %s: %s", label(name, properties[name]), display(value)))
      end
    end
    vim.ui.select({ "Submit", "Edit", "Decline" }, { prompt = table.concat(lines, "\n") }, function(choice)
      if choice == "Submit" then
        return respond(nil, { action = "accept", content = next(content) and content or vim.empty_dict() })
      elseif choice == "Edit" then
        return collect(1)
      elseif choice == "Decline" then
        return respond(nil, { action = "decline" })
      end
      cancel()
    end)
  end

  vim.ui.select({ "Respond", "Decline" }, {
    prompt = string.format("[%s] %s", ctx.server, params.message or "The server is requesting information."),
  }, function(choice)
    if choice == "Respond" then
      return collect(1)
    elseif choice == "Decline" then
      return respond(nil, { action = "decline" })
    end
    cancel()
  end)
end

local function prompt_url(params, ctx, respond)
  local url = tostring(params.url or "")
  local host = url:match("^%a[%w+.-]*://([^/?#]+)") or "(unknown host)"
  local lines = {
    string.format("[%s] %s", ctx.server, params.message or "The server asks you to open a URL."),
    "URL:  " .. url,
    "Host: " .. host,
  }
  if host:lower():find("xn--", 1, true) then
    table.insert(lines, "Warning: the host uses an internationalized (punycode) name.")
  end
  vim.ui.select({ "Open in browser", "Decline" }, { prompt = table.concat(lines, "\n") }, function(choice)
    if choice == "Open in browser" then
      vim.ui.open(url)
      return respond(nil, { action = "accept" })
    elseif choice == "Decline" then
      return respond(nil, { action = "decline" })
    end
    respond(nil, { action = "cancel" })
  end)
end

--- @param params table  `elicitation/create` params
--- @param ctx table  `{ server = <name> }`
--- @param respond fun(err: any, result: table)
function M.prompt(params, ctx, respond)
  if params.mode == "url" then
    return prompt_url(params, ctx, respond)
  end
  prompt_form(params, ctx, respond)
end

return M
