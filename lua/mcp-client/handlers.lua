--- Client-side MCP features: answering a server's `roots/list`,
--- `elicitation/create`, and `sampling/createMessage` (and legacy `ping`).
---
--- Legacy servers send these as JSON-RPC requests over the connection; modern
--- servers embed them in an `input_required` result (multi round-trip
--- requests). Both paths dispatch through `M.dispatch`.
---
--- User configuration (`handlers` in a server config or in `setup()`):
---   roots       fun(ctx): Root[]  | false   default: the current working directory
---   elicitation fun(params, ctx, respond) | false   default: vim.ui prompts
---   sampling    fun(params, ctx, respond)           default: none (not declared)
--- `ctx` is `{ server = <server name> }`; `respond(err, result)` completes the
--- request. Setting a handler to `false` disables it and stops the client from
--- declaring the matching capability.
local M = {}

local METHOD_NOT_FOUND = -32601
local INTERNAL_ERROR = -32603

local function default_roots()
  local cwd = vim.fn.getcwd()
  return { { uri = vim.uri_from_fname(cwd), name = vim.fn.fnamemodify(cwd, ":t") } }
end

local function default_elicitation(params, ctx, respond)
  require("mcp-client.elicitation").prompt(params, ctx, respond)
end

--- The effective handler table: defaults, overridden key by key by `user`.
function M.resolve(user)
  user = user or {}
  local resolved = { roots = default_roots, elicitation = default_elicitation }
  for key, value in pairs(user) do
    resolved[key] = value
  end
  for key, value in pairs(resolved) do
    if value == false then
      resolved[key] = nil
    end
  end
  return resolved
end

--- Client capabilities implied by the configured handlers.
function M.capabilities(user)
  local resolved = M.resolve(user)
  local capabilities = {}
  if resolved.roots then
    capabilities.roots = vim.empty_dict()
  end
  if resolved.elicitation then
    capabilities.elicitation = { form = vim.empty_dict(), url = vim.empty_dict() }
  end
  if resolved.sampling then
    capabilities.sampling = vim.empty_dict()
  end
  return capabilities
end

local function rpc_error(code, message)
  return { code = code, message = message }
end

--- Answer one server-to-client request.
--- @param user table|nil  the user's `handlers` config
--- @param method string
--- @param params table|nil
--- @param ctx table  `{ server = <name> }`
--- @param respond fun(err: {code: integer, message: string}|nil, result: table|nil)  called exactly once
function M.dispatch(user, method, params, ctx, respond)
  local resolved = M.resolve(user)
  local settled = false
  local function finish(err, result)
    if settled then
      return
    end
    settled = true
    if err ~= nil and type(err) ~= "table" then
      err = rpc_error(INTERNAL_ERROR, tostring(err))
    end
    respond(err, result)
  end

  local ok, thrown = pcall(function()
    if method == "ping" then
      return finish(nil, vim.empty_dict())
    end
    if method == "roots/list" and resolved.roots then
      return finish(nil, { roots = resolved.roots(ctx) })
    end
    if method == "elicitation/create" and resolved.elicitation then
      return resolved.elicitation(params or {}, ctx, finish)
    end
    if method == "sampling/createMessage" and resolved.sampling then
      return resolved.sampling(params or {}, ctx, finish)
    end
    finish(rpc_error(METHOD_NOT_FOUND, "client does not support " .. tostring(method)))
  end)
  if not ok then
    finish(rpc_error(INTERNAL_ERROR, tostring(thrown)))
  end
end

--- Fulfil an `InputRequiredResult.inputRequests` map one request at a time
--- (prompts must not overlap), in key order. A request the client does not
--- support is left out of the responses; a handler error aborts with that
--- error.
--- @param done fun(err: string|nil, responses: table|nil)
function M.resolve_input_requests(user, input_requests, ctx, done)
  local keys = vim.tbl_keys(input_requests or {})
  table.sort(keys)
  local responses = {}
  local index = 0

  local function step()
    index = index + 1
    local key = keys[index]
    if key == nil then
      return done(nil, responses)
    end
    local request = input_requests[key]
    if type(request) ~= "table" then
      return step()
    end
    M.dispatch(user, request.method, request.params, ctx, function(err, result)
      if err then
        if err.code == METHOD_NOT_FOUND then
          return step()
        end
        return done(string.format("%s for input request %q failed: %s", request.method, key, err.message), nil)
      end
      responses[key] = result
      step()
    end)
  end

  step()
end

return M
