-- Covers R12 fail-closed transport security and the token-refresh lifecycle:
--
--   * transport/tls.lua's URL-scheme + credential-presence gate:
--       - a non-localhost hub with no TLS and/or no token is refused (R12);
--       - a localhost hub is unaffected and proceeds.
--   * auth/refresh.lua's refresh-token grant:
--       - an expired access token is refreshed transparently before retry;
--       - a rotated refresh token is stored;
--       - a revoked refresh token surfaces a terminal re-auth-required error
--         rather than retrying indefinitely, and never leaks the token.
--   * bearer attachment on the wire: a request through a transport carrying an
--     Authorization header actually sends it (via a loopback HTTP double).

local tls = require("mcphub-neovim.transport.tls")
local refresh = require("mcphub-neovim.auth.refresh")
local client = require("mcphub-neovim.client")

local HttpDouble = require("tests.helpers.http_double")
local wait_for = require("tests.helpers.wait")

describe("transport.tls fail-closed gate (R12)", function()
	local function has_token()
		return { has_token = true }
	end
	local function no_token()
		return { has_token = false }
	end

	describe("localhost is unaffected", function()
		it("allows http://127.0.0.1 with no token and no TLS", function()
			local ok, reason = tls.check_connection_allowed("http://127.0.0.1:8080/mcp", no_token())
			assert.is_true(ok, reason)
		end)

		it("allows http://localhost with no token and no TLS", function()
			assert.is_true(tls.check_connection_allowed("http://localhost:3000/mcp", no_token()))
		end)

		it("allows http://[::1] (IPv6 loopback) with no token and no TLS", function()
			assert.is_true(tls.check_connection_allowed("http://[::1]:9000/mcp", no_token()))
		end)
	end)

	describe("non-localhost is fail-closed", function()
		it("refuses a non-localhost http:// URL even with a token (no TLS)", function()
			local ok, reason = tls.check_connection_allowed("http://hub.example.com/mcp", has_token())
			assert.is_false(ok)
			assert.is_string(reason)
			assert.matches("TLS", reason)
		end)

		it("refuses a non-localhost https:// URL with no token (no auth)", function()
			local ok, reason = tls.check_connection_allowed("https://hub.example.com/mcp", no_token())
			assert.is_false(ok)
			assert.is_string(reason)
			-- Names the missing credential, not a generic "failed".
			assert.matches("auth", reason)
		end)

		it("refuses a non-localhost http:// URL with no token (both missing)", function()
			local ok, reason = tls.check_connection_allowed("http://hub.example.com/mcp", no_token())
			assert.is_false(ok)
			assert.is_string(reason)
		end)

		it("allows a non-localhost https:// URL WITH a token", function()
			local ok, reason = tls.check_connection_allowed("https://hub.example.com/mcp", has_token())
			assert.is_true(ok, reason)
		end)

		it("treats a bare loopback-looking hostname (127.0.0.2) as non-localhost", function()
			-- Only the canonical loopback names/addresses are exempt; a different
			-- 127.0.0.0/8 alias is still a real network address for R12 purposes
			-- unless it is exactly 127.0.0.1. (U9 validates the live cert case.)
			local ok = tls.check_connection_allowed("http://127.0.0.2/mcp", no_token())
			assert.is_false(ok)
		end)
	end)

	describe("the refusal reason never contains a secret", function()
		it("does not echo any token material in the refusal string", function()
			local _, reason = tls.check_connection_allowed("http://hub.example.com/mcp", {
				has_token = true,
				-- Even if a caller (wrongly) passed the value, tls must not echo it.
				access_token = "SECRET-should-never-appear",
			})
			assert.is_nil(reason:find("SECRET-should-never-appear", 1, true))
		end)
	end)
end)

