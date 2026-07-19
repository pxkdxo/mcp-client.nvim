local wait_for = require("tests.helpers.wait")
local http_get = require("tests.helpers.http_client")

local RedirectListener = require("mcphub-neovim.auth.redirect_listener")

describe("auth.redirect_listener", function()
	local listener

	after_each(function()
		if listener then
			listener:close()
			listener = nil
		end
	end)

	it("binds to 127.0.0.1 on an ephemeral port and reports a loopback redirect_uri", function()
		listener = RedirectListener.new({ expected_state = "s", on_result = function() end })
		local started, err = listener:start()

		assert.is_true(started, tostring(err))
		assert.is_number(listener.port)
		assert.is_true(listener.port > 0)
		assert.are.equal(string.format("http://127.0.0.1:%d/callback", listener.port), listener.redirect_uri)
	end)

	it("captures the authorization code when state matches", function()
		local result
		listener = RedirectListener.new({
			expected_state = "expected-state",
			on_result = function(res)
				result = res
			end,
		})
		assert.is_true(listener:start())

		http_get(listener.port, "/callback?code=the-auth-code&state=expected-state")

		assert.is_true(wait_for(function()
			return result ~= nil
		end))
		assert.is_nil(result.err)
		assert.are.equal("the-auth-code", result.code)
	end)

	it("rejects a callback whose state does not match, without yielding a code", function()
		local result
		listener = RedirectListener.new({
			expected_state = "expected-state",
			on_result = function(res)
				result = res
			end,
		})
		assert.is_true(listener:start())

		http_get(listener.port, "/callback?code=attacker-code&state=WRONG")

		assert.is_true(wait_for(function()
			return result ~= nil
		end))
		assert.is_not_nil(result.err)
		assert.is_nil(result.code)
		assert.matches("state", result.err)
	end)

	it("rejects a callback with a missing state parameter", function()
		local result
		listener = RedirectListener.new({
			expected_state = "expected-state",
			on_result = function(res)
				result = res
			end,
		})
		assert.is_true(listener:start())

		http_get(listener.port, "/callback?code=attacker-code")

		assert.is_true(wait_for(function()
			return result ~= nil
		end))
		assert.is_not_nil(result.err)
		assert.is_nil(result.code)
	end)

	it("surfaces an authorization-server error carried on the callback", function()
		local result
		listener = RedirectListener.new({
			expected_state = "expected-state",
			on_result = function(res)
				result = res
			end,
		})
		assert.is_true(listener:start())

		http_get(listener.port, "/callback?error=access_denied&state=expected-state")

		assert.is_true(wait_for(function()
			return result ~= nil
		end))
		assert.is_not_nil(result.err)
		assert.is_nil(result.code)
		assert.matches("access_denied", result.err)
	end)

	it("fires on_result at most once even across multiple callbacks", function()
		local count = 0
		listener = RedirectListener.new({
			expected_state = "expected-state",
			on_result = function()
				count = count + 1
			end,
		})
		assert.is_true(listener:start())

		http_get(listener.port, "/callback?code=first&state=expected-state")
		assert.is_true(wait_for(function()
			return count == 1
		end))

		-- A second navigation to the (now-closed) listener must not deliver
		-- another result. The connection should simply fail.
		pcall(http_get, listener.port, "/callback?code=second&state=expected-state")

		-- Give any erroneous second callback a chance to arrive.
		vim.wait(200, function()
			return count > 1
		end)
		assert.are.equal(1, count)
	end)

	it("times out with a clear error when no callback arrives", function()
		local result
		listener = RedirectListener.new({
			expected_state = "expected-state",
			timeout_ms = 150,
			on_result = function(res)
				result = res
			end,
		})
		assert.is_true(listener:start())

		assert.is_true(wait_for(function()
			return result ~= nil
		end, 1000))
		assert.is_not_nil(result.err)
		assert.matches("timed out", result.err)
		assert.is_nil(result.code)
	end)

	it("never places the captured code into its error text", function()
		local result
		listener = RedirectListener.new({
			expected_state = "expected-state",
			on_result = function(res)
				result = res
			end,
		})
		assert.is_true(listener:start())

		-- State mismatch: the code must be rejected AND must not leak into the error.
		http_get(listener.port, "/callback?code=super-secret-code&state=WRONG")

		assert.is_true(wait_for(function()
			return result ~= nil
		end))
		assert.is_not_nil(result.err)
		assert.is_nil(result.err:find("super-secret-code", 1, true))
	end)
end)
