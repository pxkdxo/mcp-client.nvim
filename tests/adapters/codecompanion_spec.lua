local client = require("mcphub-neovim.client")
local native = require("mcphub-neovim.native")

--- CodeCompanion adapter specs (U5). The real `codecompanion.nvim` plugin is
--- not a dependency of this repo (only locally installed on the author's
--- machine for reference, per the task brief) -- vendoring its ~13MB tree
--- purely to run these specs would be a heavyweight, out-of-scope test
--- infrastructure change the plan never asked for. Instead, this file fakes
--- the exact two modules the adapter genuinely `require()`s
--- (`codecompanion.mcp`, `codecompanion.config`) via `package.loaded`, built
--- to the *real, verified* shapes documented at the top of
--- `lua/mcphub-neovim/adapters/codecompanion.lua` (each cited against the
--- actual installed source at
--- `~/.local/share/nvim/lazy/codecompanion.nvim`):
---   - `codecompanion.mcp.register_tools(server_name, tools, group)` /
---     `.unregister_tools(server_name)` / `.get_registered_tools()` --
---     `mcp/init.lua:44-56`, a plain module-local registry with no
---     dependency on CodeCompanion's own MCP `Client` class.
---   - `codecompanion.config.interactions.chat.editor_context` -- a plain
---     table of `{ description, callback(self) }` entries, resolved
---     synchronously by `editor_context/user.lua:18-30`
---     (`self.config.callback(self)`, return value used immediately as
---     message content -- no async completion path exists in this
---     subsystem, confirmed by grepping both `editor_context/init.lua` and
---     `editor_context/user.lua`).
---   - `codecompanion.config.interactions.chat.slash_commands` (U12) -- a
---     plain, live module table of `{ description, callback(chat) }`
---     entries, read directly by `pairs()` on every completion/action-palette
---     resolution pass (`providers/completion/init.lua:98-101`,
---     `interactions/chat/action_palette.lua:95-99`, `keymaps.lua:6`) and
---     invoked via `SlashCommands:execute`
---     (`interactions/chat/slash_commands/init.lua:80-108`), which calls
---     `item.config.callback(chat)` directly when present (line 85-87) rather
---     than requiring a full `SlashCommand.new/execute/output` class -- the
---     exact same "plain table read live by pairs()" shape `editor_context`
---     already has, empirically verified against the real installed plugin
---     (mutating this table after `codecompanion.setup()` runs is picked up
---     by the real `completion.slash_commands()` and a real chat buffer's
---     `SlashCommands.run`, both exercised headlessly against
---     `~/.local/share/nvim/lazy/codecompanion.nvim` before writing this
---     adapter code).
--- This keeps the fake honest to the real API shape (each field asserted
--- against was independently confirmed against the installed source, not
--- invented for the test) while keeping the test suite self-contained.

local function fresh_codecompanion_mcp()
	local registry = {}
	return {
		register_tools = function(server_name, tools, group)
			registry[server_name] = { tools = tools, group = group }
		end,
		unregister_tools = function(server_name)
			registry[server_name] = nil
		end,
		get_registered_tools = function()
			local all_tools, all_groups = {}, {}
			for server_name, entry in pairs(registry) do
				for name, cfg in pairs(entry.tools) do
					all_tools[name] = cfg
				end
				if entry.group then
					all_groups[server_name] = entry.group
				end
			end
			return all_tools, all_groups
		end,
		_registry = registry,
	}
end

local function fresh_codecompanion_config()
	return {
		constants = {
			USER_ROLE = "user",
			SYSTEM_ROLE = "system",
			LLM_ROLE = "llm",
		},
		interactions = {
			chat = {
				editor_context = {},
				slash_commands = {
					-- Real config always carries this sub-key alongside per-command
					-- entries (config.lua:539-545); present here so the adapter's
					-- additions can never accidentally clobber it.
					opts = { acp = { enabled = true } },
				},
			},
		},
	}
end

