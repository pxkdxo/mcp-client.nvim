--- Protocol-revision knowledge shared by every transport and the client
--- layer: which revisions this client speaks, how a request declares its
--- revision and capabilities, and how a server's era is recognized.
---
--- Two eras of MCP exist on the wire:
---   * modern (2026-07-28 and later): stateless. Every request carries its
---     protocol version, client info, and client capabilities in
---     `params._meta`; there is no handshake. Servers answer `server/discover`.
---   * legacy (2025-11-25 and earlier): an `initialize` request followed by a
---     `notifications/initialized` notification establishes the session.
local handlers = require("mcp-client.handlers")

local M = {}

--- Revisions this client speaks, newest first within each era.
M.MODERN_VERSIONS = { "2026-07-28" }
M.LEGACY_VERSIONS = { "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" }

M.CLIENT_NAME = "mcp-client.nvim"
M.CLIENT_VERSION = "0.2.0"

M.META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
M.META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
M.META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
M.META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"
M.META_SUBSCRIPTION_ID = "io.modelcontextprotocol/subscriptionId"

M.ERROR = {
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL = -32603,
  HEADER_MISMATCH = -32020,
  MISSING_REQUIRED_CLIENT_CAPABILITY = -32021,
  UNSUPPORTED_PROTOCOL_VERSION = -32022,
}

local MODERN_ERROR_CODES = {
  [M.ERROR.HEADER_MISMATCH] = true,
  [M.ERROR.MISSING_REQUIRED_CLIENT_CAPABILITY] = true,
  [M.ERROR.UNSUPPORTED_PROTOCOL_VERSION] = true,
}

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

function M.is_modern_version(version)
  return contains(M.MODERN_VERSIONS, version)
end

function M.is_legacy_version(version)
  return contains(M.LEGACY_VERSIONS, version)
end

--- The newest modern revision both sides support, or nil.
--- @param supported string[]|nil  the server's advertised versions
function M.pick_modern_version(supported)
  if type(supported) ~= "table" then
    return nil
  end
  for _, version in ipairs(M.MODERN_VERSIONS) do
    if contains(supported, version) then
      return version
    end
  end
  return nil
end

function M.client_info(config)
  return { name = M.CLIENT_NAME, version = config.client_version or M.CLIENT_VERSION }
end

--- `config.capabilities`, when set, replaces the capabilities derived from
--- the configured handlers. Always a JSON object on the wire: an empty Lua
--- table would serialize as `[]`.
function M.client_capabilities(config)
  local capabilities = config.capabilities or handlers.capabilities(config.handlers)
  if next(capabilities) == nil then
    return vim.empty_dict()
  end
  return capabilities
end

--- A copy of `message` whose `params._meta` declares `version` plus this
--- client's identity and capabilities, merged over any caller-supplied
--- `_meta` keys.
function M.with_meta(message, config, version)
  local params = vim.tbl_extend("force", {}, message.params or {})
  params._meta = vim.tbl_extend("force", params._meta or {}, {
    [M.META_PROTOCOL_VERSION] = version,
    [M.META_CLIENT_INFO] = M.client_info(config),
    [M.META_CLIENT_CAPABILITIES] = M.client_capabilities(config),
  })
  return vim.tbl_extend("force", {}, message, { params = params })
end

function M.discover_request(config, id, version)
  return M.with_meta(
    { jsonrpc = "2.0", id = id, method = "server/discover", params = {} },
    config,
    version or M.MODERN_VERSIONS[1]
  )
end

function M.initialize_request(config, id)
  return {
    jsonrpc = "2.0",
    id = id,
    method = "initialize",
    params = {
      protocolVersion = M.LEGACY_VERSIONS[1],
      capabilities = M.client_capabilities(config),
      clientInfo = M.client_info(config),
    },
  }
end

M.INITIALIZED_NOTIFICATION = { jsonrpc = "2.0", method = "notifications/initialized" }

--- The JSON-RPC error object of `decoded` when its code is one only a
--- modern server emits, else nil.
function M.modern_error(decoded)
  local err = type(decoded) == "table" and decoded.error or nil
  if type(err) == "table" and MODERN_ERROR_CODES[err.code] then
    return err
  end
  return nil
end

--- Whether `decoded` is a successful `server/discover` response.
function M.is_discover_result(decoded)
  return type(decoded) == "table"
    and type(decoded.result) == "table"
    and type(decoded.result.supportedVersions) == "table"
end

--- Validate an InitializeResult envelope and return the negotiated version.
--- @return string|nil version, string|nil err
function M.negotiated_legacy_version(decoded)
  if type(decoded) ~= "table" then
    return nil, "initialize returned no result"
  end
  if decoded.error then
    return nil, "initialize failed: " .. tostring(decoded.error.message or vim.inspect(decoded.error))
  end
  local version = type(decoded.result) == "table" and decoded.result.protocolVersion or nil
  if type(version) ~= "string" then
    return nil, "initialize result has no protocolVersion"
  end
  if not M.is_legacy_version(version) then
    return nil, string.format("server negotiated unsupported protocol version %q", version)
  end
  return version, nil
end

--- Server identity, capabilities, and instructions from a DiscoverResult or
--- InitializeResult envelope.
function M.server_description(decoded)
  local result = type(decoded) == "table" and type(decoded.result) == "table" and decoded.result or {}
  local meta = type(result._meta) == "table" and result._meta or {}
  return {
    server_info = result.serverInfo or meta[M.META_SERVER_INFO],
    capabilities = type(result.capabilities) == "table" and result.capabilities or {},
    instructions = result.instructions,
  }
end

return M
