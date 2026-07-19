--- Avante adapter (U4, extended by U11): translate this plugin's
--- client/tool/prompt surface -- `require("mcphub-neovim.client").get_clients(filter)`
--- plus each client object's `request(rpc_message, callback)` -- into
--- Avante's real `custom_tools` and `slash_commands` integration points,
--- replacing `mcphub.extensions.avante`.
---
--- This is a thin adapter (R6): it holds no direct hub or transport logic
--- of its own. Every tool call it exposes to Avante is, underneath, a
--- standard MCP `tools/list` / `tools/call` JSON-RPC message routed through
--- a client object's `request()` -- exactly the same call a native server
--- (U3) or a remote hub connection (U1/U2) already answers. The adapter
--- never imports `mcphub-neovim.transport.*`, never touches a `Job` object,
--- and never assumes a client is remote or native -- `get_clients()`
--- deliberately makes the two indistinguishable, and this file relies on
--- that uniformity rather than working around it.
---
--- Avante's real `custom_tools` shape (verified against the actual
--- `yetone/avante.nvim` source, not guessed -- see
--- `~/.local/share/nvim/lazy/avante.nvim/lua/avante/llm_tools/init.lua`
--- and `lua/avante/types.lua`):
---
---   require("avante").setup({
---     custom_tools = function() return { <AvanteLLMTool>, ... } end,
---     -- (a plain list table is also accepted; `Config.custom_tools` is
---     -- called as a function only `if type(custom_tools) == "function"`)
---   })
---
--- Each `AvanteLLMTool` (types.lua:479-488) needs:
---   name         string
---   description  string
---   param        { type = "table", fields = { { name, description, type,
---                  optional? }, ... } }   -- types.lua:493-506
---   returns      { { name, description, type, optional? }, ... }
---   func         fun(input: table, opts: AvanteLLMToolFuncOpts):
---                  (boolean|string|nil, string|nil)
---
--- `AvanteLLMToolFuncOpts` (types.lua:458-465) carries `on_log(log)` and
--- `on_complete(result, err)`. `llm_tools/init.lua:1411-1441`
--- (`process_tool_use`) calls `func(input, opts)` and accepts *either*
--- calling convention a tool wants to use: a synchronous `return result,
--- err`, or (for async work) returning `nil, nil` and calling
--- `opts.on_complete(result, err)` later -- "Result and error being nil
--- means that the tool was executed asynchronously" (init.lua:1440-1441).
---
--- That dual sync/async contract is exactly what this plugin's own
--- `request()` already has: a native client (U3) invokes its callback
--- synchronously; a remote client (U1/U2) always invokes it asynchronously.
--- So `func` below never tries to guess which kind of client it is calling
--- -- it always drives the result out through `opts.on_complete`, and simply
--- returns `nil, nil` immediately after issuing the request. That is a
--- correct, spec-sanctioned "this tool is asynchronous" response even on
--- the (synchronous) native path -- `process_tool_use` already handles a
--- `func` that always defers to `on_complete` rather than one that
--- sometimes returns synchronously, so there is no special-casing needed
--- for native vs. remote here (see the note in `task-3-report.md`: the
--- caller of `request()` must not assume the callback defers, but nothing
--- requires an *adapter built on top of it* to return synchronously too).

local client = require("mcphub-neovim.client")

local M = {}

--- Normalize a client `request()` result to the bare MCP payload, regardless of
--- which kind of client produced it. This adapter is deliberately client-kind
--- agnostic (native, U3, vs remote, U1/U2), but the two client kinds deliver the
--- result at different nesting:
---   * native  -> the handler's return value directly, e.g. `{ tools = {...} }`;
---   * remote  -> the full JSON-RPC envelope, e.g. `{ jsonrpc, id, result = { tools = {...} } }`.
--- (Local test doubles historically mimic the native/unwrapped shape, so this
--- divergence only bites against a real remote hub -- surfaced by U9.) A remote
--- envelope is unambiguous: it carries a nested `result` table (native payloads
--- for these methods -- tools/list, resources/list, tools/call -- never do). So
--- unwrap one level of `.result` when present; otherwise use the value as-is.
local function unwrap_result(result)
	if type(result) == "table" and type(result.result) == "table" then
		return result.result
	end
	return result
end

