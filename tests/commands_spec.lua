-- `commands.lua` registers the `:MCPAuth [server-name]` Ex command and
-- implements pure target-resolution logic: given no argument or an explicit
-- server name, it resolves either a definite target server name or a clear
-- reason why none was chosen.
--
-- These specs drive `commands.resolve_target` and `commands.complete`
-- directly against `config._record_hub`-populated state, mirroring how
-- config_spec.lua/health_spec.lua build scenarios without a real connection.

local commands = require("mcp-client.commands")
local config = require("mcp-client.config")
local dcr = require("mcp-client.auth.dcr")
local mcp_client = require("mcp-client.client")

--- Build a minimal fake TokenStore with a fixed `status()` return, matching
--- the shape token_store.lua's real `status()` produces (has_token/expired
--- are the only fields the "needs authentication" predicate cares about).
--- Also records every `:save(token)` call so happy-path specs can assert the
--- token landed on this exact store object.
local function fake_store(status)
	local store = {
		key = "fake",
		status = function()
			return status
		end,
		saved = {},
	}
	store.save = function(_self, token)
		table.insert(store.saved, token)
		return true, nil
	end
	return store
end

describe("commands (MCPAuth target resolution + completion)", function()
	after_each(function()
		config._reset()
		commands._reset()
	end)

	describe("resolve_target", function()
		it("no argument, exactly one eligible server: resolves that server's name", function()
			config._record_hub("needs_auth", {
				url = "https://server.example.com/mcp",
				token_store = fake_store({ has_token = false, expired = false }),
			})
			config._record_hub("local_hub", { url = "http://localhost:9999" })

			local name, err = commands.resolve_target(nil)
			assert.are.equal("needs_auth", name)
			assert.is_nil(err)
		end)

		it("explicit valid name resolves regardless of current token validity", function()
			config._record_hub("valid", {
				url = "https://server.example.com/mcp",
				token_store = fake_store({ has_token = true, expired = false }),
			})

			local name, err = commands.resolve_target("valid")
			assert.are.equal("valid", name)
			assert.is_nil(err)
		end)

		it('no argument, zero eligible servers: reports "nothing to authenticate"', function()
			config._record_hub("valid", {
				url = "https://server.example.com/mcp",
				token_store = fake_store({ has_token = true, expired = false }),
			})
			config._record_hub("local_hub", { url = "http://localhost:9999" })

			local name, err = commands.resolve_target(nil)
			assert.is_nil(name)
			assert.is_not_nil(err)
			assert.is_not_nil(err:lower():find("nothing to authenticate"))
		end)

		it("no argument, two or more eligible servers: reports the candidate list and picks none", function()
			config._record_hub("needs_auth_a", {
				url = "https://a.example.com/mcp",
				token_store = fake_store({ has_token = false, expired = false }),
			})
			config._record_hub("needs_auth_b", {
				url = "https://b.example.com/mcp",
				token_store = fake_store({ has_token = true, expired = true }),
			})

			local name, err = commands.resolve_target(nil)
			assert.is_nil(name)
			assert.is_not_nil(err)
			assert.is_not_nil(err:find("needs_auth_a"))
			assert.is_not_nil(err:find("needs_auth_b"))
		end)

		it(
			"explicit name not present in configured servers: clear 'not configured' error, no flow attempted",
			function()
				local name, err = commands.resolve_target("ghost")
				assert.is_nil(name)
				assert.is_not_nil(err)
				assert.is_not_nil(err:lower():find("not configured"))
			end
		)

		it(
			"explicit name for a server with no token_store: clear 'does not use token-based authentication' error",
			function()
				config._record_hub("local_hub", { url = "http://localhost:9999" })

				local name, err = commands.resolve_target("local_hub")
				assert.is_nil(name)
				assert.is_not_nil(err)
				assert.is_not_nil(err:lower():find("does not use token%-based authentication"))
			end
		)

		it(
			"explicit name for a localhost server configured with an explicit auth.token_store override is treated as eligible",
			function()
				config._record_hub("local_override", {
					url = "http://localhost:9999",
					token_store = fake_store({ has_token = false, expired = false }),
				})

				local name, err = commands.resolve_target("local_override")
				assert.are.equal("local_override", name)
				assert.is_nil(err)
			end
		)
	end)

	describe("complete", function()
		it("returns every configured server name that has a token_store, including ones with a valid token", function()
			config._record_hub("valid", {
				url = "https://server.example.com/mcp",
				token_store = fake_store({ has_token = true, expired = false }),
			})
			config._record_hub("needs_auth", {
				url = "https://other.example.com/mcp",
				token_store = fake_store({ has_token = false, expired = false }),
			})
			config._record_hub("local_hub", { url = "http://localhost:9999" })

			local candidates = commands.complete("", ":MCPAuth ", 9)
			table.sort(candidates)
			assert.are.same({ "needs_auth", "valid" }, candidates)
		end)

		it("returns an empty list when no configured server has a token_store", function()
			config._record_hub("local_hub", { url = "http://localhost:9999" })

			local candidates = commands.complete("", ":MCPAuth ", 9)
			assert.are.same({}, candidates)
		end)
	end)

	describe("authenticate", function()
		local real_run_flow, real_connect, real_get_clients

		before_each(function()
			real_run_flow = dcr.run_flow
			real_connect = mcp_client.connect
			real_get_clients = mcp_client.get_clients
		end)

		after_each(function()
			dcr.run_flow = real_run_flow
			mcp_client.connect = real_connect
			mcp_client.get_clients = real_get_clients
			mcp_client._reset_registry()
		end)

		--- Replaces dcr.run_flow with a double that records the opts it was
		--- handed and resolves synchronously with either a fixed token or a
		--- fixed error, matching stub_connect's recording convention in
		--- config_spec.lua.
		local function stub_run_flow(result)
			local calls = {}
			dcr.run_flow = function(opts, callback)
				table.insert(calls, opts)
				if result.err then
					return callback(nil, result.err)
				end
				return callback(result.token or { access_token = "fresh-token" }, nil)
			end
			return calls
		end

		--- Replaces mcp_client.connect with a double that records the config it
		--- was handed and reports success/failure per `opts.fail`, registering a
		--- connected client object into the real registry (via register_native)
		--- so get_clients() sees it -- mirrors config_spec.lua's stub_connect.
		---
		--- Mints a fresh, globally-unique id per successful connect (like the
		--- real `client.lua:new_id()` does), rather than deriving one from the
		--- server name. A name-derived id would make a second `connect()` for
		--- the same name silently overwrite the prior registry slot by id
		--- collision -- passing the "exactly one live client" assertion
		--- below for the wrong reason, without ever exercising `authenticate`'s
		--- own disconnect-then-`_forget` teardown of the stale entry.
		local function stub_client_connect(opts)
			opts = opts or {}
			local calls = {}
			local next_fake_id = 0
			mcp_client.connect = function(cfg, connect_opts)
				table.insert(calls, cfg)
				if opts.fail then
					return connect_opts.on_connect(nil, opts.fail)
				end
				next_fake_id = next_fake_id + 1
				local stopped = false
				local obj = { id = "fake-client:" .. next_fake_id, name = cfg.name, config = cfg }
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
				mcp_client.register_native(obj)
				connect_opts.on_connect(obj, nil)
			end
			return calls
		end

		--- Capture every vim.notify call made during `fn()`.
		local function capture_notifications(fn)
			local notifications = {}
			local real_notify = vim.notify
			vim.notify = function(msg, level)
				table.insert(notifications, { msg = msg, level = level })
			end
			local ok, err = pcall(fn)
			vim.notify = real_notify
			assert.is_true(ok, err)
			return notifications
		end

		it(
			"happy path: saves the token onto the pre-existing store and reconnects with the retained connect_config",
			function()
				local store = fake_store({ has_token = false, expired = false })
				local connect_config = {
					url = "https://server.example.com/mcp",
					name = "needs_auth",
					headers = { ["X-Custom"] = "keep-me" },
					auth = { token_store = store },
				}
				config._record_hub("needs_auth", {
					url = connect_config.url,
					token_store = store,
					connect_config = connect_config,
				})

				local run_flow_calls = stub_run_flow({ token = { access_token = "new-token" } })
				local connect_calls = stub_client_connect()

				local notifications = capture_notifications(function()
					commands.authenticate("needs_auth")
				end)

				assert.are.equal(1, #run_flow_calls)
				assert.are.equal(connect_config.url, run_flow_calls[1].server_url)

				assert.are.equal(1, #store.saved)
				assert.are.equal("new-token", store.saved[1].access_token)

				assert.are.equal(1, #connect_calls)
				assert.are.equal(connect_config, connect_calls[1])

				assert.is_true(#notifications >= 1)
				local last = notifications[#notifications]
				assert.is_not_nil(last.msg:lower():find("needs_auth"))
			end
		)

		it(
			"happy path: an already-connected server still runs run_flow and saves a fresh token, ending with exactly one live client for that name",
			function()
				local store = fake_store({ has_token = true, expired = false })
				local connect_config = {
					url = "https://server.example.com/mcp",
					name = "already_connected",
					auth = { token_store = store },
				}
				config._record_hub("already_connected", {
					url = connect_config.url,
					token_store = store,
					connect_config = connect_config,
				})

				local connect_calls = stub_client_connect()
				-- Pre-connect once, as if setup() already dialed this server.
				mcp_client.connect(connect_config, {
					on_connect = function() end,
				})
				assert.are.equal(1, #mcp_client.get_clients({ name = "already_connected" }))

				local run_flow_calls = stub_run_flow({ token = { access_token = "rotated-token" } })

				capture_notifications(function()
					commands.authenticate("already_connected")
				end)

				assert.are.equal(1, #run_flow_calls)
				assert.are.equal(1, #store.saved)
				assert.are.equal("rotated-token", store.saved[1].access_token)

				local live = mcp_client.get_clients({ name = "already_connected" })
				assert.are.equal(1, #live)
			end
		)

		it(
			"edge case: target has no live client yet -- the teardown step is a no-op and reconnect proceeds normally",
			function()
				local store = fake_store({ has_token = false, expired = false })
				local connect_config = {
					url = "https://server.example.com/mcp",
					name = "fresh_target",
					auth = { token_store = store },
				}
				config._record_hub("fresh_target", {
					url = connect_config.url,
					token_store = store,
					connect_config = connect_config,
				})

				-- No live client registered for this name: get_clients() returns an
				-- empty list, so the loop over it must call :disconnect() zero times.
				-- A fake entry under a DIFFERENT name proves disconnect is never
				-- called on anything not matching the requested filter either.
				local disconnect_called = false
				local other_name_client = {
					disconnect = function()
						disconnect_called = true
					end,
				}
				local get_clients_calls = {}
				mcp_client.get_clients = function(filter)
					table.insert(get_clients_calls, filter)
					if filter and filter.name == "fresh_target" then
						return {}
					end
					return { other_name_client }
				end
				stub_run_flow({ token = { access_token = "tok" } })
				local connect_calls = stub_client_connect()

				capture_notifications(function()
					commands.authenticate("fresh_target")
				end)

				assert.are.equal(1, #get_clients_calls)
				assert.are.equal("fresh_target", get_clients_calls[1].name)
				assert.is_false(disconnect_called)
				assert.are.equal(1, #connect_calls)
			end
		)

		it(
			"error path: dcr.run_flow reports an error -- clear failure notification, save/reconnect never attempted",
			function()
				local store = fake_store({ has_token = false, expired = false })
				local connect_config = {
					url = "https://server.example.com/mcp",
					name = "flow_fails",
					auth = { token_store = store },
				}
				config._record_hub("flow_fails", {
					url = connect_config.url,
					token_store = store,
					connect_config = connect_config,
				})

				stub_run_flow({ err = "discovery: no response from server" })
				local connect_calls = stub_client_connect()

				local notifications = capture_notifications(function()
					commands.authenticate("flow_fails")
				end)

				assert.are.equal(0, #store.saved)
				assert.are.equal(0, #connect_calls)

				assert.are.equal(1, #notifications)
				assert.is_not_nil(notifications[1].msg:find("discovery: no response from server", 1, true))
				assert.are.equal(vim.log.levels.WARN, notifications[1].level)
			end
		)

		it(
			"error path: token saved successfully but the reconnect itself fails -- a distinct notification from an OAuth failure",
			function()
				local store = fake_store({ has_token = false, expired = false })
				local connect_config = {
					url = "https://server.example.com/mcp",
					name = "reconnect_fails",
					auth = { token_store = store },
				}
				config._record_hub("reconnect_fails", {
					url = connect_config.url,
					token_store = store,
					connect_config = connect_config,
				})

				stub_run_flow({ token = { access_token = "tok" } })
				stub_client_connect({ fail = "connection refused" })

				local notifications = capture_notifications(function()
					commands.authenticate("reconnect_fails")
				end)

				assert.are.equal(1, #store.saved)

				assert.are.equal(1, #notifications)
				assert.is_not_nil(notifications[1].msg:find("connection refused", 1, true))
				-- Distinct from a run_flow/OAuth failure message.
				assert.is_nil(notifications[1].msg:lower():find("discovery"))
			end
		)

		it("integration: none of the vim.notify calls interpolate connect_config or connect_config.headers", function()
			local store = fake_store({ has_token = false, expired = false })
			local connect_config = {
				url = "https://server.example.com/mcp",
				name = "secret_headers",
				headers = { ["Authorization"] = "Bearer super-secret-value" },
				auth = { token_store = store },
			}
			config._record_hub("secret_headers", {
				url = connect_config.url,
				token_store = store,
				connect_config = connect_config,
			})

			stub_run_flow({ token = { access_token = "tok" } })
			stub_client_connect({ fail = "connection refused" })

			local notifications = capture_notifications(function()
				commands.authenticate("secret_headers")
			end)

			for _, n in ipairs(notifications) do
				assert.is_nil(n.msg:find("super%-secret%-value"))
				assert.is_nil(n.msg:find("Bearer", 1, true))
			end
		end)

		it(
			"concurrency guard: a second authenticate() call for a name already in flight is rejected, not raced",
			function()
				local store = fake_store({ has_token = false, expired = false })
				local connect_config = {
					url = "https://server.example.com/mcp",
					name = "concurrent_target",
					auth = { token_store = store },
				}
				config._record_hub("concurrent_target", {
					url = connect_config.url,
					token_store = store,
					connect_config = connect_config,
				})

				-- A run_flow double that never calls back, simulating an
				-- in-progress browser-based OAuth flow the user hasn't finished.
				local run_flow_calls = {}
				dcr.run_flow = function(opts, _callback)
					table.insert(run_flow_calls, opts)
				end

				local notifications = capture_notifications(function()
					commands.authenticate("concurrent_target")
					commands.authenticate("concurrent_target")
				end)

				-- Only the first call actually dispatched a flow; the second was
				-- rejected before reaching dcr.run_flow at all.
				assert.are.equal(1, #run_flow_calls)
				assert.are.equal(1, #notifications)
				assert.is_not_nil(notifications[1].msg:lower():find("already in progress"))
			end
		)
	end)

	describe("register", function()
		it("registers :MCPAuth with nargs = '?' and a completion function", function()
			local created = {}
			local real_create = vim.api.nvim_create_user_command
			vim.api.nvim_create_user_command = function(name, callback, opts)
				table.insert(created, { name = name, callback = callback, opts = opts })
			end

			local ok, err = pcall(commands.register)
			vim.api.nvim_create_user_command = real_create
			assert.is_true(ok, err)

			assert.are.equal(1, #created)
			assert.are.equal("MCPAuth", created[1].name)
			assert.are.equal("?", created[1].opts.nargs)
			assert.are.equal("function", type(created[1].opts.complete))
			assert.are.equal("function", type(created[1].callback))
		end)

		it("calling register() twice does not error (idempotent re-setup)", function()
			local real_create = vim.api.nvim_create_user_command
			vim.api.nvim_create_user_command = function(_name, _callback, _opts) end

			assert.has_no.errors(function()
				commands.register()
				commands.register()
			end)

			vim.api.nvim_create_user_command = real_create
		end)

		--- Captures the real callback register() hands to nvim_create_user_command,
		--- so these specs exercise on_mcpauth itself (not just resolve_target in
		--- isolation) -- the callback is the only path a real `:MCPAuth` invocation
		--- actually goes through.
		local function captured_callback()
			local created
			local real_create = vim.api.nvim_create_user_command
			vim.api.nvim_create_user_command = function(_name, callback, _opts)
				created = callback
			end
			commands.register()
			vim.api.nvim_create_user_command = real_create
			return created
		end

		it(
			"invoking the registered callback with no args reports resolve_target's error when nothing is configured",
			function()
				local callback = captured_callback()

				local notifications = {}
				local real_notify = vim.notify
				vim.notify = function(msg, level)
					table.insert(notifications, { msg = msg, level = level })
				end
				local ok, err = pcall(callback, { args = "" })
				vim.notify = real_notify
				assert.is_true(ok, err)

				assert.are.equal(1, #notifications)
				assert.is_not_nil(notifications[1].msg:lower():find("nothing to authenticate"))
			end
		)

		it(
			"invoking the registered callback with an explicit name dispatches straight to authenticate (dcr.run_flow fires)",
			function()
				config._record_hub("registered_target", {
					url = "https://server.example.com/mcp",
					token_store = fake_store({ has_token = false, expired = false }),
					connect_config = { url = "https://server.example.com/mcp", name = "registered_target" },
				})

				local run_flow_calls = {}
				local real_run_flow = dcr.run_flow
				dcr.run_flow = function(opts, _callback)
					table.insert(run_flow_calls, opts)
				end

				local callback = captured_callback()
				local ok, err = pcall(callback, { args = "registered_target" })
				dcr.run_flow = real_run_flow
				assert.is_true(ok, err)

				assert.are.equal(1, #run_flow_calls)
				assert.are.equal("https://server.example.com/mcp", run_flow_calls[1].server_url)
			end
		)
	end)
end)
