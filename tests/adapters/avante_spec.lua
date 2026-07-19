local client = require("mcphub-neovim.client")
local native = require("mcphub-neovim.native")
local avante = require("mcphub-neovim.adapters.avante")

--- Avante adapter specs (U4). The adapter is a thin translation layer: it
--- turns `client.get_clients()`'s tool/resource/prompt surface into
--- Avante's real `custom_tools` integration point (a list of tool-spec
--- tables, each with `name`/`description`/`param`/`func(input, opts)`,
--- verified against the actual `yetone/avante.nvim` source at
--- `~/.local/share/nvim/lazy/avante.nvim/lua/avante/llm_tools/init.lua` and
--- `types.lua`). It must hold no direct hub or transport logic of its own
--- (R6): every one of these specs only ever touches client objects through
--- `client.register_native`/`native.register` and the public `request()`/
--- `notify()` shape U2 established -- never a transport or Job object.

--- Build a fake *remote-shaped* client object: unlike a native server,
--- its `request()` callback fires asynchronously (deferred via
--- `vim.schedule`), exactly like a real remote transport's curl callback
--- would. Registered through `client.register_native` -- which is just a
--- registry insertion, not remote-specific -- so the test can exercise the
--- adapter against "remote-like async" semantics without spinning up any
--- real transport/socket, keeping the adapter itself innocent of transport
--- concerns while still proving it handles async callbacks correctly.
local function make_async_client(opts)
	local stopped = false
	local obj = {
		name = opts.name,
	}
	function obj:is_stopped()
		return stopped
	end
	function obj:request(rpc_message, callback)
		if stopped then
			return callback("client is disconnected", nil, nil)
		end
		vim.schedule(function()
			opts.handle(rpc_message, callback)
		end)
	end
	function obj:notify(_rpc_message) end
	function obj:disconnect()
		stopped = true
	end
	return client.register_native(obj)
end

--- A minimal remote-shaped double answering the standard MCP methods this
--- adapter needs: tools/list and tools/call.
local function make_remote_double(name, tools_listing, on_call)
	return make_async_client({
		name = name,
		handle = function(rpc_message, callback)
			if rpc_message.method == "tools/list" then
				return callback(nil, { tools = tools_listing }, nil)
			elseif rpc_message.method == "tools/call" then
				return on_call(rpc_message.params, callback)
			end
			return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
		end,
	})
end

