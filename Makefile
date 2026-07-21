.PHONY: test

DEPS_DIR := .deps
PLENARY_DIR := $(DEPS_DIR)/plenary.nvim
PLENARY_URL := https://github.com/nvim-lua/plenary.nvim

test: $(PLENARY_DIR)
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

$(PLENARY_DIR):
	git clone --depth 1 $(PLENARY_URL) $(PLENARY_DIR)
