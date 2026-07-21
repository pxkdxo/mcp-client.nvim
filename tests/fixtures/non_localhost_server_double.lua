--- Synthetic non-localhost HTTPS server double.
---
--- Stands in for a real non-localhost MCP server: a real HTTPS server bound to
--- a loopback alias other than localhost (e.g. 127.0.0.2), presenting a
--- self-signed certificate. Supports both the fail-closed path (a non-localhost
--- URL with no TLS/token, refused before any socket opens -- needs no running
--- server) and the successful-auth path (https:// + bearer token completes a
--- real TLS handshake against the self-signed cert, trusted via
--- CURL_CA_BUNDLE, with the bearer header observable via the request capture).
---
--- The live server is best-effort so it never hard-fails the suite:
---   1. Only 127.0.0.1 is guaranteed bound to loopback on macOS by default
---      (Linux binds all of 127.0.0.0/8 freely); a small candidate list of
---      aliases is probed and the first bindable one is used.
---   2. vim.uv has no TLS and the plugin's transport must not pass curl's
---      --insecure, so TLS is terminated by a small Node https server instead.
--- When the live server can't be brought up, `:available()` returns false;
--- fail-closed assertions still run against the chosen non-localhost URL, and
--- successful-auth assertions should skip.

local uv = vim.uv or vim.loop

local M = {}

--- Candidate non-localhost loopback hosts to try to bind, in order. All are in
--- 127.0.0.0/8 (loopback) but are not canonical localhost identifiers, so the
--- auth/TLS gate treats them as non-localhost. 127.0.0.2/3 work out-of-the-box
--- on Linux; the 127.10.x / 127.50.x entries cover common macOS `lo0 alias`
--- setups for developers who have configured one.
local CANDIDATE_HOSTS = {
	"127.0.0.2",
	"127.0.0.3",
	"127.10.0.1",
	"127.10.0.2",
	"127.50.100.1",
}

--- Whether `host` can be bound on an ephemeral port right now.
--- @param host string
--- @return boolean
local function can_bind(host)
	local server = uv.new_tcp()
	local ok = pcall(function()
		assert(server:bind(host, 0))
	end)
	pcall(function()
		server:close()
	end)
	return ok
end

--- Find the first candidate loopback alias that binds on this machine, or nil.
--- @return string|nil
local function pick_bindable_host()
	for _, host in ipairs(CANDIDATE_HOSTS) do
		if can_bind(host) then
			return host
		end
	end
	return nil
end

--- Reserve a free ephemeral port on `host` (bind :0, read the assigned port,
--- release). There is an unavoidable tiny race before the Node server rebinds
--- it, acceptable for a local test fixture.
--- @param host string
--- @return number
local function reserve_port(host)
	local server = uv.new_tcp()
	assert(server:bind(host, 0))
	local port = server:getsockname().port
	server:close()
	return port
end

--- Generate a self-signed cert (+key) for `host` into `dir` via the system
--- openssl. Returns cert_path, key_path on success or nil, err.
local function generate_self_signed(dir, host)
	local cert = dir .. "/cert.pem"
	local key = dir .. "/key.pem"
	local cmd = {
		"openssl",
		"req",
		"-x509",
		"-newkey",
		"rsa:2048",
		"-keyout",
		key,
		"-out",
		cert,
		"-days",
		"1",
		"-nodes",
		"-subj",
		"/CN=" .. host,
		"-addext",
		"subjectAltName=IP:" .. host,
	}
	local result = vim.system(cmd, { text = true }):wait()
	if result.code ~= 0 then
		return nil, nil, "openssl failed: " .. (result.stderr or "")
	end
	return cert, key
end

