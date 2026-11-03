--- stdio MCP transport: the server is a subprocess exchanging newline-
--- delimited JSON-RPC messages over its stdin/stdout. Its stderr is kept
--- (the most recent lines) for error messages and `:MCPStatus`.
---
--- `M.connect` decides the server's era as the stdio binding prescribes:
--- probe with a modern `server/discover`; a DiscoverResult or a recognized
--- modern error means a modern server, while any other error -- or no reply
--- within `discover_timeout` -- means a legacy server, which then gets the
--- `initialize` handshake. A DiscoverResult that arrives late, before the
--- `initialize` reply, still wins.
local protocol = require("mcp-client.protocol")
local rpc = require("mcp-client.rpc")
local transport_util = require("mcp-client.transport.util")

local M = {}

local STDERR_LINES = 20
local DEFAULT_TIMEOUT_MS = 10000
local DEFAULT_DISCOVER_TIMEOUT_MS = 3000
local SHUTDOWN_GRACE_MS = 2000

local Stdio = {}
Stdio.__index = Stdio

--- Start the server process.
--- @param opts table  command (string), args (string[]|nil), env (table|nil), cwd (string|nil)
--- @return table|nil transport, string|nil err
function Stdio.spawn(opts)
  local self = setmetatable({
    command = opts.command,
    _pending = {},
    _stdout = "",
    _stderr = {},
    _closed = false,
    _exited = false,
  }, Stdio)

  local argv = vim.list_extend({ opts.command }, opts.args or {})
  local ok, process = pcall(vim.system, argv, {
    stdin = true,
    text = true,
    env = opts.env,
    cwd = opts.cwd,
    stdout = function(_, data)
      vim.schedule(function()
        self:_on_stdout(data)
      end)
    end,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          self:_on_stderr(data)
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      self:_on_exit(result)
    end)
  end)
  if not ok then
    return nil, string.format("failed to start %q: %s", opts.command, tostring(process))
  end
  self._process = process
  self.pid = process.pid
  return self, nil
end

function Stdio:set_on_message(fn)
  self._on_message = fn
end

--- Called once when the process exits without `close()` having been called.
function Stdio:set_on_drop(fn)
  self._on_drop = fn
end

function Stdio:exited()
  return self._exited
end

--- The most recent stderr lines, oldest first.
function Stdio:stderr_tail()
  return vim.list_slice(self._stderr, 1)
end

function Stdio:_on_stderr(data)
  for _, line in ipairs(vim.split(data, "\n", { trimempty = true })) do
    table.insert(self._stderr, line)
    if #self._stderr > STDERR_LINES then
      table.remove(self._stderr, 1)
    end
  end
end

function Stdio:_on_stdout(data)
  if data == nil then
    return
  end
  self._stdout = self._stdout .. data
  while true do
    local newline = self._stdout:find("\n", 1, true)
    if not newline then
      return
    end
    local line = self._stdout:sub(1, newline - 1)
    self._stdout = self._stdout:sub(newline + 1)
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" then
      self:_handle_message(decoded)
    end
  end
end

function Stdio:_handle_message(decoded)
  if decoded.method ~= nil then
    if self._on_message and not self._closed then
      self._on_message(decoded)
    end
    return
  end
  local callback = decoded.id ~= nil and self._pending[decoded.id]
  if callback then
    self._pending[decoded.id] = nil
    callback(transport_util.rpc_error_message(decoded), decoded, nil)
  end
end

--- Why the process ended, with its last stderr lines.
function Stdio:exit_reason()
  local reason = string.format("server process %q exited", self.command)
  if self._exit_code ~= nil then
    reason = reason .. string.format(" with code %d", self._exit_code)
  end
  if #self._stderr > 0 then
    reason = reason .. "; stderr:\n  " .. table.concat(self._stderr, "\n  ")
  end
  return reason
end

function Stdio:_on_exit(result)
  self._exited = true
  self._exit_code = result.code
  local pending = self._pending
  self._pending = {}
  local reason = self:exit_reason()
  for _, callback in pairs(pending) do
    pcall(callback, reason, nil, nil)
  end
  if not self._closed and self._on_drop then
    self._on_drop()
  end
end

function Stdio:_write(message)
  if self._closed or self._exited then
    return "transport is closed"
  end
  local ok, err = pcall(function()
    self._process:write(vim.json.encode(message) .. "\n")
  end)
  return not ok and tostring(err) or nil
end

