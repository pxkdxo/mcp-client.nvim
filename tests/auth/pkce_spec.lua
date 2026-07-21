local pkce = require("mcp-client.auth.pkce")

describe("auth.pkce", function()
	describe("generate", function()
		it("produces a verifier, an S256 challenge, and a state", function()
			local pair = pkce.generate()

			assert.is_string(pair.code_verifier)
			assert.is_string(pair.code_challenge)
			assert.are.equal("S256", pair.code_challenge_method)
			assert.is_string(pair.state)
		end)

		it("generates a code_verifier within RFC 7636's 43-128 character length range", function()
			for _ = 1, 20 do
				local pair = pkce.generate()
				assert.is_true(#pair.code_verifier >= 43, "verifier too short: " .. #pair.code_verifier)
				assert.is_true(#pair.code_verifier <= 128, "verifier too long: " .. #pair.code_verifier)
			end
		end)

		it("uses only RFC 7636 unreserved characters in the verifier", function()
			for _ = 1, 20 do
				local pair = pkce.generate()
				assert.matches("^[A-Za-z0-9%-._~]+$", pair.code_verifier)
			end
		end)

		it("produces a URL-safe base64 challenge with no padding", function()
			local pair = pkce.generate()
			-- base64url alphabet only: A-Z a-z 0-9 - _  (no +, /, or = padding)
			assert.matches("^[A-Za-z0-9%-_]+$", pair.code_challenge)
			assert.is_nil(pair.code_challenge:find("="))
			assert.is_nil(pair.code_challenge:find("+", 1, true))
			assert.is_nil(pair.code_challenge:find("/", 1, true))
		end)

		it("derives the challenge as base64url(SHA-256(verifier))", function()
			local pair = pkce.generate()
			local expected = pkce.s256_challenge(pair.code_verifier)
			assert.are.equal(expected, pair.code_challenge)
		end)

		it("matches the RFC 7636 Appendix B test vector for S256", function()
			-- Verifier and challenge from RFC 7636 Appendix B.
			local challenge = pkce.s256_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
			assert.are.equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge)
		end)

		it("generates distinct verifiers and states across calls", function()
			local seen_verifiers, seen_states = {}, {}
			for _ = 1, 50 do
				local pair = pkce.generate()
				assert.is_nil(seen_verifiers[pair.code_verifier], "duplicate verifier generated")
				assert.is_nil(seen_states[pair.state], "duplicate state generated")
				seen_verifiers[pair.code_verifier] = true
				seen_states[pair.state] = true
			end
		end)

		it("generates a state long enough to resist guessing", function()
			local pair = pkce.generate()
			-- At least 128 bits of entropy encoded; base64url of 16 bytes is ~22 chars.
			assert.is_true(#pair.state >= 22, "state too short: " .. #pair.state)
			assert.matches("^[A-Za-z0-9%-_]+$", pair.state)
		end)
	end)
end)
