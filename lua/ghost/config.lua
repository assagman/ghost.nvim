--- Ghost configuration module
--- @module ghost.config

local M = {}

--- Default configuration for Ghost
--- @class GhostConfig
--- @field keybind string Keybind to open the prompt buffer
--- @field backend "opencode"|"codex" Which ACP backend to use
--- @field acp_command string|table Command to run for ACP (default: "opencode"). Table format bypasses "acp" argument for custom scripts.
--- @field acp_cwd string|nil Working directory for ACP subprocess (default: current directory)
--- @field agent string|nil Agent name to use (e.g., "NULL", "plan", "explore", "general")
--- @field model string|nil Model name/id to request (e.g., "gpt-4.1", "o1")
--- @field autoread boolean Enable autoread so buffers reload when agent edits files
--- @field window GhostWindowConfig Prompt window dimensions configuration
--- @field response_window GhostWindowConfig Response window dimensions configuration

--- Window configuration
--- @class GhostWindowConfig
--- @field width number Width as percentage of editor (0.0-1.0)
--- @field height number Height as percentage of editor (0.0-1.0)

--- @type GhostConfig
M.defaults = {
  keybind = "<leader>aq",
  backend = "opencode",
  acp_command = "opencode", -- Command to run for ACP subprocess
  acp_cwd = nil, -- Working directory for ACP (nil = current directory)
  agent = nil, -- Agent name (nil = OpenCode default, or "NULL", "plan", "explore", etc.)
  model = nil, -- Model name/id (nil = backend default)
  autoread = true, -- Enable autoread so buffers reload when agent edits files
  window = {
    width = 0.6,
    height = 0.3,
  },
  response_window = {
    width = 0.7,
    height = 0.5,
  },
}

--- Current configuration (populated by setup)
--- @type GhostConfig
M.options = {}

--- Validate configured backend
--- @param backend unknown
--- @return "opencode"|"codex" backend
local function validate_backend(backend)
  if backend == nil or backend == "" then
    return "opencode"
  end

  if backend == "opencode" or backend == "codex" then
    return backend
  end

  error(string.format('Ghost: invalid backend %q (expected "opencode" or "codex")', tostring(backend)))
end

--- Setup configuration by merging user options with defaults
--- @param opts GhostConfig|nil User configuration options
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  M.options.backend = validate_backend(M.options.backend)
end

return M
