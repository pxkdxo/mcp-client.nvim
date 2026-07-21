--- Configuration and setup orchestration (U8) -- the single "glue" call a
--- real user's config makes.
---
--- Every prior unit (U1-U7) built one piece; nothing wired them together into
--- the `require("mcp-client").setup(opts)` a user actually calls. This
--- module is that wiring. It:
---   * validates and normalizes the externally-supplied configuration -- so no
---     personal path, port, or credential lives in this plugin's source (R7);
---   * registers each configured native, in-process server via `native.register`
---     (U3);
---   * connects each configured remote server via `client.connect` (U2), threading
---     an auto-constructed `TokenStore` (U7) into any non-localhost server that did
---     not bring its own (design question 3);
---   * records what it set up in a small module-local state table that
---     `health.lua` (U8) reads back to build `:checkhealth mcp-client`,
---     without health.lua having to re-derive any of this wiring.
---
--- What it deliberately does NOT do (design question 3, explicit scope
--- boundary): it never *triggers* the interactive OAuth authorization flow
--- (`auth.dcr.run_flow`, which opens a browser and blocks on a loopback
--- redirect). A non-localhost server with no stored token yet fails closed at the
--- transport gate (R12, tls.lua) with a clear, actionable error; setup surfaces
--- that error and points the user at how to authenticate (see README and the
--- error text below). Auto-triggering a login on every Neovim startup is an
--- undesigned UX surface out of scope for this unit.

local mcp_client = require("mcp-client.client")
local native = require("mcp-client.native")
local tls = require("mcp-client.transport.tls")
local token_store = require("mcp-client.auth.token_store")

local M = {}

--- What `setup()` last wired up, for `health.lua` to read back. Purely a
--- reporting record: the live client roster is always re-read from
--- `client.get_clients()`, never cached here. Each `servers[name]` entry carries
--- the server's `url` and (if one was configured/constructed) its `token_store`.
local state = {
	servers = {}, ---@type table<string, { url: string, token_store: table|nil }>
	native_servers = {}, ---@type string[]
}

--- Public, read-only view of the setup record for health.lua.
--- @return table { servers = table<string, {url, token_store}>, native_servers = string[] }
function M.state()
	return state
end

--- Convenience accessor for one server's record (nil if not configured).
--- @param name string
--- @return table|nil { url, token_store }
function M.get_hub(name)
	return state.servers[name]
end

--- Reset the setup record. Called by tests between specs, and internally at the
--- start of each `setup()` so a re-`setup()` reflects only the latest config.
--- Does not tear down live clients -- that is `client._reset_registry()`'s job.
function M._reset()
	state = { servers = {}, native_servers = {} }
end

--- Record a server in the state table (used by setup, and directly by health specs
--- to construct scenarios without opening a real connection).
--- @param name string
--- @param record table { url = string, token_store = table|nil }
function M._record_hub(name, record)
	state.servers[name] = record
end

--- Record a native server name in the state table.
--- @param name string
function M._record_native(name)
	table.insert(state.native_servers, name)
end

--- Normalize the two accepted server-config shapes into a name->config map:
---   * `opts.server`  -- a single server config table (shorthand for one server);
---   * `opts.servers` -- a map of `name -> server config`.
--- Both may be present, though a single server is the common case (the dotfiles'
--- `server_url` singular). Each server config's `name` defaults to its map key so
--- health/get_clients can correlate it; an explicit `config.name` wins.
local function collect_servers(opts)
	local servers = {}
	if opts.server ~= nil then
		assert(type(opts.server) == "table", "setup: `server` must be a table")
		local name = opts.server.name or "default"
		servers[name] = opts.server
	end
	if opts.servers ~= nil then
		assert(type(opts.servers) == "table", "setup: `servers` must be a table (name -> server config)")
		for name, cfg in pairs(opts.servers) do
			assert(type(cfg) == "table", string.format("setup: server %q config must be a table", tostring(name)))
			servers[name] = cfg
		end
	end
	return servers
end

--- Resolve the TokenStore for one server, per design question 3:
---   * a caller-supplied `config.auth.token_store` is always honored as-is;
---   * a localhost server gets none (the R12 gate exempts localhost, and there is
---     nothing to authenticate);
---   * a non-localhost server with no supplied store gets one auto-constructed,
---     keyed by server name, on the backend/data_home from `opts.token_store`
---     (defaults to auto-detected keychain/file).
--- Returns the store (or nil) and does NOT trigger any OAuth flow.
---
--- `store_opts.key`, if set, is always namespaced with the server's own `name`
--- (`"<key>:<name>"`), never used verbatim: `opts.token_store.key` is a single
--- global default shared across every server in one `setup()` call, and a bare
--- override would collapse every non-localhost server without its own
--- `auth.token_store` onto the exact same backing file/keychain entry --
--- silently corrupting one server's stored credentials with another's on the
--- next refresh. Namespacing by name preserves `key`'s only legitimate
--- purpose (a stable per-deployment/per-profile prefix) while keeping
--- distinct servers' storage always distinct.
local function resolve_token_store(name, server_config, store_opts)
	local supplied = server_config.auth and server_config.auth.token_store or nil
	if supplied then
		return supplied
	end
	if tls.is_localhost(server_config.url) then
		return nil
	end
	store_opts = store_opts or {}
	local key = name
	if store_opts.key then
		key = store_opts.key .. ":" .. name
	end
	return token_store.new({
		key = key,
		backend = store_opts.backend,
		data_home = store_opts.data_home,
	})
