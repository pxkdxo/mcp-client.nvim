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
	tool_meta = {
		echo = {
			description = "Echo the given text back",
			inputSchema = {
				type = "object",
				properties = { text = { type = "string", description = "Text to echo" } },
			},
		},
		boom = {
			description = "Deliberately fail",
			inputSchema = { type = "object", properties = {} },
		},
	},
	resources = {
		["example://greeting"] = function(_params)
			return { content = { { type = "text", text = "hello from example-native" } } }
		end,
	},
	resource_meta = {
		["example://greeting"] = {
			description = "A static greeting resource",
		},
	},
	prompts = {
		greet = function(arguments)
			local who = (arguments and arguments.who) or "world"
			return {
				messages = {
					{
						role = "user",
						content = { type = "text", text = "Hello, " .. who .. "!" },
					},
				},
			}
		end,
	},
	prompt_meta = {
		greet = {
			description = "Greet someone by name",
			arguments = { { name = "who", description = "Who to greet", required = false } },
		},
	},
}
