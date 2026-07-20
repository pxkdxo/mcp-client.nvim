-- Configuration/orchestration specs (U8). `config.setup(opts)` is the single
-- glue call a real user's config makes: it validates and normalizes the
-- externally-supplied configuration (R7 -- nothing personal baked into the
-- plugin source), registers native servers via `native.register`, connects
-- each configured hub via `client.connect`, and threads an auto-constructed
-- TokenStore into any non-localhost hub that did not bring its own (design
-- question 3). It never triggers an interactive OAuth flow.
--
-- These specs drive the orchestration through the same public seams every
-- adapter uses (`client.get_clients()`, `native.register`) and inject a fake
-- `client.connect` so no real transport/socket is ever opened -- the same
-- discipline the adapter specs follow.

local client = require("mcphub-neovim.client")
local config = require("mcphub-neovim.config")

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

	--- Replace client.connect with a double that records the config it was
	--- handed and immediately reports a connected, remote-shaped client object
	--- registered into the real registry (so get_clients() sees it).
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
	end)

	describe("hubs", function()
		it("connects each configured hub, passing its url through to client.connect", function()
			local calls = stub_connect()
			config.setup({
				hubs = {
					local_hub = { url = "http://localhost:9999" },
				},
			})

			assert.are.equal(1, #calls)
			assert.are.equal("http://localhost:9999", calls[1].url)
			-- Name defaults to the map key when not otherwise supplied.
			assert.are.equal("local_hub", calls[1].name)
		end)

		it("connects multiple hubs (R7's plural server list)", function()
			local calls = stub_connect()
			config.setup({
				hubs = {
					a = { url = "http://localhost:1111" },
					b = { url = "http://localhost:2222" },
				},
			})
			assert.are.equal(2, #calls)
		end)

		it("supports a single `hub` shorthand as well as a `hubs` map", function()
			local calls = stub_connect()
			config.setup({
				hub = { url = "http://localhost:3333" },
			})
			assert.are.equal(1, #calls)
			assert.are.equal("http://localhost:3333", calls[1].url)
		end)

		it("does not construct a TokenStore for a localhost hub", function()
			stub_connect()
			config.setup({
				hubs = { local_hub = { url = "http://localhost:9999" } },
			})
			local record = config.get_hub("local_hub")
			assert.is_not_nil(record)
			assert.is_nil(record.token_store)
		end)

		it("auto-constructs a TokenStore for a non-localhost hub with none supplied", function()
			local calls = stub_connect()
			config.setup({
				hubs = { remote = { url = "https://hub.example.com/mcp" } },
				-- Keep the store on the file backend under a temp dir so the spec
				-- never touches a real keychain or the developer's data home.
				token_store = { backend = "file", data_home = vim.fn.tempname() },
			})
			local record = config.get_hub("remote")
			assert.is_not_nil(record)
			assert.is_not_nil(record.token_store)
			-- The store is threaded into the connect config's auth sub-table so
			-- client.connect consults it (U7).
			assert.are.equal(record.token_store, calls[1].auth.token_store)
		end)

		it(
			"regression: a global token_store.key is namespaced per-hub, never used verbatim, so two non-localhost hubs never collide onto the same stored token",
			function()
				stub_connect()
				config.setup({
					hubs = {
						remote_a = { url = "https://hub-a.example.com/mcp" },
						remote_b = { url = "https://hub-b.example.com/mcp" },
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

		it("does not overwrite a caller-supplied token_store on a hub", function()
			local calls = stub_connect()
			local mine = require("mcphub-neovim.auth.token_store").new({
				key = "custom",
				backend = "file",
				data_home = vim.fn.tempname(),
			})
			config.setup({
				hubs = {
					remote = { url = "https://hub.example.com/mcp", auth = { token_store = mine } },
				},
			})
			assert.are.equal(mine, calls[1].auth.token_store)
			assert.are.equal(mine, config.get_hub("remote").token_store)
		end)
	end)

	describe("validation", function()
		it("errors when a hub config has no url", function()
			stub_connect()
			assert.has_error(function()
				config.setup({ hubs = { bad = {} } })
			end)
		end)

		it("accepts an empty/absent opts table without error (no hubs, no native servers)", function()
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
		it("records native server names and hub records after setup", function()
			stub_connect()
			config.setup({
				native_servers = { example = require("tests.fixtures.example_native_server") },
				hubs = { local_hub = { url = "http://localhost:9999" } },
			})
			local state = config.state()
			assert.are.equal("example-native", state.native_servers[1])
			assert.is_not_nil(state.hubs.local_hub)
			assert.are.equal("http://localhost:9999", state.hubs.local_hub.url)
		end)

		it("_reset clears recorded state so a later setup starts clean", function()
			stub_connect()
			config.setup({ hubs = { local_hub = { url = "http://localhost:9999" } } })
			config._reset()
			local state = config.state()
			assert.are.equal(0, #state.native_servers)
			assert.is_nil(next(state.hubs))
		end)
	end)
end)
