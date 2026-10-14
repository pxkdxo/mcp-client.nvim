-- Server-agnosticism and resilience/auth integration spec.
--
-- Two kinds of coverage:
--
--   * HERMETIC (always runs): client-kind / envelope agnosticism and the
--     fail-closed auth gate -- exercised with local doubles and pure gate
--     checks.
--   * LIVE (skips gracefully when the endpoint is unreachable): protocol
--     parity against ravitemer/mcp-hub (:40032) and samanhappy/mcphub (:3000),
--     and the successful-auth path against a self-signed-TLS non-localhost
--     double. The two hubs are complementary, not redundant: ravitemer covers
--     the legacy-SSE transport and a strict-JSON edge case; samanhappy covers
--     Streamable HTTP and is the more actively maintained of the two, but
--     neither alone exercises everything this client needs to validate.
--
-- Every live block probes reachability first and skips with a visible reason
-- (pending("...")) rather than hard-failing, so the suite stays green without
-- those external processes running. See tests/helpers/live_backends.lua.
--
-- This spec only ever contacts the two sanctioned validation endpoints
-- (:40032, :3000) and locally-bound loopback aliases.

local client = require("mcp-client.client")
local tls = require("mcp-client.transport.tls")
local live_backends = require("tests.helpers.live_backends")
local wait_for = require("tests.helpers.wait")
local non_localhost = require("tests.fixtures.non_localhost_server_double")

--- A minimal remote-shaped client double: its request() callback delivers the
--- full JSON-RPC envelope (`{ jsonrpc, id, result = {...} }`), exactly as the
--- real remote transports (streamable_http, legacy_sse) do, so adapters must
--- unwrap `result.result` rather than reading `result` directly. Callbacks
--- fire on a deferred vim.schedule to match remote clients' always-async
--- contract.
local function make_enveloped_remote_double(name, listing)
	local obj = {
		id = "envelope-double-" .. name,
		name = name,
	}
	function obj:is_stopped()
		return false
	end
	function obj:request(rpc_message, callback)
		vim.schedule(function()
			local payload
			if rpc_message.method == "tools/list" then
				payload = { tools = listing }
			elseif rpc_message.method == "tools/call" then
				payload = { content = { { type = "text", text = "called:" .. tostring(rpc_message.params.name) } } }
			else
				return callback("unsupported: " .. tostring(rpc_message.method), nil, nil)
			end
			-- The remote envelope shape: payload nested under `result`.
			callback(nil, { jsonrpc = "2.0", id = rpc_message.id, result = payload }, nil)
		end)
	end
	function obj:notify() end
	function obj:disconnect() end
	return obj
end

describe("server-agnosticism: adapters are agnostic to the result envelope", function()
	after_each(function()
		client._reset_registry()
		vim.wait(30, function()
			return false
		end)
	end)

	it("Avante adapter reads tools from a remote (enveloped) client, not just a native one", function()
		local avante = require("mcp-client.adapters.avante")
		client.register_native(make_enveloped_remote_double("remote-server", {
			{ name = "enveloped_tool", description = "d", inputSchema = { type = "object" } },
		}))

		-- First call kicks off the async tools/list; the listing lands on a later call.
		avante.custom_tools()
		assert.is_true(
			wait_for(function()
				for _, t in ipairs(avante.custom_tools()) do
					if t.name == "mcp_remote-server__enveloped_tool" then
						return true
					end
				end
				return false
			end, 2000),
			"Avante adapter must surface a tool from an enveloped remote client"
		)
	end)

	it("CodeCompanion adapter reads tools from a remote (enveloped) client", function()
		-- Stub CodeCompanion's modules so refresh() publishes into a fake registry.
		local registered = {}
		package.loaded["codecompanion.mcp"] = {
			register_tools = function(server_name, tools, _group)
				registered[server_name] = tools
			end,
			unregister_tools = function(server_name)
				registered[server_name] = nil
			end,
			get_registered_tools = function()
				return registered
			end,
		}
		package.loaded["codecompanion.config"] = { interactions = { chat = { editor_context = {} } } }
		package.loaded["mcp-client.adapters.codecompanion"] = nil
		local cc = require("mcp-client.adapters.codecompanion")

		local double = make_enveloped_remote_double("remote-server-cc", {
			{ name = "cc_enveloped_tool", description = "d", inputSchema = { type = "object" } },
		})
		client.register_native(double)

		-- refresh() kicks off the async tools/list and publishes synchronously from
		-- whatever is cached; call it once to trigger the request, wait for the
		-- reply, then again to publish the now-cached listing. Don't call it inside
		-- the poll loop -- it does synchronous republish work on every call.
		cc.exports.refresh()
		vim.wait(500, function()
			return false
		end)
		cc.exports.refresh()
		assert.is_true(
			wait_for(function()
				-- registered is keyed by client id -> { [prefixed_tool_name] = spec }.
				local tools = registered[double.id] or {}
				for name in pairs(tools) do
					if tostring(name):find("cc_enveloped_tool", 1, true) then
						return true
					end
				end
				return false
			end, 2000),
			"CodeCompanion adapter must publish a tool from an enveloped remote client"
		)

		package.loaded["codecompanion.mcp"] = nil
		package.loaded["codecompanion.config"] = nil
		package.loaded["mcp-client.adapters.codecompanion"] = nil
	end)
end)

