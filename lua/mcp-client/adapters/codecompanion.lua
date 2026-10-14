--- CodeCompanion adapter: translates this plugin's client/tool surface --
--- `require("mcp-client.client").get_clients(filter)` plus each client
--- object's `request(rpc_message, callback)` -- into CodeCompanion's
--- extension, tool, and editor-context integration points, replacing
--- `mcphub.extensions.codecompanion`.
---
--- This is a thin adapter: it holds no direct server or transport logic of
--- its own. Every tool call and resource read it exposes to CodeCompanion is,
--- underneath, a standard MCP `tools/list` / `tools/call` / `resources/list`
--- / `resources/read` JSON-RPC message routed through a client object's
--- `request()`. The adapter never imports `mcp-client.transport.*`, never
--- touches a `Job` object, and never assumes a client is remote or native --
--- `get_clients()` deliberately makes the two indistinguishable, and this
--- file relies on that uniformity.
---
--- ## Extension registration
---
--- Registered either via `require("codecompanion").register_extension(...)`
--- or via `setup({ extensions = { ["mcp-client"] = { callback = ... } } })`.
--- Either way, `M.setup(opts)` below is what gets called.
---
--- ## Tool registration
---
--- Tools are published through CodeCompanion's internal MCP tool registry
--- (`codecompanion.mcp.register_tools` / `unregister_tools`), the same
--- registry CodeCompanion's own built-in MCP client uses. This adapter is a
--- second, independent producer of that registry for clients that this
--- plugin -- not CodeCompanion's own MCP subsystem -- connects and manages.
---
--- ## Resource/variable bridging
---
--- Resources are bridged through `config.interactions.shared.editor_context`
--- as `#{mcp_<client name>}`. That callback must return synchronously --
--- CodeCompanion's `editor_context` API has no deferred/async completion
--- path -- so it always returns whatever is currently cached for that
--- client. For a native client (whose `request()` callback fires
--- synchronously) this is always current; for a remote client (always
--- asynchronous) it may be stale or empty until a background
--- `resources/list`/`resources/read` round trip lands. That's an inherent
--- limitation of CodeCompanion's `editor_context` contract, not something
--- this adapter can route around.
---
--- ## Prompt/slash-command bridging
---
--- MCP prompts are bridged as entries in
--- `config.interactions.chat.slash_commands`, using the plain
--- `{ description, callback(chat) }` shape (not the `SlashCommand` class,
--- which only matters for slash commands needing a custom completion-menu
--- picker). `SlashCommands:execute` calls `item.config.callback(chat)`
--- directly for this shape.
---
--- Argument collection uses `vim.ui.input` once per declared
--- `PromptArgument` (name/description/required) to build the flat
--- `arguments` table `prompts/get` expects. Collection is
--- continuation-passing rather than a loop that reads a variable after
--- `vim.ui.input()` returns, because async `vim.ui.input` providers (e.g.
--- snacks.nvim, dressing.nvim, noice.nvim) defer `on_confirm` to a later
--- event-loop tick instead of calling it before returning.
---
--- Prompt messages are added via `Chat:add_message` (not `add_buf_message`,
--- which explicitly does not enter the LLM-visible message stack) since a
--- prompt's purpose is to seed real conversational context.

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

--- Namespace CodeCompanion tool/editor-context entries with this prefix so
--- multiple clients' entries can never collide with each other or with a
--- builtin/other-extension entry under the same generic registries this
--- adapter shares.
local NAME_PREFIX = "mcp_"

--- Cache of each client's most recently known tool/resource/prompt listing,
--- keyed by client id. CodeCompanion's integration points here
--- (`Tools.resolve`'s `callback()`, `editor_context`'s `callback(self)`) are
--- themselves synchronous and cannot block on a remote client's async
--- round-trip, so each call returns whatever is currently cached and
--- opportunistically kicks off a fresh listing request. `is_stopped()` is
--- re-checked against the live registry independently of this cache on
--- every access (see `M.exports.refresh`/`build_group_entries` below), so a
--- disconnected client's stale cache entry is never served past that check.
local tools_cache = {}
local resources_cache = {}
local prompts_cache = {}
local refresh
local publish_scheduled = false
-- Discovery completes asynchronously; publish cached results without starting
-- another discovery cycle. Coalesce the three list responses into one turn.
local function publish_discovered()
	if publish_scheduled then return end
	publish_scheduled = true
	local config = package.loaded["codecompanion.config"]
	vim.schedule(function()
		publish_scheduled = false
		if not config or package.loaded["codecompanion.config"] ~= config then return end
		refresh(true)
	end)
end

