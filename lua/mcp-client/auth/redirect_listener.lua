--- OAuth 2.1 loopback redirect listener (RFC 8252 §7.3).
---
--- Hand-rolls HTTP on vim.uv instead of going through plenary.curl: the
--- authorization-code redirect leg is plaintext loopback by design (the
--- authorization server redirects the browser to
--- http://127.0.0.1:<port>/callback), so there is no TLS involved and no
--- need for curl. Every other HTTP(S) call in this plugin still uses curl.
---
--- Security invariants (do not weaken):
---   * Binds to 127.0.0.1 explicitly, never 0.0.0.0.
---   * `state` is validated BEFORE the authorization `code` is accepted;
---     a mismatched callback is rejected outright and its code is never
---     handed to the token-exchange stage.
---   * Single-shot and short-lived: fires `on_result` exactly once
---     (success, mismatch, error, or timeout), then closes immediately.
---   * No secrets in error text: a rejected callback's `code` is never
---     interpolated into an error message.
local uv = vim.uv or vim.loop

local RedirectListener = {}
RedirectListener.__index = RedirectListener

local DEFAULT_TIMEOUT_MS = 300000 -- 5 minutes for the user to complete the browser flow.

--- Percent-decode a single query-string value.
local function url_decode(value)
	value = value:gsub("+", " ")
	return (value:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

--- Parse "a=1&b=2" into a table of decoded key/value pairs.
local function parse_query(query)
	local params = {}
	for pair in query:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]+)=?(.*)$")
		if key then
			params[url_decode(key)] = url_decode(value)
		end
	end
	return params
end

--- @param opts table
---   expected_state (string, required) the per-flow state to validate against
---   on_result      (fun(result: table), required) called exactly once with
---                  one of:
---                    { code = string }                -- state validated, code captured
---                    { err  = string }                -- mismatch/AS error/timeout
---                  Never carries a rejected code in the error text.
---   timeout_ms     (number|nil) how long to wait for a callback (default 5min)
function RedirectListener.new(opts)
	assert(type(opts) == "table", "opts table is required")
	assert(type(opts.expected_state) == "string" and opts.expected_state ~= "", "expected_state is required")
	assert(type(opts.on_result) == "function", "on_result is required")

	return setmetatable({
		_expected_state = opts.expected_state,
		_on_result = opts.on_result,
		_timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
		_done = false,
		_server = nil,
		_timer = nil,
		_clients = {},
		port = nil,
		redirect_uri = nil,
	}, RedirectListener)
end

--- Replace the result handler after construction. Useful when a caller must
--- start() the listener first (to learn its ephemeral port / redirect_uri)
--- before it can build the closure that consumes the result. If a result has
--- already fired, this is a no-op.
--- @param on_result fun(result: table)
function RedirectListener:set_on_result(on_result)
	assert(type(on_result) == "function", "on_result must be a function")
	self._on_result = on_result
end

--- Bind the listener and begin accepting the single redirect callback.
--- @return boolean started, string|nil err
function RedirectListener:start()
	local server = uv.new_tcp()
	-- Explicit loopback bind. Port 0 asks the OS for an ephemeral port.
	local ok, bind_err = pcall(function()
		assert(server:bind("127.0.0.1", 0))
	end)
	if not ok then
		if not server:is_closing() then
			server:close()
		end
		return false, "could not bind loopback redirect listener: " .. tostring(bind_err)
	end

	self._server = server
	self.port = server:getsockname().port
	self.redirect_uri = string.format("http://127.0.0.1:%d/callback", self.port)

	server:listen(16, function(listen_err)
		if listen_err or self._done then
			return
		end
		self:_accept()
	end)

	self._timer = uv.new_timer()
	self._timer:start(self._timeout_ms, 0, function()
		self:_finish({ err = "authorization timed out waiting for redirect callback" })
	end)

	return true
end

function RedirectListener:_accept()
	local client = uv.new_tcp()
	local ok = pcall(function()
		self._server:accept(client)
	end)
	if not ok then
		if not client:is_closing() then
			client:close()
		end
		return
	end
	table.insert(self._clients, client)

	local buf = ""
	client:read_start(function(read_err, chunk)
		if read_err then
			if not client:is_closing() then
				client:close()
			end
			return
		end
		if not chunk then
			return
		end
		buf = buf .. chunk

		-- We only need the request line; wait until the header block terminates.
		if not buf:find("\r\n\r\n", 1, true) then
			return
		end

		local path = buf:match("^%u+%s+(%S+)%s+HTTP/")
		self:_respond(client)
		self:_handle_callback(path)
	end)
end

--- Send a fixed, secret-free browser-facing page, then move on. The response
--- body deliberately contains no code, state, or token -- just a human note.
function RedirectListener:_respond(client)
	local body = "<!doctype html><html><body>"
		.. "<p>Authorization received. You can close this window and return to Neovim.</p>"
		.. "</body></html>"
	local response = "HTTP/1.1 200 OK\r\n"
		.. "Content-Type: text/html\r\n"
		.. "Content-Length: "
		.. tostring(#body)
		.. "\r\n"
		.. "Connection: close\r\n\r\n"
		.. body
	pcall(function()
		client:write(response, function()
			if not client:is_closing() then
				client:close()
			end
		end)
	end)
end

--- Validate the callback and, only on a validated state, capture the code.
function RedirectListener:_handle_callback(path)
	if self._done then
		return
	end

	local query = path and path:match("%?(.*)$") or ""
	local params = parse_query(query)

	-- State must be validated before the code or error field is read; a
	-- missing state (nil) also fails this equality check.
	if params.state ~= self._expected_state then
		return self:_finish({ err = "authorization redirect rejected: state parameter did not match" })
	end

	-- Past the state gate, an AS may redirect back with an OAuth error
	-- instead of a code (RFC 6749 §4.1.2.1). The error code is safe to
	-- surface -- it carries no secret.
	if params.error and params.error ~= "" then
		return self:_finish({
			err = "authorization server returned error: " .. params.error,
		})
	end

	if not params.code or params.code == "" then
		return self:_finish({ err = "authorization redirect carried no code" })
	end

	return self:_finish({ code = params.code })
end

--- Deliver the (single) result and tear everything down. Idempotent: only
--- the first call fires on_result; later calls are no-ops.
function RedirectListener:_finish(result)
	if self._done then
		return
	end
	self._done = true
	self:_teardown()
	self._on_result(result)
end

function RedirectListener:_teardown()
	if self._timer and not self._timer:is_closing() then
		self._timer:stop()
		self._timer:close()
	end
	self._timer = nil

	for _, client in ipairs(self._clients) do
		if not client:is_closing() then
			client:close()
		end
	end
	self._clients = {}

	if self._server and not self._server:is_closing() then
		self._server:close()
	end
	self._server = nil
end

--- Explicit teardown for callers/tests that abandon the flow before a
--- callback arrives. Safe to call multiple times; does not fire on_result.
function RedirectListener:close()
	self._done = true
	self:_teardown()
end

return RedirectListener
