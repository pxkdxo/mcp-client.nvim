-- Covers RFC 7591 Dynamic Client Registration, the token-exchange POST, and
-- the orchestrated discovery-through-token-exchange flow.
local HttpDouble = require("tests.helpers.http_double")
local http_get = require("tests.helpers.http_client")
local wait_for = require("tests.helpers.wait")

local dcr = require("mcp-client.auth.dcr")

describe("auth.dcr", function()
  local double

  after_each(function()
    if double then
      double:stop()
      double = nil
    end
  end)

  describe("register", function()
    it("POSTs an RFC 7591 registration and returns the assigned client_id", function()
      local received_body
      double = HttpDouble.new({
        on_request = function(method, path, rest)
          if method == "POST" and path == "/register" then
            received_body = rest
            return {
              status = 201,
              body = vim.json.encode({
                client_id = "assigned-client-id",
                redirect_uris = { "http://127.0.0.1:9999/callback" },
              }),
            }
          end
          return { status = 404, body = "" }
        end,
      })

      local result, err
      dcr.register({
        registration_endpoint = double.url .. "/register",
        redirect_uri = "http://127.0.0.1:9999/callback",
        client_name = "mcp-client",
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(err)
      assert.are.equal("assigned-client-id", result.client_id)
      assert.is_not_nil(received_body)
      assert.matches("redirect_uris", received_body, 1, true)
    end)

    it("surfaces a stage-labeled error when registration is rejected", function()
      double = HttpDouble.new({
        on_request = function()
          return { status = 400, body = vim.json.encode({ error = "invalid_redirect_uri" }) }
        end,
      })

      local result, err
      dcr.register({
        registration_endpoint = double.url .. "/register",
        redirect_uri = "http://127.0.0.1:9999/callback",
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.matches("registration", err)
    end)
  end)

  describe("exchange_code_for_token", function()
    it("POSTs the code + verifier and returns a typed token result", function()
      local received_body
      double = HttpDouble.new({
        on_request = function(method, path, rest)
          if method == "POST" and path == "/token" then
            received_body = rest
            return {
              status = 200,
              body = vim.json.encode({
                access_token = "the-access-token",
                refresh_token = "the-refresh-token",
                token_type = "Bearer",
                expires_in = 3600,
                scope = "mcp",
              }),
            }
          end
          return { status = 404, body = "" }
        end,
      })

      local result, err
      dcr.exchange_code_for_token({
        token_endpoint = double.url .. "/token",
        code = "the-auth-code",
        code_verifier = "the-verifier",
        client_id = "the-client",
        redirect_uri = "http://127.0.0.1:9999/callback",
        resource = "https://server.example/mcp",
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(err)
      assert.are.equal("the-access-token", result.access_token)
      assert.are.equal("the-refresh-token", result.refresh_token)
      assert.are.equal("Bearer", result.token_type)
      assert.is_number(result.expires_at)
      -- Endpoint and client metadata needed to refresh later.
      assert.are.equal(double.url .. "/token", result.token_endpoint)
      assert.are.equal("the-client", result.client_id)
      assert.are.equal("https://server.example/mcp", result.resource)
      assert.matches("grant_type=authorization_code", received_body, 1, true)
      assert.matches("code_verifier=the%-verifier", received_body)
    end)

    it("surfaces an AS token error (invalid_grant) distinctly from a network failure", function()
      double = HttpDouble.new({
        on_request = function()
          return {
            status = 400,
            body = vim.json.encode({
              error = "invalid_grant",
              error_description = "authorization code expired",
            }),
          }
        end,
      })

      local result, err
      dcr.exchange_code_for_token({
        token_endpoint = double.url .. "/token",
        code = "expired",
        code_verifier = "v",
        client_id = "c",
        redirect_uri = "http://127.0.0.1:9999/callback",
        resource = "https://server.example/mcp",
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.matches("invalid_grant", err)
      -- Distinct from a network-level failure: it names the token endpoint error.
      assert.matches("token", err)
    end)

    it("distinguishes a network-level failure from an AS error response", function()
      -- Point at a port nothing is listening on to force a connect failure.
      local result, err
      dcr.exchange_code_for_token({
        token_endpoint = "http://127.0.0.1:1/token",
        code = "c",
        code_verifier = "v",
        client_id = "c",
        redirect_uri = "http://127.0.0.1:9999/callback",
        resource = "https://server.example/mcp",
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end, 5000))
      assert.is_nil(result)
      assert.is_not_nil(err)
      -- Not an OAuth error code; a transport failure.
      assert.is_nil(err:find("invalid_grant", 1, true))
    end)

    it("never leaks the access or refresh token into error text on a malformed success body", function()
      double = HttpDouble.new({
        on_request = function()
          -- 200 but missing access_token.
          return { status = 200, body = vim.json.encode({ token_type = "Bearer" }) }
        end,
      })

      local result, err
      dcr.exchange_code_for_token({
        token_endpoint = double.url .. "/token",
        code = "c",
        code_verifier = "v",
        client_id = "c",
        redirect_uri = "http://127.0.0.1:9999/callback",
        resource = "https://server.example/mcp",
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.matches("token", err)
    end)
  end)

  -- The orchestrated flow. A single HttpDouble routes on path to stand in for
  -- the server (401), PRM, AS metadata, DCR, and token endpoints; the browser
  -- open is stubbed to drive a callback against the real redirect listener.
  describe("run_flow", function()
    --- Build a routing double for the AS-side endpoints. `opts.with_dcr`
    --- controls whether AS metadata advertises a registration_endpoint.
    local function build_double(opts)
      opts = opts or {}
      return HttpDouble.new({
        on_request = function(method, path, rest)
          -- The server's protected resource: 401 with a PRM pointer.
          if path == "/mcp" then
            return {
              status = 401,
              headers = {
                ["WWW-Authenticate"] = 'Bearer resource_metadata="'
                  .. opts.base_url
                  .. '/.well-known/oauth-protected-resource"',
              },
              body = "",
            }
          end
          if path == "/.well-known/oauth-protected-resource" then
            return {
              status = 200,
              body = vim.json.encode({
                resource = opts.base_url .. "/mcp",
                authorization_servers = { opts.base_url },
              }),
            }
          end
          if path == "/.well-known/oauth-authorization-server" then
            local doc = {
              issuer = opts.base_url,
              authorization_endpoint = opts.base_url .. "/authorize",
              token_endpoint = opts.base_url .. "/token",
              code_challenge_methods_supported = { "S256" },
            }
            if opts.with_dcr then
              doc.registration_endpoint = opts.base_url .. "/register"
            end
            return { status = 200, body = vim.json.encode(doc) }
          end
          if method == "POST" and path == "/register" then
            return {
              status = 201,
              body = vim.json.encode({ client_id = "dcr-client-id" }),
            }
          end
          if method == "POST" and path == "/token" then
            opts.token_body = rest
            return {
              status = 200,
              body = vim.json.encode({
                access_token = "flow-access-token",
                refresh_token = "flow-refresh-token",
                token_type = "Bearer",
                expires_in = 3600,
              }),
            }
          end
          return { status = 404, body = "" }
        end,
      })
    end

    it("completes the full flow when the AS supports DCR", function()
      local opts = { with_dcr = true }
      double = build_double(opts)
      opts.base_url = double.url

      local captured_auth_url
      local result, err
      dcr.run_flow({
        server_url = double.url .. "/mcp",
        open_url = function(url)
          captured_auth_url = url
          -- Simulate the browser redirecting back with the code+state.
          local port = url:match("redirect_uri=http%%3A%%2F%%2F127%.0%.0%.1%%3A(%d+)")
          local state = url:match("[&?]state=([^&]+)")
          http_get(tonumber(port), "/callback?code=flow-code&state=" .. state)
          return true
        end,
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(
        wait_for(function()
          return result ~= nil or err ~= nil
        end, 5000),
        "flow did not settle: " .. tostring(err)
      )
      assert.is_nil(err)
      assert.are.equal("flow-access-token", result.access_token)
      assert.are.equal("flow-refresh-token", result.refresh_token)
      assert.are.equal(double.url .. "/mcp", result.resource)
      assert.are.equal("dcr-client-id", result.client_id)
      -- The authorization URL carried the mandatory pieces.
      assert.matches("code_challenge=", captured_auth_url, 1, true)
      assert.matches("code_challenge_method=S256", captured_auth_url, 1, true)
      assert.matches("resource=", captured_auth_url, 1, true)
      assert.matches("state=", captured_auth_url, 1, true)
    end)

    it("falls back to a configured client_id when the AS omits registration", function()
      local opts = { with_dcr = false }
      double = build_double(opts)
      opts.base_url = double.url

      local result, err
      dcr.run_flow({
        server_url = double.url .. "/mcp",
        client_id = "configured-fallback-client",
        open_url = function(url)
          local port = url:match("redirect_uri=http%%3A%%2F%%2F127%.0%.0%.1%%3A(%d+)")
          local state = url:match("[&?]state=([^&]+)")
          http_get(tonumber(port), "/callback?code=flow-code&state=" .. state)
          return true
        end,
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(
        wait_for(function()
          return result ~= nil or err ~= nil
        end, 5000),
        "flow did not settle: " .. tostring(err)
      )
      assert.is_nil(err)
      assert.are.equal("flow-access-token", result.access_token)
      assert.are.equal("configured-fallback-client", result.client_id)
    end)

    it("errors when the AS omits registration and no fallback client_id is configured", function()
      local opts = { with_dcr = false }
      double = build_double(opts)
      opts.base_url = double.url

      local result, err
      dcr.run_flow({
        server_url = double.url .. "/mcp",
        open_url = function()
          return true
        end,
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end, 5000))
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.matches("client_id", err)
    end)

    it("surfaces the authorization URL for manual entry when no browser opens", function()
      local opts = { with_dcr = true }
      double = build_double(opts)
      opts.base_url = double.url

      local manual_url, prompted
      local result, err
      dcr.run_flow({
        server_url = double.url .. "/mcp",
        open_url = function()
          return false
        end,
        prompt_for_code = function(url)
          manual_url = url
          prompted = true
          return "manual-code"
        end,
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(
        wait_for(function()
          return result ~= nil or err ~= nil
        end, 5000),
        "flow did not settle: " .. tostring(err)
      )
      assert.is_true(prompted, "manual prompt was not invoked")
      assert.matches("code_challenge=", manual_url, 1, true)
      assert.is_nil(err)
      assert.are.equal("flow-access-token", result.access_token)
    end)

    it("surfaces a timeout when neither the browser nor manual entry yields a code", function()
      local opts = { with_dcr = true }
      double = build_double(opts)
      opts.base_url = double.url

      local result, err
      dcr.run_flow({
        server_url = double.url .. "/mcp",
        redirect_timeout_ms = 150,
        open_url = function()
          return true -- browser "opened" but user never completes it
        end,
      }, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end, 2000))
      assert.is_nil(result)
      assert.matches("timed out", err)
    end)
  end)
end)
