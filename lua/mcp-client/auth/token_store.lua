--- Persistent OAuth token storage.
---
--- A token result (the typed table dcr.exchange_code_for_token / refresh.refresh
--- produce -- access_token, refresh_token, expires_at, token_endpoint,
--- client_id, resource, ...) is persisted between Neovim sessions so a server
--- connection does not force a fresh OAuth flow every launch.
---
--- Two backends, chosen automatically (overridable for tests):
---   * keychain -- the OS keychain where a binding exists. On macOS this is the
---     `security` generic-password CLI. The secret material lives in the
---     keychain; nothing touches disk.
---   * file     -- a 0600-permissioned JSON file under $XDG_DATA_HOME/mcp-client/
---     when no keychain binding is available. Never world-readable, always
---     outside the repository checkout, and (living under $XDG_DATA_HOME) never
---     committed to version control.
---
--- Security invariants:
---   * No secret (access token, refresh token) ever appears in a log line, an
---     error message, or the status table exposed for :checkhealth.
---   * The file backend chmods to 0600 immediately after writing.

local M = {}

local KEYCHAIN_SERVICE = "mcp-client"

--- Default command runner for the keychain backend: runs argv synchronously and
--- returns { code = number, stdout = string }. Injectable via opts for tests so
--- specs never touch the real login keychain.
local function default_command_runner(argv)
	local out = vim.fn.system(argv)
	return { code = vim.v.shell_error, stdout = out }
end

--- Which backend is available on this host? macOS with the `security` CLI on
--- PATH gets the keychain; everything else falls back to the file backend.
--- (No Linux Secret Service / libsecret binding is wired up here yet; the file
--- backend still meets the "never world-readable, never committed" bar.)
local function detect_backend()
	if vim.fn.has("mac") == 1 and vim.fn.executable("security") == 1 then
		return "keychain"
	end
	return "file"
end

--- Resolve the $XDG_DATA_HOME base directory (default ~/.local/share), honoring
--- an explicit override for tests. This is deliberately outside any repository
--- checkout.
local function data_home_dir(override)
	if override and override ~= "" then
		return override
	end
	local xdg = vim.env.XDG_DATA_HOME
	if xdg and xdg ~= "" then
		return xdg
	end
	return vim.fn.expand("~/.local/share")
end

--- A filesystem-safe token derived from an arbitrary store key, for use in a
--- filename or a keychain account name.
local function safe_key(key)
	return (tostring(key):gsub("[^%w%-._]", "_"))
end

--- @class TokenStore
--- @field key string
--- @field backend "keychain"|"file"
local TokenStore = {}
TokenStore.__index = TokenStore

--- @param opts table
---   key            (string) identifies which server this token belongs to (e.g.
---                  the server URL or host); scopes storage so multiple servers coexist.
---   backend        ("keychain"|"file"|nil) force a backend; auto-detected if nil.
---   data_home      (string|nil) override $XDG_DATA_HOME base (tests).
---   command_runner (fun(argv)->{code,stdout}|nil) override the keychain CLI
---                  runner (tests); defaults to a synchronous vim.fn.system.
--- @return TokenStore
function M.new(opts)
	opts = opts or {}
	assert(type(opts.key) == "string" and opts.key ~= "", "token_store: key is required")
	return setmetatable({
		key = opts.key,
		backend = opts.backend or detect_backend(),
		_data_home = opts.data_home,
		_run = opts.command_runner or default_command_runner,
	}, TokenStore)
end

-- ---------------------------------------------------------------------------
-- Serialization. The persisted form is only the fields needed to reuse and
-- refresh the token; `raw` (which may carry AS-specific extras) is intentionally
-- not persisted to keep the stored blob minimal and predictable.
-- ---------------------------------------------------------------------------

local PERSISTED_FIELDS = {
	"access_token",
	"refresh_token",
	"token_type",
	"expires_at",
	"scope",
	"token_endpoint",
	"client_id",
	"resource",
}

local function serialize(token)
	local slim = {}
	for _, field in ipairs(PERSISTED_FIELDS) do
		slim[field] = token[field]
	end
	return vim.json.encode(slim)
end

local function deserialize(blob)
	if not blob or blob == "" then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, blob)
	if not ok or type(decoded) ~= "table" or type(decoded.access_token) ~= "string" then
		return nil
	end
	return decoded
end

-- ---------------------------------------------------------------------------
-- File backend.
-- ---------------------------------------------------------------------------

function TokenStore:path()
	local dir = data_home_dir(self._data_home) .. "/mcp-client"
	return dir .. "/token-" .. safe_key(self.key) .. ".json"
end

function TokenStore:_file_save(blob)
	local path = self:path()
	local dir = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(dir, "p")
	-- Restrict the directory too, so a token file created inside it is not
	-- listable by other users.
	pcall(vim.loop.fs_chmod, dir, tonumber("700", 8))

	-- Create the file with 0600 from the outset (open with the restrictive mode)
	-- rather than writing world-readable then chmod'ing, to avoid a window where
	-- the secret is readable.
	local fd, open_err = vim.loop.fs_open(path, "w", tonumber("600", 8))
	if not fd then
		return false, "token_store: could not open token file for writing: " .. tostring(open_err)
	end
	vim.loop.fs_write(fd, blob)
	vim.loop.fs_close(fd)
	-- Enforce 0600 explicitly in case the umask widened the create mode.
	pcall(vim.loop.fs_chmod, path, tonumber("600", 8))
	return true, nil
