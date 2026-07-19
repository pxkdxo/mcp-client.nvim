-- Covers U7 token persistence and the bearer-header attachment helper.
--
-- Persistence has two backends: an OS keychain (macOS `security` CLI) where a
-- binding is available, and a 0600-permissioned file under $XDG_DATA_HOME as a
-- fallback. These tests exercise the *file* backend against a temp
-- $XDG_DATA_HOME (real file I/O, real permissions -- never the developer's real
-- login keychain), and exercise the keychain backend through an injected
-- command runner so the invocation shape is verified without side effects.
--
-- Security invariant under test throughout: no secret (access token, refresh
-- token) ever appears in a status string or an error message.

local token_store = require("mcphub-neovim.auth.token_store")

local function make_tmpdir()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return dir
end

--- A sample typed token result, shaped like dcr.exchange_code_for_token's.
local function sample_token(overrides)
	local base = {
		access_token = "SECRET-access-token-value",
		refresh_token = "SECRET-refresh-token-value",
		token_type = "Bearer",
		expires_at = os.time() + 3600,
		scope = "mcp",
		token_endpoint = "https://as.example/token",
		client_id = "the-client-id",
		resource = "https://hub.example/mcp",
	}
	return vim.tbl_extend("force", base, overrides or {})
end

describe("auth.token_store", function()
	local tmp

	before_each(function()
		tmp = make_tmpdir()
	end)

	after_each(function()
		if tmp then
			vim.fn.delete(tmp, "rf")
			tmp = nil
		end
	end)

	--- Build a store forced onto the file backend, isolated to a temp dir.
	local function file_store(key)
		return token_store.new({
			key = key or "hub.example",
			backend = "file",
			data_home = tmp,
		})
	end

	describe("file backend round-trip", function()
		it("saves and loads a token result unchanged", function()
			local store = file_store()
			local tok = sample_token()

			local ok, err = store:save(tok)
			assert.is_true(ok, err)

			local loaded = store:load()
			assert.is_not_nil(loaded)
			assert.are.equal(tok.access_token, loaded.access_token)
			assert.are.equal(tok.refresh_token, loaded.refresh_token)
			assert.are.equal(tok.token_type, loaded.token_type)
			assert.are.equal(tok.expires_at, loaded.expires_at)
			assert.are.equal(tok.token_endpoint, loaded.token_endpoint)
			assert.are.equal(tok.client_id, loaded.client_id)
			assert.are.equal(tok.resource, loaded.resource)
		end)

		it("persists across a fresh store instance (survives a Neovim session)", function()
			file_store():save(sample_token())
			-- A brand-new store object for the same key must read it back.
			local loaded = file_store():load()
			assert.is_not_nil(loaded)
			assert.are.equal("SECRET-access-token-value", loaded.access_token)
		end)

		it("returns nil when nothing has been saved yet", function()
			assert.is_nil(file_store("never-saved"):load())
		end)

		it("writes the token file with 0600 permissions", function()
			local store = file_store()
			store:save(sample_token())
			local path = store:path()
			assert.is_not_nil(path)
			-- Octal permission bits, masked to the low 9 (user/group/other rwx).
			local mode = vim.fn.getfperm(path)
			assert.are.equal("rw-------", mode)
		end)

		it("writes the token file outside the repository checkout", function()
			local store = file_store()
			store:save(sample_token())
			local path = store:path()
			-- The temp XDG_DATA_HOME is not inside this repo tree.
			assert.is_nil(path:find("mcphub%-neovim/lua"))
			assert.is_nil(path:find("mcphub%-neovim/tests"))
			assert.is_not_nil(path:find(vim.pesc(tmp), 1))
		end)

		it("clears a persisted token", function()
			local store = file_store()
			store:save(sample_token())
			assert.is_not_nil(store:load())
			store:clear()
			assert.is_nil(store:load())
		end)
	end)

	describe("status (for :checkhealth, U8) never leaks secrets", function()
		it("reports presence and expiry without the token values", function()
			local store = file_store()
			store:save(sample_token())
			local status = store:status()

			assert.is_true(status.has_token)
			assert.is_true(status.has_refresh_token)
			assert.is_number(status.expires_at)
			assert.is_false(status.expired)

			-- The whole serialized status must not contain any secret.
			local blob = vim.inspect(status)
			assert.is_nil(blob:find("SECRET-access-token-value", 1, true))
			assert.is_nil(blob:find("SECRET-refresh-token-value", 1, true))
		end)

		it("reports expired=true once expires_at is in the past", function()
			local store = file_store()
			store:save(sample_token({ expires_at = os.time() - 1 }))
			local status = store:status()
			assert.is_true(status.expired)
		end)

		it("reports has_token=false when nothing is stored", function()
			local status = file_store("empty"):status()
			assert.is_false(status.has_token)
			assert.is_false(status.has_refresh_token)
		end)
	end)

	describe("apply_to_headers (bearer attachment)", function()
		it("sets Authorization: Bearer <token> on a headers table in place", function()
			local headers = { ["X-Existing"] = "keep" }
			token_store.apply_to_headers(headers, sample_token())
			assert.are.equal("Bearer SECRET-access-token-value", headers["Authorization"])
			-- Other headers are untouched.
			assert.are.equal("keep", headers["X-Existing"])
		end)

		it("mutates the same table reference (so a shared headers table rotates)", function()
			local headers = {}
			token_store.apply_to_headers(headers, sample_token())
			token_store.apply_to_headers(headers, sample_token({ access_token = "rotated-token" }))
			assert.are.equal("Bearer rotated-token", headers["Authorization"])
		end)

		it("uses the token_type as the scheme when it is not Bearer", function()
			local headers = {}
			token_store.apply_to_headers(headers, sample_token({ token_type = "DPoP" }))
			assert.are.equal("DPoP SECRET-access-token-value", headers["Authorization"])
		end)

		it("removes Authorization when given nil (cleared token)", function()
			local headers = { ["Authorization"] = "Bearer old" }
			token_store.apply_to_headers(headers, nil)
			assert.is_nil(headers["Authorization"])
		end)
	end)

	describe("keychain backend invocation shape", function()
		it("save/load/clear drive the macOS security CLI with the right args", function()
			-- Injected command runner captures argv and fakes a keychain store,
			-- so the invocation shape is verified without touching the real
			-- login keychain. runner(argv) -> { code = 0, stdout = "..." }.
			local vault = {}
			local seen = {}
			local function runner(argv)
				table.insert(seen, argv)
				local sub = argv[2]
				if sub == "add-generic-password" then
					-- ... -s <service> -a <account> -w <password>
					local svc, acct, pw
					for i = 1, #argv do
						if argv[i] == "-s" then
							svc = argv[i + 1]
						elseif argv[i] == "-a" then
							acct = argv[i + 1]
						elseif argv[i] == "-w" then
							pw = argv[i + 1]
						end
					end
					vault[svc .. "\0" .. acct] = pw
					return { code = 0, stdout = "" }
				elseif sub == "find-generic-password" then
					local svc, acct
					for i = 1, #argv do
						if argv[i] == "-s" then
							svc = argv[i + 1]
						elseif argv[i] == "-a" then
							acct = argv[i + 1]
						end
					end
					local v = vault[svc .. "\0" .. acct]
					if v == nil then
						return { code = 44, stdout = "" } -- SecItemNotFound
					end
					return { code = 0, stdout = v .. "\n" }
				elseif sub == "delete-generic-password" then
					local svc, acct
					for i = 1, #argv do
						if argv[i] == "-s" then
							svc = argv[i + 1]
						elseif argv[i] == "-a" then
							acct = argv[i + 1]
						end
					end
					vault[svc .. "\0" .. acct] = nil
					return { code = 0, stdout = "" }
				end
				return { code = 1, stdout = "" }
			end

			local store = token_store.new({
				key = "hub.example",
				backend = "keychain",
				command_runner = runner,
			})

			local tok = sample_token()
			assert.is_true(store:save(tok))
			local loaded = store:load()
			assert.is_not_nil(loaded)
			assert.are.equal(tok.access_token, loaded.access_token)
			assert.are.equal(tok.refresh_token, loaded.refresh_token)

			store:clear()
			assert.is_nil(store:load())

			-- It used the `security` CLI, and the -U update flag on add.
			assert.are.equal("security", seen[1][1])
			local add = seen[1]
			local has_update = false
			for _, a in ipairs(add) do
				if a == "-U" then
					has_update = true
				end
			end
			assert.is_true(has_update)
		end)
	end)
end)
