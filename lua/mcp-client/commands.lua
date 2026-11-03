--- The `:MCPAuth`, `:MCPReconnect`, `:MCPLogout`, and `:MCPStatus` Ex
--- commands: registration, completion, target resolution, and the actions
--- they dispatch to.
---
--- Target resolution turns "no argument" or "an explicit name" into either a
--- definite target server name or a clear, `vim.notify`-reported reason why
--- none was chosen. It reads `config.state().servers` (the same record
--- `health.lua` reads back from `config.setup()`/`config._record_hub`) and
--- never triggers the OAuth flow itself -- see `M.authenticate` below.
---
--- "Needs authentication" (the no-argument auto-resolve/list predicate) means
--- a server has a non-nil `token_store` whose `status().has_token` is false,
--- or whose token is expired. This is the same "has a `token_store`" test
--- completion uses (`resolve_token_store` in config.lua checks a caller
--- override before it checks `is_localhost`, so a localhost server with an
--- explicit `auth.token_store` override also qualifies) -- just additionally
--- filtered by current validity. Explicit-name resolution never applies that
--- validity filter: naming a server always resolves it, even if its token is
--- already valid.
---
--- `config.lua` requires this module (to call `M.register()` once from
--- `M.setup()`), so this module must not require `mcp-client.config` at load
--- time -- that would be a load-order cycle. `config` is required lazily,
--- inside each function that needs it, instead.
local function config()
  return require("mcp-client.config")
end

local function dcr()
  return require("mcp-client.auth.dcr")
end

local function mcp_client()
  return require("mcp-client.client")
end

local M = {}

--- Names with an authenticate() call currently in flight (dcr.run_flow
--- dispatched, no terminal callback fired yet). Guards against two
--- concurrent `:MCPAuth <name>` invocations for the same server racing each
--- other's token save and registry teardown/reconnect.
local in_flight = {}

--- Whether `name` is also a registered native server's name.
local function names_native(name)
  return vim.tbl_contains(config().state().native_servers, name)
end

--- Disconnect and forget every live remote client for `name`, so a
--- replacement connection never coexists with the one it replaces and
--- `get_clients({ name = name })` cannot return the stale entry.
---
--- The registry is shared with native servers and a client object does not
--- say which kind it is, so nothing is torn down when `name` also names a
--- native server: that would destroy it with nothing to bring it back. The
--- cost in that collision is a stale duplicate remote entry.
local function teardown(name)
  if names_native(name) then
    return
  end
  for _, live_client in ipairs(mcp_client().get_clients({ name = name })) do
    live_client:disconnect()
    mcp_client()._forget(live_client.id)
  end
end

--- Names with a reconnect dialing, so overlapping reconnects of one server
--- cannot each register a client.
local reconnecting = {}

--- Replace a configured server's live connection with a fresh one made from
--- its retained `connect_config`. `on_done(err)` reports the new connection,
--- or that a reconnect of this server is already in progress.
local function reconnect_server(name, on_done)
  if reconnecting[name] then
    return on_done("a reconnect is already in progress")
  end
  reconnecting[name] = true
  teardown(name)
  mcp_client().connect(config()._connect_config(name), {
    on_connect = function(_, err)
      reconnecting[name] = nil
      on_done(err)
    end,
  })
end

