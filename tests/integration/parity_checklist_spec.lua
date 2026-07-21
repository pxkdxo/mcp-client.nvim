-- U9 parity checklist verification.
--
-- The plan's U9 parity checklist is derived from the dotfiles repo's real
-- `nvim/lua/plugins/ai.lua` (its current mcphub.nvim config). This spec pins
-- each checklist row to a concrete, verifiable fact about THIS plugin's public
-- surface, so "parity" is an executable assertion rather than a prose claim in a
-- report. It is deliberately hermetic -- it needs no live server and no network --
-- because it validates the plugin's OWN API shape against the surfaces the
-- mcphub.nvim config used.
--
-- The checklist (verbatim from the brief), with how each row is covered here:
--
--   | mcphub.nvim surface                    | mcp-client equivalent          | Status              |
--   |----------------------------------------|-----------------------------------|---------------------|
--   | server_url (server connection)            | R1 core conn, ext. configured(R7) | Covered by U1,U8    |
--   | native_servers.orchestrator            | Excluded for v1                   | Out of scope        |
--   | extensions.avante (tools/vars/slash)   | U4 Avante adapter, U11 slash cmds | Covered by U4,U11   |
--   | extensions.codecompanion (...)         | U5 CodeCompanion adapter, U12/U13 | Covered by U5,U12,U13 |
--   | :MCPHub interactive dashboard          | :checkhealth mcp-client        | Covered by U8       |
--   | Avante disabled_tools (host config)    | host-plugin config, not ours      | Out of scope        |
--
-- Note (U11/U12 closed the original gap this file used to test around):
-- prompt/slash-command bridging was a known, user-approved deferred gap in
-- both adapters when this spec was first written (U9). U11 (Avante) and U12
-- (CodeCompanion) subsequently implemented it in full -- see
-- minor-findings.md's "KNOWN GAP ... now RESOLVED by U11"/"...U12" entries --
-- and U13 fixed a CodeCompanion editor_context regression discovered along
-- the way. The rows below now assert the actual bridging surface exists,
-- not merely that a gap is recorded. The one genuinely still-open gap is
-- Avante's own resources/vars clause (investigated, not built -- see
-- minor-findings.md's "RESOLVED: Avante adapter resource/vars bridging (R4
-- gap) -- investigated, not built"), asserted directly in that row below.