describe("server-agnosticism: live protocol parity [skips if server unreachable]", function()
	after_each(function()
		client._reset_registry()
		vim.wait(30, function()
			return false
		end)
	end)

	it("ravitemer/mcp-hub (:40032): connect, tools/list, clean disconnect", function()
		if not live_backends.ravitemer_reachable() then
			pending("ravitemer/mcp-hub validation instance (localhost:40032) is not reachable; skipping live check")
			return
		end

		local got
		client.connect({ url = live_backends.RAVITEMER_MCP_HUB_URL, name = "ravitemer-parity" }, {
			on_connect = function(c, e)
				got = { c = c, e = e }
			end,
		})
		assert.is_true(
			wait_for(function()
				return got ~= nil
			end, 12000),
			"connect to :40032 did not settle"
		)
		assert.is_nil(got.e, "connect error: " .. tostring(got.e))
		-- This server speaks the legacy two-endpoint SSE transport.
		assert.are.equal("legacy_sse", got.c.transport)

		-- params must encode as a JSON object (vim.empty_dict()), not `[]` --
		-- this server rejects an empty array here.
		local reply
		got.c:request(
			{ jsonrpc = "2.0", id = 2, method = "tools/list", params = vim.empty_dict() },
			function(err, result)
				reply = { err = err, result = result }
			end
		)
		assert.is_true(
			wait_for(function()
				return reply ~= nil
			end, 12000),
			"tools/list did not settle"
		)
		assert.is_nil(reply.err, "tools/list error: " .. tostring(reply.err))
		-- Remote clients deliver the full JSON-RPC envelope: payload under result.result.
		local tools = reply.result and reply.result.result and reply.result.result.tools
		assert.is_table(tools)
		assert.is_true(#tools > 0, "expected a non-empty tool listing from the real server")

		got.c:disconnect()
		assert.is_true(
			wait_for(function()
				return got.c:is_stopped()
			end, 3000),
			"client did not report stopped after disconnect"
		)
	end)

	it("samanhappy/mcphub (:3000): identical connect+list behavior through the same code path", function()
		if not live_backends.samanhappy_reachable() then
			pending("samanhappy/mcphub container (localhost:3000) is not reachable; skipping live check")
			return
		end
		if not live_backends.samanhappy_mcp_reachable() then
			-- The container only mounts /mcp and /sse routes after its upstream
			-- servers finish initializing; if any configured upstream fails, no MCP
			-- route is ever mounted even though the dashboard stays reachable.
			pending("samanhappy/mcphub exposes no mounted MCP endpoint; skipping live MCP parity against it")
			return
		end

		-- The same client.connect code path (no server-specific branch) must
		-- connect and list tools here. samanhappy serves Streamable HTTP on
		-- /mcp/<group>; $smart routes across all configured servers.
		local url = live_backends.SAMANHAPPY_BASE_URL .. "/mcp/$smart"
		local got
		client.connect({ url = url, name = "samanhappy-parity" }, {
			on_connect = function(c, e)
				got = { c = c, e = e }
			end,
		})
		assert.is_true(
			wait_for(function()
				return got ~= nil
			end, 12000),
			"connect to samanhappy MCP endpoint did not settle"
		)
		assert.is_nil(got.e, "connect error: " .. tostring(got.e))
		assert.is_not_nil(got.c)

		local reply
		got.c:request(
			{ jsonrpc = "2.0", id = 2, method = "tools/list", params = vim.empty_dict() },
			function(err, result)
				reply = { err = err, result = result }
			end
		)
		assert.is_true(wait_for(function()
			return reply ~= nil
		end, 12000))
		assert.is_nil(reply.err, "tools/list error: " .. tostring(reply.err))

		got.c:disconnect()
	end)
end)

describe("resilience: connection loss is a visible failure, never a hang", function()
	-- The bounded-reconnect state machine itself is covered by
	-- tests/reconnect_spec.lua and tests/client_spec.lua against a controllable
	-- local double. Here we (a) re-assert the no-hang property through the
	-- public client API against a local double, and (b) do a live
	-- normal-operation confirmation against :40032 when reachable.

	after_each(function()
		client._reset_registry()
		vim.wait(30, function()
			return false
		end)
	end)

	it("a caller-visible disconnect makes is_stopped() true and never hangs (public API)", function()
		local HttpDouble = require("tests.helpers.http_double")
		local double = HttpDouble.new({
			on_request = function()
				return { status = 200, body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = {} }) }
			end,
		})
		local got
		client.connect({ url = double.url .. "/mcp", name = "resilience-local" }, {
			on_connect = function(c, e)
				got = { c = c, e = e }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end, 3000))
		assert.is_nil(got.e)

		-- An explicit disconnect is the caller-visible failure path: it must resolve
		-- to a terminal stopped state promptly, not hang.
		got.c:disconnect()
		assert.is_true(
			wait_for(function()
				return got.c:is_stopped()
			end, 3000),
			"client must reach a terminal stopped state, not hang"
		)
		-- A request after disconnect fails fast rather than hanging forever.
		local reply
		got.c:request({ jsonrpc = "2.0", id = 9, method = "ping", params = vim.empty_dict() }, function(err, result)
			reply = { err = err, result = result }
		end)
		assert.is_true(
			wait_for(function()
				return reply ~= nil
			end, 2000),
			"a request on a stopped client must fail fast, not hang"
		)
		assert.is_not_nil(reply.err)
		double:stop()
	end)

	it("live :40032 normal-operation lifecycle (connect -> disconnect) completes bounded", function()
		if not live_backends.ravitemer_reachable() then
			pending("ravitemer/mcp-hub (localhost:40032) not reachable; skipping live lifecycle check")
			return
		end
		local got
		client.connect({ url = live_backends.RAVITEMER_MCP_HUB_URL, name = "resilience-live-normal" }, {
			on_connect = function(c, e)
				got = { c = c, e = e }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end, 12000))
		assert.is_nil(got.e)
		got.c:disconnect()
		assert.is_true(
			wait_for(function()
				return got.c:is_stopped()
			end, 3000),
			"clean disconnect from the real server must complete, not hang"
		)
	end)
