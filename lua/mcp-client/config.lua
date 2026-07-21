--- Configuration and setup orchestration -- wires user config into the
--- rest of the plugin via `require("mcp-client").setup(opts)`. It:
---   * validates and normalizes the externally-supplied configuration;
---   * registers each configured native, in-process server via `native.register`;
---   * connects each configured remote server via `client.connect`, threading
---     an auto-constructed `TokenStore` into any non-localhost server that did
---     not bring its own;
---   * records what it set up in a small module-local state table that
---     `health.lua` reads back to build `:checkhealth mcp-client`.
---
--- Setup never triggers the interactive OAuth flow (`auth.dcr.run_flow`,
--- which opens a browser and blocks on a loopback redirect). A non-localhost
--- server with no stored token fails closed at the transport gate (tls.lua)
--- with an actionable error pointing at how to authenticate manually.

local commands = require("mcp-client.commands")
local mcp_client = require("mcp-client.client")
local native = require("mcp-client.native")
local tls = require("mcp-client.transport.tls")
local token_store = require("mcp-client.auth.token_store")

local M = {}

--- What `setup()` last wired up, for `health.lua` to read back. Purely a
--- reporting record -- the live client roster is always re-read from
--- `client.get_clients()`, never cached here.
local state = {
	servers = {}, ---@type table<string, { url: string, token_store: table|nil, connect_config: table|nil }>
	native_servers = {}, ---@type string[]
}

--- Public, read-only view of the setup record for health.lua. Per-server
--- entries expose only `{url, token_store}` -- never `connect_config`, which
--- can carry a plaintext credential in `.headers`. Returns a fresh table
--- (never the live internal one) so a caller cannot reach the withheld field
--- by walking the returned object's metatable/internals either.
--- @return table { servers = table<string, {url, token_store}>, native_servers = string[] }
function M.state()
	local servers = {}
	for name, record in pairs(state.servers) do
		servers[name] = { url = record.url, token_store = record.token_store }
	end
	return { servers = servers, native_servers = state.native_servers }
end

--- Convenience accessor for one server's record (nil if not configured).
--- Never exposes `connect_config` -- see `M._connect_config` below for the
--- internal-only accessor that does.
--- @param name string
--- @return table|nil { url, token_store }
function M.get_hub(name)
	local record = state.servers[name]
	if record == nil then
		return nil
	end
	return { url = record.url, token_store = record.token_store }
end

--- Internal-only accessor for the exact table `connect_server` built and
--- passed to `mcp_client.connect`, so `commands.lua`'s `authenticate` action
--- can reconnect a server exactly as `setup()` originally did (including its
--- `auth.token_store`, the same object as `get_hub(name).token_store`, not a
--- copy). Deliberately **not** exposed via `get_hub`/`state()`: unlike
--- `token_store` (an opaque object whose only read surface, `:status()`, is
--- already redacted), `connect_config` is a plain table whose `.headers` can
--- carry a plaintext credential (e.g. a custom `X-API-Key` header) -- so it
--- must never be reachable through this module's public accessors.
--- @param name string
--- @return table|nil
function M._connect_config(name)
	local record = state.servers[name]
	return record and record.connect_config or nil
end

--- Reset the setup record. Called by tests between specs, and internally at the
--- start of each `setup()`. Does not tear down live clients -- that is
--- `client._reset_registry()`'s job.
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
--- Both may be present. Each server config's `name` defaults to its map key
--- so health/get_clients can correlate it; an explicit `config.name` wins.
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

--- Resolve the TokenStore for one server:
---   * a caller-supplied `config.auth.token_store` is always honored as-is;
---   * a localhost server gets none (nothing to authenticate);
---   * a non-localhost server with no supplied store gets one auto-constructed,
---     keyed by server name, on the backend/data_home from `opts.token_store`
---     (defaults to auto-detected keychain/file).
--- Returns the store (or nil) and does NOT trigger any OAuth flow.
---
--- `store_opts.key`, if set, is always namespaced with the server's own `name`
--- (`"<key>:<name>"`), never used verbatim -- a bare override would collapse
--- every non-localhost server without its own `auth.token_store` onto the
--- same backing file/keychain entry, corrupting one server's credentials
--- with another's on the next refresh.
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
--- (client.connect consults `config.auth.token_store`), records the server
--- in the state table, and surfaces a connect error through an actionable
--- notification -- including, for the fail-closed no-token case, the
--- concrete steps the user can take to authenticate.
local function connect_server(name, server_config, store_opts)
	assert(
		type(server_config.url) == "string" and server_config.url ~= "",
		string.format("setup: server %q requires a `url`", tostring(name))
	)

	local store = resolve_token_store(name, server_config, store_opts)

	-- Thread the store into `auth` without clobbering other auth fields the
	-- caller set.
	local connect_config = vim.tbl_extend("force", {}, server_config)
	connect_config.name = server_config.name or name
	if store then
		connect_config.auth = vim.tbl_extend("force", server_config.auth or {}, { token_store = store })
	end

	state.servers[name] = { url = server_config.url, token_store = store, connect_config = connect_config }

	mcp_client.connect(connect_config, {
		on_connect = function(_client_object, err)
			if err then
				local msg = string.format("mcp-client: failed to connect server %q: %s", name, tostring(err))
				-- Append a concrete next step for the two credential-related
				-- failure shapes, rather than leaving the user with a dead end.
				if not tls.is_localhost(server_config.url) and store then
					local auth_status = store:status()
					if not auth_status.has_token then
						-- Fail-closed refusal: no credential configured at all.
						-- The snippet below saves to store.key (the resolved,
						-- possibly-namespaced key), not the bare server name --
						-- an `opts.token_store.key` prefix would otherwise make
						-- this snippet save the token where setup() never looks.
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
								store.key
							)
					elseif auth_status.expired then
						-- Stored token exists but refresh (already attempted before
						-- dialing) failed, e.g. a revoked refresh token or network error.
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
								store.key
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

--- The single glue entrypoint, delegated to from
--- `require("mcp-client").setup(opts)`.
---
--- @param opts table|nil
---   server            (table|nil)  a single server config (shorthand): { url, name?,
---                  headers?, reconnect?, auth?, ... } -- same shape client.connect's
---                  `config` accepts.
---   servers           (table|nil)  a map of `name -> server config` for one or more servers.
---                  `name` defaults to the map key.
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

	-- Disconnect and clear every previously-registered client first, so a
	-- second setup() call (the README documents this as how you re-apply
	-- config) replaces the prior roster instead of accumulating duplicate
	-- connections/native registrations alongside it.
	mcp_client._reset_registry()
	M._reset()

	-- Native, in-process servers registered first so they are already in
	-- get_clients() when adapters/health run.
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

	-- Remote servers, each with its resolved TokenStore.
	for name, server_config in pairs(collect_servers(opts)) do
		connect_server(name, server_config, opts.token_store)
	end

	-- Register :MCPAuth once state is populated so its no-argument
	-- resolution/completion see this setup()'s servers immediately.
	-- nvim_create_user_command overwrites an already-defined command of the
	-- same name, so a repeated setup() call is safe here.
	commands.register()
end

return M