--- Send a request; `callback(err, envelope)` fires with the response, or
--- with an error if the process exits first.
function Stdio:request(message, callback)
  if message.id ~= nil then
    self._pending[message.id] = callback
  end
  local err = self:_write(message)
  if err then
    if message.id ~= nil then
      self._pending[message.id] = nil
    end
    callback(err, nil, nil)
  end
end

function Stdio:notify(message, on_done)
  local err = self:_write(message)
  if on_done then
    vim.schedule(function()
      on_done(err)
    end)
  end
end

function Stdio:respond(message)
  self:_write(message)
end

--- Shut the server down: close its stdin, then escalate to SIGTERM and
--- SIGKILL if it has not exited after a grace period each.
function Stdio:close()
  if self._closed then
    return
  end
  self._closed = true
  if self._exited then
    return
  end
  pcall(function()
    self._process:write(nil)
  end)
  vim.defer_fn(function()
    if not self._exited then
      pcall(self._process.kill, self._process, "sigterm")
      vim.defer_fn(function()
        if not self._exited then
          pcall(self._process.kill, self._process, "sigkill")
        end
      end, SHUTDOWN_GRACE_MS)
    end
  end, SHUTDOWN_GRACE_MS)
end

function Stdio:get_stream_job()
  return nil
end

M.Stdio = Stdio

--- Start a stdio server and establish its protocol era.
--- @param config table  command, args, env, cwd, timeout, discover_timeout,
---   plus the handler/capability fields `protocol` reads
--- @param on_done fun(result: table|nil, err: string|nil)  result has the
---   same shape as `transport.detect.connect`'s, with transport = "stdio"
function M.connect(config, on_done)
  local process, spawn_err = Stdio.spawn(config)
  if not process then
    return on_done(nil, spawn_err)
  end

  local settled = false
  local function finish(result, err)
    if settled then
      return
    end
    settled = true
    if err then
      process:close()
    end
    on_done(result, err)
  end

  local function modern(decoded, version)
    process.protocol_version = version
    finish({
      transport = "stdio",
      era = "modern",
      client = process,
      protocol_version = version,
      description = protocol.server_description(decoded),
    }, nil)
  end

  local initialize_sent = false
  local function legacy()
    if initialize_sent or settled then
      return
    end
    initialize_sent = true
    process:request(protocol.initialize_request(config, rpc.next_id()), function(err, decoded)
      if settled then
        return
      end
      if err and not decoded then
        return finish(nil, err)
      end
      local version, version_err = protocol.negotiated_legacy_version(decoded)
      if not version then
        return finish(nil, version_err)
      end
      process.protocol_version = version
      process:notify(protocol.INITIALIZED_NOTIFICATION)
      finish({
        transport = "stdio",
        era = "legacy",
        client = process,
        protocol_version = version,
        initialize_result = decoded,
        description = protocol.server_description(decoded),
      }, nil)
    end)
  end

  local function probe(version, retried)
    process:request(protocol.discover_request(config, rpc.next_id(), version), function(err, decoded)
      if settled then
        return
      end
      if protocol.is_discover_result(decoded) then
        local negotiated = protocol.pick_modern_version(decoded.result.supportedVersions)
        if negotiated then
          return modern(decoded, negotiated)
        end
        return legacy()
      end
      local modern_err = protocol.modern_error(decoded)
      if modern_err and modern_err.code == protocol.ERROR.UNSUPPORTED_PROTOCOL_VERSION then
        local supported = type(modern_err.data) == "table" and modern_err.data.supported or {}
        local alternative = protocol.pick_modern_version(supported)
        if alternative and not retried then
          return probe(alternative, true)
        end
        for _, candidate in ipairs(supported) do
          if protocol.is_legacy_version(candidate) then
            return legacy()
          end
        end
        return finish(
          nil,
          string.format(
            "server supports protocol versions %s, none of which this client speaks",
            table.concat(supported, ", ")
          )
        )
      end
      if modern_err then
        return finish(nil, "server rejected the discovery request: " .. tostring(modern_err.message))
      end
      if process:exited() then
        return finish(nil, err)
      end
      legacy()
    end)
  end

  probe(protocol.MODERN_VERSIONS[1], false)
  vim.defer_fn(legacy, config.discover_timeout or DEFAULT_DISCOVER_TIMEOUT_MS)
  local timeout = config.timeout or DEFAULT_TIMEOUT_MS
  vim.defer_fn(function()
    finish(nil, string.format("server did not complete the handshake within %d ms", timeout))
  end, timeout)
end

return M