end

function TokenStore:_file_load()
	local path = self:path()
	local fd = vim.loop.fs_open(path, "r", tonumber("600", 8))
	if not fd then
		return nil
	end
	local stat = vim.loop.fs_fstat(fd)
	local blob = stat and stat.size > 0 and vim.loop.fs_read(fd, stat.size, 0) or ""
	vim.loop.fs_close(fd)
	return blob
end

function TokenStore:_file_clear()
	pcall(vim.loop.fs_unlink, self:path())
end

-- ---------------------------------------------------------------------------
-- Keychain backend (macOS `security` generic-password).
-- ---------------------------------------------------------------------------

function TokenStore:_keychain_save(blob)
	-- -U updates the item if it already exists (otherwise add fails on a repeat
	-- save). -w LAST carries the secret value. The blob is JSON, opaque to the
	-- keychain.
	local res = self._run({
		"security",
		"add-generic-password",
		"-U",
		"-s",
		KEYCHAIN_SERVICE,
		"-a",
		safe_key(self.key),
		"-w",
		blob,
	})
	if res.code ~= 0 then
		return false, "token_store: keychain write failed"
	end
	return true, nil
end

function TokenStore:_keychain_load()
	-- -w prints ONLY the password to stdout; find returns 44 (SecItemNotFound)
	-- when absent.
	local res = self._run({
		"security",
		"find-generic-password",
		"-s",
		KEYCHAIN_SERVICE,
		"-a",
		safe_key(self.key),
		"-w",
	})
	if res.code ~= 0 then
		return nil
	end
	return (res.stdout or ""):gsub("%s+$", "")
end

function TokenStore:_keychain_clear()
	self._run({
		"security",
		"delete-generic-password",
		"-s",
		KEYCHAIN_SERVICE,
		"-a",
		safe_key(self.key),
	})
end

-- ---------------------------------------------------------------------------
-- Public instance API.
-- ---------------------------------------------------------------------------

--- Persist a token result. Returns (true, nil) or (false, error) -- the error
--- string never contains any token material.
--- @param token table  a typed token result
--- @return boolean ok, string|nil err
function TokenStore:save(token)
	assert(
		type(token) == "table" and type(token.access_token) == "string",
		"token_store: token with access_token required"
	)
	local blob = serialize(token)
	if self.backend == "keychain" then
		return self:_keychain_save(blob)
	end
	return self:_file_save(blob)
end

--- Load the persisted token result, or nil if none is stored / it is unreadable.
--- @return table|nil
function TokenStore:load()
	local blob
	if self.backend == "keychain" then
		blob = self:_keychain_load()
	else
		blob = self:_file_load()
	end
	return deserialize(blob)
end

--- Remove any persisted token.
function TokenStore:clear()
	if self.backend == "keychain" then
		self:_keychain_clear()
	else
		self:_file_clear()
	end
end

--- Non-secret status for :checkhealth and error messages. Reports presence
--- and expiry state ONLY -- never the token, refresh token, or any secret.
--- @return table {
---   backend           = "keychain"|"file",
---   has_token         = boolean,
---   has_refresh_token = boolean,
---   expires_at        = number|nil,   -- absolute unix time, non-secret
---   expired           = boolean,      -- true iff expires_at is in the past
--- }
function TokenStore:status()
	local token = self:load()
	if not token then
		return {
			backend = self.backend,
			has_token = false,
			has_refresh_token = false,
			expires_at = nil,
			expired = false,
		}
	end
	local expired = false
	if type(token.expires_at) == "number" then
		expired = token.expires_at <= os.time()
	end
	return {
		backend = self.backend,
		has_token = type(token.access_token) == "string",
		has_refresh_token = type(token.refresh_token) == "string",
		expires_at = type(token.expires_at) == "number" and token.expires_at or nil,
		expired = expired,
	}
end

-- ---------------------------------------------------------------------------
-- Bearer-header attachment (module-level; no store instance needed).
--
-- `entry.config.headers` is the same table reference reused across transport
-- (re)constructions and re-merged into every request, including after a
-- reconnect. Mutating it in place here keeps the Authorization header current
-- for every current and future transport without reaching into transport
-- internals.
-- ---------------------------------------------------------------------------

--- Set (or clear) the Authorization header on a headers table IN PLACE.
--- @param headers table  the shared config.headers table
--- @param token table|nil  a token result; nil clears the Authorization header
function M.apply_to_headers(headers, token)
	assert(type(headers) == "table", "token_store.apply_to_headers: headers table required")
	if not token or type(token.access_token) ~= "string" then
		headers["Authorization"] = nil
		return
	end
	local scheme = token.token_type
	if type(scheme) ~= "string" or scheme == "" then
		scheme = "Bearer"
	end
	headers["Authorization"] = scheme .. " " .. token.access_token
end

return M
