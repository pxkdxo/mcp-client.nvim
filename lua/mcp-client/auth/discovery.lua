--- OAuth 2.1 metadata discovery for MCP servers.
---
--- Two RFCs, two hops:
---   1. RFC 9728 Protected Resource Metadata (PRM): a 401 from a
---      non-localhost server carries a `WWW-Authenticate: Bearer
---      resource_metadata="..."` challenge pointing at the server's PRM
---      document, which lists the `authorization_servers` that guard it.
---   2. RFC 8414 Authorization Server Metadata: for a chosen AS, its
---      `.well-known/oauth-authorization-server` document names the
---      `authorization_endpoint`, `token_endpoint`, and optionally a
---      `registration_endpoint` (RFC 7591 DCR).
---
--- Every network call here goes through plenary.curl because these are
--- ordinary HTTPS requests to the server and its authorization server
--- (vim.uv has no TLS). Each failure is surfaced with a stage label
--- ("protected resource metadata", "authorization server metadata") so a
--- caller never sees a generic "auth failed".
local curl = require("plenary.curl")

local M = {}

local REQUEST_TIMEOUT_MS = 30000

--- Parse a `WWW-Authenticate` header value for the RFC 9728
--- `resource_metadata` URL. Returns the URL, or nil if absent.
--- @param header string|nil
--- @return string|nil
function M.parse_www_authenticate(header)
	if type(header) ~= "string" then
		return nil
	end
	-- resource_metadata is a quoted-string parameter of the Bearer challenge.
	return header:match('resource_metadata%s*=%s*"([^"]+)"')
end

--- Derive the default RFC 9728 well-known PRM URL from a server URL, used when
--- the server omits `resource_metadata` from its challenge (or sends no
--- challenge parameters at all). The well-known path is joined to the server's
--- origin.
--- @param server_url string
--- @return string
function M.default_prm_url(server_url)
	local origin = server_url:match("^(https?://[^/]+)") or server_url
	return origin .. "/.well-known/oauth-protected-resource"
end

--- Derive the RFC 8414 well-known AS metadata URL from an issuer URL. Per
--- RFC 8414, the well-known suffix is inserted after the authority and
--- before any issuer path component; for the common issuer-with-no-path case
--- this is simply `<issuer>/.well-known/oauth-authorization-server`.
--- @param issuer string
--- @return string
local function as_metadata_url(issuer)
	local origin, path = issuer:match("^(https?://[^/]+)(.*)$")
	if not origin then
		origin, path = issuer, ""
	end
	path = path:gsub("/$", "")
	return origin .. "/.well-known/oauth-authorization-server" .. path
end

--- Shared GET-and-decode-JSON helper. `stage` labels errors so the caller
--- knows which discovery hop failed.
local function get_json(url, stage, callback)
	curl.get(url, {
		headers = { ["Accept"] = "application/json" },
		timeout = REQUEST_TIMEOUT_MS,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return callback(nil, string.format("%s: no response", stage))
			end
			if response.status < 200 or response.status >= 300 then
				return callback(nil, string.format("%s: fetch returned status %d", stage, response.status))
			end
			local ok, decoded = pcall(vim.json.decode, response.body)
			if not ok or type(decoded) ~= "table" then
				return callback(nil, string.format("%s: response was not valid JSON", stage))
			end
			return callback(decoded, nil)
		end),
		on_error = vim.schedule_wrap(function(err)
			callback(nil, string.format("%s: request failed: %s", stage, err.message or "unknown error"))
		end),
	})
end

--- Fetch and validate the RFC 9728 Protected Resource Metadata document.
--- @param prm_url string
--- @param callback fun(result: table|nil, err: string|nil)
---   On success, result = {
---     resource             = string|nil,   -- the protected resource identifier
---     authorization_servers = string[],    -- non-empty list of AS issuer URLs
---     raw                  = table,         -- the full decoded document
---   }
function M.fetch_protected_resource_metadata(prm_url, callback)
	get_json(prm_url, "protected resource metadata", function(doc, err)
		if err then
			return callback(nil, err)
		end

		local servers = doc.authorization_servers
		if type(servers) ~= "table" or #servers == 0 then
			return callback(nil, "protected resource metadata: document did not list any authorization_servers")
		end

		return callback({
			resource = doc.resource,
			authorization_servers = servers,
			raw = doc,
		}, nil)
	end)
end

--- Fetch and validate RFC 8414 Authorization Server Metadata for an issuer.
--- @param issuer string the AS issuer URL (from PRM's authorization_servers)
--- @param callback fun(result: table|nil, err: string|nil)
---   On success, result = {
---     issuer                = string|nil,
---     authorization_endpoint = string,     -- required
---     token_endpoint         = string,     -- required
---     registration_endpoint  = string|nil, -- present iff the AS supports DCR
---     code_challenge_methods_supported = string[]|nil,
---     raw                    = table,       -- the full decoded document
---   }
function M.fetch_authorization_server_metadata(issuer, callback)
	get_json(as_metadata_url(issuer), "authorization server metadata", function(doc, err)
		if err then
			return callback(nil, err)
		end

		if type(doc.authorization_endpoint) ~= "string" or type(doc.token_endpoint) ~= "string" then
			return callback(
				nil,
				"authorization server metadata: document missing authorization_endpoint or token_endpoint"
			)
		end

		return callback({
			issuer = doc.issuer,
			authorization_endpoint = doc.authorization_endpoint,
			token_endpoint = doc.token_endpoint,
			registration_endpoint = doc.registration_endpoint,
			code_challenge_methods_supported = doc.code_challenge_methods_supported,
			raw = doc,
		}, nil)
	end)
end

return M