--- Avante's `custom_tools` contract is itself synchronous: `Config.custom_tools`
--- is called with no callback and its return value used immediately
--- (`llm_tools/init.lua:683-684,702-705`: `if type(custom_tools) == "function"
--- then custom_tools = custom_tools() end`). A remote client's `tools/list`
--- reply, in contrast, always arrives later (U1/U2: remote transports are
--- always async). Those two facts cannot be reconciled by blocking --
--- `custom_tools()` must return before a remote round-trip can complete.
---
--- So `custom_tools()` returns the most recently known listing for each
--- client synchronously (empty until the first reply arrives), and
--- opportunistically kicks off a fresh `tools/list` refresh on every call.
--- A native client's `request()` callback fires synchronously (U3), so its
--- listing is always current on the very call that triggered the refresh;
--- a remote client's listing catches up on the *next* call after its reply
--- lands. This is a cache of tool *metadata* only, not of client identity
--- or connection state -- `is_stopped()` is re-checked against the live
--- registry on every `custom_tools()` call (see below), so a disconnected
--- client is dropped immediately rather than waiting for its cache entry
--- to expire.
local tools_cache = {} ---@type table<string, table[]>

--- Ask one client for its current tool listing via the standard MCP
--- `tools/list` method, routed through the client's own `request()` -- no
--- client-kind-specific logic, no transport access. Updates `tools_cache`
--- when a reply arrives (synchronously for a native client, later for a
--- remote one); a client that errors or returns something malformed simply
--- leaves the previous cache entry (or the initial empty list) in place
--- rather than raising, so one misbehaving client can never take down the
--- whole tool list.
---
--- Both current client implementations (native, U3; remote, U1/U2) only
--- ever report failures through the `(err, result, response)` callback --
--- neither throws synchronously out of `request()` itself. This `pcall` is
--- pure defense-in-depth against a hypothetical future client (registered
--- via the generic `client.register_native`-style hook) that throws
--- synchronously: that failure is treated exactly like an `err` callback
--- argument -- the cache is simply left untouched -- rather than
--- propagating out of this function and aborting the `for` loop in
--- `M.custom_tools()` for every other, unrelated client still left to
--- iterate.
local function refresh_client_tools(mcp_client)
	local ok, err = pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = 1,
			method = "tools/list",
			-- vim.empty_dict(), not {}: an empty Lua table serializes to a JSON
			-- array `[]`, which a strict real hub rejects (HTTP 400 "Invalid
			-- message") -- MCP requires `params` to be an object. (Surfaced by
			-- U9's real-hub validation; local doubles echo regardless of shape.)
			params = vim.empty_dict(),
		}, function(cb_err, result, _response)
			local payload = unwrap_result(result)
			if cb_err or type(payload) ~= "table" or type(payload.tools) ~= "table" then
				return
			end
			tools_cache[mcp_client.id] = payload.tools
		end)
	end)
	if not ok then
		-- Same handling as a callback-reported error: leave the cache as-is.
		return err
	end
end

