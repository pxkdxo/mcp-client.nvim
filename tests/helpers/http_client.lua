--- Minimal raw-socket HTTP GET client, for specs only.
---
--- Stands in for a browser hitting the OAuth loopback redirect URI, so specs
--- can drive a real callback against a real listener over 127.0.0.1. Plain
--- TCP is fine here: the loopback redirect leg is plaintext-localhost by
--- design (RFC 8252).
---
--- Fire-and-forget: opens a connection, writes a bare GET request line, and
--- closes without parsing the response. The spec observes listener behavior
--- via its on_result callback.
local uv = vim.uv or vim.loop

--- @param port number the loopback port to connect to
--- @param path string request target, e.g. "/callback?code=x&state=y"
return function(port, path)
  local client = uv.new_tcp()
  local connected = false

  client:connect("127.0.0.1", port, function(err)
    if err then
      if not client:is_closing() then
        client:close()
      end
      return
    end
    connected = true
    local request = string.format("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", path)
    client:write(request, function()
      -- Drain the response so the listener finishes writing before
      -- the connection is torn down.
      client:read_start(function(read_err, chunk)
        if read_err or not chunk then
          if not client:is_closing() then
            client:close()
          end
        end
      end)
    end)
  end)

  -- Block until connect + write complete; loopback resolves near-instantly.
  vim.wait(1000, function()
    return connected
  end)
end
