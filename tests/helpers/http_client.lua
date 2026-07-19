--- Minimal raw-socket HTTP GET client, for specs only.
---
--- The companion to tests/helpers/http_double.lua: where that stands in for
--- a remote server, this stands in for "the browser" navigating to the
--- OAuth loopback redirect URI, so redirect_listener_spec can drive a real
--- callback against the real listener over a real 127.0.0.1 socket. Built on
--- vim.uv for the same reason the double is: test-fixture code has no TLS
--- constraint, and the loopback redirect leg is plaintext-localhost by
--- design (RFC 8252) anyway.
---
--- Fire-and-forget: it opens a connection to 127.0.0.1:<port>, writes a bare
--- GET request line, and closes. It does not parse or return the response;
--- the spec observes the listener's behavior through its on_result callback.
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
			-- Read (and discard) the response so the listener can finish
			-- writing before we tear the connection down.
			client:read_start(function(read_err, chunk)
				if read_err or not chunk then
					if not client:is_closing() then
						client:close()
					end
				end
			end)
		end)
	end)

	-- Let the event loop flush the connect + write. Short bound; the listener
	-- is local so this resolves near-instantly in practice.
	vim.wait(1000, function()
		return connected
	end)
end