--- Normalize a client `request()` result to the bare MCP payload, regardless
--- of which kind of client produced it. Native clients deliver the handler's
--- return value directly (e.g. `{ tools = {...} }`); remote clients deliver
--- the full JSON-RPC envelope (`{ jsonrpc, id, result = { tools = {...} } }`).
--- A nested `result` table alone is not a reliable envelope signal: a native
--- tool is an arbitrary, MCP-unaware Lua function, and its own payload can
--- legitimately use `result` as an ordinary field name (e.g. a calc/lookup
--- tool returning `{ result = { value = 42 } }`) -- unwrapping that would
--- silently corrupt the tool's own data. Require the two fields that only a
--- genuine JSON-RPC response carries (`jsonrpc`, `id`) alongside the nested
--- `result` table before unwrapping.
local function unwrap_result(result)
	if type(result) == "table" and type(result.result) == "table" and result.jsonrpc == "2.0" and result.id ~= nil then
		return result.result
	end
	return result
end

--- Ask one client for its current tool listing via the standard MCP
--- `tools/list` method. A failure (thrown or callback-reported) simply
--- leaves the previous cache entry in place rather than raising, so one
--- misbehaving client can never take down the whole tool/resource listing.
local function refresh_client_tools(mcp_client)
	pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = new_request_id(),
			method = "tools/list",
			-- vim.empty_dict(), not {}: an empty Lua table serializes to a JSON
			-- array `[]`, which a strict real server rejects (HTTP 400) -- MCP
			-- requires `params` to be an object.
			params = vim.empty_dict(),
		}, function(err, result, _response)
			local payload = unwrap_result(result)
			if err or type(payload) ~= "table" or type(payload.tools) ~= "table" then
				return
			end
			tools_cache[mcp_client.id] = payload.tools
			publish_discovered()
		end)
	end)
end

--- Ask one client for its current prompt listing via the standard MCP
--- `prompts/list` method. Same shape as `refresh_client_tools` above.
local function refresh_client_prompts(mcp_client)
	pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = new_request_id(),
			method = "prompts/list",
			params = vim.empty_dict(),
		}, function(err, result, _response)
			local payload = unwrap_result(result)
			if err or type(payload) ~= "table" or type(payload.prompts) ~= "table" then
				return
			end
			prompts_cache[mcp_client.id] = payload.prompts
			publish_discovered()
		end)
	end)
end

--- Ask one client for its current resource listing via the standard MCP
--- `resources/list` method. Same shape as `refresh_client_tools` above.
local function refresh_client_resources(mcp_client)
	pcall(function()
		mcp_client:request({
			jsonrpc = "2.0",
			id = new_request_id(),
			method = "resources/list",
			params = vim.empty_dict(),
		}, function(err, result, _response)
			local payload = unwrap_result(result)
			if err or type(payload) ~= "table" or type(payload.resources) ~= "table" then
				return
			end
			resources_cache[mcp_client.id] = payload.resources
			publish_discovered()
		end)
	end)
end

--- MCP's `inputSchema` is already standard JSON Schema, and CodeCompanion's
--- tool `schema.function.parameters` expects exactly that shape untouched,
--- so no field-by-field translation is needed. A tool with no declared
--- schema still gets a minimal, valid empty-object schema so it remains
--- callable (just without argument documentation for the LLM).
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