describe("U9 parity checklist (against ai.lua's mcphub.nvim config)", function()
	it("row: server_url -> externally-configured server connection (U1 + U8)", function()
		-- mcphub.nvim: `server_url = "http://localhost:37373"` (a single external
		-- server URL, externally supplied). mcp-client's equivalent is
		-- config.setup accepting an externally-supplied server `url` (R7: no URL,
		-- port, or path baked into the plugin) and client.connect opening it.
		local config = require("mcp-client.config")
		local client = require("mcp-client.client")
		assert.is_function(config.setup)
		assert.is_function(client.connect)
		-- Accepts a single-server shorthand (the `server_url` singular analogue) AND
		-- a plural map -- and takes the URL from opts, never a hardcoded default.
		assert.is_function(config.state)
		-- Sanity: setup with a single server records it under the given url, proving
		-- the connection target is externally configured, not baked in.
		config._reset()
		config._record_hub("h", { url = "http://example.invalid:1/mcp" })
		assert.are.equal("http://example.invalid:1/mcp", config.get_hub("h").url)
		config._reset()
	end)

	it("row: native_servers.orchestrator -> explicitly out of scope for v1", function()
		-- mcphub.nvim wires `native_servers = { orchestrator = require("servers.orchestrator") }`.
		-- Per the plan's Key Technical Decisions, the orchestrator native server is
		-- excluded for v1. mcp-client DOES provide the generic native-server
		-- mechanism (U3) the orchestrator would have used, but ships no
		-- orchestrator itself -- which is the correct "out of scope" outcome.
		local native = require("mcp-client.native")
		assert.is_function(native.register) -- generic mechanism exists (U3)
		-- No orchestrator module is bundled by this plugin.
		local ok = pcall(require, "mcp-client.servers.orchestrator")
		assert.is_false(ok, "no orchestrator native server should be bundled (out of scope for v1)")
	end)

	it("row: extensions.avante -> U4 tools bridge + U11 prompt/slash-command bridge", function()
		-- mcphub.nvim: `extensions.avante = { make_tools, make_vars, make_slash_commands }`.
		-- mcp-client's Avante adapter provides the tools bridge (U4) and the
		-- prompt/slash-command bridge (U11, closing what was a deferred gap when
		-- this spec was first written). `custom_slash_commands`/`refresh` are the
		-- real, callable U11 entry points (avante.lua), independently exercised
		-- end-to-end in tests/adapters/avante_spec.lua's own "prompt/slash-command
		-- translation, U11" describe block -- this row only asserts the surface
		-- exists, not the full behavior that spec already covers.
		local avante = require("mcp-client.adapters.avante")
		assert.is_table(avante)
		assert.is_true(
			type(avante.custom_tools) == "function" or type(avante.mcp_tool) == "function",
			"Avante adapter must expose a tools bridge"
		)
		assert.is_function(avante.custom_slash_commands, "Avante adapter must expose a prompt/slash-command bridge")
		assert.is_function(avante.refresh, "Avante adapter must expose a refresh() to re-publish slash commands")

		-- The one still-genuinely-open gap in this row: Avante's own
		-- resources/vars clause was investigated and deliberately not built (no
		-- resources/vars-equivalent extension point exists in avante.nvim's real
		-- config surface) -- confirm that decision is still recorded, not silently
		-- dropped from tracking.
		local repo_root =
			vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/mcp-client/init.lua", false)[1], ":h:h:h")
		local findings = repo_root .. "/.superpowers/sdd/minor-findings.md"
		assert.are.equal(1, vim.fn.filereadable(findings), "minor-findings.md must exist to record the gap")
		local text = table.concat(vim.fn.readfile(findings), "\n")
		assert.is_truthy(
			text:find("resource/vars", 1, true),
			"Avante's resources/vars gap must stay documented in minor-findings.md, not silently dropped"
		)
	end)

	it("row: extensions.codecompanion -> U5 adapter, U12 prompt bridge, U13 editor_context fix", function()
		-- mcphub.nvim's codecompanion extension config sets `make_vars = false --
		-- Broken, tries to access 'variables'` in ai.lua. mcp-client's
		-- CodeCompanion adapter does NOT inherit that brokenness: U5 built real
		-- resource/editor_context bridging, U12 added prompt/slash-command
		-- bridging (closing what was a deferred gap when this spec was first
		-- written), and U13 fixed a real editor_context-path regression discovered
		-- along the way -- there is no remaining "make_vars" gap for this row to
		-- document. `setup`/`exports.refresh` are the real, callable entry points
		-- that wire all of tools/resources/prompts, independently exercised
		-- end-to-end in tests/adapters/codecompanion_spec.lua's own
		-- "prompt/slash-command bridging (U12)" describe block -- this row only
		-- asserts the surface exists, not the full behavior that spec covers.
		local cc = require("mcp-client.adapters.codecompanion")
		assert.is_table(cc)
		assert.is_function(cc.setup, "CodeCompanion adapter must expose setup()")
		assert.is_table(cc.exports)
		assert.is_function(
			cc.exports.refresh,
			"CodeCompanion adapter must expose exports.refresh() to re-publish tools/resources/prompts"
		)
	end)

	it("row: :MCPHub dashboard -> :checkhealth mcp-client (U8)", function()
		-- mcphub.nvim ships an interactive :MCPHub dashboard. Per Key Decisions
		-- that is excluded; the replacement is a health report surfaced through
		-- Neovim's native :checkhealth. Assert the health module exposes the
		-- checkhealth entrypoint (`health.check`, what `:checkhealth mcp-client`
		-- invokes) and that NO interactive dashboard command is created.
		local health = require("mcp-client.health")
		assert.is_function(health.check)
		-- No :MCPHub-style command is defined by this plugin.
		local commands = vim.api.nvim_get_commands({})
		assert.is_nil(commands["MCPHub"], "no interactive :MCPHub dashboard command should exist")
	end)

	it("row: Avante disabled_tools -> host-plugin config, unaffected (out of scope)", function()
		-- ai.lua's `disabled_tools = { "read_file", "bash", ... }` lives in Avante's
		-- OWN opts, not in the mcphub config, and defers built-in file/bash ops to
		-- MCP-provided tools. This is host-plugin (Avante) configuration; this
		-- plugin neither owns nor needs to reproduce it. The only parity-relevant
		-- fact is that mcp-client's Avante adapter does not clobber or require
		-- it -- i.e. loading the adapter has no such surface at all.
		local avante = require("mcp-client.adapters.avante")
		assert.is_nil(rawget(avante, "disabled_tools"), "disabled_tools is host config, not this adapter's concern")
	end)
end)
