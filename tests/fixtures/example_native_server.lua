--- Minimal test-only native server fixture (U3). Proves the registration
--- mechanism only -- not a real, shipped native server (see the plan's Key
--- Technical Decisions: `orchestrator.lua` is explicitly out of scope for
--- v1). Styled after `mcphub.nvim`'s `native_servers` config shape: a plain
--- table with `name` plus `tools`/`resources`/`prompts` tables of plain Lua
--- functions.

return {
	name = "example-native",
	tools = {
		echo = function(params)
			return { text = (params and params.text) or "" }
		end,
		boom = function(_params)
			error("boom: deliberate tool failure")
		end,
	},
	resources = {},
	prompts = {},
}
