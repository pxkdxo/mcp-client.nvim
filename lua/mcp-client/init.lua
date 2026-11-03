--- mcp-client: an MCP (Model Context Protocol) client for Neovim.
---
--- Exposed as `require("mcp-client")`, deliberately not `require("mcphub")`,
--- to avoid colliding with `mcphub.nvim`'s own module name while both may be
--- present in a dev/test environment.
local M = {}

--- The user-facing setup entrypoint: `require("mcp-client").setup(opts)`.
--- See `mcp-client.config.setup` for the full shape of `opts`.
--- @param opts table|nil
function M.setup(opts)
  return require("mcp-client.config").setup(opts)
end

return M
