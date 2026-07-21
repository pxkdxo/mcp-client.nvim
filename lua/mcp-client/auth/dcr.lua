--- Client registration, token exchange, and full-flow orchestration for the
--- OAuth 2.1 Authorization Code + PKCE grant.
---
--- Also covers the token-exchange POST and the stage that stitches
--- discovery -> (DCR or configured client_id) -> PKCE -> loopback capture ->
--- token exchange into a single typed result, since both are RFC-defined
--- POSTs to the authorization server and this is the module that turns
--- discovery output into a token.
---
--- Networking: register() and exchange_code_for_token() POST to the
--- authorization server via plenary.curl (never raw vim.uv -- these are
--- HTTPS calls and libuv has no TLS). Only the loopback redirect leg uses
--- vim.uv, and that lives in redirect_listener.lua.
---
--- Secrets: the code_verifier, authorization code, access token, and refresh
--- token are never interpolated into a log line or error message here. Error
--- paths report OAuth error *codes* (e.g. "invalid_grant") and endpoints,
--- never token or code values.
local curl = require("plenary.curl")

local discovery = require("mcp-client.auth.discovery")
local pkce = require("mcp-client.auth.pkce")
local RedirectListener = require("mcp-client.auth.redirect_listener")

local M = {}

local REQUEST_TIMEOUT_MS = 30000
local CLIENT_NAME = "mcp-client"

--- Percent-encode a string for use in an application/x-www-form-urlencoded
--- body or a query string (RFC 3986 unreserved characters pass through).
local function url_encode(value)
	return (tostring(value):gsub("[^%w%-._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--- Encode a table of params as an application/x-www-form-urlencoded string.
local function form_encode(params)
	local parts = {}
	for key, value in pairs(params) do
		table.insert(parts, url_encode(key) .. "=" .. url_encode(value))
	end
	return table.concat(parts, "&")
end

--- Extract an OAuth error code from a decoded error body, if present.
local function oauth_error(decoded)
	if type(decoded) == "table" and type(decoded.error) == "string" then
		return decoded.error
	end
	return nil
end

--- Perform RFC 7591 Dynamic Client Registration.
--- @param opts table
---   registration_endpoint (string, required)
---   redirect_uri          (string, required)
---   client_name           (string|nil)
--- @param callback fun(result: table|nil, err: string|nil)
---   On success, result = { client_id = string, raw = table }
function M.register(opts, callback)
	assert(opts.registration_endpoint, "registration_endpoint is required")
	assert(opts.redirect_uri, "redirect_uri is required")

	local body = vim.json.encode({
		client_name = opts.client_name or CLIENT_NAME,
		redirect_uris = { opts.redirect_uri },
		grant_types = { "authorization_code", "refresh_token" },
		response_types = { "code" },
		token_endpoint_auth_method = "none", -- public client: no secret
	})

	curl.post(opts.registration_endpoint, {
		headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
		body = body,
		timeout = REQUEST_TIMEOUT_MS,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return callback(nil, "dynamic client registration: no response")
			end
			local ok, decoded = pcall(vim.json.decode, response.body)
			if response.status < 200 or response.status >= 300 then
				local code = ok and oauth_error(decoded)
				return callback(
					nil,
					string.format(
						"dynamic client registration: endpoint returned status %d%s",
						response.status,
						code and (" (" .. code .. ")") or ""
					)
				)
			end
			if not ok or type(decoded) ~= "table" or type(decoded.client_id) ~= "string" then
				return callback(nil, "dynamic client registration: response missing client_id")
			end
			return callback({ client_id = decoded.client_id, raw = decoded }, nil)
		end),
		on_error = vim.schedule_wrap(function(err)
			callback(nil, "dynamic client registration: request failed: " .. (err.message or "unknown error"))
		end),
	})
end

--- Build the authorization request URL (RFC 6749 §4.1.1 + PKCE + RFC 8707
--- resource). The redirect_uri and resource are percent-encoded; state and
--- code_challenge come from the pkce module.
--- @param opts table {
---   authorization_endpoint, client_id, redirect_uri, code_challenge,
---   state, resource, scope (optional)
--- }
--- @return string
function M.build_authorization_url(opts)
	local params = {
		response_type = "code",
		client_id = opts.client_id,
		redirect_uri = opts.redirect_uri,
		code_challenge = opts.code_challenge,
		code_challenge_method = "S256",
		state = opts.state,
		resource = opts.resource,
	}
	if opts.scope then
		params.scope = opts.scope
	end
	local sep = opts.authorization_endpoint:find("?", 1, true) and "&" or "?"
	return opts.authorization_endpoint .. sep .. form_encode(params)
end

--- Exchange an authorization code for tokens (RFC 6749 §4.1.3 + PKCE §4.5 +
--- RFC 8707 resource).
--- @param opts table {
---   token_endpoint, code, code_verifier, client_id, redirect_uri, resource
--- }
--- @param callback fun(result: table|nil, err: string|nil)
---   On success, result = {
---     access_token   = string,       -- SECRET
---     refresh_token  = string|nil,   -- SECRET, present iff issued
---     token_type     = string,       -- e.g. "Bearer"
---     expires_at     = number|nil,   -- absolute unix time (os.time-based)
---     scope          = string|nil,
---     -- metadata needed to refresh later, none of it secret:
---     token_endpoint = string,
---     client_id      = string,
---     resource       = string,
---     raw            = table,        -- full decoded token response
---   }
function M.exchange_code_for_token(opts, callback)
	local body = form_encode({
		grant_type = "authorization_code",
		code = opts.code,
		redirect_uri = opts.redirect_uri,
		client_id = opts.client_id,
		code_verifier = opts.code_verifier,
		resource = opts.resource,
	})

	curl.post(opts.token_endpoint, {
		headers = {
			["Content-Type"] = "application/x-www-form-urlencoded",
			["Accept"] = "application/json",
		},
		body = body,
		timeout = REQUEST_TIMEOUT_MS,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return callback(nil, "token exchange: no response from token endpoint")
			end
			local ok, decoded = pcall(vim.json.decode, response.body)
			if response.status < 200 or response.status >= 300 then
				local code = ok and oauth_error(decoded)
				return callback(
					nil,
					string.format(
						"token exchange: token endpoint returned status %d%s",
						response.status,
						code and (" (" .. code .. ")") or ""
					)
				)
			end
			if not ok or type(decoded) ~= "table" or type(decoded.access_token) ~= "string" then
				return callback(nil, "token exchange: token endpoint response missing access_token")
			end

			local expires_at
			if type(decoded.expires_in) == "number" then
				expires_at = os.time() + decoded.expires_in
			end

			return callback({
				access_token = decoded.access_token,
				refresh_token = decoded.refresh_token,
				token_type = decoded.token_type or "Bearer",
				expires_at = expires_at,
				scope = decoded.scope,
				token_endpoint = opts.token_endpoint,
				client_id = opts.client_id,
				resource = opts.resource,
				raw = decoded,
			}, nil)
		end),
		on_error = vim.schedule_wrap(function(err)
			callback(nil, "token exchange: request failed: " .. (err.message or "unknown error"))
		end),
	})