--- The actual OAuth-flow-triggering + reconnect action, given a resolved
--- server name. `register()`'s command callback calls this after
--- `resolve_target` returns a definite name. Public (not test-only, despite
--- this module's other underscore-prefixed helpers being internal seams) --
--- it is the one thing a human typing `:MCPAuth` actually causes to happen,
--- and the supported way to trigger it non-interactively/from a script.
---
--- A name with a call already in flight is rejected with a notification
--- instead of starting a second `dcr.run_flow` -- otherwise two overlapping
--- calls could both tear down and reconnect the same registry entry, or race
--- each other's token save.
---
--- Runs `dcr.run_flow` unconditionally -- no short-circuit on an already-valid
--- token, matching explicit-name resolution's own rule that naming a server
--- always re-authenticates it. On a flow error, notifies and stops -- no
--- save, no reconnect attempted.
---
--- On success, saves the token directly onto this server's existing
--- TokenStore object (`config().get_hub(name).token_store`) -- never a
--- freshly-constructed store with a reconstructed key -- then replaces the
--- server's live connection (see `teardown` and `reconnect_server`).
---
--- Finally reconnects using the exact retained `connect_config` (fetched via
--- `config()._connect_config(name)`, the internal-only accessor -- never a
--- freshly-built minimal one), reporting the reconnect's own success/failure
--- distinctly from an OAuth failure.
---
--- Failure notifications reuse `dcr.run_flow`'s returned error string as-is
--- (that module's error strings are secret-free by construction) rather than
--- wrapping it with additional context. No notification here ever
--- interpolates `connect_config` or `connect_config.headers` wholesale --
--- only the server name and error strings.
--- @param name string  a server name already validated by resolve_target
function M.authenticate(name)
  if in_flight[name] then
    vim.notify(string.format("mcp-client: authentication for %q is already in progress.", name), vim.log.levels.WARN)
    return
  end
  in_flight[name] = true

  local record = config().get_hub(name)

  dcr().run_flow({ server_url = record.url }, function(token, err)
    if err then
      in_flight[name] = nil
      vim.notify(string.format("mcp-client: authentication for %q failed: %s", name, err), vim.log.levels.WARN)
      return
    end

    record.token_store:save(token)

    reconnect_server(name, function(connect_err)
      in_flight[name] = nil
      if connect_err then
        vim.notify(
          string.format(
            "mcp-client: authenticated %q and saved the new token, but reconnecting failed: %s",
            name,
            connect_err
          ),
          vim.log.levels.WARN
        )
        return
      end
      vim.notify(string.format("mcp-client: authenticated and reconnected %q.", name), vim.log.levels.INFO)
    end)
  end)
end

--- Whether a server record has a token_store at all. Does not consider
--- current token validity.
--- @param record table  a `config.state().servers` entry
--- @return boolean
local function has_token_store(record)
  return record ~= nil and record.token_store ~= nil
end

--- Whether a server record needs authentication: has a token_store AND (no
--- token yet OR the stored token is expired).
--- @param record table  a `config.state().servers` entry
--- @return boolean
local function needs_auth(record)
  if not has_token_store(record) then
    return false
  end
  local status = record.token_store:status()
  return not status.has_token or status.expired
end

--- Every configured server name with a non-nil `token_store`, sorted for
--- deterministic output (candidate lists, completion).
--- @return string[]
local function servers_with_token_store()
  local names = {}
  for name, record in pairs(config().state().servers) do
    if has_token_store(record) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

--- Every configured server name that currently needs authentication, sorted
--- for deterministic output.
--- @return string[]
local function servers_needing_auth()
  local names = {}
  for name, record in pairs(config().state().servers) do
    if needs_auth(record) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

--- Resolve `:MCPAuth [server-name]`'s target.
---
--- With an explicit `name`:
---   * errors "not configured" if no such server is in `config.state().servers`;
---   * errors "does not use token-based authentication" if the server has no
---     `token_store` (the common case: an unconfigured localhost server);
---   * otherwise resolves to `name`, regardless of current token validity.
---
--- With no `name` (nil or ""):
---   * partitions configured servers by "needs authentication";
---   * exactly one candidate resolves to that candidate's name;
---   * zero candidates reports "nothing to authenticate";
---   * two or more candidates reports the candidate list and resolves to
---     nothing, asking for an explicit name.
---
--- @param name string|nil
--- @return string|nil target, string|nil err
function M.resolve_target(name)
  if name ~= nil and name ~= "" then
    local record = config().get_hub(name)
    if record == nil then
      return nil, string.format("mcp-client: server %q is not configured.", name)
    end
    if not has_token_store(record) then
      return nil, string.format("mcp-client: server %q does not use token-based authentication.", name)
    end
    return name, nil
  end

  local candidates = servers_needing_auth()
  if #candidates == 0 then
    return nil, "mcp-client: nothing to authenticate -- no configured server currently needs authentication."
  end
  if #candidates == 1 then
    return candidates[1], nil
  end
  return nil,
    string.format(
      "mcp-client: multiple servers need authentication (%s) -- run :MCPAuth <server-name> to pick one.",
      table.concat(candidates, ", ")
    )
end

--- `:MCPAuth <Tab>` completion candidates: every configured server name that
--- has a `token_store`, not only ones currently needing auth -- keeps
--- completion useful for re-authenticating an already-valid server.
--- Matches `nvim_create_user_command`'s `complete` function signature:
--- `fun(arg_lead, cmd_line, cursor_pos): string[]`.
--- @return string[]
function M.complete(_arg_lead, _cmd_line, _cursor_pos)
  return servers_with_token_store()
end

--- `:MCPAuth [server-name]` callback: resolves the target and, on a definite
--- target, hands it to `M.authenticate`. On no definite target, reports
--- `resolve_target`'s error the same way the plugin already reports connect
--- errors (`vim.notify`, no interactive picker).
--- @param cmd_opts table  the table `nvim_create_user_command`'s callback receives
local function on_mcpauth(cmd_opts)
  local name = cmd_opts.args
  if name == "" then
    name = nil
  end
  local target, err = M.resolve_target(name)
  if not target then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  M.authenticate(target)
end

--- Every configured remote server name, sorted.
local function configured_servers()
  local names = vim.tbl_keys(config().state().servers)
  table.sort(names)
  return names
end

--- `:MCPReconnect [server-name]`: replace one configured server's connection,
--- or every configured server's when no name is given.
--- @param name string|nil
function M.reconnect(name)
  local names
  if name ~= nil and name ~= "" then
    if config().get_hub(name) == nil then
      return vim.notify(string.format("mcp-client: server %q is not configured.", name), vim.log.levels.WARN)
    end
    names = { name }
  else
    names = configured_servers()
    if #names == 0 then
      return vim.notify("mcp-client: no servers are configured.", vim.log.levels.WARN)
    end
  end
  for _, target in ipairs(names) do
    reconnect_server(target, function(err)
      if err then
        vim.notify(string.format("mcp-client: reconnecting %q failed: %s", target, err), vim.log.levels.WARN)
      else
        vim.notify(string.format("mcp-client: reconnected %q.", target), vim.log.levels.INFO)
      end
    end)
  end
end

--- `:MCPLogout <server-name>`: delete the server's stored token and
--- disconnect it. `:MCPAuth` signs in again.
--- @param name string
function M.logout(name)
  local record = config().get_hub(name)
  if record == nil then
    return vim.notify(string.format("mcp-client: server %q is not configured.", name), vim.log.levels.WARN)
  end
  if not has_token_store(record) then
    return vim.notify(
      string.format("mcp-client: server %q does not use token-based authentication.", name),
      vim.log.levels.WARN
    )
  end
  record.token_store:clear()
  teardown(name)
  vim.notify(
    string.format("mcp-client: signed out of %q and deleted its stored token; :MCPAuth %s signs in again.", name, name),
    vim.log.levels.INFO
  )
end

--- The live remote client for a configured server, if any.
local function live_remote(name)
  if names_native(name) then
    return nil
  end
  for _, live_client in ipairs(mcp_client().get_clients({ name = name })) do
    return live_client
  end
end

local function auth_line(name, store)
  local status = store:status()
  if not status.has_token then
    return string.format("auth: no stored token -- run :MCPAuth %s", name)
  end
  local expiry = type(status.expires_at) == "number" and os.date("%Y-%m-%d %H:%M", status.expires_at) or "unknown"
  if status.expired then
    return string.format("auth: token expired %s%s", expiry, status.has_refresh_token and " (refreshable)" or "")
  end
  return string.format("auth: token valid until %s", expiry)
end

--- The lines `:MCPStatus` shows: per configured server its connection state,
--- transport, protocol era and version, server identity, process id and last
--- stderr line (stdio), and auth status; then the native servers.
--- @return string[]
function M.status_lines()
  local state = config().state()
  local names = configured_servers()
  if #names == 0 and #state.native_servers == 0 then
    return { "mcp-client: no servers configured" }
  end

  local lines = {}
  for _, name in ipairs(names) do
    local record = state.servers[name]
    local where = record.url or ("stdio: " .. record.command)
    local live = live_remote(name)
    if live == nil then
      table.insert(lines, string.format("%s: not connected (%s)", name, where))
    else
      table.insert(
        lines,
        string.format(
          "%s: %s over %s, %s protocol %s (%s)",
          name,
          live:state(),
          tostring(live.transport),
          tostring(live.era),
          tostring(live.protocol_version),
          where
        )
      )
      local info = live.server_info
      if type(info) == "table" and info.name then
        table.insert(lines, string.format("  server: %s %s", info.name, info.version or ""))
      end
      if live.pid then
        table.insert(lines, string.format("  pid: %d", live.pid))
      end
      local stderr = live:stderr()
      if #stderr > 0 then
        table.insert(lines, "  stderr: " .. stderr[#stderr])
      end
    end
    if record.token_store then
      table.insert(lines, "  " .. auth_line(name, record.token_store))
    end
  end
  for _, name in ipairs(state.native_servers) do
    table.insert(lines, string.format("%s: native (in-process)", name))
  end
  return lines
end

--- Register the plugin's Ex commands. Called once from `config.lua`'s
--- `M.setup()`. `nvim_create_user_command` overwrites an already-defined
--- command of the same name, so calling `register()` again on a repeated
--- `setup()` call is safe.
function M.register()
  vim.api.nvim_create_user_command("MCPAuth", on_mcpauth, {
    nargs = "?",
    complete = M.complete,
    desc = "Run the OAuth authorization flow for a configured MCP server",
  })
  vim.api.nvim_create_user_command("MCPReconnect", function(cmd_opts)
    M.reconnect(cmd_opts.args)
  end, {
    nargs = "?",
    complete = configured_servers,
    desc = "Reconnect one configured MCP server, or all of them",
  })
  vim.api.nvim_create_user_command("MCPLogout", function(cmd_opts)
    M.logout(cmd_opts.args)
  end, {
    nargs = 1,
    complete = M.complete,
    desc = "Delete a configured MCP server's stored token and disconnect it",
  })
  vim.api.nvim_create_user_command("MCPStatus", function()
    vim.api.nvim_echo({ { table.concat(M.status_lines(), "\n") } }, false, {})
  end, {
    nargs = 0,
    desc = "Show the connection, protocol, and auth status of every MCP server",
  })
end

--- Clear the authenticate and reconnect in-flight guards. Test-only -- lets
--- specs isolate scenarios that deliberately leave a name "in flight" (a call
--- whose callback never fires) without leaking that state into later tests
--- reusing the same server name.
function M._reset()
  in_flight = {}
  reconnecting = {}
end

return M
