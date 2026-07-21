--- mcp-client: an MCP (Model Context Protocol) client for Neovim.
---
--- Exposed as `require("mcp-client")`, deliberately not `require("mcphub")`,
--- to avoid colliding with `mcphub.nvim`'s own module name while both may be
--- present in a dev/test environment.
local detect = require("mcp-client.transport.detect")

local M = {}

--- Semantic version of the MCP protocol revision this client speaks.
--- Sent as `protocolVersion` in InitializeRequest; legacy servers that omit
--- `MCP-Protocol-Version` in their own responses are assumed to be on this
--- revision.
local PROTOCOL_VERSION = "2025-03-26"

local function build_initialize_request(config)
	return {
		jsonrpc = "2.0",
		id = 1,
		method = "initialize",
		params = {
			protocolVersion = PROTOCOL_VERSION,
			-- vim.empty_dict(), not {}: an empty Lua table serializes to a JSON
			-- array `[]`, which a strict server rejects -- MCP requires
			-- `capabilities` to be an object.
			capabilities = config.capabilities or vim.empty_dict(),
			clientInfo = {
				name = config.name or "mcp-client",
				version = config.client_version or "0.1.0",
			},
		},
	}
end

--- Connect to a remote MCP server, detecting whether it speaks the modern
--- single-endpoint Streamable HTTP transport or the legacy two-endpoint
--- HTTP+SSE transport, and hand back a transport-agnostic client.
---
--- Mirrors `vim.lsp.start(config, opts)`'s config/opts split: `config`
--- describes *what* to connect to, `opts` describes *how* the caller
--- wants to be notified.
---
--- @param config table
---   url              (string, required) the server's MCP endpoint URL
---   name             (string|nil) client name sent in InitializeRequest
---   client_version   (string|nil) client version sent in InitializeRequest
---   capabilities     (table|nil) client capabilities sent in InitializeRequest
---   headers          (table|nil) extra headers merged into every request
--- @param opts table
---   on_connect (fun(client: table|nil, err: string|nil)) required;
---     called exactly once, either with a connected client (transport
---     field "streamable_http"|"legacy_sse", request/notify/close
---     methods) or with a descriptive error and no client.
---   timeout    (number|nil) InitializeRequest timeout in ms (default 10000)
function M.connect(config, opts)
	assert(type(config) == "table", "config table is required")
	assert(type(config.url) == "string" and config.url ~= "", "config.url is required")
	opts = opts or {}
	assert(type(opts.on_connect) == "function", "opts.on_connect is required")

	detect.connect({
		url = config.url,
		request = build_initialize_request(config),
		headers = config.headers,
		timeout = opts.timeout,
	}, function(result, err)
		if err then
			return opts.on_connect(nil, err)
		end

		local transport_client = result.client
		opts.on_connect({
			transport = result.transport,
			session_id = result.session_id,
			endpoint = result.endpoint,
			initialize_result = result.initialize_result,
			request = function(rpc_message, callback)
				return transport_client:request(rpc_message, callback)
			end,
			notify = function(rpc_message)
				return transport_client:notify(rpc_message)
			end,
			close = function()
				return transport_client:close()
			end,
		}, nil)
	end)
end

--- The user-facing setup entrypoint: `require("mcp-client").setup(opts)`,
--- mirroring `require("mcphub").setup(opts)`'s call shape so migrating a
--- config off `mcphub.nvim` is a mechanical swap.
---
--- All orchestration (validating/normalizing config, registering native
--- servers, connecting servers, wiring OAuth token stores) lives in
--- `config.lua`. `config` is required lazily so `connect()` (and specs that
--- exercise it in isolation) don't pull in the whole client/native/auth
--- stack unless `setup()` is actually called.
---
--- @param opts table|nil  see `mcp-client.config.setup` for the full shape.
function M.setup(opts)
	return require("mcp-client.config").setup(opts)
end

return M
