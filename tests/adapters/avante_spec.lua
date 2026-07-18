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
end)
