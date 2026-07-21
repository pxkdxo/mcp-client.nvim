--- Fail-closed transport-security gate.
---
--- This module does not implement TLS itself; plenary.curl's underlying curl
--- process performs the handshake and certificate verification. Its sole job
--- is a pre-connection policy check: before a connection to a non-localhost
--- server is opened, refuse it outright unless the URL uses https:// AND a
--- credential (bearer token) is configured. A localhost server is exempt.
---
--- The check is a pure function of the URL and a small, non-secret token-status
--- table; it never receives, echoes, or logs any token value.

local M = {}

--- The canonical loopback host identifiers exempt from the gate. Only these
--- exact forms are treated as localhost; any other 127.0.0.0/8 alias (e.g.
--- 127.0.0.2) is a real network address for policy purposes.
local LOCALHOST_HOSTS = {
	["localhost"] = true,
	["127.0.0.1"] = true,
	["::1"] = true,
	["[::1]"] = true,
	["0.0.0.0"] = true,
}

--- Extract the scheme (lowercased) and host (lowercased, port stripped) from a
--- URL. Returns scheme, host. Host is the bracketed form for IPv6 (e.g.
--- "[::1]") so it can be matched against LOCALHOST_HOSTS directly.
local function parse_url(url)
	local scheme = url:match("^(%a[%w+.-]*)://")
	scheme = scheme and scheme:lower() or nil

	local authority = url:match("^%a[%w+.-]*://([^/]*)") or ""
	-- Strip userinfo (user:pass@) if present.
	authority = authority:gsub("^[^@]*@", "")

	local host
	local bracketed = authority:match("^(%[[^%]]*%])")
	if bracketed then
		host = bracketed -- IPv6 literal, keep the brackets
	else
		host = authority:match("^([^:]*)")
	end
	host = host and host:lower() or ""
	return scheme, host
end

--- Is this URL's host one of the canonical loopback identifiers?
--- @param url string
--- @return boolean
function M.is_localhost(url)
	local _, host = parse_url(url)
	return LOCALHOST_HOSTS[host] == true
end

--- Decide whether a connection to `url` is allowed.
---
--- localhost: always allowed (no auth/TLS requirement).
--- non-localhost: allowed only if the scheme is https:// AND a token is present.
--- Otherwise refused (fail closed) with a clear, secret-free reason.
---
--- @param url string  the configured server URL
--- @param token_status table|nil  { has_token = boolean }, e.g. token_store:status()
---   Only the `has_token` flag is read; no token value is inspected or echoed.
--- @return boolean allowed, string|nil reason  reason is set iff not allowed
function M.check_connection_allowed(url, token_status)
	if M.is_localhost(url) then
		return true, nil
	end

	local scheme = parse_url(url)
	local has_tls = scheme == "https"
	local has_token = token_status ~= nil and token_status.has_token == true

	if has_tls and has_token then
		return true, nil
	end

	-- Build a reason that names exactly what is missing, never a token value.
	local missing = {}
	if not has_tls then
		table.insert(missing, "TLS (the server URL must use https:// for a non-localhost connection)")
	end
	if not has_token then
		table.insert(missing, "authentication (no bearer token is configured for this non-localhost server)")
	end

	return false,
		"refusing to connect (fail closed): a non-localhost server connection requires " .. table.concat(
			missing,
			" and "
		) .. "; refusing rather than connecting unauthenticated"
end

return M
