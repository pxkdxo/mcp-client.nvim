local elicitation = require("mcp-client.elicitation")
local handlers = require("mcp-client.handlers")

--- Replace vim.ui.select / vim.ui.input with a scripted queue of answers.
--- Each answer is a choice label (select), a string (input), or `false` for
--- escaping the prompt. Every prompt shown is recorded in `prompts`.
local function script(answers)
  local prompts = {}
  local original = { select = vim.ui.select, input = vim.ui.input, open = vim.ui.open }
  local opened = {}
  vim.ui.select = function(items, opts, on_choice)
    table.insert(prompts, opts.prompt)
    local answer = table.remove(answers, 1)
    if answer == false then
      return on_choice(nil)
    end
    for _, item in ipairs(items) do
      local text = opts.format_item and opts.format_item(item) or item
      if text == answer then
        return on_choice(item)
      end
    end
    error("no choice " .. tostring(answer) .. " in " .. vim.inspect(items))
  end
  vim.ui.input = function(opts, on_confirm)
    table.insert(prompts, opts.prompt)
    local answer = table.remove(answers, 1)
    on_confirm(answer ~= false and answer or nil)
  end
  vim.ui.open = function(url)
    table.insert(opened, url)
  end
  return {
    prompts = prompts,
    opened = opened,
    restore = function()
      vim.ui.select, vim.ui.input, vim.ui.open = original.select, original.input, original.open
    end,
  }
end

local FORM = {
  message = "Tell me about yourself",
  requestedSchema = {
    type = "object",
    properties = {
      age = { type = "integer", minimum = 0 },
      color = { type = "string", oneOf = { { const = "#f00", title = "Red" }, { const = "#00f", title = "Blue" } } },
      name = { type = "string", title = "Name" },
      subscribe = { type = "boolean" },
    },
    required = { "name", "age" },
  },
}

local function run(params, answers)
  local ui = script(answers)
  local result
  local ok, err = pcall(elicitation.prompt, params, { server = "srv" }, function(_, r)
    result = r
  end)
  ui.restore()
  assert(ok, err)
  return result, ui
end

describe("elicitation (default vim.ui handler)", function()
  local notify
  before_each(function()
    notify = vim.notify
    vim.notify = function() end
  end)
  after_each(function()
    vim.notify = notify
  end)

  it("collects typed form fields, re-asking on invalid input, and submits after review", function()
    local result, ui = run(FORM, { "Respond", "abc", "3.5", "42", "Blue", "Ada", "(leave empty)", "Submit" })
    assert.are.same({ action = "accept", content = { age = 42, color = "#00f", name = "Ada" } }, result)
    assert.matches("^%[srv%] Tell me about yourself", ui.prompts[1])
    -- age was asked three times: two rejected answers, then a valid one.
    assert.are.equal(ui.prompts[2], ui.prompts[3])
    assert.are.equal(ui.prompts[2], ui.prompts[4])
    assert.matches("Name: Ada", ui.prompts[#ui.prompts])
  end)

  it("returns to the fields from the review step on Edit", function()
    local result = run(FORM, { "Respond", "1", "Red", "Al", "false", "Edit", "2", "Red", "Bo", "true", "Submit" })
    assert.are.same({ action = "accept", content = { age = 2, color = "#f00", name = "Bo", subscribe = true } }, result)
  end)

  it("answers decline and cancel for an explicit refusal and an escaped prompt", function()
    assert.are.same({ action = "decline" }, run(FORM, { "Decline" }))
    assert.are.same({ action = "cancel" }, run(FORM, { false }))
    assert.are.same({ action = "cancel" }, run(FORM, { "Respond", "1", false }))
  end)

  it("shows the full URL and its host and opens it only after consent", function()
    local params = { mode = "url", message = "Connect your account", url = "https://auth.example.com/connect?x=1" }
    local result, ui = run(params, { "Open in browser" })
    assert.are.same({ action = "accept" }, result)
    assert.are.same({ params.url }, ui.opened)
    assert.matches("URL:  https://auth%.example%.com/connect%?x=1", ui.prompts[1])
    assert.matches("Host: auth%.example%.com", ui.prompts[1])

    local declined, declined_ui = run(params, { "Decline" })
    assert.are.same({ action = "decline" }, declined)
    assert.are.same({}, declined_ui.opened)
  end)
end)

describe("handlers", function()
  it("refuses unsupported or disabled requests with method-not-found and reports handler errors", function()
    local errors = {}
    local function capture(err)
      table.insert(errors, err)
    end
    handlers.dispatch(nil, "sampling/createMessage", {}, { server = "s" }, capture)
    handlers.dispatch({ roots = false }, "roots/list", {}, { server = "s" }, capture)
    handlers.dispatch({
      roots = function()
        error("disk on fire")
      end,
    }, "roots/list", {}, { server = "s" }, capture)
    assert.are.equal(-32601, errors[1].code)
    assert.are.equal(-32601, errors[2].code)
    assert.are.equal(-32603, errors[3].code)
    assert.matches("disk on fire", errors[3].message)
  end)

  it("defaults roots to the working directory", function()
    local result
    handlers.dispatch(nil, "roots/list", {}, { server = "s" }, function(_, r)
      result = r
    end)
    assert.are.same(
      { { uri = vim.uri_from_fname(vim.fn.getcwd()), name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t") } },
      result.roots
    )
  end)

  it("fulfils input requests it supports, omits ones it does not, and aborts on a handler error", function()
    local responses
    handlers.resolve_input_requests(nil, {
      a = { method = "roots/list" },
      b = { method = "sampling/createMessage", params = {} },
    }, { server = "s" }, function(err, r)
      assert.is_nil(err)
      responses = r
    end)
    assert.are.same({ "a" }, vim.tbl_keys(responses))

    local failure
    handlers.resolve_input_requests({
      sampling = function(_, _, respond)
        respond("no model configured")
      end,
    }, { b = { method = "sampling/createMessage", params = {} } }, { server = "s" }, function(err)
      failure = err
    end)
    assert.matches("no model configured", failure)
  end)
end)