end

--- Connect one server. Threads the resolved TokenStore into `config.auth`
--- (client.connect consults `config.auth.token_store`, U7), records the server in
--- the state table, and surfaces a connect error through an actionable
--- notification -- including, for the fail-closed no-token case, the concrete
--- next step the user can take to authenticate (design question 3: a real,
--- working manual mechanism, not a bare "no token configured").
local function connect_server(name, server_config, store_opts)
	assert(
		type(server_config.url) == "string" and server_config.url ~= "",
		string.format("setup: server %q requires a `url`", tostring(name))
	)

	local store = resolve_token_store(name, server_config, store_opts)

	-- Build the connect config: start from the user's server config, force the
	-- resolved name, and thread the store into `auth` without clobbering any
	-- other auth fields the caller set.
	local connect_config = vim.tbl_extend("force", {}, server_config)
	connect_config.name = server_config.name or name
	if store then
		connect_config.auth = vim.tbl_extend("force", server_config.auth or {}, { token_store = store })
	end

	state.servers[name] = { url = server_config.url, token_store = store }

	mcp_client.connect(connect_config, {
		on_connect = function(_client_object, err)
			if err then
				local msg = string.format("mcp-client: failed to connect server %q: %s", name, tostring(err))
				-- Append a concrete next step for the two credential-related
				-- failure shapes, rather than leaving the user with a dead end.
				-- (These are documented manual mechanisms, not an auto-login --
				-- see design question 3 / the README.)
				if not tls.is_localhost(server_config.url) and store then
					local auth_status = store:status()
					if not auth_status.has_token then
						-- R12 fail-closed refusal: no credential configured at all.
						msg = msg
							.. "\n"
							.. string.format(
								"No stored token for this server yet. Authenticate once with:\n"
									.. "  require('mcp-client.auth.dcr').run_flow({ server_url = %q }, function(token, ferr)\n"
									.. "    if token then require('mcp-client.auth.token_store')\n"
									.. "      .new({ key = %q }):save(token) end\n"
									.. "  end)\n"
									.. "then re-run setup() (or restart Neovim).",
								server_config.url,
								name
							)
					elseif auth_status.expired then
						-- A stored token exists (M.connect already tried to refresh
						-- it before dialing) but the connection still failed --
						-- commonly the refresh itself failed (revoked/expired
						-- refresh token, or a network error). Re-authentication is
						-- the same manual mechanism as the no-token case above.
						msg = msg
							.. "\n"
							.. string.format(
								"The stored token was expired and the automatic refresh failed. "
									.. "Re-authenticate once with:\n"
									.. "  require('mcp-client.auth.dcr').run_flow({ server_url = %q }, function(token, ferr)\n"
									.. "    if token then require('mcp-client.auth.token_store')\n"
									.. "      .new({ key = %q }):save(token) end\n"
									.. "  end)\n"
									.. "then re-run setup() (or restart Neovim) -- or, if this looks like a "
									.. "transient network failure rather than a revoked token, just retry.",
								server_config.url,
								name
							)
					end
				end
				vim.schedule(function()
					vim.notify(msg, vim.log.levels.WARN)
				end)
			end
		end,
	})
end

--- The single glue entrypoint. All configuration is externally supplied here
--- (R7). Delegated to from `require("mcp-client").setup(opts)`.
---
--- @param opts table|nil
---   server            (table|nil)  a single server config (shorthand): { url, name?,
---                  headers?, reconnect?, auth?, ... } -- same shape client.connect's
---                  `config` accepts.
---   servers           (table|nil)  a map of `name -> server config` for one or more servers
---                  (R7's plural "server list"). `name` defaults to the map key.
---   native_servers (table|nil)  a map of `name -> native server config`
---                  (`tools`/`resources`/`prompts` tables; native.register's shape).
---                  A config with no `name` uses its map key.
---   token_store    (table|nil)  defaults for auto-constructed TokenStores:
---                  { backend?, data_home?, key? } -- forwarded to token_store.new.
---                  Only used for non-localhost servers that did not supply their own
---                  `auth.token_store`. `key`, if set, is a shared prefix namespaced
---                  per-server (`"<key>:<server name>"`), never a verbatim override -- it
---                  cannot be used to collapse two servers onto the same stored token.
function M.setup(opts)
	opts = opts or {}
	assert(type(opts) == "table", "setup: opts must be a table")

	M._reset()

	-- 1. Native, in-process servers (U3). Registered first so they are already
	--    in get_clients() when adapters/health run.
	if opts.native_servers ~= nil then
		assert(type(opts.native_servers) == "table", "setup: `native_servers` must be a table")
		for key, server_config in pairs(opts.native_servers) do
			assert(
				type(server_config) == "table",
				string.format("setup: native server %q config must be a table", tostring(key))
			)
			local server = vim.tbl_extend("force", {}, server_config)
			server.name = server_config.name or key
			native.register(server)
			M._record_native(server.name)
		end
	end

	-- 2. Remote servers (U2), each with its resolved TokenStore (U7).
	for name, server_config in pairs(collect_servers(opts)) do
		connect_server(name, server_config, opts.token_store)
	end
end

return M
