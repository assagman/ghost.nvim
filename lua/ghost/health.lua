--- Ghost health check module
--- Provides :checkhealth ghost diagnostics
--- @module ghost.health

local health = vim.health
local start = health.start
local ok = health.ok
local warn = health.warn
local error = health.error

local M = {}

--- Check if an executable is available
--- @param name string Executable name
--- @param desc string Description for display
--- @param required boolean Whether this is required
local function check_executable(name, desc, required)
  if vim.fn.executable(name) == 1 then
    ok(desc .. " is available")
    return true
  else
    if required then
      error(desc .. " is not available (required)")
    else
      warn(desc .. " is not available")
    end
    return false
  end
end

function M.check()
  start("ghost.nvim")

  -- Check Neovim version
  local nvim_version = vim.version()
  if nvim_version.major < 0 or (nvim_version.major == 0 and nvim_version.minor < 10) then
    error("Neovim 0.10+ required, you're using " .. tostring(nvim_version))
  else
    ok("Neovim " .. tostring(nvim_version))
  end

  -- Check Ghost configuration
  local config_ok, config = pcall(require, "ghost.config")
  if not config_ok then
    error("Failed to load ghost.config module")
    return
  end

  local backend = config.options and config.options.backend or "opencode"
  ok("Backend: " .. backend)

  -- Check backend executables
  start("ghost.nvim: Backend Dependencies")

  if backend == "opencode" then
    local acp_cmd = config.options and config.options.acp_command or "opencode"
    if type(acp_cmd) == "table" then
      acp_cmd = acp_cmd[1]
    end
    check_executable(acp_cmd, "opencode (ACP backend)", true)
  elseif backend == "codex" then
    check_executable("bunx", "bunx (required for codex backend)", true)
    check_executable("bun", "bun runtime", false)
  end

  -- Check optional dependencies
  start("ghost.nvim: Optional Dependencies")

  -- Git (for project-based session persistence)
  if check_executable("git", "git (for project session persistence)", false) then
    -- Check if we're in a git repo
    local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
    if handle then
      local result = handle:read("*a")
      handle:close()
      if result and result ~= "" then
        ok("Inside git repository")
      else
        warn("Not inside a git repository (sessions will use cwd-based naming)")
      end
    end
  end

  -- Snacks.nvim (for enhanced picker UI)
  local snacks_ok, snacks = pcall(require, "snacks")
  if snacks_ok and snacks.picker then
    ok("Snacks.nvim available (enhanced session picker)")
  else
    warn("Snacks.nvim not available (using vim.ui.select fallback for :GhostList)")
  end

  -- Check ACP connection status
  start("ghost.nvim: Connection Status")

  local acp_ok, acp = pcall(require, "ghost.acp")
  if acp_ok then
    if acp.is_connected and acp.is_connected() then
      ok("ACP connected")
      if acp.get_session_id then
        local session_id = acp.get_session_id()
        if session_id then
          ok("Session ID: " .. session_id)
        end
      end
    else
      warn("ACP not connected (will connect on first prompt)")
    end
  else
    warn("Could not check ACP status")
  end
end

return M