--- A remote-shaped double answering only prompts/list and prompts/get --
--- deliberately separate from make_remote_double (which only answers
--- tools/*) so prompt-bridging specs don't have to thread unrelated tool
--- fixtures through, and to independently prove the adapter's prompt path
--- also unwraps a remote client's JSON-RPC envelope (unwrap_result), not
--- just its tool path.
local function make_remote_prompt_double(name, prompts_listing, on_get)
	return make_async_client({
		name = name,
		handle = function(rpc_message, callback)
			if rpc_message.method == "prompts/list" then
				-- Envelope-shaped reply, like a real remote hub -- proves
				-- unwrap_result() is exercised for prompts too.
				return callback(nil, { jsonrpc = "2.0", id = 1, result = { prompts = prompts_listing } }, nil)
			elseif rpc_message.method == "prompts/get" then
				return on_get(rpc_message.params, callback)
			end
			return callback("unsupported method: " .. tostring(rpc_message.method), nil, nil)
		end,
	})
end

--- A pathological client double whose `request()` throws synchronously
--- instead of reporting failure through the `(err, result, response)`
--- callback -- neither of this codebase's real client implementations
--- (native, U3; remote, U1/U2) behaves this way today, but the adapter must
--- still be hardened against a hypothetical future client that does, per
--- the U4 review finding: a synchronous throw from one client's
--- `request()` must not abort `M.custom_tools()`'s iteration over any other
--- registered clients, and must not crash whatever in Avante calls a tool's
--- `func`.
local function make_throwing_client(name)
	local stopped = false
	local obj = { name = name }
	function obj:is_stopped()
		return stopped
	end
	function obj:request(_rpc_message, _callback)
		error("synchronous throw from request(): " .. name)
	end
	function obj:notify(_rpc_message) end
	function obj:disconnect()
		stopped = true
	end
	return client.register_native(obj)
end

describe("adapters.avante (custom_tools translation)", function()
	after_each(function()
		client._reset_registry()
	end)

	it("has zero direct hub or transport knowledge (R6): does not require transport/* modules", function()
		-- A crude but effective static check: the adapter module's own source
		-- must never `require` the transport package or touch a Job object
		-- directly -- only the public client API (require("mcphub-neovim.client")).
		local path = debug.getinfo(avante.custom_tools, "S").source:sub(2)
		local f = assert(io.open(path, "r"))
		local source = f:read("*a")
		f:close()
		assert.is_nil(source:match('require%(%s*"mcphub%-neovim%.transport'))
		assert.is_nil(source:match("plenary%.job"))
		assert.is_nil(source:match("[Jj]ob:pid"))
		assert.is_nil(source:match("vim%.uv%.kill"))
	end)

	it("happy path: a tool call from Avante resolves through the adapter to a native server", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local tools = avante.custom_tools()
		assert.is_table(tools)

		local echo_tool
		for _, t in ipairs(tools) do
			if t.name == "echo" then
				echo_tool = t
			end
		end
		assert.is_not_nil(echo_tool)
		assert.are.equal("Echo the given text back", echo_tool.description)
		assert.are.equal("table", echo_tool.param.type)

		-- Exercise it the way Avante's process_tool_use actually calls a
		-- custom tool: func(input, opts), completion reported either via a
		-- synchronous return or opts.on_complete.
		local got_result, got_err
		local completed = false
		local result, err = echo_tool.func({ text = "hello" }, {
			on_complete = function(result, err)
				completed = true
				got_result, got_err = result, err
			end,
		})

		if result ~= nil or err ~= nil then
			got_result, got_err = result, err
			completed = true
		end

		assert.is_true(completed)
		assert.is_nil(got_err)
		assert.is_not_nil(got_result)
		assert.matches("hello", got_result)
	end)

	it("happy path: a tool call from Avante resolves through the adapter to a remote hub connection", function()
		make_remote_double("remote-hub", {
			{
				name = "remote_echo",
				description = "Echo via a remote hub",
				inputSchema = { type = "object", properties = { text = { type = "string" } } },
			},
		}, function(params, callback)
			callback(nil, { text = params.arguments.text }, nil)
		end)

		-- Avante's real custom_tools() contract is itself synchronous
		-- (llm_tools/init.lua:683-684: called with no callback, return
		-- value used immediately) -- it cannot block for a remote round
		-- trip. So the first call only kicks off the tools/list refresh;
		-- the listing catches up on the next call, once the remote
		-- double's deferred reply has landed.
		local tools = avante.custom_tools()
		local remote_tool
		for _, t in ipairs(tools) do
			if t.name == "remote_echo" then
				remote_tool = t
			end
		end
		assert.is_nil(remote_tool)

		vim.wait(200, function()
			for _, t in ipairs(avante.custom_tools()) do
				if t.name == "remote_echo" then
					remote_tool = t
				end
			end
			return remote_tool ~= nil
		end)

		assert.is_not_nil(remote_tool)
		assert.are.equal("Echo via a remote hub", remote_tool.description)

		-- The remote double's request() defers its callback via
		-- vim.schedule -- proving the adapter's func() genuinely supports
		-- Avante's async on_complete path, not just a synchronous return.
		local got_result, got_err
		local completed = false
		local result, err = remote_tool.func({ text = "remote-hello" }, {
			on_complete = function(result, err)
				completed = true
				got_result, got_err = result, err
			end,
		})
		-- Must not have completed synchronously: the callback is deferred.
		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_nil(err)

		vim.wait(200, function()
			return completed
		end)

		assert.is_true(completed)
		assert.is_nil(got_err)
		assert.is_not_nil(got_result)
		assert.matches("remote%-hello", got_result)
	end)

	it("edge case: zero connected clients means no tools are registered, not an error", function()
		assert.are.equal(0, #client.get_clients())
		local tools
		assert.has_no.errors(function()
			tools = avante.custom_tools()
		end)
		assert.is_table(tools)
		assert.are.equal(0, #tools)
	end)

	it("integration: a client transitioning to disconnected is reflected on next access, not stale", function()
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		local tools_before = avante.custom_tools()
		local found_before = false
		for _, t in ipairs(tools_before) do
			if t.name == "echo" then
				found_before = true
			end
		end
		assert.is_true(found_before)

		-- Disconnect the native server -- is_stopped() now true, exactly the
		-- state a real client transitions to on MCPDetach.
		server:disconnect()
		assert.is_true(server:is_stopped())

		-- The adapter must re-query get_clients() on this next call rather
		-- than reuse a snapshot captured when custom_tools() was first built:
		-- a disconnected client contributes no tools.
		local tools_after = avante.custom_tools()
		local found_after = false
		for _, t in ipairs(tools_after) do
			if t.name == "echo" then
				found_after = true
			end
		end
		assert.is_false(found_after)
	end)

	it("resilience: a throwing client's request() does not break custom_tools() for other clients", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)
		make_throwing_client("throws-on-request")

		-- refresh_client_tools() calls request() on every registered client,
		-- including the throwing one -- this must not raise out of
		-- custom_tools() itself, and the well-behaved native client's tools
		-- must still be listed.
		local tools
		assert.has_no.errors(function()
			tools = avante.custom_tools()
		end)
		assert.is_table(tools)

		local echo_tool
		for _, t in ipairs(tools) do
			assert.are_not.equal("throws-on-request", t.name)
			if t.name == "echo" then
				echo_tool = t
			end
		end
		assert.is_not_nil(echo_tool)
	end)

	it("resilience: func() on a throwing client does not crash the caller, and reports via on_complete", function()
		-- build_tool_spec() is a private local, not exported by the
		-- adapter, so the realistic way to get a hold of a real tool spec
		-- built around a client object is the same path M.custom_tools()
		-- itself uses: register a real (well-behaved) native client so its
		-- tools/list succeeds and a spec is built, then make that same
		-- client's request() throw synchronously for the tools/call this
		-- test actually exercises -- simulating the hypothetical future
		-- client the review finding is concerned with, without needing a
		-- separate throwing double wired all the way through tools/list.
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		local tools = avante.custom_tools()
		local echo_tool
		for _, t in ipairs(tools) do
			if t.name == "echo" then
				echo_tool = t
			end
		end
		assert.is_not_nil(echo_tool)

		-- Monkey-patch this registered client's request() to throw
		-- synchronously, simulating the hypothetical future client the
		-- review finding is concerned with, without needing a second
		-- tools/list round trip.
		function server:request(_rpc_message, _callback)
			error("synchronous throw from request(): tools/call")
		end

		local got_result, got_err
		local completed = false
		local result, err
		assert.has_no.errors(function()
			result, err = echo_tool.func({ text = "hello" }, {
				on_complete = function(res, e)
					completed = true
					got_result, got_err = res, e
				end,
			})
		end)

		-- func() itself still returns nil, nil synchronously (its contract
		-- never changes), but the thrown error must be reported through
		-- on_complete exactly like a callback-reported err would be.
		assert.is_nil(result)
		assert.is_nil(err)
		assert.is_true(completed)
		assert.is_nil(got_result)
		assert.is_not_nil(got_err)
		assert.matches("synchronous throw from request", got_err)
	end)
end)

--- Avante adapter specs (U11): prompt/slash-command bridging. Verified
--- against the real, installed `yetone/avante.nvim` source --
--- `Config.slash_commands` (`avante/config.lua:348,1111`) is a plain
--- `AvanteSlashCommand[]` array (unlike `custom_tools`, it has no function
--- form), read fresh on every `avante.utils.get_commands()` call
--- (`avante/utils/init.lua:1559-1579`, itself invoked on every chat
--- submission via `Sidebar:handle_submit` at `avante/sidebar.lua:2814` and
--- on every `/`-completion via `cmp_avante/commands.lua:33,56`) but never
--- re-invoked as a function -- so, like Avante's own ACP integration
--- (`avante/llm.lua:1188-1211`, which does
--- `table.insert(Config.slash_commands, {...})` at runtime to register
--- agent-defined commands), this adapter's contract is to hand callers a
--- table (`M.slash_commands`) whose *contents* are refreshed in place, not
--- a table that is replaced wholesale.
---
--- `AvanteSlashCommand` (`avante/types.lua:555-560`): `name`, `description`,
--- `details`, optional `shorthelp`, optional `callback` typed
--- `fun(self: avante.Sidebar, args: string, cb?: fun(args: string): nil)`.
--- Critically, `Sidebar:handle_submit` (`avante/sidebar.lua:2808-2834`) only
--- forwards a callback's `cb`-rewritten text into the normal LLM turn for
--- the two hardcoded names `"lines"` and `"commit"` -- every other command
--- (built-in or custom) just runs `cmd.callback(self, args); return`, i.e.
--- the callback is solely responsible for rendering its own output. The
--- only generic, publicly-referenced rendering primitive available to an
--- external command (confirmed via the old `mcphub.nvim`'s own
--- `extensions/avante/slash_commands.lua`, which this adapter replaces, and
--- still present in the installed source) is
--- `Sidebar:add_chat_history(messages, opts)` (`avante/sidebar.lua:2481`).
--- So a prompt's rendered content is appended as a chat message via
--- `sidebar:add_chat_history(...)`, exactly like the old extension did.
---
--- `M.custom_tools()`'s dual sync/async and cache-per-client-id/`pcall`/
--- `unwrap_result` conventions all carry over unchanged for prompts: a
--- native client's `prompts/get` callback fires synchronously (U3); a
--- remote client's is always async (U1/U2); a remote reply is enveloped
--- (`{jsonrpc, id, result = {...}}`) while a native one is the bare payload.
describe("adapters.avante (prompt/slash-command translation, U11)", function()
	after_each(function()
		client._reset_registry()
	end)

	it("happy path: an MCP prompt on a native server is an invocable slash command matching prompts/get", function()
		local example = require("tests.fixtures.example_native_server")
		native.register(example)

		local commands = avante.custom_slash_commands()
		assert.is_table(commands)

		local greet_command
		for _, cmd in ipairs(commands) do
			if cmd.name:match("greet$") then
				greet_command = cmd
			end
		end
		assert.is_not_nil(greet_command)
		assert.are.equal("Greet someone by name", greet_command.description)
		assert.is_function(greet_command.callback)

		-- Exercise the callback the way Sidebar:handle_submit actually calls
		-- it: callback(sidebar, args). A fake sidebar double stands in for
		-- avante.Sidebar; only add_chat_history is exercised here.
		local rendered
		local fake_sidebar = {
			add_chat_history = function(_self, messages, _opts)
				rendered = messages
			end,
		}
		greet_command.callback(fake_sidebar, "Ada")

		assert.is_not_nil(rendered)
		local found = false
		for _, message in ipairs(rendered) do
			if message.content and message.content:match("Hello, Ada!") then
				found = true
			end
		end
		assert.is_true(found)
	end)

	it("happy path: a prompt exposed by a remote (enveloped) client is an invocable slash command", function()
		make_remote_prompt_double("remote-prompts", {
			{
				name = "remote_greet",
				description = "Greet someone via a remote hub",
				arguments = { { name = "who", required = false } },
			},
		}, function(params, callback)
			local who = (params.arguments and params.arguments.who) or "world"
			-- Remote reply is also enveloped, like the real hub U9 validated
			-- against.
			callback(nil, {
				jsonrpc = "2.0",
				id = 1,
				result = { messages = { { role = "user", content = { type = "text", text = "Hi, " .. who .. "!" } } } },
			}, nil)
		end)

		-- custom_slash_commands()'s own contract is synchronous (mirroring
		-- custom_tools()), so the first call only kicks off the prompts/list
		-- refresh; the listing catches up on the next call once the remote
		-- double's deferred reply has landed.
		local commands = avante.custom_slash_commands()
		local remote_command
		for _, cmd in ipairs(commands) do
			if cmd.name:match("remote_greet$") then
				remote_command = cmd
			end
		end
		assert.is_nil(remote_command)

		vim.wait(200, function()
			for _, cmd in ipairs(avante.custom_slash_commands()) do
				if cmd.name:match("remote_greet$") then
					remote_command = cmd
				end
			end
			return remote_command ~= nil
		end)
		assert.is_not_nil(remote_command)
		assert.are.equal("Greet someone via a remote hub", remote_command.description)

		local rendered
		local completed = false
		local fake_sidebar = {
			add_chat_history = function(_self, messages, _opts)
				rendered = messages
				completed = true
			end,
		}
		remote_command.callback(fake_sidebar, "Grace")
		-- Must not have rendered synchronously: the double's callback is
		-- deferred via vim.schedule.
		assert.is_false(completed)

		vim.wait(200, function()
			return completed
		end)

		assert.is_true(completed)
		assert.is_not_nil(rendered)
		local found = false
		for _, message in ipairs(rendered) do
			if message.content and message.content:match("Hi, Grace!") then
				found = true
			end
		end
		assert.is_true(found)
	end)

	it("edge case: zero connected clients means no slash commands are registered, not an error", function()
		assert.are.equal(0, #client.get_clients())
		local commands
		assert.has_no.errors(function()
			commands = avante.custom_slash_commands()
		end)
		assert.is_table(commands)
		assert.are.equal(0, #commands)
	end)

	it(
		"integration: a client transitioning to disconnected is reflected in the slash-command list on next access",
		function()
			local example = require("tests.fixtures.example_native_server")
			local server = native.register(example)

			local commands_before = avante.custom_slash_commands()
			local found_before = false
			for _, cmd in ipairs(commands_before) do
				if cmd.name:match("greet$") then
					found_before = true
				end
			end
			assert.is_true(found_before)

			server:disconnect()
			assert.is_true(server:is_stopped())

			local commands_after = avante.custom_slash_commands()
			local found_after = false
			for _, cmd in ipairs(commands_after) do
				if cmd.name:match("greet$") then
					found_after = true
				end
			end
			assert.is_false(found_after)
		end
	)
end)

--- Avante adapter specs (fix: real Avante config wiring). The Critical
--- finding from the U11 review: handing `require("avante").setup({
--- slash_commands = M.slash_commands })` a table reference and mutating its
--- *contents* afterward does NOT work against the real, installed
--- avante.nvim -- `M.setup`/`M.override` (`avante/config.lua:1231,1347`)
--- merge the caller's `opts` via `vim.tbl_deep_extend("force", ...)`, which
--- (unlike the shallow `vim.tbl_extend`) deep-*copies* nested table values
--- rather than preserving reference identity. So `Config.slash_commands`
--- becomes a different table object than `M.slash_commands` the instant
--- `setup()` runs; mutating `M.slash_commands` afterward is a no-op as far
--- as Avante is concerned. Reproduced independently by the reviewer against
--- a real headless `nvim 0.12.4` session with the installed avante.nvim.
---
--- The real, working precedent (verified in the installed source):
--- `avante/llm.lua:1188-1213` (`available_commands_update`, the ACP session
--- handler) does `table.insert(Config.slash_commands, {...})` where `Config
--- = require("avante.config")` -- mutating the *live, already-merged*
--- config module's own array, obtained via `require()` AFTER `setup()` has
--- already run, not a separately-created table handed into `setup()`'s
--- `opts` and hoped to survive the merge by reference. This adapter now
--- does the same thing.
---
--- Since avante.nvim is not a vendored dependency of this repo (only
--- locally installed for reference, same situation `codecompanion_spec.lua`
--- documents for codecompanion.nvim), this fakes the one real module the
--- adapter now actually `require()`s (`avante.config`) via `package.loaded`,
--- built to the real, verified shape (`slash_commands = {}`,
--- `config.lua:1111`) -- exactly `codecompanion_spec.lua`'s
--- `fresh_codecompanion_config()` convention, applied to Avante. This is the
--- test that would have caught the original bug: it asserts on the STUBBED
--- CONFIG MODULE'S OWN `slash_commands` table, not the adapter's internal
--- cache/bookkeeping -- i.e. it verifies data actually lands in the thing
--- Avante reads (`Utils.get_commands()`, `avante/utils/init.lua:1559-1579`
--- iterates `Config.slash_commands` directly), not just in some adapter-side
--- table that merely *claims* to be kept in sync.
describe("adapters.avante (fix: real Avante config wiring)", function()
	local fake_avante_config

	local function fresh_avante_config()
		return { slash_commands = {} }
	end

	before_each(function()
		fake_avante_config = fresh_avante_config()
		package.loaded["avante.config"] = fake_avante_config
		-- Force a clean reload of the adapter module itself so module-level
		-- caches (prompts_cache etc.) never leak between specs, same
		-- discipline codecompanion_spec.lua applies to its own adapter.
		package.loaded["mcphub-neovim.adapters.avante"] = nil
	end)

	after_each(function()
		client._reset_registry()
		package.loaded["avante.config"] = nil
		package.loaded["mcphub-neovim.adapters.avante"] = nil
	end)

	it(
		"custom_slash_commands() writes MCP-derived commands directly into require('avante.config').slash_commands",
		function()
			local example = require("tests.fixtures.example_native_server")
			native.register(example)

			local fresh_avante = require("mcphub-neovim.adapters.avante")
			fresh_avante.custom_slash_commands()

			-- The load-bearing assertion: the STUBBED avante.config MODULE's
			-- own slash_commands array (not fresh_avante's return value, not
			-- any adapter-internal cache) must contain the MCP-derived
			-- command. Mutating a table the adapter merely hands to
			-- setup()'s opts would never reach here, since this is the
			-- module require("avante.config") resolves to independently of
			-- whatever was passed into any setup()/opts table.
			local found = false
			for _, cmd in ipairs(fake_avante_config.slash_commands) do
				if cmd.name:match("greet$") then
					found = true
				end
			end
			assert.is_true(found, "expected the greet prompt to land in require('avante.config').slash_commands")
		end
	)

	it(
		"refresh clears stale mcp:-prefixed entries from require('avante.config').slash_commands on disconnect",
		function()
			local example = require("tests.fixtures.example_native_server")
			local server = native.register(example)

			local fresh_avante = require("mcphub-neovim.adapters.avante")
			fresh_avante.custom_slash_commands()

			local found_before = false
			for _, cmd in ipairs(fake_avante_config.slash_commands) do
				if cmd.name:match("greet$") then
					found_before = true
				end
			end
			assert.is_true(found_before)

			server:disconnect()
			fresh_avante.custom_slash_commands()

			local found_after = false
			for _, cmd in ipairs(fake_avante_config.slash_commands) do
				if cmd.name:match("greet$") then
					found_after = true
				end
			end
			assert.is_false(found_after)
		end
	)

	it(
		"never destroys a user's own manually-configured slash commands in require('avante.config').slash_commands",
		function()
			local example = require("tests.fixtures.example_native_server")
			native.register(example)

			-- Simulate a user who configured their own slash command directly,
			-- e.g. `require("avante").setup({ slash_commands = { { name =
			-- "my-command", ... } } })` -- which, after a real setup() merge,
			-- would live right here in Config.slash_commands alongside whatever
			-- this adapter owns.
			table.insert(fake_avante_config.slash_commands, {
				name = "my-command",
				description = "A user-defined command, not owned by this adapter",
				details = "A user-defined command, not owned by this adapter",
				callback = function() end,
			})

			local fresh_avante = require("mcphub-neovim.adapters.avante")
			fresh_avante.custom_slash_commands()

			local found_user_command = false
			local found_mcp_command = false
			for _, cmd in ipairs(fake_avante_config.slash_commands) do
				if cmd.name == "my-command" then
					found_user_command = true
				end
				if cmd.name:match("greet$") then
					found_mcp_command = true
				end
			end
			assert.is_true(found_user_command, "a user's own manually-configured slash command must survive a refresh")
			assert.is_true(found_mcp_command, "the MCP-derived command must still be present")

			-- Refresh again (simulating a second LLM turn / cmp completion) --
			-- the user's own command must still be untouched, not duplicated or
			-- dropped.
			fresh_avante.custom_slash_commands()
			local user_command_count = 0
			for _, cmd in ipairs(fake_avante_config.slash_commands) do
				if cmd.name == "my-command" then
					user_command_count = user_command_count + 1
				end
			end
			assert.are.equal(1, user_command_count)
		end
	)
end)