describe("adapters.codecompanion (extension: tool + editor_context translation)", function()
	local fake_mcp
	local fake_config

	before_each(function()
		fake_mcp = fresh_codecompanion_mcp()
		fake_config = fresh_codecompanion_config()
		package.loaded["codecompanion.mcp"] = fake_mcp
		package.loaded["codecompanion.config"] = fake_config
		-- Force a clean reload of the adapter module itself so module-level
		-- caches (tools_cache/resources_cache) never leak between specs.
		package.loaded["mcphub-neovim.adapters.codecompanion"] = nil
	end)

	after_each(function()
		client._reset_registry()
		package.loaded["codecompanion.mcp"] = nil
		package.loaded["codecompanion.config"] = nil
		package.loaded["mcphub-neovim.adapters.codecompanion"] = nil
	end)

	it("has zero direct hub or transport knowledge (R6): does not require transport/* modules", function()
		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		local path = debug.getinfo(codecompanion_adapter.setup, "S").source:sub(2)
		local f = assert(io.open(path, "r"))
		local source = f:read("*a")
		f:close()
		assert.is_nil(source:match('require%(%s*"mcphub%-neovim%.transport'))
		assert.is_nil(source:match("plenary%.job"))
		assert.is_nil(source:match("[Jj]ob:pid"))
		assert.is_nil(source:match("vim%.uv%.kill"))
	end)

	it("is a real CodeCompanion extension: setup() is a function, exports.refresh is a function", function()
		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		assert.is_function(codecompanion_adapter.setup)
		assert.is_table(codecompanion_adapter.exports)
		assert.is_function(codecompanion_adapter.exports.refresh)
	end)

	it("happy path: a tool call resolves through the adapter to a native server", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local all_tools, all_groups = fake_mcp.get_registered_tools()

		local echo_name
		for name in pairs(all_tools) do
			if name:match("echo$") then
				echo_name = name
			end
		end
		assert.is_not_nil(echo_name, "expected an echo-derived tool to be registered")

		local tool_cfg = all_tools[echo_name]
		assert.is_function(tool_cfg.callback)
		local resolved = tool_cfg.callback()
		assert.are.equal(echo_name, resolved.name)
		assert.are.equal("function", resolved.schema.type)
		assert.are.equal(echo_name, resolved.schema["function"].name)
		assert.is_table(resolved.schema["function"].parameters)
		assert.is_function(resolved.cmds[1])

		-- A group entry is also published, same shape as the internal MCP
		-- bridge's own tool_bridge.setup_tools output (mcp/tool_bridge.lua:172-177).
		local found_group = false
		for _, group in pairs(all_groups) do
			for _, name in ipairs(group.tools) do
				if name == echo_name then
					found_group = true
				end
			end
		end
		assert.is_true(found_group)

		-- Exercise the tool the way CodeCompanion's real Runner:run_tool
		-- actually calls a resolved tool's cmds[1]
		-- (tools/runtime/runner.lua:100-108): fun(tools, args, opts),
		-- completion reported via opts.output_cb.
		local got_output
		resolved.cmds[1]({}, { text = "hello" }, {
			output_cb = function(output)
				got_output = output
			end,
		})

		assert.is_not_nil(got_output)
		assert.are.equal("success", got_output.status)
		assert.matches("hello", got_output.data)
	end)

	it("happy path: a tool call resolves through the adapter to a remote hub connection", function()
		local stopped = false
		local obj = { name = "remote-hub" }
		function obj:is_stopped()
			return stopped
		end
		function obj:request(rpc_message, callback)
			if stopped then
				return callback("client is disconnected", nil, nil)
			end
			vim.schedule(function()
				if rpc_message.method == "tools/list" then
					return callback(nil, {
						tools = {
							{
								name = "remote_echo",
								description = "Echo via a remote hub",
								inputSchema = { type = "object", properties = { text = { type = "string" } } },
							},
						},
					}, nil)
				elseif rpc_message.method == "tools/call" then
					return callback(nil, {
						content = { { type = "text", text = rpc_message.params.arguments.text } },
					}, nil)
				end
				return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
			end)
		end
		function obj:notify(_rpc_message) end
		function obj:disconnect()
			stopped = true
		end
		client.register_native(obj)

		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")

		-- setup() kicks off the initial tools/list refresh, but the remote
		-- double's reply is deferred via vim.schedule -- exactly like a
		-- real remote transport's async curl callback -- so nothing is
		-- registered yet synchronously after setup() returns.
		codecompanion_adapter.setup({})
		local all_tools = fake_mcp.get_registered_tools()
		local found
		for name in pairs(all_tools) do
			if name:match("remote_echo$") then
				found = name
			end
		end
		assert.is_nil(found, "remote client's tools must not appear synchronously")

		-- refresh() (exports.refresh) re-queries and re-registers; call it
		-- again once the deferred tools/list reply has landed.
		vim.wait(200, function()
			codecompanion_adapter.exports.refresh()
			local tools = fake_mcp.get_registered_tools()
			for name in pairs(tools) do
				if name:match("remote_echo$") then
					found = name
				end
			end
			return found ~= nil
		end)

		assert.is_not_nil(found)
		local tool_cfg = fake_mcp.get_registered_tools()[found]
		local resolved = tool_cfg.callback()

		local completed = false
		local got_output
		resolved.cmds[1]({}, { text = "remote-hello" }, {
			output_cb = function(output)
				completed = true
				got_output = output
			end,
		})
		-- Must not have completed synchronously: the remote double's
		-- callback is deferred via vim.schedule.
		assert.is_false(completed)

		vim.wait(200, function()
			return completed
		end)

		assert.is_true(completed)
		assert.are.equal("success", got_output.status)
		assert.matches("remote%-hello", got_output.data)
	end)

	it("edge case: resource bridging via editor_context works for a native client (synchronous)", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local editor_context = fake_config.interactions.chat.editor_context
		local entry_key
		for key in pairs(editor_context) do
			if key:match("example%-native$") then
				entry_key = key
			end
		end
		assert.is_not_nil(entry_key, "expected an editor_context entry for the native client")

		local entry = editor_context[entry_key]
		assert.is_function(entry.callback)

		-- editor_context/user.lua:18-30 calls this synchronously and uses
		-- the return value immediately as chat message content -- no
		-- callback/opts argument, no async completion path. A native
		-- client's request() fires synchronously (U3), so this resolves to
		-- real, current resource content on the very first call.
		local content = entry.callback({})
		assert.is_string(content)
		assert.matches("example://greeting", content)
		assert.matches("hello from example%-native", content)
	end)

	it(
		"edge case: resource bridging via editor_context against a remote client documents CodeCompanion's real gap "
			.. "(no async completion path) rather than silently working around it",
		function()
			local stopped = false
			local obj = { name = "remote-resources" }
			function obj:is_stopped()
				return stopped
			end
			function obj:request(rpc_message, callback)
				if stopped then
					return callback("client is disconnected", nil, nil)
				end
				vim.schedule(function()
					if rpc_message.method == "resources/list" then
						return callback(nil, { resources = { { uri = "remote://thing" } } }, nil)
					elseif rpc_message.method == "resources/read" then
						return callback(nil, { content = { { type = "text", text = "remote content" } } }, nil)
					end
					return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
				end)
			end
			function obj:notify(_rpc_message) end
			function obj:disconnect()
				stopped = true
			end
			client.register_native(obj)

			local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
			codecompanion_adapter.setup({})

			local editor_context = fake_config.interactions.chat.editor_context
			local entry_key
			for key in pairs(editor_context) do
				if key:match("remote%-resources$") then
					entry_key = key
				end
			end
			assert.is_not_nil(entry_key)
			local entry = editor_context[entry_key]

			-- CodeCompanion's editor_context.callback contract is
			-- synchronous-only (verified: editor_context/user.lua has no
			-- deferred/async completion path at all). The remote client's
			-- resources/list reply has not landed yet (setup() just ran;
			-- vim.schedule has not fired), so this MUST resolve to the "no
			-- resources currently available" placeholder -- not an error,
			-- not a hang (R11), and not some invented parallel async
			-- mechanism -- exactly the documented, honest degradation this
			-- adapter is required to expose rather than hide.
			local content = entry.callback({})
			assert.is_string(content)
			assert.matches("No resources currently available", content)

			-- Once the deferred resources/list reply lands and a refresh
			-- is triggered, the same synchronous callback contract now
			-- serves cached-but-real content -- still synchronous, still
			-- no async completion path, just backed by a cache a
			-- background refresh populated.
			vim.wait(200, function()
				codecompanion_adapter.exports.refresh()
				local refreshed = fake_config.interactions.chat.editor_context[entry_key].callback({})
				return refreshed:match("remote://thing") ~= nil
			end)

			local refreshed_content = fake_config.interactions.chat.editor_context[entry_key].callback({})
			assert.matches("remote://thing", refreshed_content)
		end
	)

	it("edge case: zero connected clients means no tools or editor_context entries, not an error", function()
		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		assert.has_no.errors(function()
			codecompanion_adapter.setup({})
		end)
		local all_tools = fake_mcp.get_registered_tools()
		assert.are.equal(0, vim.tbl_count(all_tools))
	end)

	it("integration: a client transitioning to disconnected is reflected on next refresh, not stale", function()
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local found_before = false
		for name in pairs(fake_mcp.get_registered_tools()) do
			if name:match("echo$") then
				found_before = true
			end
		end
		assert.is_true(found_before)

		-- Disconnect the native server -- is_stopped() now true, exactly
		-- the state a real client transitions to on MCPDetach.
		server:disconnect()
		assert.is_true(server:is_stopped())

		-- The adapter must re-query get_clients() on the next refresh
		-- rather than reuse a snapshot captured when setup() first ran: a
		-- disconnected client contributes no tools.
		codecompanion_adapter.exports.refresh()
		local found_after = false
		for name in pairs(fake_mcp.get_registered_tools()) do
			if name:match("echo$") then
				found_after = true
			end
		end
		assert.is_false(found_after)
	end)

	it("integration: a client fully removed from the registry has its editor_context entry pruned", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local editor_context = fake_config.interactions.chat.editor_context
		local entry_key
		for key in pairs(editor_context) do
			if key:match("example%-native$") then
				entry_key = key
			end
		end
		assert.is_not_nil(entry_key, "expected an editor_context entry for the native client before removal")

		-- Fully remove the client from the registry (not merely
		-- disconnect it) -- the same thing client._reset_registry() does
		-- between specs, and the strictest version of "a client can
		-- disappear" this adapter must handle: unlike is_stopped(), there
		-- is no live object left at all to keep a stale closure over.
		client._reset_registry()

		codecompanion_adapter.exports.refresh()
		assert.is_nil(
			fake_config.interactions.chat.editor_context[entry_key],
			"a fully-removed client's editor_context entry must be pruned, not left as a dangling closure"
		)
	end)

	it("resilience: a throwing client's request() does not break refresh() for other clients", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local obj = { name = "throws-on-request" }
		function obj:is_stopped()
			return false
		end
		function obj:request(_rpc_message, _callback)
			error("synchronous throw from request(): throws-on-request")
		end
		function obj:notify(_rpc_message) end
		function obj:disconnect() end
		client.register_native(obj)

		local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
		assert.has_no.errors(function()
			codecompanion_adapter.setup({})
		end)

		local found_echo = false
		for name, cfg in pairs(fake_mcp.get_registered_tools()) do
			assert.is_falsy(name:match("^" .. "mcp_throws%-on%-request"))
			if name:match("echo$") and cfg.callback then
				found_echo = true
			end
		end
		assert.is_true(found_echo)
	end)

	describe("prompt/slash-command bridging (U12)", function()
		--- A minimal chat double: just enough of `CodeCompanion.Chat` for a
		--- slash command's `callback(chat)` to add a real message via
		--- `chat:add_message({role, content}, opts)` -- the real
		--- content-bearing call `fetch.lua`/`file.lua`/`symbols.lua`/`help.lua`
		--- all use (verified: `add_buf_message` explicitly does NOT enter the
		--- LLM message stack, per its own doc comment in
		--- `interactions/chat/init.lua:1811-1812`, so a prompt's whole point --
		--- seeding real conversational context -- requires `add_message`, not
		--- `add_buf_message`).
		local function fake_chat()
			local messages = {}
			return {
				messages = messages,
				add_message = function(_self, data, opts)
					table.insert(messages, { data = data, opts = opts })
				end,
			}
		end

		it(
			"happy path: an MCP prompt on a native server is invocable as a slash command matching prompts/get",
			function()
				local example = require("tests.fixtures.example_native_server")
				native.register(example)

				local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
				codecompanion_adapter.setup({})

				local slash_commands = fake_config.interactions.chat.slash_commands
				local entry_key
				for key in pairs(slash_commands) do
					if key:match("greet$") and key:match("example%-native") then
						entry_key = key
					end
				end
				assert.is_not_nil(entry_key, "expected a slash command entry for the example-native `greet` prompt")

				local entry = slash_commands[entry_key]
				assert.is_string(entry.description)
				assert.is_function(entry.callback)

				-- The declared prompt argument (`prompt_meta.greet.arguments = {
				-- {name="who", required=false}}`) is collected via vim.ui.input;
				-- stub it to answer deterministically instead of driving real UI.
				local original_input = vim.ui.input
				vim.ui.input = function(_opts, on_confirm)
					on_confirm("Ada")
				end

				local chat = fake_chat()
				entry.callback(chat)

				vim.ui.input = original_input

				assert.are.equal(1, #chat.messages)
				local msg = chat.messages[1]
				assert.are.equal("user", msg.data.role)
				-- Matches prompts/get's actual result for prompts.greet({who="Ada"}):
				-- { messages = { { role = "user", content = { type = "text", text =
				-- "Hello, Ada!" } } } } -- the rendered content must be exactly that
				-- plain text, not a JSON-encoded blob that merely contains this
				-- substring (render_result's list-shaped fallback would produce
				-- '{"text":"Hello, Ada!","type":"text"}', which `assert.matches`
				-- would wrongly accept -- assert exact equality instead).
				assert.are.equal("Hello, Ada!", msg.data.content)
			end
		)

		it(
			"happy path: an MCP prompt exposed by a remote (enveloped) client is invocable as a slash command",
			function()
				local stopped = false
				local obj = { name = "remote-prompts" }
				function obj:is_stopped()
					return stopped
				end
				function obj:request(rpc_message, callback)
					if stopped then
						return callback("client is disconnected", nil, nil)
					end
					vim.schedule(function()
						if rpc_message.method == "prompts/list" then
							return callback(nil, {
								result = {
									prompts = {
										{
											name = "summarize",
											description = "Summarize the given text",
											arguments = {
												{ name = "text", description = "Text to summarize", required = true },
											},
										},
									},
								},
							}, nil)
						elseif rpc_message.method == "prompts/get" then
							return callback(nil, {
								result = {
									messages = {
										{
											role = "user",
											content = {
												type = "text",
												text = "Summary of: " .. rpc_message.params.arguments.text,
											},
										},
									},
								},
							}, nil)
						end
						return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
					end)
				end
				function obj:notify(_rpc_message) end
				function obj:disconnect()
					stopped = true
				end
				client.register_native(obj)

				local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
				codecompanion_adapter.setup({})

				-- Remote double replies via vim.schedule, exactly like a real async
				-- transport -- refresh() must be called again once it lands.
				local entry_key
				vim.wait(200, function()
					codecompanion_adapter.exports.refresh()
					local slash_commands = fake_config.interactions.chat.slash_commands
					for key in pairs(slash_commands) do
						if key:match("summarize$") and key:match("remote%-prompts") then
							entry_key = key
						end
					end
					return entry_key ~= nil
				end)
				assert.is_not_nil(
					entry_key,
					"expected a slash command entry for the remote client's `summarize` prompt"
				)

				local entry = fake_config.interactions.chat.slash_commands[entry_key]

				local original_input = vim.ui.input
				vim.ui.input = function(_opts, on_confirm)
					on_confirm("remote payload")
				end

				local chat = fake_chat()
				entry.callback(chat)

				vim.ui.input = original_input

				-- The prompts/get round trip is itself async (remote client), so the
				-- message lands only after the scheduled callback fires.
				vim.wait(200, function()
					return #chat.messages > 0
				end)

				assert.are.equal(1, #chat.messages)
				-- Exact equality, not a substring match: a JSON-encoded blob would
				-- still contain this substring and wrongly pass `assert.matches`.
				assert.are.equal("Summary of: remote payload", chat.messages[1].data.content)
			end
		)

		it("edge case: zero connected clients means no slash-command entries, not an error", function()
			local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
			assert.has_no.errors(function()
				codecompanion_adapter.setup({})
			end)

			local slash_commands = fake_config.interactions.chat.slash_commands
			local count = 0
			for key in pairs(slash_commands) do
				if key ~= "opts" then
					count = count + 1
				end
			end
			assert.are.equal(0, count)
		end)

		it(
			"integration: a client transitioning to disconnected has its prompt slash commands pruned on next refresh",
			function()
				local example = require("tests.fixtures.example_native_server")
				local server = native.register(example)

				local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
				codecompanion_adapter.setup({})

				local slash_commands = fake_config.interactions.chat.slash_commands
				local found_before = false
				for key in pairs(slash_commands) do
					if key:match("greet$") and key:match("example%-native") then
						found_before = true
					end
				end
				assert.is_true(found_before)

				server:disconnect()
				assert.is_true(server:is_stopped())

				codecompanion_adapter.exports.refresh()

				local found_after = false
				for key in pairs(fake_config.interactions.chat.slash_commands) do
					if key:match("greet$") and key:match("example%-native") then
						found_after = true
					end
				end
				assert.is_false(found_after, "a disconnected client's prompt slash commands must not remain registered")
			end
		)

		it("integration: a client fully removed from the registry has its prompt slash commands pruned", function()
			local example = require("tests.fixtures.example_native_server")
			native.register(example)

			local codecompanion_adapter = require("mcphub-neovim.adapters.codecompanion")
			codecompanion_adapter.setup({})

			local entry_key
			for key in pairs(fake_config.interactions.chat.slash_commands) do
				if key:match("greet$") and key:match("example%-native") then
					entry_key = key
				end
			end
			assert.is_not_nil(entry_key)

			client._reset_registry()
			codecompanion_adapter.exports.refresh()

			assert.is_nil(
				fake_config.interactions.chat.slash_commands[entry_key],
				"a fully-removed client's prompt slash command must be pruned, not left as a dangling closure"
			)
		end)
	end)
end)
