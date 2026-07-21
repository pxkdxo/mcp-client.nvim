-- U9 server-agnosticism & resilience/auth integration spec.
--
-- Unlike every prior unit's tests (which use in-repo local doubles only), U9's
-- Approach calls for validating against REAL, externally-running MCP servers. This
-- spec therefore has two kinds of coverage, clearly separated:
--
--   * HERMETIC (always runs): client-kind / envelope agnosticism and the R12
--     fail-closed gate -- exercised with local doubles and pure gate checks, so
--     they run everywhere and act as regression guards for the interop bugs U9
--     surfaced against the real servers.
--   * LIVE (skips gracefully when the endpoint is unreachable): protocol parity
--     against ravitemer/mcp-hub (:40032) and samanhappy/mcphub (:3000), and the
--     R12 successful-auth path against a self-signed-TLS non-localhost double.
--
-- PORTABILITY (binding requirement): a contributor or CI running `make test`
-- will NOT have the two exact external processes (localhost:40032,
-- localhost:3000) running. Every live block probes reachability first and SKIPS
-- with a visible reason (pending("...")) rather than hard-failing, so the full
-- suite stays green for them. See tests/helpers/live_backends.lua.
--
-- SAFETY: this spec only ever contacts the two sanctioned validation endpoints
-- (:40032, :3000) and locally-bound loopback aliases. The user's real,
-- daily-driver server on port 37373 is never referenced anywhere.
--
-- Requirements covered: R9 (server-agnosticism, no server-specific code path),
-- R11 (connection-loss surfaced as a visible failure, adapters degrade -- no
-- hang), R12 (bearer auth + TLS for non-localhost; fail closed without them).

local client = require("mcp-client.client")
local tls = require("mcp-client.transport.tls")
local live_backends = require("tests.helpers.live_backends")
local wait_for = require("tests.helpers.wait")
local non_localhost = require("tests.fixtures.non_localhost_server_double")

--- A minimal remote-shaped client double: its request() callback delivers the
--- FULL JSON-RPC envelope (`{ jsonrpc, id, result = {...} }`), exactly as the
--- real remote transports (streamable_http, legacy_sse) do -- and unlike the
--- older adapter doubles, which returned the unwrapped payload and so never
--- exercised the envelope-unwrapping path. This is the regression guard for the
--- U9-surfaced "adapter reads result.tools but a real server nests it under
--- result.result" bug. request() callbacks fire on a deferred vim.schedule to
--- match remote clients' always-async contract.
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

