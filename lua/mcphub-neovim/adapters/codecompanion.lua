--- CodeCompanion adapter (U5): translate this plugin's client/tool surface --
--- `require("mcphub-neovim.client").get_clients(filter)` plus each client
--- object's `request(rpc_message, callback)` -- into CodeCompanion's real
--- extension, tool, and editor-context integration points, replacing
--- `mcphub.extensions.codecompanion`.
---
--- This is a thin adapter (R6): it holds no direct hub or transport logic
--- of its own. Every tool call and resource read it exposes to CodeCompanion
--- is, underneath, a standard MCP `tools/list` / `tools/call` /
--- `resources/list` / `resources/read` JSON-RPC message routed through a
--- client object's `request()` -- exactly the same call a native server
--- (U3) or a remote hub connection (U1/U2) already answers. The adapter
--- never imports `mcphub-neovim.transport.*`, never touches a `Job` object,
--- and never assumes a client is remote or native -- `get_clients()`
--- deliberately makes the two indistinguishable, and this file relies on
--- that uniformity rather than working around it.
---
--- CodeCompanion's real extension/tool/editor-context shape (verified
--- against the actual, locally-installed `olimorris/codecompanion.nvim`
--- source, not guessed -- see the file-by-file citations below).
---
--- ## 1. Extension registration
---
--- `lua/codecompanion/_extensions/init.lua` (`Extensions.resolve`/
--- `load_extension`) requires `codecompanion._extensions.<name>` from the
--- runtimepath (or a caller-supplied callback table/function/string) and
--- calls `ext.setup(opts)`; an optional `ext.exports` table is then
--- reachable as `require("codecompanion").extensions.<name>`. There is also
--- `CodeCompanion.register_extension(name, extension)` (`init.lua:29-34`)
--- for registering one directly without a `codecompanion._extensions.*`
--- module on the runtimepath -- the path this adapter's own consumer is
--- expected to use:
---
---   require("codecompanion").register_extension("mcphub-neovim", {
---     callback = require("mcphub-neovim.adapters.codecompanion"),
---   })
---
--- (equivalently, `require("codecompanion").setup({ extensions = {
--- ["mcphub-neovim"] = { callback = require("mcphub-neovim.adapters.codecompanion") } } })`).
--- Either way, `M.setup(opts)` below is what actually gets called.
---
--- ## 2. Tool registration
---
--- The generic, third-party-reachable path is `config.interactions.chat.tools`
--- (`lua/codecompanion/config.lua:159-352`; resolved per LLM tool call by
--- `Tools.resolve`, `lua/codecompanion/interactions/chat/tools/init.lua:502-530`,
--- which calls `tool.callback()` fresh every time -- so a `callback`-shaped
--- entry is never a frozen snapshot). But CodeCompanion's own *internal*
--- MCP client (`lua/codecompanion/mcp/*` -- a competing, first-class MCP
--- implementation added in PR #2549 that spawns `cmd`-configured
--- subprocesses itself) already publishes a smaller, purpose-built registry
--- for exactly this shape of problem: `lua/codecompanion/mcp/init.lua:44-56`
--- (`M.register_tools(server_name, tools, group)` /
--- `M.unregister_tools(server_name)` / `M.get_registered_tools()`), which
--- operates purely on a module-local table with **no** coupling to that
--- internal MCP `Client` class, and is merged into every chat buffer's live
--- tool set on every resolution pass via `add_mcp_tools`, a `pre_filter`
--- hook unconditionally applied by
--- `lua/codecompanion/interactions/chat/tools/filter.lua:4-24`. That is the
--- one call site: `M.register_tools`/`M.unregister_tools` are called here
--- exactly the way `codecompanion.mcp.tool_bridge.setup_tools` (the
--- internal MCP client's own equivalent of this adapter,
--- `lua/codecompanion/mcp/tool_bridge.lua:158-186`) calls them -- this
--- adapter is simply a second, independent producer of the same
--- already-public registry, not a reimplementation of it.
---
--- Each registered tool entry is a `CodeCompanion.Tools.Tool`
--- (`lua/codecompanion/types.lua:168-187`): `name`, `cmds` (a list of
--- `fun(tools, args, opts)`), `schema` (`{ type = "function", ["function"]
--- = { name, description, parameters, strict } }` -- standard JSON-Schema
--- function-calling shape, confirmed by
--- `lua/codecompanion/mcp/tool_bridge.lua:97-108`, which passes
--- `mcp_tool.inputSchema` straight through as `parameters` with no
--- reshaping -- so MCP's `inputSchema` needs no translation here, unlike
--- Avante's bespoke `param.fields` shape in U4), plus `output`
--- (`success`/`error`/`prompt` handlers).
---
--- `cmds[i]`'s completion contract (confirmed by
--- `lua/codecompanion/interactions/chat/tools/runtime/runner.lua:74-113`,
--- `Runner:run_tool`): the function is called as `tool_cmd(tools, args, {
--- input = ..., output_cb = output_handler })` inside a `pcall`; it may
--- *either* `return { status = "success"|"error", data = ... }`
--- synchronously, *or* return nothing and call `opts.output_cb(msg)` later
--- -- `output_handler` is idempotent (a `tool_finished` guard), so calling
--- it from inside the function body and then returning nothing is always
--- safe regardless of which path is taken. That is exactly the same dual
--- sync/async contract `client:request()` already has (native, U3,
--- synchronous callback; remote, U1/U2, always asynchronous), and exactly
--- the same shape U4's Avante adapter resolved by always deferring through
--- the async-capable path (`opts.on_complete`/here, `opts.output_cb`) and
--- never trying to also return a value synchronously.
---
--- ## 3. Resource/variable bridging
---
--- `variables` (the name the brief and `mcphub.nvim` era used) does not
--- exist under that name in this installed version -- it was renamed to
--- `editor_context` (`doc/configuration/upgrading.md:26`: *"`variables`
--- have been renamed to `editor_context`... `interactions.chat.editor_context`
--- and `interactions.inline.editor_context`"*). It is not broken or
--- unimplemented: `lua/codecompanion/interactions/shared/editor_context/user.lua`
--- (the resolver for any config entry with no `path`, i.e. a user/extension-
--- registered context) is a real, working, synchronous-only mechanism --
--- `EditorContext:chat_render` (`user.lua:18-30`) calls
--- `self.config.callback(self)` and uses **its return value directly and
--- immediately** as the injected chat message content. There is no
--- deferred/async completion path anywhere in this subsystem (confirmed by
--- grepping `editor_context/init.lua` and `editor_context/user.lua` for
--- any callback/schedule/coroutine machinery beyond that one synchronous
--- call) -- unlike `tools`' `output_cb`, an `editor_context.callback` MUST
--- return its content before the call returns.
---
--- That is a **real, load-bearing limitation of CodeCompanion's current,
--- correctly-functioning API**, not a bug to route around: a native
--- client's `request()` callback fires synchronously (U3), so its resource
--- content is always fresh when `#{mcp:<client>}` is used; a remote
--- client's `request()` is always asynchronous (U1/U2), so this bridging
--- path can only ever return the most recently cached resource content for
--- a remote client -- exactly the same honest constraint U4's `custom_tools`
--- cache documents for Avante's synchronous `custom_tools()` call, applied
--- here to resources instead of tools. This adapter implements the
--- bridging path exactly as CodeCompanion's `editor_context` contract
--- requires (a plain synchronous `callback(self)` returning message
--- content) rather than inventing a parallel, unsanctioned async injection
--- mechanism -- the gap for remote clients is CodeCompanion's `editor_context`
--- design, not a shortcut taken here.

local client = require("mcphub-neovim.client")

local M = {}

--- Namespace CodeCompanion tool/editor-context entries with this prefix so
--- multiple clients' entries can never collide with each other or with a
--- builtin/other-extension entry under the same generic registries this
--- adapter shares.
local NAME_PREFIX = "mcp_"

--- Cache of each client's most recently known tool/resource listing, keyed
--- by client id, same rationale as U4's `tools_cache`: CodeCompanion's own
--- integration points here (`Tools.resolve`'s `callback()`,
--- `editor_context`'s `callback(self)`) are themselves synchronous and
--- cannot block on a remote client's async round-trip, so each call
--- returns whatever is currently cached and opportunistically kicks off a
--- fresh listing request. `is_stopped()` is re-checked against the live
--- registry independently of this cache on every access (see
--- `M.exports.refresh`/`build_group_entries` below), so a disconnected
--- client's stale cache entry is never served past that check.
local tools_cache = {}
local resources_cache = {}

--- Ask one client for its current tool listing via the standard MCP
--- `tools/list` method. Mirrors U4's `refresh_client_tools` exactly: a
--- `pcall` around `request()` is pure defense-in-depth against a
--- hypothetical future client that throws synchronously instead of
--- reporting failure through the `(err, result, response)` callback --
--- neither current client implementation (native, U3; remote, U1/U2) does
--- this today. A failure (thrown or callback-reported) simply leaves the
--- previous cache entry in place rather than raising, so one misbehaving
--- client can never take down the whole tool/resource listing.
local function refresh_client_tools(mcp_client)
	pcall(function()
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
	end)
end

--- Ask one client for its current resource listing via the standard MCP
--- `resources/list` method. Same shape and same defense-in-depth rationale
--- as `refresh_client_tools` above.
local function refresh_client_resources(mcp_client)
	pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = 1,
			method = "resources/list",
			params = {},
		}, function(err, result, _response)
			if err or type(result) ~= "table" or type(result.resources) ~= "table" then
				return
			end
			resources_cache[mcp_client.id] = result.resources
		end)
	end)
