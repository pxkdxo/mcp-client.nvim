--- JSON-RPC helpers shared by every caller of a client object's `request()`.
local M = {}

local next_request_id = 0

--- Process-wide monotonic JSON-RPC request id. Requests are correlated by id
--- (client.lua's `_in_flight`, each transport's pending map), so every caller
--- sharing a client must draw ids from the same sequence.
--- @return integer
function M.next_id()
  next_request_id = next_request_id + 1
  return next_request_id
end

--- Normalize a `request()` result to the bare MCP payload. A native client
--- returns the handler's value directly (e.g. `{ tools = {...} }`); a remote
--- client returns the JSON-RPC envelope (`{ jsonrpc, id, result = {...} }`).
--- A nested `result` table alone is not an envelope signal -- a native tool's
--- payload may use `result` as an ordinary field -- so unwrapping also
--- requires `jsonrpc` and `id`.
function M.unwrap_result(result)
  if type(result) == "table" and type(result.result) == "table" and result.jsonrpc == "2.0" and result.id ~= nil then
    return result.result
  end
  return result
end

--- Request every page of a paginated `*/list` method, following `nextCursor`
--- until the server omits it, and concatenate each page's `field` array.
--- Stops with an error if the server repeats a cursor, so a misbehaving
--- server cannot loop forever.
---
--- @param mcp_client table  a client object (remote or native)
--- @param method string  e.g. "tools/list"
--- @param field string  the result array to collect, e.g. "tools"
--- @param callback fun(err: string|nil, items: table[]|nil)
function M.list_all(mcp_client, method, field, callback)
  local items = {}
  local seen_cursors = {}

  local function fetch(cursor)
    -- vim.empty_dict(), not {}: an empty Lua table serializes to a JSON
    -- array, and MCP requires `params` to be an object.
    local params = cursor and { cursor = cursor } or vim.empty_dict()
    local ok, request_err = pcall(function()
      mcp_client:request({ jsonrpc = "2.0", id = M.next_id(), method = method, params = params }, function(err, result)
        if err then
          return callback(err, nil)
        end
        local payload = M.unwrap_result(result)
        if type(payload) ~= "table" or type(payload[field]) ~= "table" then
          return callback(string.format("malformed %s result: missing %q array", method, field), nil)
        end
        vim.list_extend(items, payload[field])
        local next_cursor = payload.nextCursor
        if type(next_cursor) ~= "string" or next_cursor == "" then
          return callback(nil, items)
        end
        if seen_cursors[next_cursor] then
          return callback(string.format("%s returned a repeated cursor %q", method, next_cursor), nil)
        end
        seen_cursors[next_cursor] = true
        fetch(next_cursor)
      end)
    end)
    if not ok then
      callback(tostring(request_err), nil)
    end
  end

  fetch(nil)
end

return M
