local HttpDouble = require("tests.helpers.http_double")
local wait_for = require("tests.helpers.wait")

local mcphub = require("mcp-client")

local function initialize_result_body()
	return vim.json.encode({
		jsonrpc = "2.0",
		id = 1,
		result = {
			protocolVersion = "2025-03-26",
			capabilities = {},
			serverInfo = { name = "test-server", version = "0.0.1" },
		},
	})
end

describe("mcp-client (public entrypoint)", function()
	local double

	after_each(function()
		if double then
			double:stop()
			double = nil
		end
	end)

	it("is required as mcp-client, not mcphub", function()
		assert.is_not_nil(mcphub)
		assert.has_error(function()
			require("mcphub")
		end)
	end)

	it("connects over streamable_http when the server supports it", function()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json", ["Mcp-Session-Id"] = "sess-1" },
						body = initialize_result_body(),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local got_client, got_err
		local done = false
		mcphub.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(client, err)
				got_client, got_err = client, err
				done = true
			end,
		})

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(got_err)
		assert.is_not_nil(got_client)
		assert.are.equal("streamable_http", got_client.transport)

		got_client.close()
	end)

	it("connects over legacy_sse when the server only supports the two-endpoint transport", function()
		double = HttpDouble.new({
			on_request = function(method, path)
				if method == "POST" and path == "/mcp" then
					return { status = 400, body = "" }
				end
				if method == "GET" and path == "/mcp" then
					return {
						status = 200,
						sse = { { event = "endpoint", data = "/messages?sessionId=legacy-1" } },
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local got_client, got_err
		local done = false
		mcphub.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(client, err)
				got_client, got_err = client, err
				done = true
			end,
		})

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_nil(got_err)
		assert.is_not_nil(got_client)
		assert.are.equal("legacy_sse", got_client.transport)

		got_client.close()
	end)

	it("surfaces connection-refused as a clear error via on_connect", function()
		local got_client, got_err
		local done = false
		mcphub.connect({ url = "http://127.0.0.1:1/mcp" }, {
			on_connect = function(client, err)
				got_client, got_err = client, err
				done = true
			end,
		})

		assert.is_true(wait_for(function()
			return done
		end, 5000))
		assert.is_nil(got_client)
		assert.is_not_nil(got_err)
	end)

	it("requires a url in config", function()
		assert.has_error(function()
			mcphub.connect({}, {})
		end)
	end)

	it("regression: an omitted capabilities encodes as a JSON object, not an array", function()
		local seen_body
		double = HttpDouble.new({
			on_request = function(method, path, rest)
				if method == "POST" and path == "/mcp" then
					seen_body = rest
					return {
						status = 200,
						headers = { ["Content-Type"] = "application/json" },
						body = initialize_result_body(),
					}
				end
				return { status = 404, body = "" }
			end,
		})

		local done = false
		mcphub.connect({ url = double.url .. "/mcp" }, {
			on_connect = function(client, _err)
				if client then
					client.close()
				end
				done = true
			end,
		})

		assert.is_true(wait_for(function()
			return done
		end))
		assert.is_not_nil(seen_body)
		-- vim.json.decode can't distinguish `{}` from `[]` once decoded back
		-- into an empty Lua table -- check the raw wire body instead. A
		-- strict server rejects `"capabilities":[]`; MCP requires an object.
		assert.is_nil(seen_body:find('"capabilities":%[%]', 1))
		assert.is_not_nil(seen_body:find('"capabilities":{}', 1, true))
	end)
end)