end

--- MCP's `inputSchema` is already standard JSON Schema, and CodeCompanion's
--- tool `schema.function.parameters` expects exactly that shape untouched
--- (`codecompanion/mcp/tool_bridge.lua:97-108` passes `mcp_tool.inputSchema`
--- straight through) -- so, unlike Avante's bespoke `param.fields` shape in
--- U4, no field-by-field translation is needed here. A tool with no
--- declared schema still gets a minimal, valid empty-object schema so it
--- remains callable (just without argument documentation for the LLM).
local function tool_parameters(input_schema)
	if type(input_schema) == "table" then
		return input_schema
	end
	return { type = "object", properties = {} }
end

--- Render an MCP tool result's `content` (or the plain result CodeCompanion
--- passes through the `(err, result, response)` callback) into the plain
--- string `output.data` this adapter's `output` handlers expect.
local function render_result(result)
	if type(result) == "string" then
		return result
	elseif type(result) == "table" and type(result.content) == "table" then
		if #result.content == 1 and result.content[1].type == "text" then
			return result.content[1].text
		end
		return vim.inspect(result.content)
	elseif result ~= nil then
		return vim.json.encode(result)
	end
	return ""
end

--- Build one CodeCompanion tool config entry (the `CodeCompanion.Tools.Tool`
--- shape `Tools.resolve` returns directly, since this is case 4 -- "inline
--- tool table" -- of `Tools.resolve`, `tools/init.lua:527-529`) for a
--- single MCP tool exposed by `mcp_client`.
local function build_tool_spec(mcp_client, tool_info)
	local prefixed_name = NAME_PREFIX .. mcp_client.name .. "_" .. tool_info.name

	return {
		name = prefixed_name,
		schema = {
			type = "function",
			["function"] = {
				name = prefixed_name,
				description = tool_info.description or ("MCP tool " .. tool_info.name),
				parameters = tool_parameters(tool_info.inputSchema),
			},
		},
		cmds = {
			--- Called as `tool_cmd(tools, args, opts)`
			--- (`tools/runtime/runner.lua:100-108`); always resolves via
			--- `opts.output_cb` and returns nothing, which is correct and
			--- sufficient whether `mcp_client:request()`'s callback fires
			--- synchronously (native, U3) or asynchronously (remote,
			--- U1/U2) -- `Runner:run_tool` already supports a `cmds` entry
			--- that always defers to `output_cb` rather than one that
			--- sometimes returns a value synchronously.
			function(_tools, args, opts)
				local output_cb = opts and opts.output_cb

				-- Same defense-in-depth rationale as `refresh_client_tools`:
				-- neither current client implementation throws
				-- synchronously out of `request()`, but a caught throw is
				-- routed through `output_cb` exactly like a
				-- callback-reported `err` already is, rather than
				-- propagating out of this function and crashing whatever
				-- in CodeCompanion called it.
				local ok, call_err = pcall(function()
					mcp_client:request({
						jsonrpc = "2.0",
						id = 1,
						method = "tools/call",
						params = { name = tool_info.name, arguments = args or {} },
					}, function(err, result, _response)
						if not output_cb then
							return
						end
						if err then
							return output_cb({ status = "error", data = tostring(err) })
						end
						if type(result) == "table" and result.isError then
							return output_cb({ status = "error", data = render_result(result) })
						end
						output_cb({ status = "success", data = render_result(result) })
					end)
				end)
				if not ok and output_cb then
					output_cb({ status = "error", data = tostring(call_err) })
				end
			end,
		},
		output = {
			--- The message shared with the user when asking for their
			--- approval (`CodeCompanion.Tools.Tool.output.prompt`,
			--- `types.lua:181`).
			prompt = function(self, _tools)
				return string.format("Execute the MCP tool `%s`?", self.name)
			end,
			success = function(self, tools, _cmd, stdout)
				local out = stdout and stdout[#stdout]
				tools.chat:add_tool_output(self, out or "", out or "")
			end,
			error = function(self, tools, _cmd, stderr)
				local out = stderr and stderr[#stderr]
				tools.chat:add_tool_output(self, "MCP tool execution failed:\n" .. (out or ""), out or "")
			end,
		},
	}
end

--- Build the `codecompanion.mcp.register_tools`-shaped config table
--- (`tool_name -> CodeCompanion.Tools.Tool`) plus a `group` entry
--- describing this client's tools collectively, for one connected client.
--- Mirrors `codecompanion.mcp.tool_bridge.setup_tools`
--- (`mcp/tool_bridge.lua:158-186`), which builds exactly this same
--- `(tools, group)` pair for its own (internal, cmd-spawned) MCP clients --
--- this adapter is a second, independent producer of the same shape for
--- clients that this plugin -- not CodeCompanion's own MCP subsystem --
--- already connected and manages.
local function build_client_registration(mcp_client)
	local tool_configs = {}
	local names = {}
	for _, tool_info in ipairs(tools_cache[mcp_client.id] or {}) do
		local spec = build_tool_spec(mcp_client, tool_info)
		tool_configs[spec.name] = {
			description = tool_info.description or spec.name,
			callback = function()
				return spec
			end,
			-- Not intended to be picked individually from a slash-command
			-- style tool picker; grouped under the client's own group
			-- entry instead (same convention the internal MCP bridge uses,
			-- `mcp/tool_bridge.lua:151`).
			visible = false,
		}
		table.insert(names, spec.name)
	end

	if #names == 0 then
		return tool_configs, nil
	end

	table.sort(names)
	local group = {
		description = string.format("Tools from MCP client `%s`", mcp_client.name),
		tools = names,
		opts = { collapse_tools = true },
	}
	return tool_configs, group
end

--- Build the `editor_context`-shaped config entry (`description` +
--- synchronous `callback(self)`, the "user-defined context" shape resolved
--- by `editor_context/user.lua:6-16,18-30` for any config entry with no
--- `path`) that bridges one client's MCP resources into CodeCompanion chat
--- as `#{mcp_<client name>}`.
---
--- Per the design-doc comment at the top of this file: this `callback`
--- MUST return synchronously (CodeCompanion's `editor_context` API has no
--- deferred/async completion path at all), so it always returns whatever
--- is currently cached for this client -- current and complete for a
--- native client (whose `request()` callback fires synchronously, U3),
--- but potentially stale or empty on first use for a remote client (U1/U2:
--- always asynchronous) until a background `resources/list`/`resources/read`
--- round trip lands. That is a real, documented limitation of
--- CodeCompanion's current `editor_context` contract, not a workaround
--- invented here.
local function build_editor_context_entry(mcp_client)
	return {
		description = string.format("Share resources from MCP client `%s` with the LLM", mcp_client.name),
		callback = function(_editor_context_self)
			local resources = resources_cache[mcp_client.id] or {}
			if #resources == 0 then
				return string.format("No resources currently available from MCP client `%s`.", mcp_client.name)
			end

			local rendered = {}
			for _, resource_info in ipairs(resources) do
				local content
				pcall(function()
					mcp_client:request({
						jsonrpc = "2.0",
						id = 1,
						method = "resources/read",
						params = { uri = resource_info.uri },
					}, function(err, result, _response)
						if not err then
							content = render_result(result)
						end
					end)
				end)
				table.insert(
					rendered,
					string.format(
						"### %s\n%s",
						resource_info.uri,
						content
							or "(unavailable: this client answers resources/read asynchronously; "
								.. "content was not ready synchronously)"
					)
				)
			end
			return table.concat(rendered, "\n\n")
		end,
	}
end

--- Track which client ids currently have a registered `editor_context`
--- entry, so a client that disappears from `get_clients()` entirely
--- (fully torn down, e.g. via `client._reset_registry()` in tests, or any
--- future real teardown path that drops the registry entry rather than
--- just flipping `is_stopped()`) has its entry pruned rather than left
--- behind as a dangling closure over a client object that no longer
--- exists in the registry. A merely-`is_stopped()` client (still present
--- in `get_clients()`, just disconnected) keeps its entry -- pruning here
--- is about registry *membership*, not connection state; connection
--- state is what `is_stopped()`/`refresh()`'s tool-unregistration already
--- handles per call.
local registered_editor_context_ids = {}

--- Re-query the live client registry and (re-)publish each connected
--- client's tools into `codecompanion.mcp`'s tool registry
--- (`register_tools`/`unregister_tools`, `mcp/init.lua:44-56`), refresh
--- each client's `editor_context` entry, and opportunistically refresh
--- each client's cached tool/resource listing.
---
--- `is_stopped()` is checked against the live registry on every call, same
--- as U4: a stopped client's tools are unregistered immediately (not left
--- to linger until some cache expires), and its cache entries are dropped
--- so a later reconnect under the same id starts from a clean slate. A
--- client no longer present in `get_clients()` at all has its
--- `editor_context` entry pruned too (see `registered_editor_context_ids`
--- above).
---
--- Exposed as `exports.refresh` so a consumer can call it explicitly (e.g.
--- on `MCPAttach`/`MCPDetach`), and also called once from `M.setup` so a
--- chat buffer opened after `setup()` already sees whatever is
--- synchronously available (native clients) without requiring a manual
--- first refresh.
local function refresh()
	local mcp = require("codecompanion.mcp")
	local config = require("codecompanion.config")
	config.interactions.chat.editor_context = config.interactions.chat.editor_context or {}

	local live_ids = {}
	for _, mcp_client in ipairs(client.get_clients()) do
		live_ids[mcp_client.id] = true
		config.interactions.chat.editor_context[NAME_PREFIX .. mcp_client.name] = build_editor_context_entry(mcp_client)
		registered_editor_context_ids[mcp_client.id] = mcp_client.name

		if mcp_client:is_stopped() then
			mcp.unregister_tools(mcp_client.id)
			tools_cache[mcp_client.id] = nil
			resources_cache[mcp_client.id] = nil
		else
			refresh_client_tools(mcp_client)
			refresh_client_resources(mcp_client)
			local tool_configs, group = build_client_registration(mcp_client)
			if group then
				mcp.register_tools(mcp_client.id, tool_configs, group)
			else
				mcp.unregister_tools(mcp_client.id)
			end
		end
	end

	-- Prune editor_context entries for any client id that used to be
	-- registered but is no longer present in get_clients() at all.
	for id, name in pairs(registered_editor_context_ids) do
		if not live_ids[id] then
			config.interactions.chat.editor_context[NAME_PREFIX .. name] = nil
			registered_editor_context_ids[id] = nil
			mcp.unregister_tools(id)
			tools_cache[id] = nil
			resources_cache[id] = nil
		end
	end
end

--- CodeCompanion extension entry point
--- (`CodeCompanion.Extension.setup`, `_extensions/init.lua`): called once
--- when the extension is loaded, either via
--- `require("codecompanion").setup({ extensions = { ["mcphub-neovim"] =
--- { callback = require("mcphub-neovim.adapters.codecompanion") } } })` or
--- `require("codecompanion").register_extension("mcphub-neovim", { callback
--- = require("mcphub-neovim.adapters.codecompanion") })`.
---
--- Delegates straight to `refresh()`, which registers one `editor_context`
--- entry per currently-known client
--- (`config.interactions.chat.editor_context`, mutated in place so
--- `EditorContext.new` -- which reads that same live config table on every
--- chat buffer -- picks it up without needing a restart) and publishes
--- tools, so a chat buffer opened after `setup()` already sees whatever is
--- synchronously available (native clients) without requiring a manual
--- first refresh. `opts` is accepted per the extension contract but this
--- adapter needs no configuration of its own.
function M.setup(_opts)
	refresh()
end

--- Functions exposed via `require("codecompanion").extensions["mcphub-neovim"]`
--- (`CodeCompanion.Extension.exports`).
M.exports = {
	--- Re-query `client.get_clients()` and re-publish tool/editor-context
	--- registrations for the current client roster. Safe to call at any
	--- time (e.g. from an `MCPAttach`/`MCPDetach` `User` autocmd handler) --
	--- idempotent and does not require the extension to be re-`setup()`.
	refresh = refresh,
}

return M
