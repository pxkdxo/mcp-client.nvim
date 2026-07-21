-- `commands.lua` registers the `:MCPAuth [server-name]` Ex command and
-- implements pure target-resolution logic: given no argument or an explicit
-- server name, it resolves either a definite target server name or a clear
-- reason why none was chosen (KTD6's "needs authentication" predicate,
-- R2/R5's explicit-name-bypasses-validity rule, R6/KTD5's completion
-- candidate set).
--
-- These specs drive `commands.resolve_target` and `commands.complete`
-- directly against `config._record_hub`-populated state, mirroring how
-- config_spec.lua/health_spec.lua build scenarios without a real connection.

local commands = require("mcp-client.commands")
local config = require("mcp-client.config")

--- Build a minimal fake TokenStore with a fixed `status()` return, matching
--- the shape token_store.lua's real `status()` produces (has_token/expired
--- are the only fields KTD6 cares about).
local function fake_store(status)
	return {
		key = "fake",
		status = function()
			return status
		end,
	}
end

describe("commands (MCPAuth target resolution + completion)", function()
	after_each(function()
		config._reset()
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

		it("explicit valid name resolves regardless of current token validity (R5)", function()
			config._record_hub("valid", {
				url = "https://server.example.com/mcp",
				token_store = fake_store({ has_token = true, expired = false }),
			})

			local name, err = commands.resolve_target("valid")
			assert.are.equal("valid", name)
			assert.is_nil(err)
		end)

		it('no argument, zero eligible servers: reports "nothing to authenticate" (AE2)', function()
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
		it(
			"returns every configured server name that has a token_store, including ones with a valid token (R6, KTD5)",
			function()
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
			end
		)

		it("returns an empty list when no configured server has a token_store", function()
			config._record_hub("local_hub", { url = "http://localhost:9999" })

			local candidates = commands.complete("", ":MCPAuth ", 9)
			assert.are.same({}, candidates)
		end)
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
	end)
end)
