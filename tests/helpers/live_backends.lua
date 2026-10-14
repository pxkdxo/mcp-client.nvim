--- Live-server reachability probes for the integration specs that talk to
--- real, externally-running MCP server processes instead of in-repo test
--- doubles. CI and most contributors won't have those processes running, so
--- the specs must skip gracefully -- with a clear reason -- rather than
--- hard-fail when the endpoints are unreachable.
local curl = require("plenary.curl")

local M = {}

--- The two sanctioned live validation endpoints.
M.RAVITEMER_MCP_HUB_URL = "http://localhost:40032/mcp"
M.RAVITEMER_HEALTH_URL = "http://localhost:40032/api/health"
M.SAMANHAPPY_BASE_URL = "http://localhost:3000"

local PROBE_TIMEOUT_MS = 750

--- Treats any HTTP response (even 4xx/5xx) as "reachable" -- only a connection
--- failure or timeout means the process isn't there. Swallows all errors into
--- `false` so a probe can never itself fail a spec.
--- @param url string
--- @return boolean reachable
local function http_answers(url)
	-- Legacy hub checks are optional; the shared proxy is covered by the POC suite.
	if vim.env.MCP_CLIENT_LIVE ~= "1" then
		return false
	end
	local ok, response = pcall(function()
		return curl.get(url, { timeout = PROBE_TIMEOUT_MS })
	end)
	if not ok or not response then
		return false
	end
	return type(response.status) == "number" and response.status >= 100
end

--- @return boolean
function M.ravitemer_reachable()
	return http_answers(M.RAVITEMER_HEALTH_URL)
end

--- Probes the dashboard SPA root, not the MCP endpoint itself -- a reachable
--- samanhappy process does not guarantee a reachable MCP endpoint (see
--- samanhappy_mcp_reachable below).
--- @return boolean
function M.samanhappy_reachable()
	return http_answers(M.SAMANHAPPY_BASE_URL .. "/")
end

--- samanhappy/mcphub only mounts its MCP routes (`/mcp/:group`, `/sse/:group`,
--- `/messages`) after upstream servers finish initializing; if any upstream
--- fails to init, those routes never mount and `/mcp/...` falls through to the
--- SPA catch-all (404 "Cannot POST"). A 200/400/etc from a real handler means
--- the route is mounted; a 404 means it isn't.
--- @return boolean
function M.samanhappy_mcp_reachable()
	if not M.samanhappy_reachable() then
		return false
	end
	local ok, response = pcall(function()
		return curl.post(M.SAMANHAPPY_BASE_URL .. "/mcp/$smart", {
			timeout = PROBE_TIMEOUT_MS,
			headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json, text/event-stream" },
			body = vim.json.encode({
				jsonrpc = "2.0",
				id = 1,
				method = "initialize",
				params = vim.empty_dict(),
			}),
		})
	end)
	if not ok or not response or type(response.status) ~= "number" then
		return false
	end
	return response.status ~= 404
end

return M
