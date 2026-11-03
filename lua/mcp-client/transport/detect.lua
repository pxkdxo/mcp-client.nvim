--- HTTP connection establishment: decides which protocol era and transport a
--- server URL speaks and returns a ready transport behind the common
--- interface (`request`, `notify`, `respond`, `set_on_message`, `close`).
---
--- 1. Modern probe: POST `server/discover` with modern request metadata.
---    A DiscoverResult means a modern server. A recognized modern error means
---    a modern server too: `UnsupportedProtocolVersion` is retried once with a
---    version from its `supported` list; any other modern error fails.
--- 2. Legacy Streamable HTTP: when the probe gets a 2xx without a
---    DiscoverResult, or a 400/404/405 without a modern error, POST
---    `initialize`. A 2xx is a legacy Streamable HTTP server.
--- 3. Legacy HTTP+SSE: when `initialize` gets 400/404/405, GET the URL and
---    expect an `endpoint` event, then run `initialize` over that transport.
--- Every legacy path validates the negotiated version and sends
--- `notifications/initialized` before the connection is handed back.
local curl = require("plenary.curl")

local StreamableHttp = require("mcp-client.transport.streamable_http")
local LegacySse = require("mcp-client.transport.legacy_sse")
local transport_util = require("mcp-client.transport.util")
local protocol = require("mcp-client.protocol")
local rpc = require("mcp-client.rpc")

local M = {}

local DEFAULT_TIMEOUT_MS = 10000
local FALLBACK_STATUSES = { [400] = true, [404] = true, [405] = true }

--- Resolve a (possibly relative) `endpoint` SSE event's data against the
--- origin of the URL the stream was opened on.
local function resolve_endpoint(stream_url, endpoint)
  if endpoint:match("^https?://") then
    return endpoint
  end
  local origin = stream_url:match("^(https?://[^/]+)")
  return origin .. (endpoint:sub(1, 1) == "/" and endpoint or ("/" .. endpoint))
end

--- Finish a legacy handshake on `client`: validate the InitializeResult,
--- send `notifications/initialized`, and build the connection result.
local function complete_legacy(client, decoded, result, on_done)
  local version, version_err = protocol.negotiated_legacy_version(decoded)
  if not version then
    client:close()
    return on_done(nil, version_err)
  end
  client.protocol_version = version
  client:notify(protocol.INITIALIZED_NOTIFICATION, function(notify_err)
    if notify_err then
      client:close()
      return on_done(nil, "notifications/initialized was rejected: " .. notify_err)
    end
    if client.start_listening then
      client:start_listening()
    end
    on_done(
      vim.tbl_extend("force", result, {
        era = "legacy",
        client = client,
        protocol_version = version,
        session_id = client.session_id,
        initialize_result = decoded,
        description = protocol.server_description(decoded),
      }),
      nil
    )
  end)
end

--- Legacy HTTP+SSE discovery: GET the URL and wait for the `endpoint` event
--- naming the URL to POST messages to, then run the handshake over it. The GET
--- stays open as the transport's receive channel for the life of the
--- connection. The whole exchange must finish within `opts.timeout`, and a
--- stream that ends before it does is a failure.
local function discover_legacy_sse(opts, on_done)
  local url, headers = opts.url, opts.headers
  local settled = false
  local job
  local legacy_client
  local timer

  local function finish(result, err)
    if settled then
      return
    end
    settled = true
    pcall(function()
      timer:stop()
      timer:close()
    end)
    if err then
      if legacy_client then
        legacy_client:close()
      elseif job then
        pcall(function()
          job:shutdown()
        end)
      end
    end
    on_done(result, err)
  end

  local discovery_parser = LegacySse.SseParser.new(function(event)
    if legacy_client or event.event ~= "endpoint" then
      return
    end
    local endpoint = resolve_endpoint(url, event.data)
    legacy_client = LegacySse.new({ stream_url = url, endpoint = endpoint, headers = headers, job = job })
    legacy_client:attach_parser()
    legacy_client:request(protocol.initialize_request(opts.config, rpc.next_id()), function(err, decoded)
      if settled then
        return
      end
      if err and not decoded then
        return finish(nil, "initialize over the legacy SSE transport failed: " .. err)
      end
      complete_legacy(legacy_client, decoded, { transport = "legacy_sse", endpoint = endpoint }, finish)
    end)
  end)

  timer = vim.defer_fn(function()
    local step = legacy_client and "complete the handshake" or "send an endpoint event"
    finish(nil, string.format("legacy SSE server did not %s within %d ms", step, opts.timeout))
  end, opts.timeout)

  job = curl.get(url, {
    raw = { "-N" },
    headers = vim.tbl_extend("force", { ["Accept"] = "text/event-stream" }, headers),
    stream = vim.schedule_wrap(function(err, line)
      if err or not line then
        return
      end
      if legacy_client then
        legacy_client:feed_line(line)
      else
        discovery_parser:feed_line(line)
      end
    end),
    callback = vim.schedule_wrap(function(response)
      finish(
        nil,
        string.format("legacy SSE stream ended (status %d) before the connection was established", response.status)
      )
    end),
    on_error = vim.schedule_wrap(function(curl_err)
      finish(nil, transport_util.describe_curl_error(curl_err))
    end),
  })