--- Node HTTPS server source, written to a temp file at start so the fixture is
--- self-contained. Captures each request's method/url and Authorization header
--- to a capture file (one JSON line per request) and replies with a minimal,
--- valid MCP InitializeResult so the plugin's Streamable-HTTP detection
--- succeeds. Args: <host> <port> <cert> <key> <capture>.
local NODE_SERVER = [[
const https = require('https');
const fs = require('fs');
const [host, portStr, certPath, keyPath, capture] = process.argv.slice(2);
const port = parseInt(portStr, 10);
const server = https.createServer(
  { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) },
  (req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      fs.appendFileSync(
        capture,
        JSON.stringify({ method: req.method, url: req.url, auth: req.headers['authorization'] || null }) + '\n'
      );
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-03-26', capabilities: {}, serverInfo: { name: 'non-localhost-double', version: '0.0.1' } } }));
    });
  }
);
server.listen(port, host, () => fs.writeFileSync(capture + '.ready', '1'));
]]

--- Start a synthetic non-localhost HTTPS server double.
---
--- @return table double  with fields:
---   available (boolean)  true iff a live TLS server is up (bindable alias + Node
---                        + openssl all present). When false, only the pure-gate
---                        (fail-closed) checks are meaningful; live-connect
---                        assertions should skip.
---   host      (string|nil) the non-localhost loopback alias chosen
---   port      (number|nil) the HTTPS port
---   url       (string|nil) https://<host>:<port>/mcp -- the successful-auth URL
---   http_url  (string|nil) http://<host>:<port>/mcp  -- a no-TLS URL for the
---                          fail-closed path (same non-localhost host)
---   cafile    (string|nil) path to the self-signed cert, for CURL_CA_BUNDLE
---   requests  (fun(): table[])  parsed capture entries seen so far
---   stop      (fun())     tear down the server and remove temp files
function M.start()
	local unavailable = function(reason)
		return {
			available = false,
			reason = reason,
			requests = function()
				return {}
			end,
			stop = function() end,
		}
	end

	local host = pick_bindable_host()
	if not host then
		return unavailable("no non-localhost loopback alias is bindable on this machine")
	end
	if vim.fn.executable("node") ~= 1 then
		return unavailable("node is not available to terminate TLS")
	end
	if vim.fn.executable("openssl") ~= 1 then
		return unavailable("openssl is not available to generate a self-signed cert")
	end

	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local cert, key, cert_err = generate_self_signed(dir, host)
	if not cert then
		return unavailable(cert_err or "self-signed cert generation failed")
	end

	local capture = dir .. "/capture.log"
	-- Ensure the capture file exists so reads before the first request don't error.
	local fh = io.open(capture, "w")
	if fh then
		fh:close()
	end

	local server_js = dir .. "/server.js"
	local sfh = assert(io.open(server_js, "w"))
	sfh:write(NODE_SERVER)
	sfh:close()

	local port = reserve_port(host)

	local proc = vim.system({ "node", server_js, host, tostring(port), cert, key, capture }, { text = true })

	-- Wait for the server to signal readiness (writes capture .ready).
	local ready_flag = capture .. ".ready"
	local ready = vim.wait(5000, function()
		return vim.fn.filereadable(ready_flag) == 1
	end, 25)

	if not ready then
		pcall(function()
			proc:kill(15)
		end)
		pcall(vim.fn.delete, dir, "rf")
		return unavailable("the TLS server did not become ready in time")
	end

	local double = {
		available = true,
		host = host,
		port = port,
		url = string.format("https://%s:%d/mcp", host, port),
		http_url = string.format("http://%s:%d/mcp", host, port),
		cafile = cert,
	}

	--- Parsed capture entries (one per received request) seen so far.
	function double.requests()
		local out = {}
		local rfh = io.open(capture, "r")
		if not rfh then
			return out
		end
		for line in rfh:lines() do
			if line ~= "" then
				local ok, decoded = pcall(vim.json.decode, line)
				if ok then
					table.insert(out, decoded)
				end
			end
		end
		rfh:close()
		return out
	end

	function double.stop()
		pcall(function()
			proc:kill(15)
		end)
		pcall(vim.fn.delete, dir, "rf")
	end

	return double
end

return M
