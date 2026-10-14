--- Avante adapter: translate this plugin's client/tool/prompt surface --
--- `require("mcp-client.client").get_clients(filter)` plus each client
--- object's `request(rpc_message, callback)` -- into Avante's real
--- `custom_tools` config option and `avante.config`'s live `slash_commands`
--- array, replacing `mcphub.extensions.avante`.
---
--- This is a thin adapter: it holds no direct server or transport logic of
--- its own. Every tool call it exposes to Avante is, underneath, a standard
--- MCP `tools/list` / `tools/call` JSON-RPC message routed through a client
--- object's `request()` -- the adapter never imports `mcp-client.transport.*`,
--- never touches a `Job` object, and never assumes a client is remote or
--- native.
---
--- Avante's `custom_tools` shape (`avante/llm_tools/init.lua`,
--- `avante/types.lua`):
---
---   require("avante").setup({
---     custom_tools = function() return { <AvanteLLMTool>, ... } end,
---     -- (a plain list table is also accepted; `Config.custom_tools` is
---     -- called as a function only `if type(custom_tools) == "function"`)
---   })
---
--- Each `AvanteLLMTool` needs:
---   name         string
---   description  string
---   param        { type = "table", fields = { { name, description, type,
---                  optional? }, ... } }
---   returns      { { name, description, type, optional? }, ... }
---   func         fun(input: table, opts: AvanteLLMToolFuncOpts):
---                  (boolean|string|nil, string|nil)
---
--- `AvanteLLMToolFuncOpts` carries `on_log(log)` and `on_complete(result,
--- err)`. `process_tool_use` calls `func(input, opts)` and accepts either a
--- synchronous `return result, err`, or (for async work) returning `nil,
--- nil` and calling `opts.on_complete(result, err)` later.
---
--- A native client invokes its `request()` callback synchronously; a remote
--- client always invokes it asynchronously. `func` below never tries to
--- guess which kind of client it is calling -- it always drives the result
--- out through `opts.on_complete` and returns `nil, nil` immediately after
--- issuing the request. That is a valid "this tool is asynchronous"
--- response even on the synchronous native path.

local client = require("mcp-client.client")

local M = {}

--- Monotonic JSON-RPC id generator. Requests are correlated by
--- `rpc_message.id` (client.lua's `entry._in_flight`, legacy_sse.lua's
--- `_pending`), so two concurrent calls sharing an id would silently deliver
--- a response to the wrong callback -- e.g. an overlapping `tools/list`
--- refresh and `tools/call`. Never reused for the life of the session.
local next_request_id = 0
local function new_request_id()
	next_request_id = next_request_id + 1
	return next_request_id
end

--- Normalize a client `request()` result to the bare MCP payload. A native
--- client returns the handler's value directly (e.g. `{ tools = {...} }`); a
--- remote client returns the full JSON-RPC envelope (`{ jsonrpc, id, result
--- = { tools = {...} } }`). A nested `result` table alone isn't a reliable
--- envelope signal -- a native tool's own payload can legitimately use
--- `result` as an ordinary field name (e.g. `{ result = { value = 42 } }`) --
--- so unwrapping requires `jsonrpc`/`id` alongside the nested `result` table.
local function unwrap_result(result)
	if type(result) == "table" and type(result.result) == "table" and result.jsonrpc == "2.0" and result.id ~= nil then
		return result.result
	end
	return result
end

--- Avante's `custom_tools` contract is synchronous: `Config.custom_tools` is
--- called with no callback and its return value used immediately. A remote
--- client's `tools/list` reply always arrives later, so `custom_tools()`
--- returns the most recently known listing for each client synchronously
--- (empty until the first reply arrives) and kicks off a fresh `tools/list`
--- refresh on every call. `is_stopped()` is re-checked against the live
--- registry on every call, so a disconnected client is dropped immediately
--- rather than waiting for its cache entry to expire.
local tools_cache = {} ---@type table<string, table[]>
local tools_inflight = {} ---@type table<string, boolean>

--- Ask one client for its current tool listing via `tools/list`. A client
--- that errors or returns something malformed leaves the previous cache
--- entry (or the initial empty list) in place rather than raising, so one
--- misbehaving client can't take down the whole tool list.
local function refresh_client_tools(mcp_client)
	if tools_inflight[mcp_client.id] then
		return
	end
	tools_inflight[mcp_client.id] = true
	local ok, err = pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = new_request_id(),
			method = "tools/list",
			-- vim.empty_dict(), not {}: an empty Lua table serializes to a JSON
			-- array `[]`, which a strict real server rejects -- MCP requires
			-- `params` to be an object.
			params = vim.empty_dict(),
		}, function(cb_err, result, _response)
			tools_inflight[mcp_client.id] = nil
			local payload = unwrap_result(result)
			if cb_err or type(payload) ~= "table" or type(payload.tools) ~= "table" then
				return
			end
			tools_cache[mcp_client.id] = payload.tools
		end)
	end)
	if not ok then
		tools_inflight[mcp_client.id] = nil
		-- Same handling as a callback-reported error: leave the cache as-is.
		return err
	end
