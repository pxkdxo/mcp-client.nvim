--- `:checkhealth mcp-client` status view.
---
--- This module is purely a reporting layer: it reads what setup recorded
--- (`config.state()`) and correlates it with the live client roster
--- (`client.get_clients()` / `is_stopped()`) and, for any server with a
--- TokenStore, that store's redacted `:status()`. It never opens a connection,
--- constructs a store, or touches a transport.
---
--- Neovim's health framework calls `require("mcp-client.health").check()`
--- for `:checkhealth mcp-client` (the function is discovered by name; see
--- `:help health-dev`). `check()` accepts an optional reporter so specs can
--- capture every start/ok/warn/error/info call without a real checkhealth
--- buffer -- it defaults to `vim.health`.
---
--- Auth status is surfaced ONLY through `TokenStore:status()`, whose fields
--- are presence/expiry booleans and a non-secret absolute expiry time --
--- never the access token, the refresh token, or any header value.

local mcp_client = require("mcp-client.client")
local config = require("mcp-client.config")
local tls = require("mcp-client.transport.tls")

local M = {}

--- Find the live client object for a server by name, or nil if none is registered
--- (i.e. it never connected, or was fully torn down).
local function live_client(name)
	local matches = mcp_client.get_clients({ name = name })
	return matches[1]
end

--- Human-readable absolute time for a unix timestamp, for the expiry line.
local function fmt_time(ts)
	if type(ts) ~= "number" then
		return "unknown"
	end
	return os.date("%Y-%m-%d %H:%M:%S", ts)
end

--- Report auth status for one server, reading ONLY the redacted status table.
--- Returns true if auth is healthy (or not required), false if it warrants a
--- warning -- so the caller can factor it into the server's overall verdict.
---
--- @param connected boolean  whether this server currently has a live, connected
---   client object. With a live client, an expired-but-refreshable token is
---   refreshed transparently on the next request (`ensure_fresh_token`); with
---   no live client, refreshing requires retrying the connection instead.
local function report_auth(reporter, name, record, connected)
	local store = record.token_store
	if not store then
		-- tls.lua exempts localhost from requiring authentication.
		if tls.is_localhost(record.url) then
			reporter.info(string.format("server %q: localhost, no authentication required", name))
		end
		return true
	end

	local status = store:status()
	if not status.has_token then
		reporter.warn(
			string.format(
				"server %q: no stored authentication token (backend: %s). "
					.. "Authenticate once, then re-run setup() or restart Neovim -- see the README's "
					.. '"Authenticating a server" section.',
				name,
				status.backend
			)
		)
		return false
	end

	if status.expired then
		if not status.has_refresh_token then
			reporter.warn(
				string.format(
					"server %q: stored token is expired (expired at %s) and no refresh token is "
						.. "stored -- re-authentication is required.",
					name,
					fmt_time(status.expires_at)
				)
			)
		elseif connected then
			reporter.warn(
				string.format(
					"server %q: stored token is expired (expired at %s). "
						.. "It will be refreshed automatically on the next request.",
					name,
					fmt_time(status.expires_at)
				)
			)
		else
			reporter.warn(
				string.format(
					"server %q: stored token is expired (expired at %s). "
						.. "It will be refreshed automatically on the next connection attempt -- "
						.. "re-run setup() or restart Neovim.",
					name,
					fmt_time(status.expires_at)
				)
			)
		end
		return false
	end

	reporter.ok(
		string.format(
			"server %q: authenticated (backend: %s, token valid until %s%s)",
			name,
			status.backend,
			fmt_time(status.expires_at),
			status.has_refresh_token and ", refreshable" or ""
		)
	)
	return true
end

--- Report connection + auth status for one configured server.
local function report_hub(reporter, name, record)
	local obj = live_client(name)

	if not obj then
		reporter.error(
			string.format(
				"server %q (%s): not connected -- no client registered. "
					.. "The initial connection failed (check :messages for the reason) or setup() was never called.",
				name,
				record.url
			)
		)
		-- Still report auth so the user sees the whole picture for this server.
		report_auth(reporter, name, record, false)
		return
	end

	local stopped = obj:is_stopped()
	if stopped then
		reporter.error(
			string.format(
				"server %q (%s): disconnected -- reconnect attempts were exhausted. "
					.. "Check the server is reachable, then restart Neovim or re-run setup().",
				name,
				record.url
			)
		)
	else
		reporter.ok(string.format("server %q (%s): connected", name, record.url))
	end

	report_auth(reporter, name, record, not stopped)
end

--- Report the registered native, in-process servers. Native servers are
--- first-party, in-process code: unlike a remote server there is no connection to
--- be up or down, so a registered native server is simply reported as present.
local function report_native(reporter, native_servers)
	if #native_servers == 0 then
		reporter.info("no native (in-process) servers registered")
		return
	end
	for _, name in ipairs(native_servers) do
		-- Correlate with the live registry so a native server that was somehow
		-- removed is reported accurately, not just because setup listed it.
		local obj = live_client(name)
		if obj and not obj:is_stopped() then
			reporter.ok(string.format("native server %q: registered (in-process)", name))
		elseif obj then
			reporter.warn(string.format("native server %q: registered but stopped", name))
		else
			reporter.warn(string.format("native server %q: recorded at setup but not in the client registry", name))
		end
	end
end

--- The health entrypoint invoked by `:checkhealth mcp-client`.
--- @param reporter table|nil  { start, ok, warn, error, info } -- defaults to vim.health.
function M.check(reporter)
	reporter = reporter or vim.health

	local state = config.state()

	reporter.start("mcp-client")

	reporter.info(
		"Native servers run in-process with full Neovim/Lua privilege (no sandboxing). "
			.. "Only register native servers you trust as first-party code."
	)

	-- Servers.
	local server_names = {}
	for name in pairs(state.servers) do
		table.insert(server_names, name)
	end
	table.sort(server_names)

	if #server_names == 0 then
		reporter.info("no remote servers configured")
	else
		for _, name in ipairs(server_names) do
			report_hub(reporter, name, state.servers[name])
		end
	end

	-- Native servers.
	report_native(reporter, state.native_servers)
end

return M
