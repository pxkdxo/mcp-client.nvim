-- Minimal init.lua for running this plugin's plenary busted specs, both
-- from the outer `nvim --headless -c PlenaryBustedDirectory` invocation and
-- from the nested per-file nvim processes plenary's test harness spawns
-- with `-u tests/minimal_init.lua`.
--
-- Self-contained: assumes only that `.deps/plenary.nvim` has been fetched
-- (see the Makefile's `test` target) and this repo's own `lua/` directory.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(root .. "/.deps/plenary.nvim")

vim.cmd("runtime plugin/plenary.vim")

require("plenary.busted")
