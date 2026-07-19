local HttpDouble = require("tests.helpers.http_double")
local wait_for = require("tests.helpers.wait")

local detect = require("mcphub-neovim.transport.detect")

local INITIALIZE_REQUEST = {
	jsonrpc = "2.0",
	id = 1,
	method = "initialize",
	params = {
		protocolVersion = "2025-03-26",
		capabilities = {},
		clientInfo = { name = "mcphub-neovim", version = "0.1.0" },
	},
}

local function initialize_result_body()
	return vim.json.encode({
		jsonrpc = "2.0",
		id = 1,
		result = {
			protocolVersion = "2025-03-26",
			capabilities = {},
			serverInfo = { name = "test-hub", version = "0.0.1" },
		},
	})
end

describe("transport.detect", function()
	local double

	after_each(function()
		if double then
			double:stop()
			double = nil
		end
	end)

	it("uses the streamable_http transport when POST initialize succeeds", function()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json", ["Mcp-Session-Id"] = "session-abc" },
						body = initialize_result_body(),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local result, err
		local done = false
		detect.connect({
			url = double.url .. "/mcp",
			request = INITIALIZE_REQUEST,
			timeout = 2000,
		}, function(r, e)
			result, err = r, e
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(err)
		assert.is_not_nil(result)
		assert.are.equal("streamable_http", result.transport)
		assert.are.equal("session-abc", result.session_id)

		result.client:close()
	end)

	for _, fallback_status in ipairs({ 400, 404, 405 }) do
		it("falls back to legacy_sse when POST returns " .. fallback_status, function()
			double = HttpDouble.new({
				on_request = function(method, path)
					if method == "POST" and path == "/mcp" then
						return { status = fallback_status, body = "" }
					end
					if method == "GET" and path == "/mcp" then
						return {
							status = 200,
							sse = {
								{ event = "endpoint", data = "/messages?sessionId=legacy-session-1" },
							},
						}
					end
					return { status = 404, body = "" }
				end,
			})

			local result, err
			local done = false
			detect.connect({
				url = double.url .. "/mcp",
				request = INITIALIZE_REQUEST,
				timeout = 2000,
			}, function(r, e)
				result, err = r, e
				done = true
			end)

			assert.is_true(wait_for(function()
				return done
			end))
			assert.is_nil(err)
			assert.is_not_nil(result)
			assert.are.equal("legacy_sse", result.transport)
			assert.are.equal(double.url .. "/messages?sessionId=legacy-session-1", result.endpoint)

			result.client:close()
		end)
	end

	it("sends an Accept header naming both response shapes the spec allows", function()
		-- A real hub (samanhappy/mcphub) rejects the initial InitializeRequest
		-- with 406 Not Acceptable if this header is missing -- confirmed
		-- against the live hub during U9 validation.
		local received_head
		double = HttpDouble.new({
			on_request = function(method, path, rest, head)
				received_head = head
				if method == "POST" and path == "/mcp" then
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json", ["Mcp-Session-Id"] = "session-abc" },
						body = initialize_result_body(),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local done = false
		local result
		detect.connect({
			url = double.url .. "/mcp",
			request = INITIALIZE_REQUEST,
			timeout = 2000,
		}, function(r)
			result = r
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.matches("Accept:%s*application/json,%s*text/event%-stream", received_head)

		result.client:close()
	end)

	it("uses the streamable_http transport when POST initialize's response is a single-event SSE stream", function()
		-- The Streamable HTTP spec sanctions this response mode as an
		-- alternative to a direct JSON body -- a real hub may choose either.
		-- Reproduces the exact shape samanhappy/mcphub sent during U9's live
		-- validation for the initialize handshake itself: a Content-Length-
		-- framed (not left-open) body containing one `event: message` frame.
		-- Built as a plain `body` string, not the double's `sse` field (that
		-- field is for the legacy transport's deliberately-left-open
		-- long-lived stream -- the wrong shape for this single-shot response).
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return {
						status = 200,
						headers = { ["Content-Type"] = "text/event-stream", ["Mcp-Session-Id"] = "sse-session-1" },
						body = "event: message\ndata: " .. initialize_result_body() .. "\n\n",
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local result, err
		local done = false
		detect.connect({
			url = double.url .. "/mcp",
			request = INITIALIZE_REQUEST,
			timeout = 2000,
		}, function(r, e)
			result, err = r, e
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(err)
		assert.is_not_nil(result)
		assert.are.equal("streamable_http", result.transport)
		assert.are.equal("sse-session-1", result.session_id)
		assert.are.equal("test-hub", result.initialize_result.result.serverInfo.name)

		result.client:close()
	end)

	it("surfaces a clear error when the hub is unreachable", function()
		-- Nothing is listening on this port: connection refused, not a hang.
		local unreachable_url = "http://127.0.0.1:1/mcp"

		local result, err
		local done = false
		detect.connect({
			url = unreachable_url,
			request = INITIALIZE_REQUEST,
			timeout = 2000,
		}, function(r, e)
			result, err = r, e
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end, 5000))
		assert.is_nil(result)
		assert.is_not_nil(err)
		assert.matches("connect", err, 1, true)
	end)

	it("surfaces an error on an unexpected status code instead of assuming legacy", function()
		double = HttpDouble.new({
			on_request = function(_, _)
				return { status = 500, body = "internal error" }
			end,
		})

		local result, err
		local done = false
		detect.connect({
			url = double.url .. "/mcp",
			request = INITIALIZE_REQUEST,
			timeout = 2000,
		}, function(r, e)
			result, err = r, e
			done = true
		end)

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(result)
		assert.is_not_nil(err)
		assert.matches("500", err, 1, true)
	end)
end)