describe("client.connect enforces the fail-closed gate (R12)", function()
	after_each(function()
		client._reset_registry()
		vim.wait(30, function()
			return false
		end)
	end)

	it("refuses a non-localhost hub with no TLS and no auth, before opening a connection", function()
		local connected, err
		client.connect({
			-- A non-localhost URL that would connect-refuse at the socket anyway,
			-- but the gate must refuse it FIRST, without ever attempting the POST.
			url = "http://hub.example.com/mcp",
		}, {
			on_connect = function(c, e)
				connected, err = c, e
			end,
		})

		assert.is_true(wait_for(function()
			return connected ~= nil or err ~= nil
		end))
		assert.is_nil(connected)
		assert.is_not_nil(err)
		assert.matches("fail closed", err)
		assert.matches("R12", err)
	end)

	it("refuses a non-localhost https hub when no Authorization header is configured", function()
		local connected, err
		client.connect({
			url = "https://hub.example.com/mcp",
		}, {
			on_connect = function(c, e)
				connected, err = c, e
			end,
		})

		assert.is_true(wait_for(function()
			return connected ~= nil or err ~= nil
		end))
		assert.is_nil(connected)
		assert.matches("auth", err)
	end)

	it("allows a localhost hub with no TLS and no auth (unaffected by the gate)", function()
		-- A real loopback double: the gate must NOT interfere; the connection
		-- proceeds and initializes exactly as before this unit existed.
		local double = HttpDouble.new({
			on_request = function()
				return {
					status = 200,
					body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = { capabilities = {} } }),
				}
			end,
		})

		local connected, err
		client.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(c, e)
				connected, err = c, e
			end,
		})

		assert.is_true(
			wait_for(function()
				return connected ~= nil or err ~= nil
			end, 3000),
			"localhost connect did not settle: " .. tostring(err)
		)
		assert.is_nil(err)
		assert.is_not_nil(connected)
		double:stop()
	end)

	it("the refusal error never contains a token value", function()
		local connected, err
		client.connect({
			url = "https://hub.example.com/mcp",
			headers = { ["X-Other"] = "value" },
		}, {
			on_connect = function(c, e)
				connected, err = c, e
			end,
		})

		assert.is_true(wait_for(function()
			return connected ~= nil or err ~= nil
		end))
		assert.is_nil(connected)
		-- No secret is present here to leak, but assert the shape stays clean.
		assert.is_string(err)
	end)
end)

