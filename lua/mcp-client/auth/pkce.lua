--- PKCE (RFC 7636) and CSRF `state` generation for the OAuth 2.1
--- Authorization Code flow.
---
--- This module is pure value-generation: it does not touch the network,
--- the browser, or the loopback listener. It produces the secret
--- `code_verifier` (kept locally, sent only on the token-exchange POST),
--- the public `code_challenge` = base64url(SHA-256(verifier)) sent on the
--- authorization request, and a per-flow `state` used to bind the
--- redirect callback to this exact request (rejected on mismatch by the
--- redirect listener before any code is accepted).
---
--- Security note: the `code_verifier` returned here is a secret. Callers
--- must never log it, embed it in an error message, or leak it anywhere
--- but the token-exchange request body.
local M = {}

-- RFC 7636 unreserved character set for the code verifier:
--   ALPHA / DIGIT / "-" / "." / "_" / "~"
local VERIFIER_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

-- Verifier characters are drawn directly from the unreserved alphabet rather
-- than base64url-encoded bytes, so length is independent of byte count.
-- 64 sits comfortably inside the RFC 7636 [43, 128] range with ample entropy.
local VERIFIER_LENGTH = 64

-- 32 random bytes = 256 bits of entropy for the CSRF state parameter.
local STATE_BYTES = 32

--- Draw `n` cryptographically-unpredictable bytes as a Lua string.
---
--- Reads the OS CSPRNG via /dev/urandom (present on macOS and Linux). Falls
--- back to a seeded math.random if that read fails, so generation never
--- hard-errors.
local function random_bytes(n)
	local uv = vim.uv or vim.loop
	local fd = uv.fs_open("/dev/urandom", "r", tonumber("400", 8))
	if fd then
		local data = uv.fs_read(fd, n, 0)
		uv.fs_close(fd)
		if data and #data == n then
			return data
		end
	end

	-- Seed from high-resolution time so repeated calls in the same process
	-- still diverge.
	math.randomseed(uv.hrtime() % 2147483647)
	local bytes = {}
	for i = 1, n do
		bytes[i] = string.char(math.random(0, 255))
	end
	return table.concat(bytes)
end

--- Encode a raw byte string as unpadded base64url (RFC 4648 §5).
local function base64url_encode(raw)
	local b64 = vim.base64.encode(raw)
	return (b64:gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

--- Convert a lowercase hex digest string into its raw bytes.
local function hex_to_bytes(hex)
	return (hex:gsub("..", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

--- Compute the S256 code challenge for a given verifier:
--- base64url(SHA-256(ASCII(verifier))).
--- @param code_verifier string
--- @return string code_challenge
function M.s256_challenge(code_verifier)
	local digest_hex = vim.fn.sha256(code_verifier)
	return base64url_encode(hex_to_bytes(digest_hex))
end

--- Generate a fresh code_verifier / code_challenge / state bundle for one
--- authorization request.
--- @return table {
---   code_verifier         (string, SECRET) sent only on token exchange
---   code_challenge        (string) sent on the authorization request
---   code_challenge_method (string) always "S256"
---   state                 (string) per-flow CSRF token
--- }
function M.generate()
	local alphabet_size = #VERIFIER_ALPHABET
	local raw = random_bytes(VERIFIER_LENGTH)
	local chars = {}
	for i = 1, VERIFIER_LENGTH do
		local index = (raw:byte(i) % alphabet_size) + 1
		chars[i] = VERIFIER_ALPHABET:sub(index, index)
	end
	local code_verifier = table.concat(chars)

	return {
		code_verifier = code_verifier,
		code_challenge = M.s256_challenge(code_verifier),
		code_challenge_method = "S256",
		state = base64url_encode(random_bytes(STATE_BYTES)),
	}
end

return M
