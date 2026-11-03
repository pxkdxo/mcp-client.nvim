local rpc = require("mcp-client.rpc")

--- A client double that serves `pages` (a cursor -> result map; the first
--- page is keyed by `false`) and records the cursor each request carried.
local function paged_client(pages)
  local seen = {}
  return {
    seen = seen,
    request = function(_, message, callback)
      local cursor = message.params.cursor
      table.insert(seen, cursor or false)
      local page = pages[cursor or false]
      if type(page) == "string" then
        return callback(page, nil)
      end
      callback(nil, { jsonrpc = "2.0", id = message.id, result = page })
    end,
  }
end

describe("rpc.list_all", function()
  it("follows nextCursor across pages and concatenates the items in order", function()
    local fake = paged_client({
      [false] = { tools = { { name = "a" } }, nextCursor = "p2" },
      p2 = { tools = { { name = "b" }, { name = "c" } }, nextCursor = "p3" },
      p3 = { tools = { { name = "d" } } },
    })
    local got_err, got_items
    rpc.list_all(fake, "tools/list", "tools", function(err, items)
      got_err, got_items = err, items
    end)
    assert.is_nil(got_err)
    assert.are.same({ { name = "a" }, { name = "b" }, { name = "c" }, { name = "d" } }, got_items)
    assert.are.same({ false, "p2", "p3" }, fake.seen)
  end)

  it("fails instead of looping when the server repeats a cursor", function()
    local fake = paged_client({
      [false] = { tools = {}, nextCursor = "again" },
      again = { tools = { { name = "x" } }, nextCursor = "again" },
    })
    local got_err, got_items
    rpc.list_all(fake, "tools/list", "tools", function(err, items)
      got_err, got_items = err, items
    end)
    assert.matches("repeated cursor", got_err)
    assert.is_nil(got_items)
  end)

  it("surfaces an error from a later page rather than returning a partial listing", function()
    local fake = paged_client({
      [false] = { prompts = { { name = "a" } }, nextCursor = "p2" },
      p2 = "server returned status 500",
    })
    local got_err, got_items
    rpc.list_all(fake, "prompts/list", "prompts", function(err, items)
      got_err, got_items = err, items
    end)
    assert.are.equal("server returned status 500", got_err)
    assert.is_nil(got_items)
  end)
end)
