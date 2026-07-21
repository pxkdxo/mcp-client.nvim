local LegacySse = require("mcp-client.transport.legacy_sse")

--- Unit coverage for the pieces of the legacy transport U2 leans on that
--- U1's specs did not exercise: server-notification routing and the SSE
--- `retry:` reconnection hint. Both are driven by feeding raw SSE lines to
--- the parser -- no socket, no network.

describe("transport.legacy_sse (U2 hooks)", function()
	local function client_with_lines(lines)
		local c = LegacySse.new({ stream_url = "http://x/mcp", endpoint = "http://x/messages" })
		c:attach_parser()
		for _, line in ipairs(lines) do
			c:feed_line(line)
		end
		return c
	end

	it("routes a server-originated notification to the notification handler", function()
		local seen
		local c = LegacySse.new({ stream_url = "http://x/mcp", endpoint = "http://x/messages" })
		c:set_on_notification(function(msg)
			seen = msg
		end)
		c:attach_parser()

		c:feed_line("event: message")
		c:feed_line('data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}')
		c:feed_line("")

		assert.is_not_nil(seen)
		assert.are.equal("notifications/message", seen.method)
	end)

	it("captures the most recent SSE retry: hint as a reconnect delay", function()
		local c = client_with_lines({
			"retry: 4200",
			"",
		})
		assert.are.equal(4200, c:get_retry_hint())
	end)

	it("has no retry hint before the server sends one", function()
		local c = client_with_lines({})
		assert.is_nil(c:get_retry_hint())
	end)
end)
