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
--- and `interactions.inline.editor_context`"*). **(U13 correction:** the
--- plugin has moved again since that doc was written and since U5's
--- original investigation: the real, currently-live path is
--- `interactions.shared.editor_context`, not `interactions.chat.editor_context`.
--- `config.setup()` (`config.lua:1376-1381`) migrates a caller's
--- `args.interactions.chat.editor_context` into
--- `M.config.interactions.shared.editor_context` and nils out the old
--- `chat.editor_context` key entirely, and every real reader --
--- `interactions/chat/keymaps/init.lua:97`, `providers/completion/init.lua:281`,
--- `interactions/shared/editor_context/init.lua:90` -- reads only
--- `interactions.shared.editor_context`. Confirmed empirically with a
--- headless run against the real installed plugin: mutating
--- `interactions.shared.editor_context` in place after `setup()` is
--- observed end-to-end by the real `chat_render()` path, exactly the shape
--- this adapter now targets below.)** It is not broken or
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
---
--- ## 4. Prompt/slash-command bridging (U12)
---
--- U5's investigation flagged a class-based `SlashCommand.new/execute/output`
--- mechanism and scoped it out as "a much larger, separate integration
--- surface" without verifying its exact shape. Re-verified against the
--- CURRENT installed source (the plugin has evolved further since U5): that
--- class only matters for a slash command that needs its own custom
--- completion-menu *provider* (a picker UI, e.g. `mcp.lua`'s
--- `vim.ui.select`-based server toggle,
--- `interactions/chat/slash_commands/builtin/mcp.lua:105-142`). It is NOT
--- the only, or even the primary, registration point.
---
--- The generic, third-party-reachable path -- structurally identical to
--- `editor_context` above, not the `SlashCommand` class -- is
--- `config.interactions.chat.slash_commands`
--- (`lua/codecompanion/config.lua:372-538`): a plain module table of
--- `{ description, callback(chat) }` (or `{ description, path, opts }`)
--- entries, read live by `pairs()` on every resolution pass, not resolved
--- once and cached: `providers/completion/init.lua:98-101`
--- (`completion.slash_commands()`, the completion-menu source),
--- `interactions/chat/action_palette.lua:95-99` (the `<C-a>` actions-menu
--- source), and `interactions/chat/keymaps.lua:6` (per-command keymap
--- wiring) all iterate `config.interactions.chat.slash_commands` directly
--- via `pairs()`, so a mutation to that table is visible on the very next
--- keystroke/menu-open with no separate registration call needed -- the
--- exact same "plain, live table" shape `editor_context` already has.
---
--- `SlashCommands:execute` (`interactions/chat/slash_commands/init.lua:80-108`)
--- special-cases exactly this: "If the user has provided a callback
--- function, use that" (line 84-87) -- `item.config.callback(chat)` is
--- called directly and its return value discarded, with NO class
--- instantiation at all. This is a first-class, intentional extension path,
--- not an undocumented internal shortcut: every content-bearing builtin slash
--- command (`fetch`, `file`, `symbols`, `help`,
--- `interactions/shared/slash_commands/*.lua`,
--- `interactions/chat/slash_commands/builtin/*.lua`) still goes through the
--- class shape internally, but a `callback`-only entry is explicitly
--- supported for exactly this "external code wants to add a slash command"
--- case and is the simplest sufficient shape here (no custom picker UI is
--- needed: a prompt either takes no arguments, or a small number of
--- declared ones collected via `vim.ui.input`, one prompt at a time).
---
--- This was verified to actually work, end-to-end, against the real,
--- installed plugin (not just read) -- the same rigor U11's reviewer
--- applied when Avante's mutate-in-place assumption turned out to be false:
--- a headless Neovim run that (1) calls the real `codecompanion.setup({})`,
--- (2) mutates `require("codecompanion.config").interactions.chat.slash_commands`
--- in place afterward, and (3) confirms the real
--- `completion.slash_commands()` read path *and* a real chat buffer's
--- `SlashCommands.run(item, chat)` both observe the mutation and invoke the
--- injected `callback(chat)`, landing content via `chat:add_message`.
--- Unlike Avante's `setup()`/`override()` (which deep-copies via
--- `vim.tbl_deep_extend("force", ...)` on every call, discarding reference
--- identity), CodeCompanion's `config.setup(opts)` (`config.lua:1357-1424`)
--- reassigns the *module's* `M.config` sub-table wholesale on each call, but
--- `require("codecompanion.config")` itself always returns the same,
--- stable module object `M` (`config.lua:1437-1441`), and extensions are
--- loaded strictly after `config.setup(opts)` finishes inside
--- `CodeCompanion.setup` (`init.lua:480-520`: `config.setup(opts)` at line
--- 484, extensions loaded at line 517-520) -- so by the time this adapter's
--- own `M.setup` (the extension callback) runs, `config.interactions.chat.slash_commands`
--- is already the final, live table, and mutating it in place afterward is
--- exactly the right mechanism, with no reference-identity pitfall to guard
--- against (there is only one `M.config` in play by the time any extension
--- code runs).
---
--- `Chat:add_buf_message` (used by `editor_context` above and the trivial
--- `now` slash command) explicitly does NOT enter the LLM-visible message
--- stack (`interactions/chat/init.lua:1811-1812`: "This will NOT form part
--- of the message stack that is sent to the LLM"). A prompt's entire
--- purpose is to seed real conversational context, so this bridging uses
--- `Chat:add_message({ role = config.constants.USER_ROLE, content = ... })`
--- instead -- the same call every content-bearing builtin slash command
--- (`fetch.lua:75-78`, `file.lua`, `symbols.lua`, `help.lua`) already uses.
---
--- Argument mapping: MCP's `prompts/get` params are `{ name, arguments }`
--- (`native.lua`'s `prompts/get` handling, `native.lua:78-84`), where
--- `arguments` is a flat string-keyed table the prompt function receives
--- verbatim. A `SlashCommand`/`callback(chat)` invocation carries no
--- free-text "typed after the slash command" argument capture at all --
--- confirmed by reading every completion-provider `execute` path
--- (`providers/completion/blink/init.lua:162-215`,
--- `providers/completion/cmp/slash_commands.lua:41-53`): selecting a slash
--- command from the completion menu clears the trigger text entirely
--- (`nvim_set_current_line("")` / a text-edit removing the whole match) and
--- immediately calls `SlashCommands.run(item, chat)` -- there is no parsing
--- step anywhere that would hand a `callback` free text typed after
--- `/name`. Any argument collection is the slash command's own
--- responsibility (the `mcp.lua` builtin uses `vim.ui.select` for its own
--- picker); this adapter mirrors that by using `vim.ui.input` once per
--- declared `prompt_meta.<name>.arguments` entry (name/description/required,
--- the same `PromptArgument` shape `native.lua`'s `example_native_server`
--- fixture already demonstrates), building up the flat `arguments` table
--- `prompts/get` expects before issuing the request.

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
local prompts_cache = {}

--- Normalize a client `request()` result to the bare MCP payload, regardless of
--- which kind of client produced it (mirrors U4's avante adapter). Native
--- clients (U3) deliver the handler's return value directly (e.g.
--- `{ tools = {...} }`); remote clients (U1/U2) deliver the full JSON-RPC
--- envelope (`{ jsonrpc, id, result = { tools = {...} } }`). Local test doubles
--- historically mimic the native/unwrapped shape, so the divergence only bites
--- against a real remote hub -- surfaced by U9. A nested `result` table alone
--- is NOT a reliable envelope signal: a native tool is an arbitrary,
--- MCP-unaware Lua function, and its own payload can legitimately use
--- `result` as an ordinary field name (e.g. a calc/lookup tool returning
--- `{ result = { value = 42 } }`) -- unwrapping that would silently corrupt
--- the tool's own data. Require the two fields that only a genuine JSON-RPC
--- response carries (`jsonrpc`, `id`) alongside the nested `result` table
--- before unwrapping.
local function unwrap_result(result)
	if type(result) == "table" and type(result.result) == "table" and result.jsonrpc == "2.0" and result.id ~= nil then
		return result.result
	end
	return result
end

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
			-- vim.empty_dict(), not {}: an empty Lua table serializes to a JSON
			-- array `[]`, which a strict real hub rejects (HTTP 400) -- MCP
			-- requires `params` to be an object. (Surfaced by U9's real-hub
			-- validation; local doubles echo regardless of shape.)
			params = vim.empty_dict(),
		}, function(err, result, _response)
			local payload = unwrap_result(result)
			if err or type(payload) ~= "table" or type(payload.tools) ~= "table" then
				return
			end
			tools_cache[mcp_client.id] = payload.tools
		end)
	end)