describe("U9 server-agnosticism: adapters are agnostic to the result envelope (R9)", function()
	after_each(function()
		client._reset_registry()
		vim.wait(30, function()
			return false
		end)
	end)

	it("Avante adapter reads tools from a remote (enveloped) client, not just a native one", function()
		-- Register a remote-shaped double that nests its tools under result.result,
		-- exactly like the real servers. Before the U9 fix the adapter read result.tools
		-- and got nothing; now it unwraps and sees the listing.
		local avante = require("mcp-client.adapters.avante")
		client.register_native(make_enveloped_remote_double("remote-server", {
			{ name = "enveloped_tool", description = "d", inputSchema = { type = "object" } },
		}))

		-- First call kicks off the async tools/list; the listing lands on a later call.
		avante.custom_tools()
		assert.is_true(
			wait_for(function()
				for _, t in ipairs(avante.custom_tools()) do
					if t.name == "enveloped_tool" then
						return true
					end
				end
				return false
			end, 2000),
			"Avante adapter must surface a tool from an enveloped remote client"
		)
	end)

	it("CodeCompanion adapter reads tools from a remote (enveloped) client", function()
		-- Stub CodeCompanion's real modules exactly as the U5 adapter spec does, so
		-- refresh() publishes into a fake registry we can read back.
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

		-- refresh() kicks off the async tools/list; the enveloped reply lands on a
		-- later tick. Call refresh() once to kick off, wait for the reply, then a
		-- second refresh publishes the now-cached listing. (register_tools keys each
		-- published tool by a prefixed name, `mcp_<client>_<tool>`, so match on the
		-- substring.) Do NOT call refresh() inside the poll loop -- refresh() does
		-- synchronous republish work and is meant to be invoked on demand, not hot.
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

describe("U9 server-agnosticism: live protocol parity (R9) [skips if server unreachable]", function()
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
		client.connect({ url = live_backends.RAVITEMER_MCP_HUB_URL, name = "u9-ravitemer" }, {
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
		-- This server speaks the legacy two-endpoint SSE transport (confirmed in U9).
		assert.are.equal("legacy_sse", got.c.transport)

		-- tools/list with an OBJECT params (vim.empty_dict()); a strict server rejects
		-- an empty [] here (the U9-surfaced encoding bug). Expect a real listing.
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
			-- U9 finding: the container's MCP transport routes are registered only
			-- after initUpstreamServers() resolves; if any configured upstream fails
			-- (a Context7 URL blocked by the container's SSRF guard, in the
			-- validation config), that promise rejects and NO /mcp or /sse route is
			-- ever mounted -- every path falls through to the dashboard SPA. So a
			-- reachable dashboard does not imply a reachable MCP endpoint. Skip the
			-- live MCP assertion in that (current) state rather than hard-fail.
			pending(
				"samanhappy/mcphub is up but exposes no mounted MCP endpoint (upstream init failed; "
					.. "see U9 report) -- skipping live MCP parity against it"
			)
			return
		end

		-- If/when the MCP endpoint IS mounted, the SAME client.connect code path
		-- (no server-specific branch) must connect and list tools -- proving genuine
		-- server-agnosticism (R9). samanhappy serves modern Streamable HTTP on
		-- /mcp/<group>; $smart routes across all servers.
		local url = live_backends.SAMANHAPPY_BASE_URL .. "/mcp/$smart"
		local got
		client.connect({ url = url, name = "u9-samanhappy" }, {
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

describe("U9 resilience: connection loss is a visible failure, never a hang (R11)", function()
	-- The generic property -- an abrupt/uncommunicated disconnect drives a bounded
	-- reconnect and, on exhaustion, transitions to `disconnected` while FAILING
	-- (not hanging) in-flight requests -- is already covered deterministically by
	-- U2's own suite against a controllable local double:
	--   * tests/reconnect_spec.lua  (the bounded-backoff state machine)
	--   * tests/client_spec.lua     ("exhausts reconnect attempts, fires MCPDetach,
	--                                 and fails in-flight requests (no hang)")
	-- U9 additionally reproduced the REAL ravitemer/mcp-hub SSE re-entrancy
	-- RangeError crash against a disposable, unpatched mcp-hub@4.2.1 instance and
	-- confirmed the client neither hung nor crashed Neovim (in-flight request
	-- failed with a connection-reset error; client reached is_stopped()==true).
	-- That crash injection is inherently non-repeatable inside `make test` (it
	-- requires spawning and killing an external process), so it is documented in
	-- the U9 report rather than re-run here. Here we (a) re-assert the no-hang
	-- property through the public client API against a local double, and (b) do a
	-- live normal-operation confirmation against :40032 when reachable.

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
		client.connect({ url = double.url .. "/mcp", name = "r11-local" }, {
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
		client.connect({ url = live_backends.RAVITEMER_MCP_HUB_URL, name = "r11-live-normal" }, {
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

describe("U9 auth/TLS for non-localhost servers (R12)", function()
	-- The R12 gate is a pure policy check, so the FAIL-CLOSED assertions run
	-- everywhere (no server needed). The SUCCESSFUL-AUTH path needs a real
	-- self-signed-TLS non-localhost server, which is best-effort (a bindable
	-- non-localhost loopback alias + node + openssl); it skips gracefully when the
	-- platform can't provide one -- see tests/fixtures/non_localhost_server_double.lua.

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
		assert.matches("R12", err)
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
		-- Sanity for the fixture's premise: 127.0.0.2 is NOT exempt from R12.
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
					"non-localhost TLS double unavailable ("
						.. tostring(double.reason)
						.. "); skipping live R12 auth path"
				)
				return
			end

			local got
			client.connect({
				url = double.url,
				name = "r12-auth",
				headers = { ["Authorization"] = "Bearer THE-R12-TOKEN" },
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
				if r.auth == "Bearer THE-R12-TOKEN" then
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
