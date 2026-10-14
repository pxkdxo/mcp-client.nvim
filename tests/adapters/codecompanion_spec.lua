local client = require("mcp-client.client")
local native = require("mcp-client.native")

--- The real `codecompanion.nvim` plugin is not a dependency of this repo, so
--- this file fakes the two modules the adapter requires
--- (`codecompanion.mcp`, `codecompanion.config`) via `package.loaded`,
--- matching the shapes documented at the top of
--- `lua/mcp-client/adapters/codecompanion.lua`:
---   - `codecompanion.mcp.register_tools(server_name, tools, group)` /
---     `.unregister_tools(server_name)` / `.get_registered_tools()` -- a
---     plain module-local registry.
---   - `codecompanion.config.interactions.shared.editor_context` -- a plain
---     table of `{ description, callback(self) }` entries, resolved
---     synchronously (`self.config.callback(self)`, return value used
---     immediately as message content -- no async completion path exists in
---     this subsystem). `interactions.chat.editor_context` is a dead path:
---     `config.setup()` migrates any caller-supplied value into
---     `interactions.shared.editor_context` and nils out the old key.
---   - `codecompanion.config.interactions.chat.slash_commands` -- a plain,
---     live module table of `{ description, callback(chat) }` entries, read
---     directly by `pairs()` on every completion/action-palette resolution
---     pass and invoked via `SlashCommands:execute`, which calls
---     `item.config.callback(chat)` directly when present.

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
				-- editor_context is deliberately absent here (not even `{}`):
				-- the real config nils it out after migrating to
				-- interactions.shared.editor_context, and a regression that
				-- writes back to this dead path must be caught.
				slash_commands = {
					-- Real config always carries this sub-key alongside per-command
					-- entries; present here so the adapter's additions can never
					-- accidentally clobber it.
					opts = { acp = { enabled = true } },
				},
			},
			shared = {
				-- Real config always carries this sub-key alongside per-context
				-- entries; present here so the adapter's additions can never
				-- accidentally clobber it.
				editor_context = {
					opts = {
						excluded = { buftypes = {}, fts = {} },
					},
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
		package.loaded["mcp-client.adapters.codecompanion"] = nil
	end)

	after_each(function()
		client._reset_registry()
		package.loaded["codecompanion.mcp"] = nil
		package.loaded["codecompanion.config"] = nil
		package.loaded["mcp-client.adapters.codecompanion"] = nil
	end)

	it("has zero direct server or transport knowledge: does not require transport/* modules", function()
		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		local path = debug.getinfo(codecompanion_adapter.setup, "S").source:sub(2)
		local f = assert(io.open(path, "r"))
		local source = f:read("*a")
		f:close()
		assert.is_nil(source:match('require%(%s*"mcp%-client%.transport'))
		assert.is_nil(source:match("plenary%.job"))
		assert.is_nil(source:match("[Jj]ob:pid"))
		assert.is_nil(source:match("vim%.uv%.kill"))
	end)

	it("is a real CodeCompanion extension: setup() is a function, exports.refresh is a function", function()
		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		assert.is_function(codecompanion_adapter.setup)
		assert.is_table(codecompanion_adapter.exports)
		assert.is_function(codecompanion_adapter.exports.refresh)
	end)

	it("happy path: a tool call resolves through the adapter to a native server", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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
		-- bridge's own tool_bridge.setup_tools output.
		local found_group = false
		for _, group in pairs(all_groups) do
			for _, name in ipairs(group.tools) do
				if name == echo_name then
					found_group = true
				end
			end
		end
		assert.is_true(found_group)

		-- Exercise the tool the way CodeCompanion's real Runner:run_tool calls
		-- a resolved tool's cmds[1]: fun(tools, args, opts), completion
		-- reported via opts.output_cb.
		local got_output
		resolved.cmds[1]({}, { text = "hello" }, {
			output_cb = function(output)
				got_output = output
			end,
		})

		assert.is_not_nil(got_output)
		assert.are.equal("success", got_output.status)
		-- render_result() has no .content key to match here, so it falls
		-- through to vim.json.encode(result); assert exact equality rather
		-- than a substring match.
		assert.are.equal('{"text":"hello"}', got_output.data)
	end)

	it("regression: unwrap_result must not strip a native tool's own {result=...} payload", function()
		native.register({
			name = "result-shaped-native",
			tools = {
				lookup = function()
					return { result = { value = 42, unit = "kg" } }
				end,
			},
		})

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local all_tools = fake_mcp.get_registered_tools()

		local lookup_name
		for name in pairs(all_tools) do
			if name:match("lookup$") then
				lookup_name = name
			end
		end
		assert.is_not_nil(lookup_name, "expected a lookup-derived tool to be registered")

		local resolved = all_tools[lookup_name].callback()

		local got_output
		resolved.cmds[1]({}, {}, {
			output_cb = function(output)
				got_output = output
			end,
		})

		assert.is_not_nil(got_output)
		assert.are.equal("success", got_output.status)
		-- The native tool's own `result` key must survive intact: it is
		-- application data, not a JSON-RPC envelope for unwrap_result to
		-- strip -- only a genuine remote envelope also carries jsonrpc/id.
		local decoded = vim.json.decode(got_output.data)
		assert.is_table(decoded.result)
		assert.are.equal(42, decoded.result.value)
		assert.are.equal("kg", decoded.result.unit)
	end)

	it("happy path: a tool call resolves through the adapter to a remote server connection", function()
		local stopped = false
		local obj = { name = "remote-server" }
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
								description = "Echo via a remote server",
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

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")

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

		-- Completed asynchronous discovery publishes tools without callers
		-- polling refresh() or issuing another tools/list request.
		vim.wait(200, function()
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
		-- render_result()'s single-text-content-item branch returns the bare
		-- string directly, not JSON-encoded.
		assert.are.equal("remote-hello", got_output.data)
	end)

	it("edge case: resource bridging via editor_context works for a native client (synchronous)", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local editor_context = fake_config.interactions.shared.editor_context
		local entry_key
		for key in pairs(editor_context) do
			if key ~= "opts" and key:match("example%-native$") then
				entry_key = key
			end
		end
		assert.is_not_nil(entry_key, "expected an editor_context entry for the native client")

		local entry = editor_context[entry_key]
		assert.is_function(entry.callback)

		-- editor_context's callback is called synchronously and its return
		-- value used immediately as message content. A native client's
		-- request() also fires synchronously, so this resolves to real,
		-- current resource content on the very first call.
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

			local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
			codecompanion_adapter.setup({})

			local editor_context = fake_config.interactions.shared.editor_context
			local entry_key
			for key in pairs(editor_context) do
				if key ~= "opts" and key:match("remote%-resources$") then
					entry_key = key
				end
			end
			assert.is_not_nil(entry_key)
			local entry = editor_context[entry_key]

			-- editor_context's callback contract is synchronous-only. The
			-- remote client's resources/list reply has not landed yet, so
			-- this must resolve to the "no resources currently available"
			-- placeholder rather than error or hang.
			local content = entry.callback({})
			assert.is_string(content)
			assert.matches("No resources currently available", content)

			-- Once the deferred resources/list reply lands and a refresh is
			-- triggered, the same synchronous callback now serves
			-- cached-but-real content.
			vim.wait(200, function()
				codecompanion_adapter.exports.refresh()
				local refreshed = fake_config.interactions.shared.editor_context[entry_key].callback({})
				return refreshed:match("remote://thing") ~= nil
			end)

			local refreshed_content = fake_config.interactions.shared.editor_context[entry_key].callback({})
			assert.matches("remote://thing", refreshed_content)
		end
	)

	it("edge case: zero connected clients means no tools or editor_context entries, not an error", function()
		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		assert.has_no.errors(function()
			codecompanion_adapter.setup({})
		end)
		local all_tools = fake_mcp.get_registered_tools()
		assert.are.equal(0, vim.tbl_count(all_tools))

		local editor_context_count = 0
		for key in pairs(fake_config.interactions.shared.editor_context) do
			if key ~= "opts" then
				editor_context_count = editor_context_count + 1
			end
		end
		assert.are.equal(0, editor_context_count)
	end)

	it("integration: a client transitioning to disconnected is reflected on next refresh, not stale", function()
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local editor_context = fake_config.interactions.shared.editor_context
		local entry_key
		for key in pairs(editor_context) do
			if key ~= "opts" and key:match("example%-native$") then
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
			fake_config.interactions.shared.editor_context[entry_key],
			"a fully-removed client's editor_context entry must be pruned, not left as a dangling closure"
		)
	end)

	it(
		"regression: editor_context entries land under interactions.shared.editor_context, "
			.. "never resurrecting the dead interactions.chat.editor_context path",
		function()
			local example = require("tests.fixtures.example_native_server")
			native.register(example)

			local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
			codecompanion_adapter.setup({})

			-- The real, live path must receive the entry.
			local entry_key
			for key in pairs(fake_config.interactions.shared.editor_context) do
				if key ~= "opts" and key:match("example%-native$") then
					entry_key = key
				end
			end
			assert.is_not_nil(
				entry_key,
				"expected the entry under the real, live interactions.shared.editor_context path"
			)

			-- The old path must stay exactly as the real config leaves it
			-- after setup() (nil/absent): the adapter must never
			-- (re-)create interactions.chat.editor_context.
			assert.is_nil(
				fake_config.interactions.chat.editor_context,
				"the adapter must never write to the dead interactions.chat.editor_context path"
			)
		end
	)

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

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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

	it("regression: two concurrent tools/call requests never share a JSON-RPC id", function()
		local call_ids = {}
		local stopped = false
		local obj = { name = "id-check" }
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
						tools = { { name = "echo_tool", description = "d", inputSchema = { type = "object" } } },
					}, nil)
				elseif rpc_message.method == "tools/call" then
					-- Never replies -- this test only cares what id each
					-- concurrent call was issued with, not any response.
					table.insert(call_ids, rpc_message.id)
					return
				end
				return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
			end)
		end
		function obj:notify(_rpc_message) end
		function obj:disconnect()
			stopped = true
		end
		client.register_native(obj)

		local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
		codecompanion_adapter.setup({})

		local found
		vim.wait(200, function()
			codecompanion_adapter.exports.refresh()
			for name in pairs(fake_mcp.get_registered_tools()) do
				if name:match("echo_tool$") then
					found = name
				end
			end
			return found ~= nil
		end)
		assert.is_not_nil(found)

		local resolved = fake_mcp.get_registered_tools()[found].callback()

		-- Fire two overlapping calls before either can resolve.
		resolved.cmds[1]({}, {}, {})
		resolved.cmds[1]({}, {}, {})

		vim.wait(200, function()
			return #call_ids == 2
		end)

		assert.are.equal(2, #call_ids)
		assert.are_not.equal(call_ids[1], call_ids[2])
	end)

	describe("prompt/slash-command bridging", function()
		--- A minimal chat double: just enough of `CodeCompanion.Chat` for a
		--- slash command's `callback(chat)` to add a real message via
		--- `chat:add_message({role, content}, opts)`. `add_buf_message` does
		--- not enter the LLM message stack, so seeding real conversational
		--- context requires `add_message`.
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

				local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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

				-- The declared prompt argument is collected via vim.ui.input;
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
				-- The rendered content must be exactly this plain text, not a
				-- JSON-encoded blob that merely contains it as a substring.
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
							-- Envelope-shaped reply, like a real remote server:
							-- jsonrpc/id are what unwrap_result keys on.
							return callback(nil, {
								jsonrpc = "2.0",
								id = 1,
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
								jsonrpc = "2.0",
								id = 1,
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

				local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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

		--- `vim.ui.input`'s `on_confirm` callback is not guaranteed to run
		--- synchronously before `vim.ui.input()` returns (e.g. snacks.nvim's
		--- input provider defers it via `vim.schedule`). This stub mirrors
		--- that: it captures `on_confirm` and returns immediately without
		--- calling it, so callers must resume from inside the eventually-fired
		--- callback rather than reading state right after the call returns.
		local function deferred_input_stub()
			local pending = {}
			local stub = {}
			function stub.input(_opts, on_confirm)
				table.insert(pending, on_confirm)
			end
			--- Fire the oldest still-pending on_confirm with `value` (nil to
			--- simulate a cancelled/Esc'd prompt).
			function stub.answer(value)
				local on_confirm = table.remove(pending, 1)
				assert(on_confirm, "deferred_input_stub.answer() called with no pending vim.ui.input call")
				on_confirm(value)
			end
			function stub.pending_count()
				return #pending
			end
			return stub
		end

		it(
			"regression: a required argument collected via a genuinely deferred vim.ui.input "
				.. "(snacks.nvim-style) still reaches prompts/get once the callback actually fires",
			function()
				local obj = { name = "deferred-prompts" }
				function obj:is_stopped()
					return false
				end
				function obj:request(rpc_message, callback)
					if rpc_message.method == "prompts/list" then
						return callback(nil, {
							prompts = {
								{
									name = "deferred_greet",
									description = "Greet someone, requiring their name",
									arguments = {
										{ name = "who", description = "Who to greet", required = true },
									},
								},
							},
						}, nil)
					elseif rpc_message.method == "prompts/get" then
						return callback(nil, {
							messages = {
								{
									role = "user",
									content = {
										type = "text",
										text = "Hello, " .. rpc_message.params.arguments.who .. "!",
									},
								},
							},
						}, nil)
					end
					return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
				end
				function obj:notify(_rpc_message) end
				function obj:disconnect() end
				client.register_native(obj)

				local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
				codecompanion_adapter.setup({})

				local slash_commands = fake_config.interactions.chat.slash_commands
				local entry_key
				for key in pairs(slash_commands) do
					if key:match("deferred_greet$") and key:match("deferred%-prompts") then
						entry_key = key
					end
				end
				assert.is_not_nil(entry_key, "expected a slash command entry for the `deferred_greet` prompt")
				local entry = slash_commands[entry_key]

				local input_stub = deferred_input_stub()
				local original_input = vim.ui.input
				vim.ui.input = input_stub.input

				local chat = fake_chat()
				entry.callback(chat)

				-- The callback() call has returned, but the deferred on_confirm
				-- has NOT fired yet. No request must have gone out, and no
				-- message must have landed, yet.
				assert.are.equal(1, input_stub.pending_count())
				assert.are.equal(0, #chat.messages)

				-- Now the user actually submits the floating input.
				input_stub.answer("Grace")
				vim.ui.input = original_input

				assert.are.equal(1, #chat.messages)
				assert.are.equal("Hello, Grace!", chat.messages[1].data.content)
			end
		)

		it(
			"regression: a cancelled required argument (deferred on_confirm fires with nil) aborts "
				.. "the whole flow -- no prompts/get request is sent",
			function()
				local request_methods = {}
				local obj = { name = "deferred-required-cancel" }
				function obj:is_stopped()
					return false
				end
				function obj:request(rpc_message, callback)
					table.insert(request_methods, rpc_message.method)
					if rpc_message.method == "prompts/list" then
						return callback(nil, {
							prompts = {
								{
									name = "needs_name",
									description = "Requires a name",
									arguments = {
										{ name = "who", description = "Who to greet", required = true },
									},
								},
							},
						}, nil)
					elseif rpc_message.method == "prompts/get" then
						return callback(nil, {
							messages = {
								{ role = "user", content = { type = "text", text = "should never be reached" } },
							},
						}, nil)
					end
					return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
				end
				function obj:notify(_rpc_message) end
				function obj:disconnect() end
				client.register_native(obj)

				local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
				codecompanion_adapter.setup({})

				local slash_commands = fake_config.interactions.chat.slash_commands
				local entry_key
				for key in pairs(slash_commands) do
					if key:match("needs_name$") and key:match("deferred%-required%-cancel") then
						entry_key = key
					end
				end
				assert.is_not_nil(entry_key)
				local entry = slash_commands[entry_key]

				local input_stub = deferred_input_stub()
				local original_input = vim.ui.input
				vim.ui.input = input_stub.input

				local chat = fake_chat()
				entry.callback(chat)

				assert.are.equal(1, input_stub.pending_count())

				-- Simulate the user cancelling (Esc) the required argument's
				-- floating prompt: on_confirm fires with nil.
				input_stub.answer(nil)
				vim.ui.input = original_input

				assert.are.equal(0, #chat.messages)
				for _, method in ipairs(request_methods) do
					assert.are_not.equal("prompts/get", method)
				end
			end
		)

		it(
			"regression: a cancelled OPTIONAL argument (deferred on_confirm fires with nil) is omitted "
				.. "from arguments and collection continues to the next argument",
			function()
				local sent_arguments
				local obj = { name = "deferred-optional-skip" }
				function obj:is_stopped()
					return false
				end
				function obj:request(rpc_message, callback)
					if rpc_message.method == "prompts/list" then
						return callback(nil, {
							prompts = {
								{
									name = "multi_arg",
									description = "One optional, then one required argument",
									arguments = {
										{ name = "nickname", description = "Optional nickname", required = false },
										{ name = "who", description = "Who to greet", required = true },
									},
								},
							},
						}, nil)
					elseif rpc_message.method == "prompts/get" then
						sent_arguments = rpc_message.params.arguments
						return callback(nil, {
							messages = {
								{
									role = "user",
									content = { type = "text", text = "Hello, " .. sent_arguments.who .. "!" },
								},
							},
						}, nil)
					end
					return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
				end
				function obj:notify(_rpc_message) end
				function obj:disconnect() end
				client.register_native(obj)

				local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
				codecompanion_adapter.setup({})

				local slash_commands = fake_config.interactions.chat.slash_commands
				local entry_key
				for key in pairs(slash_commands) do
					if key:match("multi_arg$") and key:match("deferred%-optional%-skip") then
						entry_key = key
					end
				end
				assert.is_not_nil(entry_key)
				local entry = slash_commands[entry_key]

				local input_stub = deferred_input_stub()
				local original_input = vim.ui.input
				vim.ui.input = input_stub.input

				local chat = fake_chat()
				entry.callback(chat)

				-- Only the FIRST declared argument's vim.ui.input call should be
				-- pending so far -- the second must not be issued until the
				-- first's deferred callback actually fires (continuation-passing,
				-- not a loop that already moved on).
				assert.are.equal(1, input_stub.pending_count())

				-- Cancel the optional "nickname" argument.
				input_stub.answer(nil)

				-- Collection must now have proceeded to the required "who"
				-- argument's vim.ui.input call.
				assert.are.equal(1, input_stub.pending_count())
				assert.are.equal(0, #chat.messages)

				input_stub.answer("Ada")
				vim.ui.input = original_input

				assert.are.equal(1, #chat.messages)
				assert.is_nil(
					sent_arguments.nickname,
					"a cancelled optional argument must be omitted, not sent as nil/empty"
				)
				assert.are.equal("Ada", sent_arguments.who)
				assert.are.equal("Hello, Ada!", chat.messages[1].data.content)
			end
		)

		it("edge case: zero connected clients means no slash-command entries, not an error", function()
			local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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

				local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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

			local codecompanion_adapter = require("mcp-client.adapters.codecompanion")
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
