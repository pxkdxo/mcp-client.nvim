-- Parity checklist verification against ai.lua's mcphub.nvim config.
--
-- Pins each row of the mcphub.nvim -> mcp-client parity mapping to a concrete,
-- verifiable fact about this plugin's public surface, so "parity" is an
-- executable assertion rather than a prose claim. Hermetic: no live server,
-- no network -- it only checks the plugin's own API shape.
--
--   | mcphub.nvim surface                    | mcp-client equivalent                    |
--   |-----------------------------------------|-------------------------------------------|
--   | server_url (server connection)          | externally-configured connection via config/client |
--   | native_servers.orchestrator             | excluded for v1                           |
--   | extensions.avante (tools/vars/slash)     | Avante adapter: tools + slash-command bridge |
--   | extensions.codecompanion (...)           | CodeCompanion adapter: tools/resources/prompts |
--   | :MCPHub interactive dashboard             | :checkhealth mcp-client                   |
--   | Avante disabled_tools (host config)      | host-plugin config, not ours              |

describe("parity checklist (against ai.lua's mcphub.nvim config)", function()
	it("row: server_url -> externally-configured server connection", function()
		-- mcphub.nvim: `server_url = "http://localhost:37373"` (a single external
		-- server URL, externally supplied). mcp-client's equivalent is
		-- config.setup accepting an externally-supplied server `url` and
		-- client.connect opening it -- no URL, port, or path is baked in.
		local config = require("mcp-client.config")
		local client = require("mcp-client.client")
		assert.is_function(config.setup)
		assert.is_function(client.connect)
		assert.is_function(config.state)
		config._reset()
		config._record_hub("h", { url = "http://example.invalid:1/mcp" })
		assert.are.equal("http://example.invalid:1/mcp", config.get_hub("h").url)
		config._reset()
	end)

	it("row: native_servers.orchestrator -> explicitly out of scope for v1", function()
		-- mcphub.nvim wires `native_servers = { orchestrator = require("servers.orchestrator") }`.
		-- mcp-client provides the generic native-server mechanism the
		-- orchestrator would have used, but ships no orchestrator itself.
		local native = require("mcp-client.native")
		assert.is_function(native.register)
		local ok = pcall(require, "mcp-client.servers.orchestrator")
		assert.is_false(ok, "no orchestrator native server should be bundled (out of scope for v1)")
	end)

	it("row: extensions.avante -> tools bridge + prompt/slash-command bridge", function()
		-- mcphub.nvim: `extensions.avante = { make_tools, make_vars, make_slash_commands }`.
		-- The Avante adapter's tools and slash-command bridges are exercised
		-- end-to-end in tests/adapters/avante_spec.lua; this row only asserts
		-- the surface exists.
		local avante = require("mcp-client.adapters.avante")
		assert.is_table(avante)
		assert.is_true(
			type(avante.custom_tools) == "function" or type(avante.mcp_tool) == "function",
			"Avante adapter must expose a tools bridge"
		)
		assert.is_function(avante.custom_slash_commands, "Avante adapter must expose a prompt/slash-command bridge")
		assert.is_function(avante.refresh, "Avante adapter must expose a refresh() to re-publish slash commands")
	end)

	it("row: extensions.codecompanion -> tools/resources/prompts bridge", function()
		-- mcphub.nvim's codecompanion extension config sets `make_vars = false --
		-- Broken, tries to access 'variables'` in ai.lua. mcp-client's
		-- CodeCompanion adapter builds real resource/editor_context and
		-- prompt/slash-command bridging instead -- exercised end-to-end in
		-- tests/adapters/codecompanion_spec.lua; this row only asserts the
		-- surface exists.
		local cc = require("mcp-client.adapters.codecompanion")
		assert.is_table(cc)
		assert.is_function(cc.setup, "CodeCompanion adapter must expose setup()")
		assert.is_table(cc.exports)
		assert.is_function(
			cc.exports.refresh,
			"CodeCompanion adapter must expose exports.refresh() to re-publish tools/resources/prompts"
		)
	end)

	it("row: :MCPHub dashboard -> :checkhealth mcp-client", function()
		-- mcphub.nvim ships an interactive :MCPHub dashboard; this plugin
		-- replaces it with a health report through Neovim's native :checkhealth.
		local health = require("mcp-client.health")
		assert.is_function(health.check)
		local commands = vim.api.nvim_get_commands({})
		assert.is_nil(commands["MCPHub"], "no interactive :MCPHub dashboard command should exist")
	end)

	it("row: Avante disabled_tools -> host-plugin config, unaffected (out of scope)", function()
		-- ai.lua's `disabled_tools = { "read_file", "bash", ... }` lives in Avante's
		-- own opts, not in the mcphub config, and defers built-in file/bash ops to
		-- MCP-provided tools. This plugin neither owns nor needs to reproduce it.
		local avante = require("mcp-client.adapters.avante")
		assert.is_nil(rawget(avante, "disabled_tools"), "disabled_tools is host config, not this adapter's concern")
	end)
end)
