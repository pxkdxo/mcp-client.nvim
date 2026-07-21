-- `config.setup(opts)` validates and normalizes user-supplied configuration,
-- registers native servers via `native.register`, connects each configured
-- server via `client.connect`, and threads an auto-constructed TokenStore
-- into any non-localhost server that did not bring its own. It never
-- triggers an interactive OAuth flow.
--
-- These specs drive setup through the same public seams adapters use
-- (`client.get_clients()`, `native.register`) and inject a fake
-- `client.connect` so no real transport/socket is ever opened.

local client = require("mcp-client.client")
local config = require("mcp-client.config")

describe("config.setup (orchestration)", function()
	local real_connect

	before_each(function()
		real_connect = client.connect
	end)

	after_each(function()
		client.connect = real_connect
		client._reset_registry()
		config._reset()
	end)

	--- Replaces client.connect with a double that records the config it was
	--- handed and reports a connected client object registered into the real
	--- registry, so get_clients() sees it.
	local function stub_connect(opts)
		opts = opts or {}
		local calls = {}
		client.connect = function(cfg, connect_opts)
			table.insert(calls, cfg)
			if opts.fail then
				return connect_opts.on_connect(nil, opts.fail)
			end
			local stopped = false
			local obj = {
				name = cfg.name,
				config = cfg,
			}
			function obj:is_stopped()
				return stopped
			end
			function obj:request(_rpc, cb)
				return cb("noop", nil, nil)
			end
			function obj:notify(_rpc) end
			function obj:disconnect()
				stopped = true
			end
			client.register_native(obj)
			connect_opts.on_connect(obj, nil)
		end
		return calls
	end

	describe("native servers", function()
		it("registers each native server so it appears in get_clients()", function()
			stub_connect()
			config.setup({
				native_servers = {
					example = require("tests.fixtures.example_native_server"),
				},
			})

			local all = client.get_clients({ name = "example-native" })
			assert.are.equal(1, #all)
		end)

		it("accepts a native server config that omits an explicit name, using its map key", function()
			stub_connect()
			config.setup({
				native_servers = {
					mykey = { tools = {}, resources = {}, prompts = {} },
				},
			})

			local all = client.get_clients({ name = "mykey" })
			assert.are.equal(1, #all)
		end)

		it(
			"regression: a second setup() call disconnects and replaces the prior roster, not accumulates alongside it",
			function()
				stub_connect()
				config.setup({
					native_servers = {
						example = require("tests.fixtures.example_native_server"),
					},
				})
				local first = client.get_clients({ name = "example-native" })[1]

				stub_connect()
				config.setup({
					native_servers = {
						example = require("tests.fixtures.example_native_server"),
					},
				})

				local all = client.get_clients({ name = "example-native" })
				assert.are.equal(
					1,
					#all,
					"a repeated setup() must not leave the prior registration alongside a new one"
				)
				assert.is_true(first:is_stopped(), "the prior registration must be disconnected, not orphaned")
			end
		)
	end)

	describe("servers", function()
		it("connects each configured server, passing its url through to client.connect", function()
			local calls = stub_connect()
			config.setup({
				servers = {
					local_hub = { url = "http://localhost:9999" },
				},
			})

			assert.are.equal(1, #calls)
			assert.are.equal("http://localhost:9999", calls[1].url)
			-- Name defaults to the map key when not otherwise supplied.
			assert.are.equal("local_hub", calls[1].name)
		end)

		it("connects multiple configured servers", function()
			local calls = stub_connect()
			config.setup({
				servers = {
					a = { url = "http://localhost:1111" },
					b = { url = "http://localhost:2222" },
				},
			})
			assert.are.equal(2, #calls)
		end)

		it("supports a single `server` shorthand as well as a `servers` map", function()
			local calls = stub_connect()
			config.setup({
				server = { url = "http://localhost:3333" },
			})
			assert.are.equal(1, #calls)
			assert.are.equal("http://localhost:3333", calls[1].url)
		end)

		it("does not construct a TokenStore for a localhost server", function()
			stub_connect()
			config.setup({
				servers = { local_hub = { url = "http://localhost:9999" } },
			})
			local record = config.get_hub("local_hub")
			assert.is_not_nil(record)
			assert.is_nil(record.token_store)
		end)

		it(
			"retains the exact connect config passed to client.connect, including headers and reconnect tuning",
			function()
				local calls = stub_connect()
				config.setup({
					servers = {
						remote = {
							url = "https://server.example.com/mcp",
							headers = { ["X-API-Key"] = "s3cr3t" },
							reconnect = { max_attempts = 5, backoff_ms = 250 },
						},
					},
					token_store = { backend = "file", data_home = vim.fn.tempname() },
				})
				local record = config.get_hub("remote")
				assert.is_not_nil(record)
				assert.is_not_nil(record.connect_config)
				assert.are.same(calls[1], record.connect_config)
				assert.are.same({ ["X-API-Key"] = "s3cr3t" }, record.connect_config.headers)
				assert.are.same({ max_attempts = 5, backoff_ms = 250 }, record.connect_config.reconnect)
			end
		)

		it("retains connect_config.auth.token_store as the same object reference as record.token_store", function()
			local calls = stub_connect()
			config.setup({
				servers = { remote = { url = "https://server.example.com/mcp" } },
				token_store = { backend = "file", data_home = vim.fn.tempname() },
			})
			local record = config.get_hub("remote")
			assert.is_not_nil(record.connect_config)
			assert.is_not_nil(record.connect_config.auth)
			assert.are.equal(record.token_store, record.connect_config.auth.token_store)
			-- Also matches what was actually handed to client.connect.
			assert.are.equal(calls[1].auth.token_store, record.connect_config.auth.token_store)
		end)

		it("carries no auth sub-table in connect_config for a localhost server (no token store)", function()
			stub_connect()
			config.setup({
				servers = { local_hub = { url = "http://localhost:9999" } },
			})
			local record = config.get_hub("local_hub")
			assert.is_not_nil(record.connect_config)
			assert.is_nil(record.connect_config.auth)
		end)

		it("auto-constructs a TokenStore for a non-localhost server with none supplied", function()
			local calls = stub_connect()
			config.setup({
				servers = { remote = { url = "https://server.example.com/mcp" } },
				-- Use the file backend under a temp dir so the spec never touches
				-- a real keychain or the developer's data home.
				token_store = { backend = "file", data_home = vim.fn.tempname() },
			})
			local record = config.get_hub("remote")
			assert.is_not_nil(record)
			assert.is_not_nil(record.token_store)
			-- The store is threaded into the connect config's auth sub-table so
			-- client.connect consults it.
			assert.are.equal(record.token_store, calls[1].auth.token_store)
		end)

		it(
			"regression: a global token_store.key is namespaced per-server, never used verbatim, so two non-localhost servers never collide onto the same stored token",
			function()
				stub_connect()
				config.setup({
					servers = {
						remote_a = { url = "https://server-a.example.com/mcp" },
						remote_b = { url = "https://server-b.example.com/mcp" },
					},
					token_store = { backend = "file", data_home = vim.fn.tempname(), key = "shared" },
				})
				local store_a = config.get_hub("remote_a").token_store
				local store_b = config.get_hub("remote_b").token_store
				assert.is_not_nil(store_a)
				assert.is_not_nil(store_b)
				assert.are_not.equal(store_a.key, store_b.key)
				assert.are_not.equal(store_a:path(), store_b:path())
			end
		)

		it(
			"regression: the connect-failure auth hint saves under the store's actual (possibly-namespaced) key, not the bare server name",
			function()
				stub_connect({ fail = "connection refused" })
				local real_notify = vim.notify
				local notified
				vim.notify = function(msg, _level)
					notified = msg
				end
				config.setup({
					servers = { remote = { url = "https://server.example.com/mcp" } },
					token_store = { backend = "file", data_home = vim.fn.tempname(), key = "shared" },
				})
				vim.wait(30, function()
					return false
				end)
				vim.notify = real_notify

				assert.is_not_nil(notified)
				local store = config.get_hub("remote").token_store
				assert.are.equal("shared:remote", store.key)
				-- The printed snippet must save under the store's real, namespaced
				-- key -- not the bare server name, which setup() never looks up.
				assert.is_not_nil(notified:find("key = " .. vim.inspect(store.key), 1, true))
				assert.is_nil(notified:find('key = "remote"', 1, true))
			end
		)

		it("does not overwrite a caller-supplied token_store on a server", function()
			local calls = stub_connect()
			local mine = require("mcp-client.auth.token_store").new({
				key = "custom",
				backend = "file",
				data_home = vim.fn.tempname(),
			})
			config.setup({
				servers = {
					remote = { url = "https://server.example.com/mcp", auth = { token_store = mine } },
				},
			})
			assert.are.equal(mine, calls[1].auth.token_store)
			assert.are.equal(mine, config.get_hub("remote").token_store)
		end)
	end)

	describe("validation", function()
		it("errors when a server config has no url", function()
			stub_connect()
			assert.has_error(function()
				config.setup({ servers = { bad = {} } })
			end)
		end)

		it("accepts an empty/absent opts table without error (no servers, no native servers)", function()
			stub_connect()
			assert.has_no.errors(function()
				config.setup()
			end)
			assert.has_no.errors(function()
				config.setup({})
			end)
		end)
	end)

	describe("state record for health.lua", function()
		it("records native server names and server records after setup", function()
			stub_connect()
			config.setup({
				native_servers = { example = require("tests.fixtures.example_native_server") },
				servers = { local_hub = { url = "http://localhost:9999" } },
			})
			local state = config.state()
			assert.are.equal("example-native", state.native_servers[1])
			assert.is_not_nil(state.servers.local_hub)
			assert.are.equal("http://localhost:9999", state.servers.local_hub.url)
		end)

		it("_reset clears recorded state so a later setup starts clean", function()
			stub_connect()
			config.setup({ servers = { local_hub = { url = "http://localhost:9999" } } })
			config._reset()
			local state = config.state()
			assert.are.equal(0, #state.native_servers)
			assert.is_nil(next(state.servers))
		end)
	end)
end)