end)

describe("auth/TLS for non-localhost servers", function()
	-- The gate is a pure policy check, so the fail-closed assertions run
	-- everywhere (no server needed). The successful-auth path needs a real
	-- self-signed-TLS non-localhost server, which is best-effort (a bindable
	-- non-localhost loopback alias + node + openssl); it skips gracefully when
	-- the platform can't provide one -- see
	-- tests/fixtures/non_localhost_server_double.lua.

	after_each(function()
		client._reset_registry()
		vim.wait(30, function()
			return false
		end)
	end)

	it("fail-closed: a non-localhost http (no TLS, no token) server is refused before connecting", function()
		local connected, err
		client.connect({ url = "http://198.51.100.7:8080/mcp" }, {
			on_connect = function(c, e)
				connected, err = c, e
			end,
		})
		assert.is_true(wait_for(function()
			return connected ~= nil or err ~= nil
		end, 2000))
		assert.is_nil(connected)
		assert.matches("fail closed", err)
	end)

	it("fail-closed: a non-localhost https server with no token is refused (missing auth)", function()
		local connected, err
		client.connect({ url = "https://198.51.100.7/mcp" }, {
			on_connect = function(c, e)
				connected, err = c, e
			end,
		})
		assert.is_true(wait_for(function()
			return connected ~= nil or err ~= nil
		end, 2000))
		assert.is_nil(connected)
		assert.matches("auth", err)
	end)

	it("a loopback alias other than 127.0.0.1 is treated as non-localhost by the gate", function()
		-- 127.0.0.2 is NOT exempt from the fail-closed gate.
		assert.is_false(tls.is_localhost("http://127.0.0.2:9000/mcp"))
		local ok = tls.check_connection_allowed("http://127.0.0.2:9000/mcp", { has_token = false })
		assert.is_false(ok)
	end)

	describe("against a self-signed-TLS non-localhost double [skips if unavailable]", function()
		local double
		local saved_ca

		before_each(function()
			double = non_localhost.start()
			if double.available then
				-- Trust the double's self-signed cert for the plugin's underlying
				-- curl (test-only; the transport itself never sets --insecure).
				saved_ca = vim.env.CURL_CA_BUNDLE
				vim.env.CURL_CA_BUNDLE = double.cafile
			end
		end)

		after_each(function()
			if double and double.available then
				vim.env.CURL_CA_BUNDLE = saved_ca
			end
			if double then
				double.stop()
				double = nil
			end
			client._reset_registry()
			vim.wait(30, function()
				return false
			end)
		end)

		it("successful-auth: https + configured bearer connects and the bearer is on the wire", function()
			if not double.available then
				pending(
					"non-localhost TLS double unavailable (" .. tostring(double.reason) .. "); skipping live auth path"
				)
				return
			end

			local got
			client.connect({
				url = double.url,
				name = "tls-auth",
				headers = { ["Authorization"] = "Bearer THE-TEST-TOKEN" },
			}, {
				on_connect = function(c, e)
					got = { c = c, e = e }
				end,
			})
			assert.is_true(
				wait_for(function()
					return got ~= nil
				end, 8000),
				"connect to the non-localhost TLS double did not settle"
			)
			assert.is_nil(got.e, "successful-auth connect error: " .. tostring(got.e))
			assert.is_not_nil(got.c)

			-- The bearer must have reached the server over the real TLS connection.
			local reqs = double.requests()
			assert.is_true(#reqs > 0, "the double received no request")
			local saw_bearer = false
			for _, r in ipairs(reqs) do
				if r.auth == "Bearer THE-TEST-TOKEN" then
					saw_bearer = true
				end
			end
			assert.is_true(saw_bearer, "the configured bearer token was not attached to the outbound request")

			got.c:disconnect()
		end)

		it("fail-closed against the SAME non-localhost host: https with no token is refused", function()
			if not double.available then
				pending("non-localhost TLS double unavailable (" .. tostring(double.reason) .. "); skipping")
				return
			end
			-- Same real non-localhost https URL, but no configured token: refused
			-- before any request reaches the server.
			local before = #double.requests()
			local connected, err
			client.connect({ url = double.url }, {
				on_connect = function(c, e)
					connected, err = c, e
				end,
			})
			assert.is_true(wait_for(function()
				return connected ~= nil or err ~= nil
			end, 2000))
			assert.is_nil(connected)
			assert.matches("fail closed", err)
			-- Crucially, no request was sent to the server (fail-closed = no wire I/O).
			assert.are.equal(before, #double.requests())
		end)
	end)
end)
