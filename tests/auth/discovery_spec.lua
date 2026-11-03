local HttpDouble = require("tests.helpers.http_double")
local wait_for = require("tests.helpers.wait")

local discovery = require("mcp-client.auth.discovery")

describe("auth.discovery", function()
  local double

  after_each(function()
    if double then
      double:stop()
      double = nil
    end
  end)

  describe("parse_www_authenticate", function()
    it("extracts the resource_metadata URL from a Bearer challenge", function()
      local header = 'Bearer resource_metadata="https://server.example/.well-known/oauth-protected-resource"'
      assert.are.equal(
        "https://server.example/.well-known/oauth-protected-resource",
        discovery.parse_www_authenticate(header)
      )
    end)

    it("tolerates additional challenge parameters and ordering", function()
      local header = 'Bearer error="invalid_token", resource_metadata="https://h/x", error_description="expired"'
      assert.are.equal("https://h/x", discovery.parse_www_authenticate(header))
    end)

    it("returns nil when no resource_metadata is present", function()
      assert.is_nil(discovery.parse_www_authenticate('Bearer error="invalid_token"'))
      assert.is_nil(discovery.parse_www_authenticate(nil))
    end)
  end)

  describe("default_prm_url", function()
    it("derives the RFC 9728 well-known PRM URL from a server URL", function()
      assert.are.equal(
        "https://server.example/.well-known/oauth-protected-resource",
        discovery.default_prm_url("https://server.example/mcp")
      )
    end)
  end)

  describe("fetch_protected_resource_metadata", function()
    it("fetches the PRM document and returns its authorization_servers", function()
      double = HttpDouble.new({
        on_request = function(method, path)
          if method == "GET" and path == "/.well-known/oauth-protected-resource" then
            return {
              status = 200,
              body = vim.json.encode({
                resource = "https://server.example/mcp",
                authorization_servers = { "https://as.example" },
              }),
            }
          end
          return { status = 404, body = "" }
        end,
      })

      local result, err
      discovery.fetch_protected_resource_metadata(
        double.url .. "/.well-known/oauth-protected-resource",
        function(res, e)
          result, err = res, e
        end
      )

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(err)
      assert.are.same({ "https://as.example" }, result.authorization_servers)
      assert.are.equal("https://server.example/mcp", result.resource)
    end)

    it("surfaces a stage-labeled error on a non-2xx PRM response", function()
      double = HttpDouble.new({
        on_request = function()
          return { status = 500, body = "boom" }
        end,
      })

      local result, err
      discovery.fetch_protected_resource_metadata(double.url .. "/prm", function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.matches("protected resource metadata", err)
      assert.matches("500", err)
    end)

    it("surfaces a stage-labeled error when the PRM body is not JSON", function()
      double = HttpDouble.new({
        on_request = function()
          return { status = 200, body = "not json" }
        end,
      })

      local result, err
      discovery.fetch_protected_resource_metadata(double.url .. "/prm", function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.matches("protected resource metadata", err)
    end)
  end)

  describe("fetch_authorization_server_metadata", function()
    it("fetches RFC 8414 metadata and returns the key endpoints", function()
      double = HttpDouble.new({
        on_request = function(method, path)
          if method == "GET" and path == "/.well-known/oauth-authorization-server" then
            return {
              status = 200,
              body = vim.json.encode({
                issuer = "https://as.example",
                authorization_endpoint = "https://as.example/authorize",
                token_endpoint = "https://as.example/token",
                registration_endpoint = "https://as.example/register",
                code_challenge_methods_supported = { "S256" },
              }),
            }
          end
          return { status = 404, body = "" }
        end,
      })

      local result, err
      discovery.fetch_authorization_server_metadata(double.url, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(err)
      assert.are.equal("https://as.example/authorize", result.authorization_endpoint)
      assert.are.equal("https://as.example/token", result.token_endpoint)
      assert.are.equal("https://as.example/register", result.registration_endpoint)
    end)

    it("returns metadata without a registration_endpoint when the AS omits it", function()
      double = HttpDouble.new({
        on_request = function(method, path)
          if method == "GET" and path == "/.well-known/oauth-authorization-server" then
            return {
              status = 200,
              body = vim.json.encode({
                issuer = "https://as.example",
                authorization_endpoint = "https://as.example/authorize",
                token_endpoint = "https://as.example/token",
              }),
            }
          end
          return { status = 404, body = "" }
        end,
      })

      local result, err
      discovery.fetch_authorization_server_metadata(double.url, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(err)
      assert.is_nil(result.registration_endpoint)
      assert.are.equal("https://as.example/token", result.token_endpoint)
    end)

    it("errors when the AS metadata lacks required endpoints", function()
      double = HttpDouble.new({
        on_request = function()
          return { status = 200, body = vim.json.encode({ issuer = "https://as.example" }) }
        end,
      })

      local result, err
      discovery.fetch_authorization_server_metadata(double.url, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.matches("authorization server metadata", err)
    end)

    it("surfaces a stage-labeled error on a non-2xx AS metadata response", function()
      double = HttpDouble.new({
        on_request = function()
          return { status = 404, body = "" }
        end,
      })

      local result, err
      discovery.fetch_authorization_server_metadata(double.url, function(res, e)
        result, err = res, e
      end)

      assert.is_true(wait_for(function()
        return result ~= nil or err ~= nil
      end))
      assert.is_nil(result)
      assert.matches("authorization server metadata", err)
      assert.matches("404", err)
    end)
  end)
end)
