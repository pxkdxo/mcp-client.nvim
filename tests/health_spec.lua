-- Health-check specs (U8). `health.check(reporter?)` implements the body of
-- `:checkhealth mcp-client`. It reports, purely by reading the public APIs
-- other units already expose (`config.state()`, `client.get_clients()` /
-- `is_stopped()`, `TokenStore:status()`):
--   * server connection status, per configured server;
--   * registered native servers;
--   * auth status for any server that has a TokenStore (redacted fields only --
--     never the token itself).
--
-- The two brief scenarios under test:
--   * happy path: a connected server with valid auth reports `ok`;
--   * edge case: a disconnected server / failed auth reports `warn`/`error`
--     rather than crashing.
--
-- `health.check` takes an injected reporter (defaulting to `vim.health`) so a
-- spec can capture every start/ok/warn/error/info call without needing a real
-- `:checkhealth` buffer -- the same test-seam discipline token_store.lua uses
-- for its command runner.

local client = require("mcp-client.client")
local config = require("mcp-client.config")
local health = require("mcp-client.health")
local token_store = require("mcp-client.auth.token_store")

--- A reporter double that records every call vim.health would receive.
local function recording_reporter()
	local r = { events = {} }
	for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
		r[level] = function(msg)
			table.insert(r.events, { level = level, msg = msg })
		end
	end
	--- All text of a given level, concatenated -- convenient for assertions.
	function r:text(level)
		local parts = {}
		for _, e in ipairs(self.events) do
			if not level or e.level == level then
				table.insert(parts, e.msg)
			end
		end
		return table.concat(parts, "\n")
	end
	function r:has(level, pattern)
		for _, e in ipairs(self.events) do
			if e.level == level and tostring(e.msg):match(pattern) then
				return true
			end
		end
		return false
	end
	return r
end

--- Register a fake server-shaped client into the real registry with a given
--- stopped state, and record it in config's state as a server so health.lua can
--- correlate it. Returns the client object.
local function fake_hub(name, url, stopped)
	local obj = {
		name = name,
		config = { url = url, name = name },
	}
	function obj:is_stopped()
		return stopped
	end
	function obj:request(_rpc, cb)
		return cb("noop", nil, nil)
	end
	function obj:notify(_rpc) end
	function obj:disconnect()
		stopped = true
	end
	return client.register_native(obj)
end

describe("health.check", function()
	local tmp

	before_each(function()
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
	end)

	after_each(function()
		client._reset_registry()
		config._reset()
		if tmp then
			vim.fn.delete(tmp, "rf")
			tmp = nil
		end
	end)

	it("runs without error even with nothing configured", function()
		local r = recording_reporter()
		assert.has_no.errors(function()
			health.check(r)
		end)
		-- It still opens a report section.
		assert.is_true(r:has("start", "mcp%-client"))
	end)

	describe("happy path", function()
		it("reports ok for a connected localhost server with no auth required", function()
			config._record_hub("local_hub", { url = "http://localhost:9999" })
			fake_hub("local_hub", "http://localhost:9999", false)

			local r = recording_reporter()
			health.check(r)

			assert.is_true(r:has("ok", "local_hub"))
			assert.is_false(r:has("error", "local_hub"))
		end)

		it("reports ok for a connected non-localhost server with a valid stored token", function()
			local store = token_store.new({ key = "remote", backend = "file", data_home = tmp })
			store:save({
				access_token = "SECRET-do-not-print",
				refresh_token = "SECRET-refresh",
				token_type = "Bearer",
				expires_at = os.time() + 3600,
			})
			config._record_hub("remote", { url = "https://server.example.com/mcp", token_store = store })
			fake_hub("remote", "https://server.example.com/mcp", false)

			local r = recording_reporter()
			health.check(r)

			assert.is_true(r:has("ok", "remote"))
			-- Auth is reported, but the secret never is.
			local everything = r:text()
			assert.is_false(everything:find("SECRET", 1, true) ~= nil)
		end)
	end)

	describe("registered native servers", function()
		local native = require("mcp-client.native")

		it("lists registered native servers that are live in the registry", function()
			-- Mirror what config.setup does: register the server AND record its
			-- name, so health correlates the recorded name with the live client.
			native.register({ name = "orchestrator", tools = {}, resources = {}, prompts = {} })
			config._record_native("orchestrator")
			native.register({ name = "another", tools = {}, resources = {}, prompts = {} })
			config._record_native("another")

			local r = recording_reporter()
			health.check(r)

			assert.is_true(r:has("ok", "orchestrator") or r:has("info", "orchestrator"))
			assert.is_true(r:has("ok", "another") or r:has("info", "another"))
		end)

		it("warns for a native server recorded at setup but absent from the registry", function()
			config._record_native("ghost")

			local r = recording_reporter()
			assert.has_no.errors(function()
				health.check(r)
			end)
			assert.is_true(r:has("warn", "ghost"))
		end)
	end)

	describe("edge cases (must warn/error, never crash)", function()
		it("reports error for a configured server that never connected", function()
			config._record_hub("local_hub", { url = "http://localhost:9999" })
			-- No client registered for it: it never connected.

			local r = recording_reporter()
			assert.has_no.errors(function()
				health.check(r)
			end)
			assert.is_true(r:has("error", "local_hub") or r:has("warn", "local_hub"))
		end)

		it("reports error/warn for a server whose client is stopped (disconnected)", function()
			config._record_hub("local_hub", { url = "http://localhost:9999" })
			fake_hub("local_hub", "http://localhost:9999", true) -- stopped

			local r = recording_reporter()
			assert.has_no.errors(function()
				health.check(r)
			end)
			assert.is_true(r:has("error", "local_hub") or r:has("warn", "local_hub"))
		end)

		it("warns for a non-localhost server with a TokenStore but no stored token", function()
			local store = token_store.new({ key = "remote", backend = "file", data_home = tmp })
			-- Nothing saved: has_token == false.
			config._record_hub("remote", { url = "https://server.example.com/mcp", token_store = store })
			fake_hub("remote", "https://server.example.com/mcp", false)

			local r = recording_reporter()
			assert.has_no.errors(function()
				health.check(r)
			end)
			assert.is_true(r:has("warn", "token") or r:has("warn", "auth") or r:has("warn", "authenticat"))
		end)

		it("warns for a non-localhost server whose token is expired", function()
			local store = token_store.new({ key = "remote", backend = "file", data_home = tmp })
			store:save({
				access_token = "SECRET-expired",
				refresh_token = "SECRET-refresh",
				token_type = "Bearer",
				expires_at = os.time() - 10, -- already expired
			})
			config._record_hub("remote", { url = "https://server.example.com/mcp", token_store = store })
			fake_hub("remote", "https://server.example.com/mcp", false)

			local r = recording_reporter()
			assert.has_no.errors(function()
				health.check(r)
			end)
			assert.is_true(r:has("warn", "expired"))
			-- Still never leaks the token.
			assert.is_false(r:text():find("SECRET", 1, true) ~= nil)
		end)
	end)

	it("defaults to vim.health when no reporter is injected (smoke, no crash)", function()
		config._record_hub("local_hub", { url = "http://localhost:9999" })
		fake_hub("local_hub", "http://localhost:9999", false)
		assert.has_no.errors(function()
			health.check()
		end)
	end)
end)