end

--- Default OS browser-open. Detects the platform's opener and spawns it
--- detached. Returns true if a command was launched, false if none is
--- available (e.g. headless/SSH with no GUI opener on PATH).
--- @param url string
--- @return boolean opened
local function default_open_url(url)
	local candidates
	if vim.fn.has("mac") == 1 then
		candidates = { "open" }
	elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		candidates = { "start" }
	else
		candidates = { "xdg-open" }
	end

	for _, cmd in ipairs(candidates) do
		if vim.fn.executable(cmd) == 1 then
			-- jobstart detached; we do not care about its output, only that a
			-- launcher exists and was invoked with the URL.
			local ok = pcall(vim.fn.jobstart, { cmd, url }, { detach = true })
			if ok then
				return true
			end
		end
	end
	return false
end

--- Default manual-entry prompt used when no browser opens. Shows the URL and
--- blocks for the user to paste the code back. Returns the code or nil.
--- @param url string
--- @return string|nil
local function default_prompt_for_code(url)
	vim.notify(
		"mcp-client: could not open a browser automatically.\n"
			.. "Open this URL to authorize, then paste the resulting code:\n"
			.. url,
		vim.log.levels.WARN
	)
	local code = vim.fn.input("Authorization code: ")
	if code == nil or code == "" then
		return nil
	end
	return code
end

--- Run the full discovery-through-token-exchange flow and hand the typed
--- token result to `callback`. Each stage failure surfaces a specific,
--- stage-labeled error.
---
--- @param opts table
---   server_url             (string, required) the non-localhost server MCP URL
---   client_id           (string|nil) fallback client_id when the AS has no DCR
---   scope               (string|nil) requested scope
---   redirect_timeout_ms (number|nil) how long to await the redirect callback
---   open_url            (fun(url):boolean|nil) browser opener (injectable for tests)
---   prompt_for_code     (fun(url):string|nil) manual-entry fallback (injectable)
--- @param callback fun(result: table|nil, err: string|nil)
---   result is the typed token-exchange result from exchange_code_for_token.
function M.run_flow(opts, callback)
	assert(opts.server_url, "server_url is required")
	local open_url = opts.open_url or default_open_url
	local prompt_for_code = opts.prompt_for_code or default_prompt_for_code

	local done = false
	local function finish(result, err)
		if done then
			return
		end
		done = true
		callback(result, err)
	end

	-- Stage 1: probe the server for its 401 + WWW-Authenticate challenge to
	-- locate the PRM document.
	curl.get(opts.server_url, {
		timeout = REQUEST_TIMEOUT_MS,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return finish(nil, "discovery: no response from server")
			end

			local prm_url
			local transport_util = require("mcp-client.transport.util")
			local challenge = transport_util.find_header(response.headers, "WWW-Authenticate")
			if challenge then
				prm_url = discovery.parse_www_authenticate(challenge)
			end
			prm_url = prm_url or discovery.default_prm_url(opts.server_url)

			-- Stage 2: PRM -> authorization_servers.
			discovery.fetch_protected_resource_metadata(prm_url, function(prm, prm_err)
				if prm_err then
					return finish(nil, prm_err)
				end
				local resource = prm.resource or opts.server_url
				local issuer = prm.authorization_servers[1]

				-- Stage 3: AS metadata -> endpoints.
				discovery.fetch_authorization_server_metadata(issuer, function(as_meta, as_err)
					if as_err then
						return finish(nil, as_err)
					end

					-- Stage 4: obtain a client_id via DCR, else fall back.
					local function with_client_id(client_id)
						M._authorize_and_exchange({
							as_meta = as_meta,
							client_id = client_id,
							resource = resource,
							scope = opts.scope,
							redirect_timeout_ms = opts.redirect_timeout_ms,
							open_url = open_url,
							prompt_for_code = prompt_for_code,
						}, finish)
					end

					if as_meta.registration_endpoint then
						-- DCR path: the listener must bind first so registration can
						-- name the real loopback redirect_uri (its ephemeral port is
						-- unknown until then).
						return M._register_then_authorize({
							as_meta = as_meta,
							resource = resource,
							scope = opts.scope,
							redirect_timeout_ms = opts.redirect_timeout_ms,
							open_url = open_url,
							prompt_for_code = prompt_for_code,
						}, finish)
					end

					if not opts.client_id then
						return finish(
							nil,
							"client registration: authorization server has no registration_endpoint "
								.. "and no fallback client_id was configured"
						)
					end
					return with_client_id(opts.client_id)
				end)
			end)
		end),
		on_error = vim.schedule_wrap(function(err)
			finish(nil, "discovery: request to server failed: " .. (err.message or "unknown error"))
		end),
	})
