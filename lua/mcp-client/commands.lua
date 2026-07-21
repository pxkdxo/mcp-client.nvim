--- `:MCPAuth [server-name]` Ex command: registration, completion, and pure
--- target resolution.
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
--- freshly-constructed store with a reconstructed key. Then, before dialing
--- the reconnect, tears down any existing live client for this name:
--- `:disconnect()` (so no two transports for this name are live at once),
--- then `mcp_client()._forget(id)` (so the now-dead entry doesn't linger in
--- the registry -- `disconnect()` alone leaves it queryable, by design, so
--- without `_forget` a caller like `health.lua`'s `get_clients({name=...})[1]`
--- could non-deterministically pick the stale entry over the fresh one).
--- This makes re-authenticating an already-connected server replace rather
--- than duplicate the registry entry -- a no-op when there is no live client
--- yet, the common case.
---
--- The registry is shared with native, in-process servers, and a client
--- object gives no reliable way to tell the two apart (`native.lua`
--- deliberately keeps a native client indistinguishable in shape from a
--- remote one). So this skips the teardown entirely when `name` also names a
--- registered native server: tearing down "every entry matching this name"
--- would silently disconnect and forget that native server too, with no
--- reconnect step to bring it back. The rare cost is a stale duplicate
--- remote entry left behind in that specific collision; the alternative is
--- destroying an unrelated native server outright.
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
		vim.notify(
			string.format("mcp-client: authentication for %q is already in progress.", name),
			vim.log.levels.WARN
		)
		return
	end
	in_flight[name] = true

	local record = config().get_hub(name)
	local connect_config = config()._connect_config(name)

	dcr().run_flow({ server_url = connect_config.url }, function(token, err)
		if err then
			in_flight[name] = nil
			vim.notify(string.format("mcp-client: authentication for %q failed: %s", name, err), vim.log.levels.WARN)
			return
		end

		record.token_store:save(token)

		local names_collide = false
		for _, native_name in ipairs(config().state().native_servers) do
			if native_name == name then
				names_collide = true
				break
			end
		end

		if not names_collide then
			for _, live_client in ipairs(mcp_client().get_clients({ name = name })) do
				live_client:disconnect()
				mcp_client()._forget(live_client.id)
			end
		end

		mcp_client().connect(connect_config, {
			on_connect = function(_client_object, connect_err)
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
			end,
		})
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

--- Register the `:MCPAuth [server-name]` Ex command. Called once from
--- `config.lua`'s `M.setup()`. `nvim_create_user_command` overwrites an
--- already-defined command of the same name, so calling `register()` again
--- on a repeated `setup()` call is safe.
function M.register()
	vim.api.nvim_create_user_command("MCPAuth", on_mcpauth, {
		nargs = "?",
		complete = M.complete,
		desc = "Run the OAuth authorization flow for a configured MCP server",
	})
end

--- Clear the in-flight guard. Test-only -- lets specs isolate scenarios that
--- deliberately leave a name "in flight" (an authenticate() call whose
--- dcr.run_flow callback never fires) without leaking that state into later
--- tests reusing the same server name.
function M._reset()
	in_flight = {}
end

return M