describe("auth.refresh (refresh-token grant)", function()
	local double

	after_each(function()
		if double then
			double:stop()
			double = nil
		end
	end)

	local function stored_token(overrides)
		return vim.tbl_extend("force", {
			access_token = "old-access-token",
			refresh_token = "the-refresh-token",
			token_type = "Bearer",
			expires_at = os.time() - 1, -- expired
			scope = "mcp",
			token_endpoint = nil, -- set per test to the double's URL
			client_id = "the-client-id",
			resource = "https://hub.example/mcp",
		}, overrides or {})
	end

	it("POSTs grant_type=refresh_token and returns a fresh typed token", function()
		local received_body
		double = HttpDouble.new({
			on_request = function(method, path, rest)
				if method == "POST" and path == "/token" then
					received_body = rest
					return {
						status = 200,
						body = vim.json.encode({
							access_token = "new-access-token",
							refresh_token = "rotated-refresh-token",
							token_type = "Bearer",
							expires_in = 3600,
							scope = "mcp",
						}),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local result, err
		refresh.refresh(stored_token({ token_endpoint = double.url .. "/token" }), function(res, e)
			result, err = res, e
		end)

		assert.is_true(wait_for(function()
			return result ~= nil or err ~= nil
		end))
		assert.is_nil(err)
		assert.are.equal("new-access-token", result.access_token)
		-- Public-client refresh-token rotation: the new refresh token replaces
		-- the old one.
		assert.are.equal("rotated-refresh-token", result.refresh_token)
		assert.is_number(result.expires_at)
		-- Metadata for the *next* refresh is preserved.
		assert.are.equal(double.url .. "/token", result.token_endpoint)
		assert.are.equal("the-client-id", result.client_id)
		assert.are.equal("https://hub.example/mcp", result.resource)
		-- The request used the refresh grant, not the authorization-code grant.
		assert.matches("grant_type=refresh_token", received_body, 1, true)
		assert.matches("refresh_token=the%-refresh%-token", received_body)
		assert.is_nil(received_body:find("grant_type=authorization_code", 1, true))
	end)

	it("keeps the previous refresh token when the AS does not rotate it", function()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/token" then
					return {
						status = 200,
						body = vim.json.encode({
							access_token = "new-access-token",
							-- No refresh_token in the response: reuse the old one.
							token_type = "Bearer",
							expires_in = 3600,
						}),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local result, err
		refresh.refresh(stored_token({ token_endpoint = double.url .. "/token" }), function(res, e)
			result, err = res, e
		end)

		assert.is_true(wait_for(function()
			return result ~= nil or err ~= nil
		end))
		assert.is_nil(err)
		assert.are.equal("the-refresh-token", result.refresh_token)
	end)

	it("surfaces a terminal re-auth-required error on a revoked refresh token", function()
		double = HttpDouble.new({
			on_request = function()
				return {
					status = 400,
					body = vim.json.encode({
						error = "invalid_grant",
						error_description = "refresh token revoked",
					}),
				}
			end,
		})

		local result, err
		refresh.refresh(stored_token({ token_endpoint = double.url .. "/token" }), function(res, e)
			result, err = res, e
		end)

		assert.is_true(wait_for(function()
			return result ~= nil or err ~= nil
		end))
		assert.is_nil(result)
		assert.is_not_nil(err)
		-- A distinct "re-authentication required" class, not a retry-forever loop.
		assert.matches("re%-auth", err)
		-- Carries the AS error code for diagnosis.
		assert.matches("invalid_grant", err)
	end)

	it("errors (without leaking the token) when no refresh token is available", function()
		-- vim.tbl_extend drops nil values, so remove the key explicitly to model
		-- a stored token that never carried a refresh token.
		local tok = stored_token({ token_endpoint = "https://as.example/token" })
		tok.refresh_token = nil

		local result, err
		refresh.refresh(tok, function(res, e)
			result, err = res, e
		end)

		assert.is_true(wait_for(function()
			return result ~= nil or err ~= nil
		end))
		assert.is_nil(result)
		assert.matches("re%-auth", err)
	end)

	it("never leaks the refresh token into error text", function()
		double = HttpDouble.new({
			on_request = function()
				return { status = 400, body = vim.json.encode({ error = "invalid_grant" }) }
			end,
		})

		local result, err
		refresh.refresh(
			stored_token({
				refresh_token = "SUPER-SECRET-refresh",
				token_endpoint = double.url .. "/token",
			}),
			function(res, e)
				result, err = res, e
			end
		)

		assert.is_true(wait_for(function()
			return result ~= nil or err ~= nil
		end))
		assert.is_nil(result)
		assert.is_nil(err:find("SUPER-SECRET-refresh", 1, true))
	end)
end)

describe("bearer attachment on the wire (happy path)", function()
	-- The transport doesn't care that 127.0.0.1 is technically localhost for the
	-- header-merge test (per the brief): this exercises that a token applied to a
	-- shared headers table is actually sent on every outbound request.
	local token_store = require("mcphub-neovim.auth.token_store")
	local StreamableHttp = require("mcphub-neovim.transport.streamable_http")

	local double
	after_each(function()
		if double then
			double:stop()
			double = nil
		end
	end)

	it("sends Authorization: Bearer <token> on each request", function()
		local seen_auth = {}
		double = HttpDouble.new({
			on_request = function(method, path, rest, head)
				local auth = head and head:match("[Aa]uthorization:%s*([^\r\n]+)")
				table.insert(seen_auth, auth)
				return { status = 200, body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = {} }) }
			end,
		})

		-- A shared headers table, exactly as client.lua threads config.headers.
		local headers = {}
		token_store.apply_to_headers(headers, {
			access_token = "wire-token",
			token_type = "Bearer",
		})
		local transport = StreamableHttp.new({ url = double.url, headers = headers })

		local done = 0
		transport:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function()
			done = done + 1
		end)
		transport:request({ jsonrpc = "2.0", id = 2, method = "ping" }, function()
			done = done + 1
		end)

		assert.is_true(wait_for(function()
			return done == 2
		end, 3000))
		assert.are.equal(2, #seen_auth)
		assert.are.equal("Bearer wire-token", seen_auth[1])
		assert.are.equal("Bearer wire-token", seen_auth[2])
	end)

	it("reflects a rotated token on the next request through the same table", function()
		local seen_auth = {}
		double = HttpDouble.new({
			on_request = function(method, path, rest, head)
				table.insert(seen_auth, head and head:match("[Aa]uthorization:%s*([^\r\n]+)"))
				return { status = 200, body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = {} }) }
			end,
		})

		local headers = {}
		token_store.apply_to_headers(headers, { access_token = "first", token_type = "Bearer" })
		local transport = StreamableHttp.new({ url = double.url, headers = headers })

		local done = 0
		transport:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function()
			done = done + 1
			-- Rotate in place; the transport reads self.headers each request.
			token_store.apply_to_headers(headers, { access_token = "second", token_type = "Bearer" })
			transport:request({ jsonrpc = "2.0", id = 2, method = "ping" }, function()
				done = done + 1
			end)
		end)

		assert.is_true(wait_for(function()
			return done == 2
		end, 3000))
		assert.are.equal("Bearer first", seen_auth[1])
		assert.are.equal("Bearer second", seen_auth[2])
	end)
end)
