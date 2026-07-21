--- OAuth 2.1 refresh-token grant (RFC 6749 §6).
---
--- POSTs grant_type=refresh_token & refresh_token=<stored> & client_id &
--- resource to the token endpoint recorded on the stored token, exchanging an
--- expired access token for a fresh one without a new browser round-trip.
---
--- A revoked/invalid refresh token (or the absence of one) surfaces a
--- distinct "re-authentication required" error so the caller stops and
--- re-runs the full OAuth flow rather than retrying the refresh indefinitely.
---
--- Secrets (access token, refresh token) never appear in a log line or error
--- message; error paths report the token endpoint's OAuth error *code* only.

local curl = require("plenary.curl")

local M = {}

local REQUEST_TIMEOUT_MS = 30000

local function url_encode(value)
	return (tostring(value):gsub("[^%w%-._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

local function form_encode(params)
	local parts = {}
	for key, value in pairs(params) do
		table.insert(parts, url_encode(key) .. "=" .. url_encode(value))
	end
	return table.concat(parts, "&")
end

local function oauth_error(decoded)
	if type(decoded) == "table" and type(decoded.error) == "string" then
		return decoded.error
	end
	return nil
end

--- Exchange a stored token's refresh_token for a fresh access token.
---
--- @param token table  a stored token result with at least:
---   refresh_token  (string)  -- SECRET; the grant credential
---   token_endpoint (string)  -- where to POST the refresh grant
---   client_id      (string)  -- public client id to re-send
---   resource       (string|nil) -- RFC 8707 resource indicator to re-send
--- @param callback fun(result: table|nil, err: string|nil)
---   On success, result is a fresh typed token result (access_token,
---   refresh_token, token_type, expires_at, scope, token_endpoint, client_id,
---   resource, raw), with the refresh token rotated (or retained) and the
---   refresh metadata carried forward. On a revoked/absent refresh token,
---   result is nil and err is a "re-authentication required" message
---   (secret-free).
function M.refresh(token, callback)
	assert(type(token) == "table", "refresh: token table is required")

	if type(token.refresh_token) ~= "string" or token.refresh_token == "" then
		return callback(nil, "token refresh: re-authentication required (no refresh token available)")
	end
	if type(token.token_endpoint) ~= "string" or token.token_endpoint == "" then
		return callback(nil, "token refresh: re-authentication required (no token endpoint recorded for this token)")
	end

	local params = {
		grant_type = "refresh_token",
		refresh_token = token.refresh_token,
		client_id = token.client_id,
	}
	-- RFC 8707: re-send the resource indicator when we have one.
	if token.resource then
		params.resource = token.resource
	end
	if token.scope then
		params.scope = token.scope
	end

	curl.post(token.token_endpoint, {
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
			["Accept"] = "application/json",
		},
		body = form_encode(params),
		timeout = REQUEST_TIMEOUT_MS,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return callback(nil, "token refresh: no response from token endpoint")
			end

			local ok, decoded = pcall(vim.json.decode, response.body)
			if response.status < 200 or response.status >= 300 then
				local code = ok and oauth_error(decoded)
				-- Any error status on the refresh grant is terminal (no retry loop);
				-- surface the OAuth error code, never the token.
				return callback(
					nil,
					string.format(
						"token refresh: re-authentication required (token endpoint returned status %d%s)",
						response.status,
						code and (" " .. code) or ""
					)
				)
			end

			if not ok or type(decoded) ~= "table" or type(decoded.access_token) ~= "string" then
				return callback(nil, "token refresh: token endpoint response missing access_token")
			end

			local expires_at
			if type(decoded.expires_in) == "number" then
				expires_at = os.time() + decoded.expires_in
			end

			return callback({
				access_token = decoded.access_token,
				-- RFC 6749 §6: the AS MAY omit a new refresh_token, in which case the
				-- previously presented one remains valid.
				refresh_token = decoded.refresh_token or token.refresh_token,
				token_type = decoded.token_type or token.token_type or "Bearer",
				expires_at = expires_at,
				scope = decoded.scope or token.scope,
				-- Carry the refresh metadata forward so the *next* refresh works.
				token_endpoint = token.token_endpoint,
				client_id = token.client_id,
				resource = token.resource,
				raw = decoded,
			}, nil)
		end),
		on_error = vim.schedule_wrap(function(err)
			-- Network failure, not a rejected grant: distinct from re-auth-required
			-- so the caller can retry rather than forcing a full re-authorization.
			callback(nil, "token refresh: request failed: " .. (err.message or "unknown error"))
		end),
	})
end

return M