--- Build one CodeCompanion tool config entry (a `CodeCompanion.Tools.Tool`)
--- for a single MCP tool exposed by `mcp_client`.
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
			--- Always resolves via `opts.output_cb` and returns nothing,
			--- which is correct whether `mcp_client:request()`'s callback
			--- fires synchronously (native) or asynchronously (remote).
			function(_tools, args, opts)
				local output_cb = opts and opts.output_cb

				local ok, call_err = pcall(function()
					mcp_client:request({
						jsonrpc = "2.0",
						id = new_request_id(),
						method = "tools/call",
						-- arguments defaults to vim.empty_dict() (not {}) so a
						-- zero-argument tool call serializes `arguments` as a JSON
						-- object `{}`, not an array `[]` a strict server would reject.
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
			-- style tool picker; grouped under the client's own group entry.
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
--- synchronous `callback(self)`) that bridges one client's MCP resources
--- into CodeCompanion chat as `#{mcp_<client name>}`.
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
						id = new_request_id(),
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

--- Build one slash-command config entry (`{ description, callback(chat) }`)
--- for a single MCP prompt exposed by `mcp_client`, keyed by the same
--- `NAME_PREFIX .. client name .. "_" .. prompt name` convention
--- `build_tool_spec` uses.
---
--- Each `message.content` is, per MCP's `PromptMessage` shape, a single
--- content object (e.g. `{ type = "text", text = "..." }`), not the
--- `{ content = [...] }`-wrapped list shape `CallToolResult`/
--- `ReadResourceResult` use. It's wrapped into that one-element list shape
--- (`{ content = { message.content } }`) before calling `render_result`, so
--- the existing single-text-item and `vim.inspect` fallback branches handle
--- it correctly instead of falling through to the raw-JSON-encode branch.
local function build_prompt_slash_command_entry(mcp_client, prompt_info)
	local prefixed_name = NAME_PREFIX .. mcp_client.name .. "_" .. prompt_info.name

	return prefixed_name,
		{
			description = prompt_info.description or ("MCP prompt " .. prompt_info.name),
			--- Argument collection is continuation-passing rather than a
			--- loop that reads a variable after `vim.ui.input()` returns:
			--- async providers (e.g. snacks.nvim) defer `on_confirm` to a
			--- later event-loop tick instead of calling it before
			--- returning, so `collect(i)` only proceeds to the next
			--- argument (or issues the request once all are collected)
			--- from inside `vim.ui.input`'s own callback. This works
			--- under both a synchronous provider (recursion happens
			--- immediately) and an async one (recursion happens whenever
			--- the user submits that argument's prompt).
			callback = function(chat)
				local arguments = {}
				local declared = prompt_info.arguments or {}

				local function issue_request()
					pcall(function()
						mcp_client:request({
							jsonrpc = "2.0",
							id = new_request_id(),
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
--- currently-cached prompt exposed by `mcp_client`, ready to be merged
--- straight into `config.interactions.chat.slash_commands`.
local function build_prompt_slash_commands(mcp_client)
	local entries = {}
	for _, prompt_info in ipairs(prompts_cache[mcp_client.id] or {}) do
		local name, entry = build_prompt_slash_command_entry(mcp_client, prompt_info)
		entries[name] = entry
	end
	return entries
end

--- Track which client ids currently have a registered `editor_context`
--- entry, so a client that disappears from `get_clients()` entirely (fully
--- torn down, e.g. via `client._reset_registry()` in tests) has its entry
--- pruned rather than left behind as a dangling closure over a client
--- object that no longer exists in the registry. A merely-`is_stopped()`
--- client (still present in `get_clients()`, just disconnected) keeps its
--- entry -- pruning here is about registry membership, not connection
--- state.
local registered_editor_context_ids = {}

--- Track which slash-command names are currently registered per client id:
--- a client can expose any number of prompts, each becoming its own
--- slash-command entry, so pruning needs the full set of names registered
--- for that client, not just one.
local registered_prompt_slash_command_names = {}

--- Re-query the live client registry and (re-)publish each connected
--- client's tools into `codecompanion.mcp`'s tool registry, refresh each
--- client's `editor_context` entry, and opportunistically refresh each
--- client's cached tool/resource/prompt listing.
---
--- `is_stopped()` is checked against the live registry on every call: a
--- stopped client's tools are unregistered immediately (not left to linger
--- until some cache expires), and its cache entries are dropped so a later
--- reconnect under the same id starts from a clean slate. A client no
--- longer present in `get_clients()` at all has its `editor_context` entry
--- pruned too.
---
--- Exposed as `exports.refresh` so a consumer can call it explicitly (e.g.
--- on `MCPAttach`/`MCPDetach`), and also called once from `M.setup` so a
--- chat buffer opened after `setup()` already sees whatever is
--- synchronously available (native clients) without requiring a manual
--- first refresh.
refresh = function(cached_only)
	local mcp = require("codecompanion.mcp")
	local config = require("codecompanion.config")
	-- interactions.shared.editor_context, NOT interactions.chat.editor_context:
	-- config.setup() migrates the latter into the former and nils the old key
	-- out entirely.
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
			if not cached_only then
				refresh_client_tools(mcp_client)
				refresh_client_resources(mcp_client)
				refresh_client_prompts(mcp_client)
			end
			local tool_configs, group = build_client_registration(mcp_client)
			if group then
				mcp.register_tools(mcp_client.id, tool_configs, group)
			else
				mcp.unregister_tools(mcp_client.id)
			end

			-- Re-publish this client's prompt slash commands from whatever is
			-- currently cached: drop the previous registration first so a
			-- prompt that disappeared between refreshes doesn't linger.
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

--- CodeCompanion extension entry point, called once when the extension is
--- loaded via `register_extension` or `setup({ extensions = {...} })`.
---
--- Delegates straight to `refresh()`, which registers one `editor_context`
--- entry per currently-known client, publishes tools, and registers one
--- slash-command entry per currently-cached MCP prompt, so a chat buffer
--- opened after `setup()` already sees whatever is synchronously available
--- (native clients) without requiring a manual first refresh. `opts` is
--- accepted per the extension contract but this adapter needs no
--- configuration of its own.
function M.setup(_opts)
	refresh()
end

--- Functions exposed via `require("codecompanion").extensions["mcp-client"]`.
M.exports = {
	--- Re-query `client.get_clients()` and re-publish tool/editor-context/prompt
	--- registrations for the current client roster. Safe to call at any
	--- time (e.g. from an `MCPAttach`/`MCPDetach` `User` autocmd handler) --
	--- idempotent and does not require the extension to be re-`setup()`.
	refresh = refresh,
}

return M