end

local function connect_legacy(opts, on_done)
  local client = StreamableHttp.new({ url = opts.url, headers = opts.headers, era = "legacy" })
  client:request(protocol.initialize_request(opts.config, rpc.next_id()), function(err, decoded, response)
    if response == nil then
      return on_done(nil, err)
    end
    if response.status >= 200 and response.status < 300 then
      return complete_legacy(client, decoded, { transport = "streamable_http" }, on_done)
    end
    if FALLBACK_STATUSES[response.status] then
      return discover_legacy_sse(opts, on_done)
    end
    on_done(nil, string.format("server returned unexpected status %d for InitializeRequest: %s", response.status, err))
  end, { timeout = opts.timeout })
end

local function probe_modern(opts, version, retried, on_done)
  local client = StreamableHttp.new({
    url = opts.url,
    headers = opts.headers,
    era = "modern",
    protocol_version = version,
  })
  client:request(protocol.discover_request(opts.config, rpc.next_id(), version), function(err, decoded, response)
    if protocol.is_discover_result(decoded) then
      local supported = decoded.result.supportedVersions
      local negotiated = protocol.pick_modern_version(supported)
      if not negotiated then
        return connect_legacy(opts, on_done)
      end
      client.protocol_version = negotiated
      return on_done({
        transport = "streamable_http",
        era = "modern",
        client = client,
        protocol_version = negotiated,
        description = protocol.server_description(decoded),
      }, nil)
    end

    local modern_err = protocol.modern_error(decoded)
    if modern_err then
      if modern_err.code == protocol.ERROR.UNSUPPORTED_PROTOCOL_VERSION then
        local supported = type(modern_err.data) == "table" and modern_err.data.supported or nil
        local alternative = protocol.pick_modern_version(supported)
        if alternative and not retried then
          return probe_modern(opts, alternative, true, on_done)
        end
        for _, candidate in ipairs(supported or {}) do
          if protocol.is_legacy_version(candidate) then
            return connect_legacy(opts, on_done)
          end
        end
        return on_done(
          nil,
          string.format(
            "server supports protocol versions %s, none of which this client speaks",
            table.concat(supported or {}, ", ")
          )
        )
      end
      return on_done(nil, "server rejected the discovery request: " .. tostring(modern_err.message))
    end

    if response == nil then
      return on_done(nil, err)
    end
    if (response.status >= 200 and response.status < 300) or FALLBACK_STATUSES[response.status] then
      return connect_legacy(opts, on_done)
    end
    on_done(nil, string.format("server returned unexpected status %d: %s", response.status, err))
  end, { timeout = opts.timeout })
end

--- @param opts table
---   url     (string) the configured server URL
---   config  (table) the server config (handlers, capabilities, client_version)
---   headers (table|nil) extra headers merged into every request
---   timeout (number|nil) per-step bound in ms (default 10000)
--- @param on_done fun(result: table|nil, err: string|nil)
---   result = {
---     transport = "streamable_http"|"legacy_sse",
---     era = "modern"|"legacy",
---     client = <transport>,
---     protocol_version = string,
---     session_id = string|nil,        -- legacy streamable_http
---     endpoint = string|nil,          -- legacy_sse
---     initialize_result = table|nil,  -- legacy
---     description = { server_info, capabilities, instructions },
---   }
function M.connect(opts, on_done)
  assert(opts.url, "url is required")
  opts = vim.tbl_extend("force", { headers = {}, timeout = DEFAULT_TIMEOUT_MS, config = {} }, opts)
  probe_modern(opts, protocol.MODERN_VERSIONS[1], false, on_done)
end

return M
