--- Native, in-process MCP server registration.
---
--- A native server is a config table styled after `mcphub.nvim`'s existing
--- `native_servers` shape: `name` plus `tools`/`resources`/`prompts` tables
--- of plain Lua functions. `M.register(config)` wraps it in the exact same
--- client object shape `client.lua` exposes for a remote server connection
--- (`id`, `name`, `is_stopped()`, `request`, `notify`) and adds it to the
--- same registry `get_clients()` reads from (via `client.register_native`),
--- so adapters built against that shape cannot tell a native server from a
--- remote one.
---
--- No concrete native servers ship here -- see
--- `tests/fixtures/example_native_server.lua` for a minimal example.
---
--- `request(rpc_message, callback)` short-circuits straight to a direct Lua
--- function call instead of any network round-trip. Supported MCP methods
--- mirror the three capability tables:
---   tools/call      params = { name, arguments } -> tools[name](arguments)
---   resources/read  params = { uri }             -> resources[uri](params)
---   prompts/get     params = { name, arguments }  -> prompts[name](arguments)

local client = require("mcp-client.client")

local M = {}

--- Build the MCP-shaped listing for one capability table (`tools`,
--- `resources`, or `prompts`), sorted by name for a deterministic order.
--- Each entry's `meta` sidecar (`entry.tool_meta`/`resource_meta`/
--- `prompt_meta`, keyed by the same name) is merged in when present, so a
--- native server can optionally advertise a `description`/`inputSchema`/etc.
--- alongside the bare name a caller gets for free from the capability
--- table's keys alone.
local function build_listing(capability_table, meta_table, id_field)
	meta_table = meta_table or {}
	local names = {}
	for name in pairs(capability_table) do
		table.insert(names, name)
	end
	table.sort(names)

	local listing = {}
	for _, name in ipairs(names) do
		local entry_meta = meta_table[name] or {}
		local item = vim.tbl_extend("force", {}, entry_meta, { [id_field] = name })
		table.insert(listing, item)
	end
	return listing
end

--- Resolve an MCP method to a handler against a native server's capability
--- tables. Returns handler, args, nil on success or nil, nil, err if the
--- method or key is unsupported/missing. The `*/list` methods return a
--- synthetic zero-argument handler wrapping the listing table, so the call
--- site in `request()` doesn't need a separate code path for them.
local function resolve_handler(entry, method, params)
	params = params or {}
	if method == "tools/call" then
		local name = params.name
		local fn = entry.tools[name]
		if not fn then
			return nil, nil, string.format("native server %q has no tool %q", entry.name, tostring(name))
		end
		return fn, params.arguments or {}, nil
	elseif method == "resources/read" then
		local uri = params.uri
		local fn = entry.resources[uri]
		if not fn then
			return nil, nil, string.format("native server %q has no resource %q", entry.name, tostring(uri))
		end
		return fn, params, nil
	elseif method == "prompts/get" then
		local name = params.name
		local fn = entry.prompts[name]
		if not fn then
			return nil, nil, string.format("native server %q has no prompt %q", entry.name, tostring(name))
		end
		return fn, params.arguments or {}, nil
	elseif method == "tools/list" then
		local listing = build_listing(entry.tools, entry.tool_meta, "name")
		return function()
			return { tools = listing }
		end, {}, nil
	elseif method == "resources/list" then
		local listing = build_listing(entry.resources, entry.resource_meta, "uri")
		return function()
			return { resources = listing }
		end, {}, nil
	elseif method == "prompts/list" then
		local listing = build_listing(entry.prompts, entry.prompt_meta, "name")
		return function()
			return { prompts = listing }
		end, {}, nil
	end
	return nil, nil, string.format("native server %q does not support method %q", entry.name, tostring(method))
end

--- Register a native server config and return the client object.
--- @param config table
---   name          (string) the server's name, as reported through `get_clients()`
---   tools         (table|nil) map of tool name -> fun(arguments) -> result
---   resources     (table|nil) map of resource uri -> fun(params) -> result
---   prompts       (table|nil) map of prompt name -> fun(arguments) -> result
---   tool_meta     (table|nil) map of tool name -> { description, inputSchema, ... },
---     merged into that tool's `tools/list` entry (e.g. for an adapter that
---     needs a description/param schema per tool, not just its name)
---   resource_meta (table|nil) same shape as `tool_meta`, for `resources/list`
---   prompt_meta   (table|nil) same shape as `tool_meta`, for `prompts/list`
--- @return table client object: id, name, is_stopped(), request(), notify()
function M.register(config)
	assert(type(config) == "table", "config table is required")
	assert(type(config.name) == "string" and config.name ~= "", "config.name is required")

	local entry = {
		name = config.name,
		tools = config.tools or {},
		resources = config.resources or {},
		prompts = config.prompts or {},
		tool_meta = config.tool_meta or {},
		resource_meta = config.resource_meta or {},
		prompt_meta = config.prompt_meta or {},
		_stopped = false,
	}

	local obj = {
		name = entry.name,
		config = config,
	}

	function obj:is_stopped()
		return entry._stopped
	end

	--- `pcall` turns a Lua error raised inside a handler into an
	--- `(err, result, response)` callback instead of an uncaught exception.
	function obj:request(rpc_message, callback)
		assert(type(callback) == "function", "callback is required")
		rpc_message = rpc_message or {}

		if entry._stopped then
			return callback("native server is stopped", nil, nil)
		end

		local handler, args, resolve_err = resolve_handler(entry, rpc_message.method, rpc_message.params)
		if resolve_err then
			return callback(resolve_err, nil, nil)
		end

		local ok, result_or_err = pcall(handler, args)
		if not ok then
			return callback(result_or_err, nil, nil)
		end
		return callback(nil, result_or_err, nil)
	end

	--- Native servers have no persistent connection to push messages down;
	--- accept and discard so callers generic over the client shape never
	--- have to special-case native servers.
	function obj:notify(_rpc_message)
		return nil
	end

	--- Mark the native server inert. Idempotent.
	function obj:disconnect()
		entry._stopped = true
	end

	return client.register_native(obj)
end

return M