--- MCP's `inputSchema` (JSON Schema-ish: `{ type = "object", properties =
--- {...}, required = {...} }`) does not line up 1:1 with Avante's `param`
--- shape (`{ type = "table", fields = { { name, type, description,
--- optional }, ... } }`), so translate field-by-field rather than passing
--- either through untouched. Unknown/missing schemas degrade to an empty
--- field list rather than erroring -- a tool with no declared schema is
--- still callable, just without argument documentation for the LLM.
local function schema_to_param(input_schema)
	local fields = {}
	if type(input_schema) == "table" and type(input_schema.properties) == "table" then
		local required = {}
		if type(input_schema.required) == "table" then
			for _, name in ipairs(input_schema.required) do
				required[name] = true
			end
		end
		-- Sort for a deterministic field order (pairs() over `properties`
		-- would otherwise vary run to run).
		local names = {}
		for name in pairs(input_schema.properties) do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local prop = input_schema.properties[name] or {}
			table.insert(fields, {
				name = name,
				description = prop.description,
				type = prop.type or "string",
				optional = not required[name],
			})
		end
	end
	return { type = "table", fields = fields }
end

--- Build one Avante `AvanteLLMTool` entry for a single MCP tool exposed by
--- `mcp_client`. Tool names are passed through unqualified: the brief's
--- scope is translating one client's tool surface into Avante's shape, not
--- inventing a cross-client namespacing scheme Avante's real API doesn't
--- ask for. (If two connected clients ever expose same-named tools, the
--- later one in `get_clients()`'s iteration order wins in Avante's list --
--- worth revisiting if that becomes a real scenario, but out of scope here.)
local function build_tool_spec(mcp_client, tool_info)
	return {
		name = tool_info.name,
		description = tool_info.description or ("MCP tool " .. tool_info.name),
		param = schema_to_param(tool_info.inputSchema),
		returns = {
			{ name = "result", description = "Result of the MCP tool call", type = "string" },
			{ name = "error", description = "Error message if the call failed", type = "string", optional = true },
		},
		--- Avante invokes this as `func(input, opts)` (init.lua:1411). Always
		--- resolve via `opts.on_complete`: correct and sufficient whether
		--- `mcp_client:request()`'s callback fires synchronously (native,
		--- U3) or asynchronously (remote, U1/U2) -- `process_tool_use`
		--- already supports a tool that always defers to `on_complete`
		--- (init.lua:1440-1441).
		func = function(input, opts)
			local on_complete = opts and opts.on_complete
			local on_log = opts and opts.on_log

			if on_log then
				on_log("calling " .. tool_info.name .. " on " .. mcp_client.name)
			end

			-- Both current client implementations only ever report
			-- failures through the callback's `err` argument, never by
			-- throwing synchronously out of `request()`. This `pcall` is
			-- pure defense-in-depth against a hypothetical future client
			-- that does throw synchronously: the caught error is routed
			-- through `on_complete` exactly the same way a
			-- callback-reported `err` already is, rather than propagating
			-- out of `func` and crashing whatever in Avante called it.
			local ok, call_err = pcall(function()
				mcp_client:request({
					jsonrpc = "2.0",
					id = 1,
					method = "tools/call",
					-- arguments defaults to vim.empty_dict() (not {}) so a
					-- zero-argument tool call serializes `arguments` as a JSON
					-- object `{}`, not an array `[]` a strict hub would reject.
					params = { name = tool_info.name, arguments = input or vim.empty_dict() },
				}, function(err, result, _response)
					if not on_complete then
						return
					end
					if err then
						return on_complete(nil, tostring(err))
					end
					-- Unwrap the JSON-RPC envelope for a remote client so the
					-- tool's own output is surfaced, not the wrapper (a native
					-- client already returns the bare payload).
					local payload = unwrap_result(result)
					local result_str
					if type(payload) == "string" then
						result_str = payload
					elseif payload ~= nil then
						result_str = vim.json.encode(payload)
					else
						result_str = ""
					end
					on_complete(result_str, nil)
				end)
			end)
			if not ok and on_complete then
				on_complete(nil, tostring(call_err))
			end

			-- Nil, nil signals "asynchronous; wait for on_complete"
			-- (init.lua:1440-1441) -- correct for both native and remote
			-- clients, per the note above.
			return nil, nil
		end,
	}
end

--- Avante's `custom_tools` integration point (`Config.custom_tools`,
--- config.lua:1110; consumed by `llm_tools/init.lua:683-686,702-705`,
--- which accept either a table or, "if type(custom_tools) == 'function'",
--- call it to get the table). Exposed as a function here so it is always
--- re-evaluated against the current client registry rather than a snapshot
--- frozen at `require()` time -- a client that disconnects between two
--- Avante turns must disappear from the very next `custom_tools()` call,
--- not linger until some cache is invalidated.
---
--- Usage:
---   require("avante").setup({
---     custom_tools = require("mcphub-neovim.adapters.avante").custom_tools,
---   })
function M.custom_tools()
	local tools = {}
	for _, mcp_client in ipairs(client.get_clients()) do
		if not mcp_client:is_stopped() then
			refresh_client_tools(mcp_client)
			for _, tool_info in ipairs(tools_cache[mcp_client.id] or {}) do
				table.insert(tools, build_tool_spec(mcp_client, tool_info))
			end
		else
			-- A stopped client contributes nothing, and its stale cache
			-- entry (if any) is dropped so a later reconnect under the same
			-- id starts from a clean slate rather than a previous session's
			-- listing.
			tools_cache[mcp_client.id] = nil
		end
	end
	return tools
end

--- Prompt/slash-command bridging (U11). Avante's real `slash_commands`
--- integration point (verified against the actual `yetone/avante.nvim`
--- source, not guessed):
---
---   require("avante").setup({
---     slash_commands = require("mcphub-neovim.adapters.avante").slash_commands,
---   })
---
--- Unlike `custom_tools` (`config.lua:1110`, typed `AvanteLLMToolPublic[] |
--- fun(): AvanteLLMToolPublic[]` -- either a table or a function Avante
--- calls fresh each time), `Config.slash_commands` (`config.lua:348,1111`)
--- is typed `AvanteSlashCommand[]` only: a plain array, with no function
--- form. It is read fresh on every `avante.utils.get_commands()` call
--- (`utils/init.lua:1559-1579`) -- itself called on every chat submission
--- (`sidebar.lua:2814`, inside `Sidebar:handle_submit`) and on every
--- `/`-triggered completion (`cmp_avante/commands.lua:33,56`) -- but
--- `Config.slash_commands` itself is never re-invoked. So there is no
--- "recompute and return a fresh table on every access" option here the way
--- `custom_tools()` uses; the only way to keep Avante's live view current is
--- to hand it one stable table reference up front and mutate that same
--- table's *contents* afterward.
---
--- That mutate-in-place contract is not an invented workaround: Avante's own
--- ACP integration does exactly this at runtime, unprompted by any adapter --
--- `llm.lua:1188-1211` (`available_commands_update`) does
--- `table.insert(Config.slash_commands, {...})` to register agent-defined
--- commands after `setup()` has already run. `M.slash_commands` below is
--- that same kind of table: created once, handed to `setup()` once, and
--- refreshed by clearing and refilling its contents in place on every
--- `M.custom_slash_commands()` call (which also returns the freshly-built
--- list directly, for callers -- tests included -- that just want the
--- current listing without relying on table-identity mutation).
M.slash_commands = {}

--- Cache of prompt *metadata* per client id, refreshed on every
--- `M.custom_slash_commands()` call -- the exact same shape and staleness
--- handling as `tools_cache`/`refresh_client_tools` above (see those
--- comments for the full rationale: synchronous-for-native/async-for-remote
--- callback timing, pcall defense-in-depth, "leave the previous entry in
--- place on failure" degradation).
local prompts_cache = {} ---@type table<string, table[]>

--- Ask one client for its current prompt listing via the standard MCP
--- `prompts/list` method. Mirrors `refresh_client_tools` exactly (see its
--- comments): routed through the client's own `request()`, `pcall`-guarded
--- as defense-in-depth against a hypothetical synchronously-throwing
--- client, `unwrap_result()`'d so a remote client's JSON-RPC envelope and a
--- native client's bare payload are handled identically, and a
--- missing/malformed reply just leaves the previous cache entry in place
--- rather than raising.
local function refresh_client_prompts(mcp_client)
	local ok, err = pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = 1,
			method = "prompts/list",
			-- vim.empty_dict(), not {}, for the same reason as tools/list above:
			-- MCP requires `params` to be a JSON object, and a strict real hub
			-- rejects an empty Lua table's `[]` serialization.
			params = vim.empty_dict(),
		}, function(cb_err, result, _response)
			local payload = unwrap_result(result)
			if cb_err or type(payload) ~= "table" or type(payload.prompts) ~= "table" then
				return
			end
			prompts_cache[mcp_client.id] = payload.prompts
		end)
	end)
	if not ok then
		return err
	end
end

--- Render a `prompts/get` result as chat message tables suitable for
--- `Sidebar:add_chat_history` (`sidebar.lua:2481`: `AvanteLLMMessage |
--- AvanteLLMMessage[]`, each `{ role, content }` where `content` is a
--- string or the first element of a content-part list). `native.lua`'s
--- `prompts/get` handler returns "whatever the prompt function returns as
--- its result" verbatim (native.lua:21), so a real prompt is free to return
--- the full MCP `GetPromptResult` shape (`{ description?, messages:
--- [{role, content: {type, text}}] }`) or something simpler; this handles
--- both without erroring on an unexpected shape.
local function render_prompt_result(payload)
	if type(payload) == "table" and type(payload.messages) == "table" then
		local messages = {}
		for _, message in ipairs(payload.messages) do
			local content = message.content
			local text
			if type(content) == "table" then
				text = content.text
			elseif type(content) == "string" then
				text = content
			end
			table.insert(messages, { role = message.role or "user", content = text or "" })
		end
		return messages
	elseif type(payload) == "string" then
		return { { role = "user", content = payload } }
	elseif payload ~= nil then
		return { { role = "user", content = vim.json.encode(payload) } }
	end
	return { { role = "user", content = "" } }
end

--- Map Avante's single raw `args` string (whatever the user typed after the
--- slash command name) onto MCP's `prompts/get` `arguments` shape (a flat
--- `{[string]: string}` object, per each declared `PromptArgument`'s `name`
--- -- see `prompt_meta`'s `arguments` list, native.lua's `build_listing`
--- sidecar mechanism). Avante's slash-command input is a single opaque
--- string, not per-argument fields, so there is no lossless way to fill in
--- more than one declared argument from it; the one pragmatic, non-lossy
--- mapping available is binding that whole string to the first declared
--- argument's name (the common case for these prompts is exactly one
--- argument). A prompt with no declared arguments gets an empty object --
--- still callable, just with the typed text discarded, matching how a tool
--- with no declared inputSchema is still callable without documented
--- fields.
local function build_prompt_arguments(prompt_info, args)
	local declared = prompt_info.arguments
	if type(declared) ~= "table" or #declared == 0 then
		return vim.empty_dict()
	end
	local first_name = declared[1] and declared[1].name
	if type(first_name) ~= "string" or first_name == "" then
		return vim.empty_dict()
	end
	if args == nil or args == "" then
		return vim.empty_dict()
	end
	return { [first_name] = args }
end

--- Build one Avante `AvanteSlashCommand` entry for a single MCP prompt
--- exposed by `mcp_client`. Namespaced as `mcp:<client name>:<prompt name>`
--- -- following the same precedent as the old `mcphub.nvim`'s
--- `extensions/avante/slash_commands.lua` (`"mcp:" .. server_name .. ":" ..
--- prompt_name`) this adapter replaces -- both so same-named prompts from
--- two different clients cannot collide, and so a `mcp:`-prefixed name can
--- be recognized and pruned on refresh without disturbing any other
--- (built-in or user-defined) slash command sharing `Config.slash_commands`.
local function build_prompt_command(mcp_client, prompt_info)
	return {
		name = string.format("mcp:%s:%s", mcp_client.name, prompt_info.name),
		description = prompt_info.description or ("MCP prompt " .. prompt_info.name),
		details = prompt_info.description or ("MCP prompt " .. prompt_info.name),
		--- Avante invokes this as `callback(sidebar, args)`
		--- (`sidebar.lua:2827`, the "any command other than the two
		--- hardcoded special-cased names" branch of `handle_submit`) with no
		--- generic path for a `cb`-mediated return into the normal LLM turn
		--- -- rendering is entirely this callback's own responsibility. Drive
		--- the result out through `sidebar:add_chat_history(...)` the same
		--- way whether `mcp_client:request()`'s callback fires synchronously
		--- (native, U3) or asynchronously (remote, U1/U2); no sync/async
		--- branching needed since nothing here has to return a value to a
		--- caller the way `custom_tools`' `func` does.
		callback = function(sidebar, args)
			local arguments = build_prompt_arguments(prompt_info, args)
			local ok, call_err = pcall(function()
				mcp_client:request({
					jsonrpc = "2.0",
					id = 1,
					method = "prompts/get",
					params = { name = prompt_info.name, arguments = arguments },
				}, function(err, result, _response)
					if err then
						vim.notify("mcphub-neovim: prompt failed: " .. tostring(err), vim.log.levels.ERROR)
						return
					end
					local payload = unwrap_result(result)
					local messages = render_prompt_result(payload)
					if sidebar and sidebar.add_chat_history then
						sidebar:add_chat_history(messages, { visible = true })
					end
				end)
			end)
			if not ok then
				vim.notify("mcphub-neovim: prompt failed: " .. tostring(call_err), vim.log.levels.ERROR)
			end
		end,
	}
end

--- Avante's `slash_commands` integration point. Unlike `custom_tools()`,
--- this both returns the freshly-built list AND refreshes `M.slash_commands`
--- in place (clear, then refill by index) so the one stable table Avante
--- was handed at `setup()` time reflects the current client/prompt registry
--- on `Config.slash_commands`'s very next read, exactly mirroring
--- `custom_tools()`'s "always re-evaluated against the current client
--- registry, never a snapshot frozen at require() time" guarantee -- a
--- client that disconnects between two accesses must drop its slash
--- commands by the very next call, not linger.
---
--- Usage:
---   require("avante").setup({
---     slash_commands = require("mcphub-neovim.adapters.avante").slash_commands,
---   })
function M.custom_slash_commands()
	local commands = {}
	for _, mcp_client in ipairs(client.get_clients()) do
		if not mcp_client:is_stopped() then
			refresh_client_prompts(mcp_client)
			for _, prompt_info in ipairs(prompts_cache[mcp_client.id] or {}) do
				table.insert(commands, build_prompt_command(mcp_client, prompt_info))
			end
		else
			-- Same staleness handling as tools_cache: a stopped client's
			-- cache entry is dropped so a later reconnect under the same id
			-- starts clean rather than replaying a previous session's
			-- listing.
			prompts_cache[mcp_client.id] = nil
		end
	end

	for i = #M.slash_commands, 1, -1 do
		M.slash_commands[i] = nil
	end
	for _, command in ipairs(commands) do
		table.insert(M.slash_commands, command)
	end

	return commands
end

return M
