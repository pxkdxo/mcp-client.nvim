local Session = require("mcp-client.session")

--- The session owns the Mcp-Session-Id / MCP-Protocol-Version header
--- lifecycle, including safe discovery retry and non-replay of tool calls
--- on a session-scoped 404.

--- A transport double: `request(msg, cb)` returns whatever the scripted
--- `responder` yields for that call. `responder(msg, call_index)` returns
--- (err, result, response). Records every message seen for assertions.
local function transport_double(responder)
	local calls = {}
	return {
		calls = calls,
		request = function(_, msg, cb)
			table.insert(calls, msg)
			local err, result, response = responder(msg, #calls)
			cb(err, result, response)
		end,
		notify = function() end,
		close = function() end,
	}
end

describe("session (id/protocol lifecycle + 404 reinitialize)", function()
	it("tracks the session id and protocol version from initialize", function()
		local session = Session.new({
			session_id = "sess-1",
			protocol_version = "2025-03-26",
			transport = transport_double(function()
				return nil, { ok = true }
			end),
			reinitialize = function() end,
		})

		assert.are.equal("sess-1", session.session_id)
		assert.are.equal("2025-03-26", session.protocol_version)
	end)

	it("passes a normal request straight through to the transport", function()
		local session = Session.new({
			transport = transport_double(function()
				return nil, { pong = true }
			end),
			reinitialize = function() end,
		})

		local got_err, got_result
		session:request({ jsonrpc = "2.0", id = 7, method = "ping" }, function(err, result)
			got_err, got_result = err, result
		end)

		assert.is_nil(got_err)
		assert.are.same({ pong = true }, got_result)
	end)

	it("transparently reinitializes on a session 404 and retries the request", function()
		local original_transport = transport_double(function()
			return "server returned status 404: session expired", nil, { status = 404 }
		end)
		local retry_transport = transport_double(function()
			return nil, { pong = true }
		end)

		local reinit_count = 0
		local session = Session.new({
			transport = original_transport,
			session_id = "sess-1",
			reinitialize = function(on_done)
				reinit_count = reinit_count + 1
				on_done(nil, { transport = retry_transport, session_id = "sess-2" })
			end,
		})

		local got_err, got_result
		session:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
			got_err, got_result = err, result
		end)

		assert.are.equal(1, reinit_count)
		assert.is_nil(got_err)
		assert.are.same({ pong = true }, got_result)
		assert.are.equal("sess-2", session.session_id)
		-- The original request was retried against the new transport.
		assert.are.equal(1, #retry_transport.calls)
		assert.are.equal("ping", retry_transport.calls[1].method)
	end)

	it("surfaces a non-404 error without attempting a reinitialize", function()
		local reinit_count = 0
		local session = Session.new({
			transport = transport_double(function()
				return "server returned status 500: boom", nil, { status = 500 }
			end),
			reinitialize = function()
				reinit_count = reinit_count + 1
			end,
		})

		local got_err
		session:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err)
			got_err = err
		end)

		assert.are.equal(0, reinit_count)
		assert.is_not_nil(got_err)
		assert.matches("500", got_err, 1, true)
	end)

	it("surfaces the original 404 if the reinitialize itself fails", function()
		local session = Session.new({
			session_id = "sess-1",
			transport = transport_double(function()
				return "server returned status 404", nil, { status = 404 }
			end),
			reinitialize = function(on_done)
				on_done("re-handshake failed", nil)
			end,
		})

		local got_err, got_result
		session:request({ jsonrpc = "2.0", id = 1, method = "ping" }, function(err, result)
			got_err, got_result = err, result
		end)

		assert.is_nil(got_result)
		assert.is_not_nil(got_err)
	end)
	it("does not renew an unassigned session on a routing 404", function()
		local count = 0
		local session = Session.new({
			transport = transport_double(function() return "status 404", nil, {status=404} end),
			reinitialize = function() count = count + 1 end,
		})
		local failure
		session:request({method="tools/list"}, function(err) failure = err end)
		assert.are.equal(0, count)
		assert.are.equal("status 404", failure)
	end)

	it("renews but never replays a tool call or unknown method", function()
		for _, method in ipairs({"tools/call", "custom/mutate", "prompts/get"}) do
			local renewed = transport_double(function() error("request was replayed") end)
			local session = Session.new({
				session_id = "expired",
				transport = transport_double(function() return "status 404", nil, {status=404} end),
				reinitialize = function(done) done(nil, {transport=renewed, session_id="new"}) end,
			})
			local failure
			session:request({method=method}, function(err) failure=err end)
			assert.are.equal("new", session.session_id)
			assert.are.equal(0, #renewed.calls)
			assert.matches("not replayed", failure, 1, true)
		end
	end)

	it("replays discovery only once and adopts a stateless replacement", function()
		local renewals = 0
		local renewed = transport_double(function() return "status 404", nil, {status=404} end)
		local session = Session.new({
			session_id = "expired",
			transport = transport_double(function() return "status 404", nil, {status=404} end),
			reinitialize = function(done)
				renewals=renewals+1
				done(nil, {transport=renewed})
			end,
		})
		local failure
		session:request({method="tools/list"}, function(err) failure=err end)
		assert.are.equal(1, renewals)
		assert.are.equal(1, #renewed.calls)
		assert.is_nil(session.session_id)
		assert.are.equal("status 404", failure)
	end)

end)
