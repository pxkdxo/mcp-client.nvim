local client = require("mcp-client.client")
local native = require("mcp-client.native")

--- Native-server specs (U3). A native server is an in-process, Lua-function
--- backed "client" that registers into the exact same registry `client.lua`
--- backs `get_clients()` with, wearing the exact same object shape (`id`,
--- `name`, `is_stopped()`, `request`, `notify`) as a remote server connection,
--- so adapters built against that shape (later tasks) cannot tell native
--- from remote apart.

describe("native (in-process server registration)", function()
	after_each(function()
		client._reset_registry()
	end)

	it("registers a native server's tool callable through request(), visible in get_clients()", function()
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		-- Same shape as a remote client object.
		assert.is_not_nil(server.id)
		assert.are.equal("example-native", server.name)
		assert.is_function(server.is_stopped)
		assert.is_function(server.request)
		assert.is_function(server.notify)
		assert.is_false(server:is_stopped())

		-- Appears in the shared registry, indistinguishable from a remote client.
		local all = client.get_clients()
		assert.are.equal(1, #all)
		assert.are.equal(server.id, all[1].id)
		local by_name = client.get_clients({ name = "example-native" })
		assert.are.equal(1, #by_name)

		-- The tool is callable via the exact same request() path a remote
		-- server's tool would use: a JSON-RPC "tools/call" message with an
		-- (err, result, response) callback.
		local got
		server:request({
			jsonrpc = "2.0",
			id = 1,
			method = "tools/call",
			params = { name = "echo", arguments = { text = "hello" } },
		}, function(err, result, response)
			got = { err = err, result = result, response = response }
		end)

		assert.is_not_nil(got)
		assert.is_nil(got.err)
		assert.is_not_nil(got.result)
		assert.are.equal("hello", got.result.text)
	end)

	it("registers with empty capability tables without error, and is inert", function()
		local server = native.register({ name = "empty-native", tools = {}, resources = {}, prompts = {} })

		assert.is_not_nil(server.id)
		assert.is_false(server:is_stopped())
		assert.are.equal(1, #client.get_clients({ name = "empty-native" }))

		local got
		server:request({
			jsonrpc = "2.0",
			id = 1,
			method = "tools/call",
			params = { name = "nonexistent", arguments = {} },
		}, function(err, result, response)
			got = { err = err, result = result, response = response }
		end)

		assert.is_not_nil(got)
		assert.is_not_nil(got.err)
		assert.is_nil(got.result)
	end)

	it("surfaces a Lua error raised inside a tool function via (err, result, context), not a crash", function()
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		local got
		local ok = pcall(function()
			server:request({
				jsonrpc = "2.0",
				id = 2,
				method = "tools/call",
				params = { name = "boom", arguments = {} },
			}, function(err, result, response)
				got = { err = err, result = result, response = response }
			end)
		end)

		-- The call into request() itself must never throw -- the error is
		-- reported through the callback, exactly like a remote server's
		-- tool-call failure would be.
		assert.is_true(ok)
		assert.is_not_nil(got)
		assert.is_not_nil(got.err)
		assert.is_nil(got.result)
		assert.matches("boom", tostring(got.err))
	end)

	it("notify() does not error even though native servers have nothing to notify", function()
		local server = native.register({ name = "notify-native", tools = {}, resources = {}, prompts = {} })
		assert.has_no.errors(function()
			server:notify({ jsonrpc = "2.0", method = "notifications/initialized", params = {} })
		end)
	end)

	it("answers tools/list with the registered tool names, MCP-shaped", function()
		local example = require("tests.fixtures.example_native_server")
		local server = native.register(example)

		local got
		server:request({
			jsonrpc = "2.0",
			id = 1,
			method = "tools/list",
			params = {},
		}, function(err, result, response)
			got = { err = err, result = result, response = response }
		end)

		assert.is_not_nil(got)
		assert.is_nil(got.err)
		assert.is_not_nil(got.result)
		assert.is_not_nil(got.result.tools)

		local names = {}
		for _, tool in ipairs(got.result.tools) do
			names[tool.name] = true
		end
		assert.is_true(names.echo)
		assert.is_true(names.boom)
	end)

	it("answers tools/list with an empty list for a tool-less native server", function()
		local server = native.register({ name = "empty-list-native", tools = {}, resources = {}, prompts = {} })

		local got
		server:request({
			jsonrpc = "2.0",
			id = 1,
			method = "tools/list",
			params = {},
		}, function(err, result, response)
			got = { err = err, result = result, response = response }
		end)

		assert.is_nil(got.err)
		assert.are.equal(0, #got.result.tools)
	end)
end)
