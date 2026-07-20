local HttpDouble = require("tests.helpers.http_double")
local ControllableSse = require("tests.helpers.controllable_sse")
local wait_for = require("tests.helpers.wait")

local client = require("mcphub-neovim.client")

--- Client-layer specs. These exercise the composed session + reconnect +
--- transport stack end to end against a real socket-level test double,
--- driving the client through the state transitions the brief enumerates.
--- Every "no hang" assertion is proven by `wait_for`'s bounded timeout: if
--- the machine ever left a caller hanging, these would time out and fail
--- rather than pass.

local function initialize_result_body(session_id)
	return vim.json.encode({
		jsonrpc = "2.0",
		id = 1,
		result = {
			protocolVersion = "2025-03-26",
			capabilities = {},
			serverInfo = { name = "test-hub", version = "0.0.1", session = session_id },
		},
	})
end

local function collect_autocmd(pattern)
	local seen = {}
	local id = vim.api.nvim_create_autocmd("User", {
		pattern = pattern,
		callback = function(ev)
			table.insert(seen, ev.data and ev.data.client_id)
		end,
	})
	return seen, id
end

describe("client (session + reconnect + event API)", function()
	local double
	local autocmd_ids = {}

	after_each(function()
		-- Tear the registry down *first*: intentional_close fires deferred
		-- MCPDetach autocmds via vim.schedule. Flush them here, while this
		-- test's autocmds are still registered, so a teardown event can never
		-- leak into the next spec's collectors and contaminate its assertions.
		client._reset_registry()
		vim.wait(50, function()
			return false
		end)
		for _, id in ipairs(autocmd_ids) do
			pcall(vim.api.nvim_del_autocmd, id)
		end
		autocmd_ids = {}
		if double then
			double:stop()
			double = nil
		end
	end)

	local function on_autocmd(pattern)
		local seen, id = collect_autocmd(pattern)
		table.insert(autocmd_ids, id)
		return seen
	end

	it("connects over streamable_http and exposes a queryable client object", function()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json", ["Mcp-Session-Id"] = "sess-1" },
						body = initialize_result_body("sess-1"),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local attached = on_autocmd("MCPAttach")

		local got
		client.connect({ url = double.url .. "/mcp", name = "hubA" }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})

		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)
		assert.is_not_nil(got.client)
		assert.are.equal("hubA", got.client.name)
		assert.is_false(got.client:is_stopped())

		-- get_clients() reflects it, filterable by name.
		local all = client.get_clients()
		assert.are.equal(1, #all)
		assert.are.equal(got.client.id, all[1].id)
		local by_name = client.get_clients({ name = "hubA" })
		assert.are.equal(1, #by_name)

		-- MCPAttach fired with the client id.
		assert.is_true(wait_for(function()
			return #attached >= 1
		end))
		assert.are.equal(got.client.id, attached[1])

		got.client:disconnect()
	end)

	it("does a real request/response round-trip over the legacy SSE transport", function()
		local sse = ControllableSse.new()
		double = HttpDouble.new({
			on_request = function(method, path, rest)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" } -- force legacy fallback
				end
				if method == "GET" and path == "/mcp" then
					return sse:sse_handler("/messages?sessionId=legacy-1")
				end
				if method == "POST" and path:match("^/messages") then
					-- Accept the JSON-RPC request, then push the result over SSE.
					local ok, decoded = pcall(vim.json.decode, rest)
					if ok and decoded.id then
						sse:push_message({ jsonrpc = "2.0", id = decoded.id, result = { pong = true } })
					end
					return { status = 202, body = "" }
				end
				return { status = 404, body = "" }
			end,
		})

		local got
		client.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)
		assert.are.equal("legacy_sse", got.client.transport)

		local reply
		got.client:request({ jsonrpc = "2.0", id = 99, method = "ping", params = {} }, function(err, result)
			reply = { err = err, result = result }
		end)

		assert.is_true(wait_for(function()
			return reply ~= nil
		end))
		assert.is_nil(reply.err)
		assert.are.same({ pong = true }, reply.result.result)

		got.client:disconnect()
	end)

	it("fires MCPNotify when the hub pushes an unsolicited notification", function()
		local sse = ControllableSse.new()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					return sse:sse_handler("/messages?sessionId=legacy-1")
				end
				return { status = 202, body = "" }
			end,
		})

		local notified = on_autocmd("MCPNotify")

		local got
		client.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)

		-- Server-originated notification: a JSON-RPC message with a method and
		-- no id (nothing the client requested).
		sse:push_message({ jsonrpc = "2.0", method = "notifications/message", params = { level = "info" } })

		assert.is_true(wait_for(function()
			return #notified >= 1
		end))
		assert.are.equal(got.client.id, notified[1])

		got.client:disconnect()
	end)

	it("reinitializes transparently on a session 404 without surfacing an error", function()
		local reinit_seen = false
		double = HttpDouble.new({
			on_request = function(method, path, rest)
				if method == "POST" and path == "/mcp" then
					-- Distinguish the initialize handshake from the ping.
					local ok, decoded = pcall(vim.json.decode, rest)
					if ok and decoded.method == "initialize" then
						local id = reinit_seen and "sess-2" or "sess-1"
						return {
							status = 200,
							headers = { ["Content-Type"] = "application/json", ["Mcp-Session-Id"] = id },
							body = initialize_result_body(id),
						}
					end
					-- A ping on the first session 404s once; after reinit it succeeds.
					if not reinit_seen then
						reinit_seen = true
						return { status = 404, body = "session expired" }
					end
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json" },
						body = vim.json.encode({ jsonrpc = "2.0", id = decoded.id, result = { pong = true } }),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local got
		client.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)

		local reply
		got.client:request({ jsonrpc = "2.0", id = 5, method = "ping", params = {} }, function(err, result)
			reply = { err = err, result = result }
		end)

		assert.is_true(wait_for(function()
			return reply ~= nil
		end))
		assert.is_nil(reply.err)
		assert.are.same({ pong = true }, reply.result.result)
		assert.is_false(got.client:is_stopped())

		got.client:disconnect()
	end)

	it("an intentional disconnect fires MCPDetach and schedules no reconnect", function()
		local sse = ControllableSse.new()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					return sse:sse_handler("/messages?sessionId=legacy-1")
				end
				return { status = 202, body = "" }
			end,
		})

		local detached = on_autocmd("MCPDetach")
		local attached = on_autocmd("MCPAttach")

		local got
		client.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)

		-- The initial connect legitimately fires one MCPAttach; wait for it and
		-- snapshot the count so we can prove no *further* attach fires after
		-- the intentional close (which would betray an erroneous reconnect).
		assert.is_true(wait_for(function()
			return #attached >= 1
		end))
		local attach_count_before_disconnect = #attached

		got.client:disconnect()

		-- Detach fires, is_stopped() flips, and no reconnect is attempted.
		assert.is_true(wait_for(function()
			return #detached >= 1
		end))
		assert.are.equal(got.client.id, detached[1])
		assert.is_true(got.client:is_stopped())

		-- Give any (erroneous) reconnect a chance to fire an attach; it must not.
		vim.wait(300, function()
			return false
		end)
		assert.are.equal(attach_count_before_disconnect, #attached, "intentional close must not schedule a reconnect")
		-- get_clients() reflects the stopped state immediately.
		local q = client.get_clients()
		assert.are.equal(1, #q)
		assert.is_true(q[1]:is_stopped())
	end)

	it("kills the legacy stream via vim.uv.kill with the intentional-close flag set first", function()
		-- Proves the KTD mechanism itself, not just its effects: the client
		-- must (a) set job.user_data.intentional_close = true and (b) call
		-- vim.uv.kill(job:pid(), "sigterm"), in that order, so the exit handler
		-- recognises the teardown. This guards against a regression where the
		-- transport's own close() shutdown masks a broken kill path.
		local sse = ControllableSse.new()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					return sse:sse_handler("/messages?sessionId=legacy-1")
				end
				return { status = 202, body = "" }
			end,
		})

		local kill_calls = {}
		local real_kill = vim.uv.kill
		vim.uv.kill = function(pid, sig)
			table.insert(kill_calls, { pid = pid, sig = sig })
			return real_kill(pid, sig)
		end

		local got
		client.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)
		assert.are.equal("legacy_sse", got.client.transport)

		got.client:disconnect()

		assert.is_true(wait_for(function()
			return #kill_calls >= 1
		end, 2000))
		vim.uv.kill = real_kill

		assert.are.equal("sigterm", kill_calls[1].sig)
		assert.are.equal("number", type(kill_calls[1].pid))
		-- The client ends stopped with no reconnect, which only holds if the
		-- exit handler saw the intentional-close flag that disconnect() set
		-- before this kill.
		assert.is_true(got.client:is_stopped())
	end)

	it("reconnects a dropped legacy stream within the bounded attempts", function()
		local sse = ControllableSse.new()
		local get_count = 0
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					get_count = get_count + 1
					return sse:sse_handler("/messages?sessionId=legacy-1")
				end
				return { status = 202, body = "" }
			end,
		})

		local detached = on_autocmd("MCPDetach")

		local got
		client.connect({ url = double.url .. "/mcp", reconnect = { initial_delay = 20, max_attempts = 3 } }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)
		assert.are.equal(1, get_count)

		-- Drop the stream from the server side; the client should reconnect.
		sse:drop()

		assert.is_true(wait_for(function()
			return get_count >= 2
		end, 3000))
		-- A successful reconnect means it never reached the disconnected state.
		assert.are.equal(0, #detached)
		assert.is_false(got.client:is_stopped())

		got.client:disconnect()
	end)

	it("honors a server-sent SSE retry: hint over the computed backoff", function()
		local sse = ControllableSse.new()
		local get_count = 0
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					get_count = get_count + 1
					return sse:sse_handler("/messages?sessionId=legacy-1")
				end
				return { status = 202, body = "" }
			end,
		})

		local got
		-- Computed initial backoff is a tiny 20ms; the server's 500ms retry hint
		-- must win, so no reconnect GET may fire during the computed window.
		client.connect({ url = double.url .. "/mcp", reconnect = { initial_delay = 20, max_attempts = 3 } }, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)
		assert.are.equal(1, get_count)

		-- Server sends a retry hint, then drops.
		sse:push_retry(500)
		vim.wait(50, function()
			return false
		end) -- let the retry frame arrive before the drop
		sse:drop()

		-- Within the computed 20ms window (well before 500ms) no reconnect fires:
		-- the hint, not the computed backoff, governs the delay.
		vim.wait(200, function()
			return get_count >= 2
		end)
		assert.are.equal(1, get_count, "retry: hint must delay the reconnect past the computed backoff")

		-- After the hinted delay elapses, the reconnect does happen.
		assert.is_true(wait_for(function()
			return get_count >= 2
		end, 2000))

		got.client:disconnect()
	end)

	it("exhausts reconnect attempts, fires MCPDetach, and fails in-flight requests (no hang)", function()
		local sse = ControllableSse.new()
		local allow_get = true
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					if allow_get then
						return sse:sse_handler("/messages?sessionId=legacy-1")
					end
					-- Reconnect attempts fail: no stream, connection refused shape.
					return { status = 500, body = "" }
				end
				-- Requests posted while disconnected never get an SSE reply.
				return { status = 202, body = "" }
			end,
		})

		local detached = on_autocmd("MCPDetach")

		local got
		client.connect({
			url = double.url .. "/mcp",
			-- Short delays + a short per-attempt timeout keep the test fast
			-- while still driving the full exhaust path. The short
			-- attempt_timeout also directly exercises the guard that turns a
			-- silently-stalled handshake (the 500-on-GET below never yields an
			-- endpoint event) into a counted failure instead of a hang.
			reconnect = { initial_delay = 20, max_attempts = 2 },
			attempt_timeout = 150,
		}, {
			on_connect = function(c, err)
				got = { client = c, err = err }
			end,
		})
		assert.is_true(wait_for(function()
			return got ~= nil
		end))
		assert.is_nil(got.err)

		-- From now on, reconnect GETs stall (500, no endpoint event).
		allow_get = false

		-- Fire an in-flight request that can never be answered, then drop.
		local reply
		got.client:request({ jsonrpc = "2.0", id = 1, method = "ping", params = {} }, function(err, result)
			reply = { err = err, result = result }
		end)

		sse:drop()

		-- Attempts exhaust -> MCPDetach fires and the in-flight request
		-- resolves with an error rather than hanging forever.
		assert.is_true(wait_for(function()
			return #detached >= 1
		end, 5000))
		assert.are.equal(got.client.id, detached[1])
		assert.is_true(got.client:is_stopped())

		assert.is_true(wait_for(function()
			return reply ~= nil
		end, 5000))
		assert.is_not_nil(reply.err)
		assert.is_nil(reply.result)
	end)

	describe("the exposed client object's .config never leaks the live bearer token", function()
		-- token_store.apply_to_headers mutates entry.config.headers in place,
		-- writing headers["Authorization"] = "Bearer " .. access_token. Before
		-- this fix, make_client_object aliased obj.config = entry.config
		-- directly, so any reader of the public client object's .config.headers
		-- saw the real, live secret -- the one surface in this codebase that did
		-- NOT follow the "never expose the raw token, only redacted status"
		-- convention TokenStore:status()/health.lua establish everywhere else.
		local token_store = require("mcphub-neovim.auth.token_store")

		local double
		local tmp

		after_each(function()
			client._reset_registry()
			vim.wait(30, function()
				return false
			end)
			if double then
				double:stop()
				double = nil
			end
			if tmp then
				vim.fn.delete(tmp, "rf")
				tmp = nil
			end
		end)

		local function make_tmpdir()
			local dir = vim.fn.tempname()
			vim.fn.mkdir(dir, "p")
			return dir
		end

		it("redacts Authorization in exposed config.headers; the real request still carries the bearer", function()
			tmp = make_tmpdir()
			local store = token_store.new({ key = "hubSecret", backend = "file", data_home = tmp })
			store:save({
				access_token = "SECRET-live-access-token",
				token_type = "Bearer",
				expires_at = os.time() + 3600, -- not expired: no refresh path involved
			})

			local seen_auth_on_wire
			double = HttpDouble.new({
				on_request = function(method, path, rest, head)
					if method == "POST" and path == "/mcp" then
						local ok, decoded = pcall(vim.json.decode, rest)
						if ok and decoded.method == "initialize" then
							return { status = 200, body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = {} }) }
						end
						seen_auth_on_wire = head and head:match("[Aa]uthorization:%s*([^\r\n]+)")
						return {
							status = 200,
							body = vim.json.encode({ jsonrpc = "2.0", id = decoded.id, result = { pong = true } }),
						}
					end
					return { status = 404, body = "" }
				end,
			})

			local got
			client.connect({
				url = double.url .. "/mcp",
				name = "hubSecret",
				auth = { token_store = store },
			}, {
				on_connect = function(c, e)
					got = { client = c, err = e }
				end,
			})
			assert.is_true(wait_for(function()
				return got ~= nil
			end, 3000))
			assert.is_nil(got.err)

			-- The publicly exposed client object's .config must never surface the
			-- real bearer token: this is the core assertion this test exists to
			-- prove.
			assert.is_not_nil(got.client.config)
			assert.is_not_nil(got.client.config.headers)
			assert.are_not.equal("Bearer SECRET-live-access-token", got.client.config.headers["Authorization"])
			-- No token material anywhere in the exposed config, however nested.
			local dumped = vim.inspect(got.client.config)
			assert.is_nil(dumped:find("SECRET-live-access-token", 1, true))

			-- get_clients() returns the same exposed shape (it's the same object),
			-- so the leak-free guarantee holds for every caller of get_clients()
			-- too, not just the on_connect callback's object.
			local from_registry = client.get_clients({ name = "hubSecret" })[1]
			assert.is_not_nil(from_registry)
			local dumped_registry = vim.inspect(from_registry.config)
			assert.is_nil(dumped_registry:find("SECRET-live-access-token", 1, true))

			-- Non-secret introspection fields remain genuinely useful.
			assert.are.equal(double.url .. "/mcp", got.client.config.url)

			-- Meanwhile the REAL request on the wire still authenticates with the
			-- real bearer token -- the redaction must not touch the transport's
			-- actual internal headers.
			local reply
			got.client:request({ jsonrpc = "2.0", id = 42, method = "ping", params = {} }, function(err, result)
				reply = { err = err, result = result }
			end)
			assert.is_true(wait_for(function()
				return reply ~= nil
			end, 3000))
			assert.is_nil(reply.err)
			assert.are.same({ pong = true }, reply.result.result)
			assert.are.equal("Bearer SECRET-live-access-token", seen_auth_on_wire)

			got.client:disconnect()
		end)

		it(
			"keeps redaction current: headers added after client creation stay redacted, not a stale snapshot",
			function()
				tmp = make_tmpdir()
				local store = token_store.new({ key = "hubSecret2", backend = "file", data_home = tmp })
				store:save({
					access_token = "SECRET-token-v1",
					token_type = "Bearer",
					expires_at = os.time() + 3600,
				})

				double = HttpDouble.new({
					on_request = function(_, _, rest)
						local ok, decoded = pcall(vim.json.decode, rest or "")
						local id = ok and decoded.id or 1
						return { status = 200, body = vim.json.encode({ jsonrpc = "2.0", id = id, result = {} }) }
					end,
				})

				local got
				client.connect({
					url = double.url .. "/mcp",
					name = "hubSecret2",
					auth = { token_store = store },
				}, {
					on_connect = function(c, e)
						got = { client = c, err = e }
					end,
				})
				assert.is_true(wait_for(function()
					return got ~= nil
				end, 3000))
				assert.is_nil(got.err)

				-- Simulate a later token rotation writing a NEW real token into the
				-- live, shared headers table (exactly what token_store.apply_to_headers
				-- does on refresh) -- this must never surface through the exposed
				-- object either, proving the redaction is not a one-time snapshot that
				-- could go stale.
				token_store.apply_to_headers(got.client.config.headers, { access_token = "SECRET-token-v2" })

				assert.are_not.equal("Bearer SECRET-token-v2", got.client.config.headers["Authorization"])
				local dumped = vim.inspect(got.client.config)
				assert.is_nil(dumped:find("SECRET-token-v1", 1, true))
				assert.is_nil(dumped:find("SECRET-token-v2", 1, true))

				got.client:disconnect()
			end
		)
	end)
end)
