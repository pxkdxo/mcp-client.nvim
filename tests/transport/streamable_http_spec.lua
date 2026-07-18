local HttpDouble = require("tests.helpers.http_double")
local wait_for = require("tests.helpers.wait")

local StreamableHttp = require("mcphub-neovim.transport.streamable_http")

describe("transport.streamable_http", function()
	local double

	after_each(function()
		if double then
			double:stop()
			double = nil
		end
	end)

	it("sends requests as POST and decodes a JSON-RPC result", function()
		local received_body, received_session_header
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
