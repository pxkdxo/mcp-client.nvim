local HttpDouble = require("tests.helpers.http_double")
local wait_for = require("tests.helpers.wait")

local StreamableHttp = require("mcp-client.transport.streamable_http")

describe("transport.streamable_http", function()
	local double

	after_each(function()
		if double then
			double:stop()
			double = nil
		end
	end)

	it("sends requests as POST and decodes a JSON-RPC result", function()
		local received_body
		double = HttpDouble.new({
			on_request = function(method, path, rest)
				if method == "POST" and path == "/mcp" then
					received_body = rest
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json" },
						body = vim.json.encode({ jsonrpc = "2.0", id = 42, result = { ok = true } }),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local client = StreamableHttp.new({ url = double.url .. "/mcp", session_id = "abc-session" })

		local got_err, got_result
		local done = false
		client:request({ jsonrpc = "2.0", id = 42, method = "ping", params = {} }, function(err, result)
			got_err, got_result = err, result
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(got_err)
		assert.are.same({ ok = true }, got_result.result)
		assert.is_not_nil(received_body)
		assert.matches('"method":"ping"', received_body, 1, true)

		client:close()
	end)

	it("sends an Accept header naming both response shapes the spec allows", function()
		-- Streamable HTTP servers may reject requests missing this header with
		-- 406 Not Acceptable.
		local received_head
		double = HttpDouble.new({
			on_request = function(method, path, rest, head)
				received_head = head
				if method == "POST" and path == "/mcp" then
					return {
						status = 200,
						body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = { ok = true } }),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local client = StreamableHttp.new({ url = double.url .. "/mcp" })
		local done = false
		client:request({ jsonrpc = "2.0", id = 1, method = "ping", params = {} }, function()
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.matches("Accept:%s*application/json,%s*text/event%-stream", received_head)

		client:close()
	end)

	it("decodes a JSON-RPC result delivered as a single-event SSE response", function()
		-- The spec allows a single-shot response to arrive as one
		-- Content-Length-framed SSE event instead of a direct JSON body.
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					local data = vim.json.encode({ jsonrpc = "2.0", id = 1, result = { ok = true } })
					return {
						status = 200,
						headers = { ["Content-Type"] = "text/event-stream", ["Mcp-Session-Id"] = "sse-session" },
						body = "event: message\ndata: " .. data .. "\n\n",
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local client = StreamableHttp.new({ url = double.url .. "/mcp" })

		local got_err, got_result
		local done = false
		client:request({ jsonrpc = "2.0", id = 1, method = "ping", params = {} }, function(err, result)
			got_err, got_result = err, result
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(got_err)
		assert.are.same({ ok = true }, got_result.result)

		client:close()
	end)

	it("surfaces a non-2xx response as an error rather than decoding it as success", function()
		double = HttpDouble.new({
			on_request = function()
				return { status = 500, body = "boom" }
			end,
		})

		local client = StreamableHttp.new({ url = double.url .. "/mcp" })

		local got_err, got_result
		local done = false
		client:request({ jsonrpc = "2.0", id = 1, method = "ping", params = {} }, function(err, result)
			got_err, got_result = err, result
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(got_result)
		assert.is_not_nil(got_err)
		assert.matches("500", got_err, 1, true)

		client:close()
	end)

	it("does not send further requests once closed", function()
		local request_count = 0
		double = HttpDouble.new({
			on_request = function()
				request_count = request_count + 1
				return { status = 200, body = vim.json.encode({ jsonrpc = "2.0", id = 1, result = {} }) }
			end,
		})

		local client = StreamableHttp.new({ url = double.url .. "/mcp" })
		client:close()

		local got_err
		local done = false
		client:request({ jsonrpc = "2.0", id = 1, method = "ping", params = {} }, function(err)
			got_err = err
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.are.equal(0, request_count)
		assert.is_not_nil(got_err)
	end)
end)
