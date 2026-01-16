--- Ghost UI module - Floating prompt buffer
--- @module ghost.ui

local M = {}

local config = require("ghost.config")

--- @class GhostUIState
--- @field buf number|nil The prompt buffer number
--- @field win number|nil The prompt window number
--- @field autocmd_id number|nil The BufWriteCmd autocmd ID
local state = {
  buf = nil,
  win = nil,
  autocmd_id = nil,
}

--- Callback for when prompt is sent
--- This is set by init.lua to handle the send action
--- @type fun(prompt: string)|nil
M.on_send = nil

--- Extract prompt text from the buffer
--- @return string|nil The prompt text, or nil if buffer invalid
local function extract_prompt()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  return table.concat(lines, "\n")
end

--- Handle the send action (called from BufWriteCmd)
--- @return boolean True if prompt was sent, false if empty
local function handle_send()
  -- Wrap in pcall for safety
  local ok, result = pcall(function()
    local prompt = extract_prompt()

    -- Trim whitespace to check for empty
    local trimmed = prompt and prompt:match("^%s*(.-)%s*$") or ""

    if trimmed == "" then
      vim.notify("Ghost: Empty prompt, nothing to send", vim.log.levels.WARN)
      return false
    end

    -- Call the send callback if set
    if M.on_send then
      -- Wrap callback in pcall to prevent crashes
      local cb_ok, cb_err = pcall(M.on_send, prompt)
      if not cb_ok then
        vim.notify("Ghost: Error in send callback - " .. tostring(cb_err), vim.log.levels.ERROR)
      end
    else
      -- Stub: just log the prompt for now
      vim.notify("Ghost: Prompt sent (stub)", vim.log.levels.INFO)
      -- Log to messages for debugging
      local preview = prompt:sub(1, 100) .. (prompt:len() > 100 and "..." or "")
      print(string.format("Ghost prompt (%d chars): %s", #prompt, preview))
    end

    -- Close the window after sending
    M.close_prompt()

    return true
  end)

  if not ok then
    vim.notify("Ghost: Error handling send - " .. tostring(result), vim.log.levels.ERROR)
    return false
  end

  return result
end

--- Set up BufWriteCmd autocmd for the prompt buffer
--- @param buf number Buffer number
local function setup_write_autocmd(buf)
  -- Clear any existing autocmd
  if state.autocmd_id then
    pcall(vim.api.nvim_del_autocmd, state.autocmd_id)
    state.autocmd_id = nil
  end

  -- Create autocmd to intercept :w, :wq, :x on this buffer
  state.autocmd_id = vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      handle_send()
      -- Mark buffer as not modified to prevent "No write since last change" warning
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_set_option_value("modified", false, { buf = state.buf })
      end
    end,
    desc = "Ghost: Intercept save to send prompt",
  })
end

--- Calculate window dimensions based on config
--- @return table Window configuration for nvim_open_win
local function get_window_config()
  local opts = config.options
  local width = math.floor(vim.o.columns * opts.window.width)
  local height = math.floor(vim.o.lines * opts.window.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Ghost ",
    title_pos = "center",
  }
end

--- Create and open the floating prompt buffer
--- @return number|nil buf The buffer number, or nil if creation failed
--- @return number|nil win The window number, or nil if creation failed
function M.open_prompt()
  -- Wrap in pcall for safety
  local ok, buf_result, win_result = pcall(function()
    -- Close existing window if open - safely
    if state.win then
      pcall(function()
        if vim.api.nvim_win_is_valid(state.win) then
          vim.api.nvim_win_close(state.win, true)
        end
      end)
    end

    -- Create a new scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)
    if buf == 0 then
      vim.notify("Ghost: Failed to create buffer", vim.log.levels.ERROR)
      return nil, nil
    end

    -- Set buffer name - REQUIRED for BufWriteCmd to fire on :w, :wq, :x, ZZ
    pcall(vim.api.nvim_buf_set_name, buf, "ghost://prompt")

    -- Set buffer options - safely
    pcall(vim.api.nvim_set_option_value, "buftype", "acwrite", { buf = buf }) -- acwrite triggers BufWriteCmd
    pcall(vim.api.nvim_set_option_value, "bufhidden", "wipe", { buf = buf })
    pcall(vim.api.nvim_set_option_value, "swapfile", false, { buf = buf })
    pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })

    -- Open the floating window
    local win_config = get_window_config()
    local win = vim.api.nvim_open_win(buf, true, win_config)
    if win == 0 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      vim.notify("Ghost: Failed to create window", vim.log.levels.ERROR)
      return nil, nil
    end

    -- Store state
    state.buf = buf
    state.win = win

    -- Set window options - safely
    pcall(vim.api.nvim_set_option_value, "wrap", true, { win = win })
    pcall(vim.api.nvim_set_option_value, "linebreak", true, { win = win })
    pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })

    -- Set up buffer-local keymaps - safely
    pcall(vim.keymap.set, "n", "q", function()
      M.close_prompt()
    end, { buffer = buf, silent = true, desc = "Close Ghost prompt" })

    -- Set up BufWriteCmd autocmd to intercept save
    setup_write_autocmd(buf)

    -- Start in insert mode - safely
    pcall(vim.cmd, "startinsert")

    return buf, win
  end)

  if not ok then
    vim.notify("Ghost: Error opening prompt - " .. tostring(buf_result), vim.log.levels.ERROR)
    return nil, nil
  end

  return buf_result, win_result
end

--- Close the prompt window
function M.close_prompt()
  -- Wrap in pcall for safety
  pcall(function()
    -- Clean up autocmd
    if state.autocmd_id then
      pcall(vim.api.nvim_del_autocmd, state.autocmd_id)
      state.autocmd_id = nil
    end

    if state.win then
      pcall(function()
        if vim.api.nvim_win_is_valid(state.win) then
          vim.api.nvim_win_close(state.win, true)
        end
      end)
    end
    state.win = nil
    state.buf = nil
  end)
end

--- Check if prompt window is open
--- @return boolean True if prompt is open
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Get the current prompt buffer number
--- @return number|nil Buffer number or nil if not open
function M.get_buf()
  return state.buf
end

--- Get the current prompt window number
--- @return number|nil Window number or nil if not open
function M.get_win()
  return state.win
end

--- Set the callback for when a prompt is sent
--- @param callback fun(prompt: string)|nil The callback function
function M.set_on_send(callback)
  M.on_send = callback
end

--- Get the current prompt text (useful for testing/debugging)
--- @return string|nil The prompt text or nil if buffer invalid
function M.get_prompt()
  return extract_prompt()
end

return M
