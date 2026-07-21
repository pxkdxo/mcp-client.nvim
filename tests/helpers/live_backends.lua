--- Live-server reachability probes for the U9 integration specs.
---
--- U9 is the one unit that validates against REAL, externally-running MCP server
--- processes rather than in-repo test doubles (see the plan's Approach for U9).
--- A future contributor or CI environment running `make test` will NOT have
--- those exact processes running, so both integration specs MUST *skip*
--- gracefully -- with a clear, visible reason -- rather than hard-fail when the
--- endpoints are unreachable. This helper centralizes that decision so the two
--- specs share one well-commented, short-timeout probe.
---
--- The probe intentionally checks a server's plain HTTP *health/liveness* surface,
--- not the MCP protocol handshake: we only need to answer "is this specific
--- external process up and answering right now?" cheaply and without side
--- effects. It uses a very short timeout so a missing endpoint costs the suite
--- almost nothing.
---
--- SAFETY: these probes only ever touch the two sanctioned validation endpoints
--- (`localhost:40032` for ravitemer/mcp-hub, `localhost:3000` for
--- samanhappy/mcphub). The user's real, live daily-driver server on port 37373 is
--- NEVER referenced here or anywhere in this repo -- see the repo-wide hygiene
--- grep gate in U9's brief.
local curl = require("plenary.curl")

local M = {}

--- The two sanctioned live validation endpoints. Kept here (not in a spec) so
--- there is a single source of truth and the hygiene grep has one obvious place
--- to look. NOTE: neither is port 37373; that process must never be contacted.
M.RAVITEMER_MCP_HUB_URL = "http://localhost:40032/mcp"
M.RAVITEMER_HEALTH_URL = "http://localhost:40032/api/health"
M.SAMANHAPPY_BASE_URL = "http://localhost:3000"

--- A short probe budget: unreachable endpoints should barely cost the suite.
local PROBE_TIMEOUT_MS = 750

--- Is a plain HTTP GET to `url` answered (any HTTP status) within the budget?
--- We treat *any* HTTP response as "reachable" -- even a 401/404 means a live
--- process is listening and answering. Only a connection failure / timeout
--- counts as unreachable. Runs a synchronous curl (specs are synchronous), and
--- swallows all errors into `false` so a probe can never itself fail a spec.
--- @param url string
--- @return boolean reachable
local function http_answers(url)
	local ok, response = pcall(function()
		return curl.get(url, { timeout = PROBE_TIMEOUT_MS })
	end)
	if not ok or not response then
		return false
	end
	-- plenary.curl returns a table with a numeric `status`; a real answer (even
	-- an error status) has a status >= 100. A connection failure yields status 0
	-- (or no status), which we treat as unreachable.
	return type(response.status) == "number" and response.status >= 100
end

--- Is the ravitemer/mcp-hub validation instance (port 40032) reachable right
--- now? Probes its /api/health surface, which returns real JSON when up.
--- @return boolean
function M.ravitemer_reachable()
	return http_answers(M.RAVITEMER_HEALTH_URL)
end

--- Is the samanhappy/mcphub container (port 3000) reachable right now? Probes
--- its root (the dashboard SPA), which answers 200 when the process is up. NOTE
--- (U9 finding): a *reachable* samanhappy process does not guarantee a reachable
--- MCP protocol endpoint -- see samanhappy_mcp_reachable below.
--- @return boolean
function M.samanhappy_reachable()
	return http_answers(M.SAMANHAPPY_BASE_URL .. "/")
end

--- Does the samanhappy/mcphub container currently expose a usable MCP protocol
--- endpoint? This is a SEPARATE, stronger check than samanhappy_reachable().
---
--- U9 finding (documented in the task report): samanhappy/mcphub registers its
--- MCP transport routes (`/mcp/:group`, `/sse/:group`, `/messages`) only inside
--- the `initUpstreamServers().then(...)` callback. If ANY configured upstream
--- server fails to initialize (in the validation container, a Context7 URL that
--- resolves to a Docker-network-blocked address throws inside init), that
--- promise rejects, the `.then` never runs, and NO MCP HTTP route is ever
--- mounted -- every `/mcp/...` and `/sse/...` path falls through to the SPA
--- catch-all instead. So the MCP endpoint can be entirely absent even while the
--- dashboard answers 200.
---
--- We detect a *mounted, real* MCP endpoint by POSTing a minimal JSON-RPC body
--- to `/mcp/$smart`: a mounted StreamableHTTP handler answers with an MCP-shaped
--- reply or a protocol error, whereas the SPA catch-all answers 404
--- "Cannot POST /mcp/$smart". We therefore treat a 404 (Express "Cannot POST")
--- as "MCP endpoint not mounted".
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
	-- 404 => the MCP route is not mounted (SPA catch-all). Anything else (2xx, a
	-- JSON-RPC error, 400 bad-request from the real handler, etc.) means a real
	-- MCP handler is present.
	return response.status ~= 404
end

return M