end

--- DCR path: stand up the listener (so we know the redirect_uri), register
--- against it, then run the authorization + exchange.
function M._register_then_authorize(args, finish)
	local pkce_pair = pkce.generate()
	local listener = RedirectListener.new({
		expected_state = pkce_pair.state,
		timeout_ms = args.redirect_timeout_ms,
		on_result = function() end, -- replaced below once we own it
	})

	-- We need the redirect_uri before registering, but RedirectListener only
	-- exposes it after start(). Rebuild with the real on_result once started.
	local started, start_err = listener:start()
	if not started then
		return finish(nil, "redirect listener: " .. tostring(start_err))
	end
	local redirect_uri = listener.redirect_uri

	M.register({
		registration_endpoint = args.as_meta.registration_endpoint,
		redirect_uri = redirect_uri,
	}, function(reg, reg_err)
		if reg_err then
			listener:close()
			return finish(nil, reg_err)
		end
		M._authorize_and_exchange({
			as_meta = args.as_meta,
			client_id = reg.client_id,
			resource = args.resource,
			scope = args.scope,
			open_url = args.open_url,
			prompt_for_code = args.prompt_for_code,
			listener = listener,
			pkce_pair = pkce_pair,
		}, finish)
	end)
end

--- Shared authorization-request + redirect-capture + token-exchange stage.
--- Accepts an already-started listener (DCR path) or stands one up itself
--- (fallback-client_id path).
function M._authorize_and_exchange(args, finish)
	local pkce_pair = args.pkce_pair or pkce.generate()
	local listener = args.listener

	local function proceed(redirect_uri)
		local auth_url = M.build_authorization_url({
			authorization_endpoint = args.as_meta.authorization_endpoint,
			client_id = args.client_id,
			redirect_uri = redirect_uri,
			code_challenge = pkce_pair.code_challenge,
			state = pkce_pair.state,
			resource = args.resource,
			scope = args.scope,
		})

		local function exchange(code)
			M.exchange_code_for_token({
				token_endpoint = args.as_meta.token_endpoint,
				code = code,
				code_verifier = pkce_pair.code_verifier,
				client_id = args.client_id,
				redirect_uri = redirect_uri,
				resource = args.resource,
			}, finish)
		end

		-- Wire up the loopback-callback handler BEFORE opening the browser, so a
		-- fast (or, in tests, synchronous) redirect cannot arrive before we are
		-- ready to consume it. The listener validates state and gates the code.
		listener:set_on_result(function(res)
			if res.err then
				return finish(nil, res.err)
			end
			return exchange(res.code)
		end)

		local opened = args.open_url(auth_url)
		if opened then
			-- The callback (or timeout) will drive the rest of the flow.
			return
		end

		-- No browser opened: close the listener and fall back to manual entry.
		listener:close()
		local code = args.prompt_for_code(auth_url)
		if not code then
			return finish(nil, "authorization: no browser opened and no code was entered manually")
		end
		return exchange(code)
	end

	if listener then
		-- DCR path handed us a started listener; its redirect_uri is known.
		return proceed(listener.redirect_uri)
	end

	-- Fallback path: create and start our own listener now.
	listener = RedirectListener.new({
		expected_state = pkce_pair.state,
		timeout_ms = args.redirect_timeout_ms,
		on_result = function() end,
	})
	local started, start_err = listener:start()
	if not started then
		return finish(nil, "redirect listener: " .. tostring(start_err))
	end
	return proceed(listener.redirect_uri)
end

return M