end

--- Ask one client for its current prompt listing via the standard MCP
--- `prompts/list` method. Same shape and same defense-in-depth rationale as
--- `refresh_client_tools` above.
local function refresh_client_prompts(mcp_client)
	pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = 1,
			method = "prompts/list",
			-- vim.empty_dict(), not {}: see refresh_client_tools -- empty `{}`
			-- serializes as JSON `[]`, which a strict real hub rejects.
			params = vim.empty_dict(),
		}, function(err, result, _response)
			local payload = unwrap_result(result)
			if err or type(payload) ~= "table" or type(payload.prompts) ~= "table" then
				return
			end
			prompts_cache[mcp_client.id] = payload.prompts
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
			-- vim.empty_dict(), not {}: see refresh_client_tools -- empty `{}`
			-- serializes as JSON `[]`, which a strict real hub rejects.
			params = vim.empty_dict(),
		}, function(err, result, _response)
			local payload = unwrap_result(result)
			if err or type(payload) ~= "table" or type(payload.resources) ~= "table" then
				return
			end
			resources_cache[mcp_client.id] = payload.resources
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
						-- arguments defaults to vim.empty_dict() (not {}) so a
						-- zero-argument tool call serializes `arguments` as a JSON
						-- object `{}`, not an array `[]` a strict hub would reject.
						params = { name = tool_info.name, arguments = args or vim.empty_dict() },
					}, function(err, result, _response)
						if not output_cb then
							return
						end
						if err then
							return output_cb({ status = "error", data = tostring(err) })
						end
						-- Unwrap the JSON-RPC envelope for a remote client so the
						-- tool's own CallToolResult (content/isError) is read, not
						-- the wrapper (a native client returns it directly).
						local payload = unwrap_result(result)
						if type(payload) == "table" and payload.isError then
							return output_cb({ status = "error", data = render_result(payload) })
						end
						output_cb({ status = "success", data = render_result(payload) })
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
							-- Unwrap the JSON-RPC envelope for a remote client so
							-- the resource's own ReadResourceResult is rendered.
							content = render_result(unwrap_result(result))
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