end

--- MCP's `inputSchema` (JSON Schema-ish) doesn't line up 1:1 with Avante's
--- `param` shape, so translate field-by-field. Unknown/missing schemas
--- degrade to an empty field list rather than erroring -- a tool with no
--- declared schema is still callable, just without argument documentation.
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
--- `mcp_client`. Names include the configured server name so equal upstream
--- tool names from different backends remain independently callable.
local function build_tool_spec(mcp_client, tool_info)
	return {
		name = "mcp_" .. mcp_client.name .. "__" .. tool_info.name,
		description = tool_info.description or ("MCP tool " .. tool_info.name),
		param = schema_to_param(tool_info.inputSchema),
		returns = {
			{ name = "result", description = "Result of the MCP tool call", type = "string" },
			{ name = "error", description = "Error message if the call failed", type = "string", optional = true },
		},
		func = function(input, opts)
			local on_complete = opts and opts.on_complete
			local on_log = opts and opts.on_log

			if on_log then
				on_log("calling " .. tool_info.name .. " on " .. mcp_client.name)
			end

			-- Defense-in-depth against a client that throws synchronously
			-- out of request() instead of reporting errors via callback.
			local ok, call_err = pcall(function()
				mcp_client:request({
					jsonrpc = "2.0",
					id = new_request_id(),
					method = "tools/call",
					-- arguments defaults to vim.empty_dict() (not {}) so a
					-- zero-argument tool call serializes `arguments` as a JSON
					-- object `{}`, not an array `[]` a strict server would reject.
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

			-- nil, nil signals "asynchronous; wait for on_complete" -- correct
			-- for both native and remote clients.
			return nil, nil
		end,
	}
end

--- Avante's `custom_tools` integration point. Exposed as a function here so
--- it is always re-evaluated against the current client registry rather
--- than a snapshot frozen at `require()` time -- a client that disconnects
--- between two Avante turns must disappear from the very next
--- `custom_tools()` call.
---
--- Usage:
---   require("avante").setup({
---     custom_tools = require("mcp-client.adapters.avante").custom_tools,
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
			tools_inflight[mcp_client.id] = nil
		end
	end
	return tools
end

--- Prompt/slash-command bridging. Avante's `slash_commands` mechanism:
---
---   require("avante").setup({
---     -- your own manually-configured slash commands, if any, e.g.:
---     -- slash_commands = { { name = "my-command", ... } },
---   })
---   -- MCP-derived commands are wired separately -- see M.refresh() below,
---   -- not through setup()'s `opts`.
---
--- Unlike `custom_tools` (either a table or a function Avante calls fresh
--- each time), `Config.slash_commands` is typed `AvanteSlashCommand[]`
--- only: a plain array, with no function form. It is read fresh on every
--- `avante.utils.get_commands()` call, but `Config.slash_commands` itself is
--- never re-invoked, so the live view must be kept current by mutating a
--- table's *contents* in place.
---
--- `vim.tbl_deep_extend` (used internally by `setup()`/`override()` to merge
--- `opts`) deep-copies nested table values rather than preserving reference
--- identity, so a table handed into `setup()`'s `opts.slash_commands` is not
--- the same table `Config.slash_commands` ends up holding -- mutating the
--- original afterward has no effect. The working mechanism instead requires
--- `avante.config` fresh (after `setup()` has already run) and mutates its
--- live `slash_commands` array directly -- the same approach Avante's own
--- ACP integration (`llm.lua`'s `available_commands_update`) uses to
--- register commands post-setup. `M.custom_slash_commands()` (also callable
--- as `M.refresh()`, any time -- e.g. from an `MCPAttach`/`MCPDetach`
--- autocmd) requires `avante.config` fresh each time -- mirroring how
--- `adapters/codecompanion.lua`'s `refresh()` lazily requires
--- `codecompanion.mcp`/`codecompanion.config` inside the function that needs
--- them, so this file keeps loading fine even when avante.nvim is not
--- installed -- and clears+refills only the `mcp:`-prefixed entries it
--- owns, leaving any entry a user configured directly untouched.

--- Cache of prompt metadata per client id, refreshed on every
--- `M.custom_slash_commands()` call -- same shape and staleness handling as
--- `tools_cache`/`refresh_client_tools` above.
local prompts_cache = {} ---@type table<string, table[]>

--- Ask one client for its current prompt listing via `prompts/list`.
--- Mirrors `refresh_client_tools`.
local function refresh_client_prompts(mcp_client)
	local ok, err = pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = new_request_id(),
			method = "prompts/list",
			-- vim.empty_dict(), not {}, for the same reason as tools/list above:
			-- MCP requires `params` to be a JSON object, and a strict real server
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
--- `Sidebar:add_chat_history` (each `{ role, content }` where `content` is a
--- string or the first element of a content-part list). A native handler
--- returns whatever the prompt function returns verbatim, so a real prompt
--- is free to return the full MCP `GetPromptResult` shape (`{ description?,
--- messages: [{role, content: {type, text}}] }`) or something simpler; this
--- handles both without erroring on an unexpected shape.
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

--- Map Avante's single raw `args` string onto MCP's `prompts/get`
--- `arguments` shape (a flat `{[string]: string}` object). Avante's
--- slash-command input is one opaque string, not per-argument fields, so the
--- one non-lossy mapping available is binding that whole string to the
--- first declared argument's name. A prompt with no declared arguments gets
--- an empty object -- still callable, just with the typed text discarded.
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
--- so same-named prompts from two different clients cannot collide, and so
--- a `mcp:`-prefixed name can be recognized and pruned on refresh without
--- disturbing any other slash command sharing `Config.slash_commands`.
local function build_prompt_command(mcp_client, prompt_info)
	return {
		name = string.format("mcp:%s:%s", mcp_client.name, prompt_info.name),
		description = prompt_info.description or ("MCP prompt " .. prompt_info.name),
		details = prompt_info.description or ("MCP prompt " .. prompt_info.name),
		--- Avante invokes this as `callback(sidebar, args)` with no generic
		--- path for a `cb`-mediated return into the normal LLM turn --
		--- rendering is entirely this callback's own responsibility.
		callback = function(sidebar, args)
			local arguments = build_prompt_arguments(prompt_info, args)
			local ok, call_err = pcall(function()
				mcp_client:request({
					jsonrpc = "2.0",
					id = new_request_id(),
					method = "prompts/get",
					params = { name = prompt_info.name, arguments = arguments },
				}, function(err, result, _response)
					if err then
						vim.notify("mcp-client: prompt failed: " .. tostring(err), vim.log.levels.ERROR)
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
				vim.notify("mcp-client: prompt failed: " .. tostring(call_err), vim.log.levels.ERROR)
			end
		end,
	}
end

--- Names this adapter mints for its own MCP-derived slash commands all
--- start with this prefix. Used below to recognize and prune only the
--- entries this adapter owns out of the live `Config.slash_commands` array,
--- without touching any entry a user configured directly.
local MCP_PREFIX = "mcp:"

--- Lazily require Avante's real config module -- never at file load time --
--- so this file keeps loading fine even when avante.nvim is not installed.
--- Returns `nil` (rather than raising) if `avante.config` is not on the
--- runtimepath, so a caller with no Avante installed can still safely call
--- `M.custom_slash_commands()`.
local function avante_config()
	local ok, config = pcall(require, "avante.config")
	if ok then
		return config
	end
	return nil
end

--- Avante's `slash_commands` integration point. Directly mutates
--- `require("avante.config")`'s own, already-live `slash_commands` array --
--- the same way Avante's own ACP integration registers commands post-setup.
---
--- Only `mcp:`-prefixed entries (this adapter's own naming convention) are
--- cleared and refilled; any other entry already present in
--- `Config.slash_commands` is left untouched. A client that disconnects
--- between two calls has its commands dropped by the very next call,
--- mirroring `custom_tools()`'s "always re-evaluated against the current
--- client registry" guarantee.
---
--- Also returns the freshly-built list directly, for callers (tests
--- included) that just want the current listing without needing a real or
--- fake `avante.config` module in `package.loaded`.
---
--- Usage: call this (or `M.refresh()`) once after `require("avante").setup()`
--- and again from an `MCPAttach`/`MCPDetach` autocmd to keep the live
--- `Config.slash_commands` array current as clients connect and disconnect.
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

	local config = avante_config()
	if config and type(config.slash_commands) == "table" then
		-- Remove only the entries this adapter owns (mcp:-prefixed),
		-- iterating backwards so removal-by-index doesn't skip elements --
		-- any other entry (built-in, user-defined, or from another
		-- producer like Avante's own ACP integration) is left in place.
		for i = #config.slash_commands, 1, -1 do
			local entry = config.slash_commands[i]
			if
				type(entry) == "table"
				and type(entry.name) == "string"
				and entry.name:sub(1, #MCP_PREFIX) == MCP_PREFIX
			then
				table.remove(config.slash_commands, i)
			end
		end
		for _, command in ipairs(commands) do
			table.insert(config.slash_commands, command)
		end
	end

	return commands
end

--- Convenience alias for `M.custom_slash_commands()`, matching the
--- `refresh()` convention `adapters/codecompanion.lua` already established
--- for "re-query the live client registry and re-publish everything
--- downstream" -- callable from an `MCPAttach`/`MCPDetach` autocmd exactly
--- like that sibling adapter's own `refresh()`.
function M.refresh()
	return M.custom_slash_commands()
end

return M
