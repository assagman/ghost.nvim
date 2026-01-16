-- Luacheck configuration for ghost.nvim
-- https://luacheck.readthedocs.io/

-- Use LuaJIT (Neovim runtime)
std = "luajit"

-- Define Neovim globals
globals = {
  "vim",
}

-- Read-only globals (standard Lua + LuaJIT)
read_globals = {
  "jit",
  "unpack",
}

-- Ignore generated/vendor directories
exclude_files = {
  ".opencode/**",
  "node_modules/**",
}

-- Maximum line length (match stylua column_width)
max_line_length = 120

-- Maximum cyclomatic complexity
max_cyclomatic_complexity = 15

-- Warnings configuration
-- See: https://luacheck.readthedocs.io/en/stable/warnings.html

-- Allow unused arguments starting with underscore
unused_args = true
unused_secondaries = true

-- Allow self as unused (common in OOP patterns)
self = false

-- Specific file overrides can be added here:
-- files["lua/ghost/test.lua"] = { ignore = { "212" } }
