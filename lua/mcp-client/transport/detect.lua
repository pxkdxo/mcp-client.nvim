--- Transport detection: connects to a configured server URL and decides,
--- per the MCP spec's client-side detection algorithm, whether the server
--- speaks the modern single-endpoint Streamable HTTP transport or only
--- the legacy two-endpoint HTTP+SSE transport -- then hands back an
--- already-connected transport behind the common transport interface
--- (`request(rpc_message, callback)`, `notify(rpc_message)`, `close()`)
--- so the rest of the core never needs to know which one it is talking to.
---
--- Algorithm: POST the InitializeRequest to the configured URL. A 2xx
--- response means Streamable HTTP. A 400/404/405 means the server doesn't
--- recognize POST there, so fall back to legacy discovery (GET the same
--- URL, expect an `endpoint` SSE event). Any other status is a genuine
--- error.
local curl = require("plenary.curl")

local StreamableHttp = require("mcp-client.transport.streamable_http")
local LegacySse = require("mcp-client.transport.legacy_sse")
local transport_util = require("mcp-client.transport.util")

local M = {}

local FALLBACK_STATUSES = { [400] = true, [404] = true, [405] = true }

--- Resolve a (possibly relative) `endpoint` SSE event's data against the
--- origin of the URL the stream was opened on, per the legacy transport's
--- discovery contract.
local function resolve_endpoint(stream_url, endpoint)
	if endpoint:match("^https?://") then
		return endpoint
	end
	local origin = stream_url:match("^(https?://[^/]+)")
	return origin .. (endpoint:sub(1, 1) == "/" and endpoint or ("/" .. endpoint))
end

local function describe_curl_error(curl_err)
	local message = curl_err.message or vim.inspect(curl_err)
	if message:find("Failed to connect", 1, true) or message:find("Connection refused", 1, true) then
		return "could not connect to server: " .. message
	end
	return "request to server failed: " .. message
end

--- Legacy discovery: GET the configured URL and expect an `endpoint` SSE
--- event naming the URL to POST JSON-RPC messages against. The GET stays
--- open as a single long-lived job (raw = {"-N"} disables curl's response
--- buffering so SSE lines arrive as they're written) for the life of the
--- connection; once the endpoint is discovered, feed ownership passes to
--- the legacy client's own parser.
local function discover_legacy(url, headers, on_done)
	local resolved = false
	local job -- assigned below; captured by the stream callback's closure
	local legacy_client

	local discovery_parser
	discovery_parser = LegacySse.SseParser.new(function(event)
		if resolved or event.event ~= "endpoint" then
			return
		end
		resolved = true

		local endpoint = resolve_endpoint(url, event.data)
		legacy_client = LegacySse.new({
			stream_url = url,
			endpoint = endpoint,
			headers = headers,
			job = job,
		})
		legacy_client:attach_parser()

		on_done({
			transport = "legacy_sse",
			client = legacy_client,
			endpoint = endpoint,
		}, nil)
	end)

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
		on_error = vim.schedule_wrap(function(curl_err)
			if not resolved then
				on_done(nil, describe_curl_error(curl_err))
			end
		end),
	})
end

local function finalize_streamable_http(response, url, headers, on_done, requested_protocol_version)
	-- A POST response may be a direct `application/json` body, or a
	-- single-event `text/event-stream` carrying the JSON-RPC message in
	-- its `data:` field -- both are spec-legal, so try JSON first and
	-- fall back to unwrapping SSE.
	local ok, decoded = pcall(vim.json.decode, response.body)
	if not ok then
		local sse_decoded, sse_err = transport_util.decode_json_from_sse_body(response.body)
		if not sse_decoded then
			return on_done(
				nil,
				"failed to decode InitializeResult as JSON: "
					.. tostring(decoded)
					.. " (also tried SSE framing: "
					.. tostring(sse_err)
					.. ")"
			)
		end
		decoded = sse_decoded
	end

	local session_id = transport_util.find_header(response.headers, "Mcp-Session-Id")
	-- The InitializeResult declares the protocol version the server will use
	-- for this session; echo it back via MCP-Protocol-Version on every later
	-- request (falling back to what the client itself requested if the
	-- server's response omits it) -- servers that require the header on every
	-- request, not just the handshake, otherwise fail every request after it.
	local protocol_version = (decoded.result and decoded.result.protocolVersion) or requested_protocol_version

	local client = StreamableHttp.new({
		url = url,
		session_id = session_id,
		headers = headers,
		protocol_version = protocol_version,
	})

	on_done({
		transport = "streamable_http",
		client = client,
		session_id = session_id,
		protocol_version = protocol_version,
		initialize_result = decoded,
	}, nil)
end

--- @param opts table
---   url     (string) the configured server URL
---   request (table) the InitializeRequest JSON-RPC message to send
---   timeout (number|nil) per-request timeout in ms (default 10000)
---   headers (table|nil) extra headers merged into every request
--- @param on_done fun(result: table|nil, err: string|nil)
---   On success, result = {
---     transport = "streamable_http"|"legacy_sse",
---     client = <transport object implementing the common interface>,
---     session_id = string|nil,       -- streamable_http only
---     protocol_version = string|nil, -- streamable_http only
---     endpoint = string|nil,         -- legacy_sse only
---     initialize_result = table,     -- the decoded InitializeResult (streamable_http only)
---   }
function M.connect(opts, on_done)
	local url = assert(opts.url, "url is required")
	local request = assert(opts.request, "request is required")
	local timeout = opts.timeout or 10000
	local headers = opts.headers or {}

	curl.post(url, {
		headers = vim.tbl_extend(
			"force",
			{ ["Content-Type"] = "application/json", ["Accept"] = "application/json, text/event-stream" },
			headers
		),
		body = vim.json.encode(request),
		timeout = timeout,
		callback = vim.schedule_wrap(function(response)
			if not response then
				return on_done(nil, "no response from server")
			end

			if response.status >= 200 and response.status < 300 then
				return finalize_streamable_http(response, url, headers, on_done, request.params.protocolVersion)
			end

			if FALLBACK_STATUSES[response.status] then
				return discover_legacy(url, headers, on_done)
			end

			return on_done(
				nil,
				string.format(
					"server returned unexpected status %d for InitializeRequest: %s",
					response.status,
					response.body or ""
				)
			)
		end),
		on_error = vim.schedule_wrap(function(err)
			on_done(nil, describe_curl_error(err))
		end),
	})
end

return M
