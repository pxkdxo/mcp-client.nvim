--- Minimal raw-socket HTTP test double standing in for a remote MCP server.
--- Built on vim.uv directly since it plays the server side, not the client
--- (the plugin itself always talks to servers through plenary.curl).
local uv = vim.uv or vim.loop

local HttpDouble = {}
HttpDouble.__index = HttpDouble

--- Parse the request line + headers off the front of a raw HTTP request.
--- Returns method, path, and the remainder (any bytes already read as body).
local function parse_request_head(buf)
  local head_end = buf:find("\r\n\r\n", 1, true)
  if not head_end then
    return nil
  end
  local head = buf:sub(1, head_end - 1)
  local rest = buf:sub(head_end + 4)
  local method, path = head:match("^(%u+)%s+(%S+)%s+HTTP/[%d%.]+")
  return method, path, rest, head
end

--- opts.on_request(method, path, rest, head) -> a handler table describing
--- the response:
---   { status = 200, headers = {...}, body = "..." }
---   or { status = 200, headers = {...}, sse = { {event=..., data=...}, ... } }
--- For sse, the connection is left open after the entries are flushed (only
--- double:stop() closes it), so an optional `on_stream = fun(socket)` can push
--- further frames or drop the connection mid-stream.
function HttpDouble.new(opts)
  local self = setmetatable({}, HttpDouble)
  self._on_request = assert(opts.on_request, "on_request is required")
  self._server = uv.new_tcp()
  self._clients = {}
  assert(self._server:bind("127.0.0.1", 0))
  self.port = self._server:getsockname().port
  self.url = string.format("http://127.0.0.1:%d", self.port)

  self._server:listen(128, function(err)
    assert(not err, err)
    local client = uv.new_tcp()
    self._server:accept(client)
    table.insert(self._clients, client)

    local buf = ""
    client:read_start(function(read_err, chunk)
      if read_err then
        client:close()
        return
      end
      if not chunk then
        return
      end
      buf = buf .. chunk

      local method, path, rest, head = parse_request_head(buf)
      if not method then
        return -- keep buffering until we see the header terminator
      end

      local handler = self._on_request(method, path, rest, head)
      handler = handler or { status = 404, body = "" }

      local status_line = string.format("HTTP/1.1 %d %s\r\n", handler.status, handler.reason or "OK")
      local headers = handler.headers or {}

      if handler.sse then
        headers["Content-Type"] = headers["Content-Type"] or "text/event-stream"
        headers["Cache-Control"] = headers["Cache-Control"] or "no-cache"
        headers["Connection"] = headers["Connection"] or "keep-alive"
        local head = status_line
        for k, v in pairs(headers) do
          head = head .. k .. ": " .. v .. "\r\n"
        end
        head = head .. "\r\n"
        client:write(head)

        for _, entry in ipairs(handler.sse) do
          local frame = ""
          if entry.event then
            frame = frame .. "event: " .. entry.event .. "\r\n"
          end
          for _, line in ipairs(vim.split(entry.data or "", "\n", { plain = true })) do
            frame = frame .. "data: " .. line .. "\r\n"
          end
          frame = frame .. "\r\n"
          client:write(frame)
        end

        if handler.on_stream then
          handler.on_stream(client)
        end
      else
        local body = handler.body or ""
        headers["Content-Type"] = headers["Content-Type"] or "application/json"
        headers["Content-Length"] = tostring(#body)
        headers["Connection"] = headers["Connection"] or "close"
        local head = status_line
        for k, v in pairs(headers) do
          head = head .. k .. ": " .. v .. "\r\n"
        end
        head = head .. "\r\n"
        client:write(head .. body, function()
          if not (handler.headers and handler.headers["Connection"] == "keep-alive") then
            client:close()
          end
        end)
      end
    end)
  end)

  return self
end

function HttpDouble:stop()
  for _, client in ipairs(self._clients) do
    if not client:is_closing() then
      client:close()
    end
  end
  if not self._server:is_closing() then
    self._server:close()
  end
end

return HttpDouble
