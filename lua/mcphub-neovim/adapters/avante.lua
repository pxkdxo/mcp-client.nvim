--- Avante adapter (U4): translate this plugin's client/tool surface --
--- `require("mcphub-neovim.client").get_clients(filter)` plus each client
--- object's `request(rpc_message, callback)` -- into Avante's real
--- `custom_tools` integration point, replacing `mcphub.extensions.avante`.
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
local function refresh_client_tools(mcp_client)
	mcp_client:request({
		jsonrpc = "2.0",
		id = 1,
		method = "tools/list",
		params = {},
	}, function(err, result, _response)
		if err or type(result) ~= "table" or type(result.tools) ~= "table" then
			return
		end
		tools_cache[mcp_client.id] = result.tools
	end)
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

			mcp_client:request({
				jsonrpc = "2.0",
				id = 1,
				method = "tools/call",
				params = { name = tool_info.name, arguments = input or {} },
			}, function(err, result, _response)
				if not on_complete then
					return
				end
				if err then
					return on_complete(nil, tostring(err))
				end
				local result_str
				if type(result) == "string" then
					result_str = result
				elseif result ~= nil then
					result_str = vim.json.encode(result)
				else
					result_str = ""
				end
				on_complete(result_str, nil)
			end)

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

return M