--- Build one slash-command config entry (the `{ description, callback(chat) }`
--- shape `SlashCommands:execute` calls `item.config.callback(chat)` on
--- directly, `interactions/chat/slash_commands/init.lua:84-87`) for a
--- single MCP prompt exposed by `mcp_client`, keyed by the same
--- `NAME_PREFIX .. client name .. "_" .. prompt name` convention
--- `build_tool_spec` already uses.
---
--- Argument collection: for each declared `prompt_info.arguments` entry
--- (the MCP `PromptArgument` shape -- `name`/`description`/`required`,
--- confirmed against `native.lua`'s `example_native_server` fixture),
--- `vim.ui.input` is used once to collect that argument's value before
--- issuing `prompts/get`, building up the flat `arguments` table
--- `native.lua`'s `prompts/get` handling (and the MCP spec generally)
--- expects. A cancelled (`nil`) input for a required argument aborts the
--- prompt invocation rather than sending an incomplete request.
---
--- The `prompts/get` result's `messages` (MCP's `GetPromptResult` shape --
--- a list of `{ role, content }`) are each added to the chat via
--- `Chat:add_message`, NOT `add_buf_message` -- the latter explicitly does
--- not enter the LLM-visible message stack
--- (`interactions/chat/init.lua:1811-1812`), which would defeat a prompt's
--- entire purpose of seeding real conversational context. This is the same
--- call every content-bearing builtin slash command uses (`fetch.lua:75-78`
--- et al).
---
--- Each `message.content` is, per MCP's `PromptMessage` shape (confirmed
--- against `example_native_server.lua`'s `greet` prompt,
--- `tests/fixtures/example_native_server.lua`), a single content object --
--- e.g. `{ type = "text", text = "Hello, Ada!" }` -- NOT the
--- `{ content = [...] }`-wrapped list shape `CallToolResult`/
--- `ReadResourceResult` use (which is what `render_result` above is built
--- for, and where it is correctly used elsewhere in this file). Calling
--- `render_result(message.content)` directly on a bare `{type, text}`
--- object would fail its `type(result.content) == "table"` list-branch
--- check (a bare content object has no `.content` field of its own) and
--- silently fall through to `render_result`'s `vim.json.encode(result)`
--- fallback, corrupting every rendered prompt message into a raw JSON
--- string. Instead, `message.content` is wrapped into the one-element list
--- shape `render_result` expects (`{ content = { message.content } }`)
--- before calling it -- this reuses `render_result`'s existing, correct
--- single-text-item branch (`result.content[1].text`) for the common text
--- case, and its existing `vim.inspect(result.content)` fallback for any
--- other MCP-permitted content type (e.g. image/embedded-resource prompt
--- content) instead of silently corrupting it.
local function build_prompt_slash_command_entry(mcp_client, prompt_info)
	local prefixed_name = NAME_PREFIX .. mcp_client.name .. "_" .. prompt_info.name

	return prefixed_name,
		{
			description = prompt_info.description or ("MCP prompt " .. prompt_info.name),
			--- Argument collection is continuation-passing, not a `for` loop
			--- that reads a variable after `vim.ui.input()` returns: stock,
			--- synchronous Neovim `vim.ui.input` calls `on_confirm` before
			--- returning, but async providers actually in use (confirmed
			--- against the real installed `snacks.nvim`,
			--- `lua/snacks/input.lua:122-136` -- `confirm()` wraps
			--- `on_confirm(value)` in `vim.schedule(...)`, deferring it to a
			--- later event-loop tick; also true of dressing.nvim/noice.nvim)
			--- return immediately with `on_confirm` not yet called. Reading
			--- `cancelled`/`value` right after the call, as this used to do,
			--- would silently see only their unset initial state under any
			--- such provider. `collect(i)` instead proceeds to argument
			--- `i + 1` (or issues the request once all declared arguments are
			--- exhausted) exclusively from inside `vim.ui.input`'s own
			--- callback -- the same shape CodeCompanion's own builtin MCP
			--- slash command already uses for its `vim.ui.select`-based server
			--- picker (`interactions/chat/slash_commands/builtin/mcp.lua:61-72`:
			--- the continuation lives inside the selection callback, not after
			--- the call returns). This is correct under both a synchronous
			--- provider (the recursive call happens immediately, inside the
			--- still-executing outer `vim.ui.input` call, reproducing the old
			--- behavior exactly) and an async one (the recursive call happens
			--- whenever the user actually submits that argument's prompt).
			callback = function(chat)
				local arguments = {}
				local declared = prompt_info.arguments or {}

				local function issue_request()
					pcall(function()
						mcp_client:request({
							jsonrpc = "2.0",
							id = 1,
							method = "prompts/get",
							params = { name = prompt_info.name, arguments = arguments },
						}, function(err, result, _response)
							if err then
								return
							end
							local payload = unwrap_result(result)
							if type(payload) ~= "table" or type(payload.messages) ~= "table" then
								return
							end
							for _, message in ipairs(payload.messages) do
								-- Wrap the single PromptMessage content object into
								-- the one-element list shape render_result expects
								-- (see the doc comment above) --
								-- render_result(message.content) directly would
								-- silently corrupt this into a raw JSON string.
								chat:add_message({
									role = message.role or "user",
									content = render_result({ content = { message.content } }),
								})
							end
						end)
					end)
				end

				local function collect(i)
					local arg_info = declared[i]
					if arg_info == nil then
						return issue_request()
					end
					vim.ui.input({
						prompt = string.format(
							"%s%s: ",
							arg_info.name,
							arg_info.description and (" (" .. arg_info.description .. ")") or ""
						),
					}, function(input)
						if input == nil then
							if arg_info.required then
								return -- abort: a required argument was cancelled
							end
						else
							arguments[arg_info.name] = input
						end
						collect(i + 1)
					end)
				end

				collect(1)
			end,
		}
end

--- Build the slash-command config entries (name -> config) for every
--- currently-cached prompt exposed by `mcp_client`. Mirrors
--- `build_client_registration`'s tool-config-building loop, but returns a
--- flat map ready to be merged straight into
--- `config.interactions.chat.slash_commands` -- there is no group concept
--- for slash commands the way there is for tools.
local function build_prompt_slash_commands(mcp_client)
	local entries = {}
	for _, prompt_info in ipairs(prompts_cache[mcp_client.id] or {}) do
		local name, entry = build_prompt_slash_command_entry(mcp_client, prompt_info)
		entries[name] = entry
	end
	return entries
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

--- Track which slash-command names are currently registered per client id,
--- same rationale as `registered_editor_context_ids` above but a set
--- rather than a single name: a client can expose any number of prompts
--- (zero or more), each becoming its own slash-command entry, so pruning
--- needs the full set of names that were registered for that client, not
--- just one.
local registered_prompt_slash_command_names = {}

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
	-- interactions.shared.editor_context, NOT interactions.chat.editor_context
	-- (U13): confirmed against the real installed plugin that config.setup()
	-- migrates the latter into the former and nils the old key out entirely
	-- (config.lua:1376-1381) -- see the design-doc comment at the top of this
	-- file, "## 3. Resource/variable bridging", for the full citation trail.
	config.interactions.shared = config.interactions.shared or {}
	config.interactions.shared.editor_context = config.interactions.shared.editor_context or {}
	config.interactions.chat.slash_commands = config.interactions.chat.slash_commands or {}

	--- Remove every currently-registered slash-command entry for one client
	--- id (used both when a client is stopped and when pruning a
	--- fully-removed one), then clear the tracking set.
	local function unregister_prompt_slash_commands(id)
		for name in pairs(registered_prompt_slash_command_names[id] or {}) do
			config.interactions.chat.slash_commands[name] = nil
		end
		registered_prompt_slash_command_names[id] = nil
	end

	local live_ids = {}
	for _, mcp_client in ipairs(client.get_clients()) do
		live_ids[mcp_client.id] = true
		config.interactions.shared.editor_context[NAME_PREFIX .. mcp_client.name] =
			build_editor_context_entry(mcp_client)
		registered_editor_context_ids[mcp_client.id] = mcp_client.name

		if mcp_client:is_stopped() then
			mcp.unregister_tools(mcp_client.id)
			tools_cache[mcp_client.id] = nil
			resources_cache[mcp_client.id] = nil
			prompts_cache[mcp_client.id] = nil
			unregister_prompt_slash_commands(mcp_client.id)
		else
			refresh_client_tools(mcp_client)
			refresh_client_resources(mcp_client)
			refresh_client_prompts(mcp_client)
			local tool_configs, group = build_client_registration(mcp_client)
			if group then
				mcp.register_tools(mcp_client.id, tool_configs, group)
			else
				mcp.unregister_tools(mcp_client.id)
			end

			-- Re-publish this client's prompt slash commands from whatever is
			-- currently cached (same "re-query and re-publish" pattern as
			-- tools above): drop the previous registration first so a prompt
			-- that disappeared between refreshes doesn't linger.
			unregister_prompt_slash_commands(mcp_client.id)
			local prompt_entries = build_prompt_slash_commands(mcp_client)
			local names = {}
			for name, entry in pairs(prompt_entries) do
				config.interactions.chat.slash_commands[name] = entry
				names[name] = true
			end
			registered_prompt_slash_command_names[mcp_client.id] = names
		end
	end

	-- Prune editor_context entries and prompt slash commands for any client
	-- id that used to be registered but is no longer present in
	-- get_clients() at all.
	for id, name in pairs(registered_editor_context_ids) do
		if not live_ids[id] then
			config.interactions.shared.editor_context[NAME_PREFIX .. name] = nil
			registered_editor_context_ids[id] = nil
			mcp.unregister_tools(id)
			tools_cache[id] = nil
			resources_cache[id] = nil
		end
	end
	for id in pairs(registered_prompt_slash_command_names) do
		if not live_ids[id] then
			prompts_cache[id] = nil
			unregister_prompt_slash_commands(id)
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
--- (`config.interactions.shared.editor_context`, mutated in place so
--- `EditorContext.new` -- which reads that same live config table on every
--- chat buffer -- picks it up without needing a restart), publishes tools,
--- and registers one slash-command entry per currently-cached MCP prompt
--- (`config.interactions.chat.slash_commands`, mutated in place the same
--- way -- see "## 4. Prompt/slash-command bridging (U12)" above), so a
--- chat buffer opened after `setup()` already sees whatever is
--- synchronously available (native clients) without requiring a manual
--- first refresh. `opts` is accepted per the extension contract but this
--- adapter needs no configuration of its own.
function M.setup(_opts)
	refresh()
end

--- Functions exposed via `require("codecompanion").extensions["mcphub-neovim"]`
--- (`CodeCompanion.Extension.exports`).
M.exports = {
	--- Re-query `client.get_clients()` and re-publish tool/editor-context/prompt
	--- registrations for the current client roster. Safe to call at any
	--- time (e.g. from an `MCPAttach`/`MCPDetach` `User` autocmd handler) --
	--- idempotent and does not require the extension to be re-`setup()`.
	refresh = refresh,
}

return M
