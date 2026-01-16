--- Ghost context module - Capture buffer context for AI prompts
--- @module ghost.context

local M = {}

--- @class GhostCursorPosition
--- @field line number 1-based line number
--- @field col number 1-based column number

--- @class GhostSelectionRange
--- @field start_line number 1-based start line
--- @field end_line number 1-based end line
--- @field start_col number 1-based start column
--- @field end_col number 1-based end column
--- @field mode string Visual mode: 'v' (character), 'V' (line), or '<C-v>' (block)

--- @class GhostContext
--- @field file_path string|nil Absolute path to the file (nil for unnamed buffers)
--- @field file_name string|nil File name without path (nil for unnamed buffers)
--- @field file_extension string|nil File extension (nil if no extension)
--- @field filetype string Vim filetype (may be empty string)
--- @field language string|nil Detected language (via vim.filetype or filetype)
--- @field content string Full buffer content
--- @field cursor GhostCursorPosition Cursor position at capture time
--- @field bufnr number Buffer number that context was captured from
--- @field is_special boolean True if buffer is a special buffer (no file)
--- @field is_unnamed boolean True if buffer has no name
--- @field selection string|nil Selected text (nil if no selection)
--- @field selection_range GhostSelectionRange|nil Selection range info (nil if no selection)
--- @field has_selection boolean True if context includes a selection

--- Current context state (populated before opening prompt)
--- @type GhostContext|nil
M.current = nil

--- Detect language from filetype or extension
--- @param filetype string Vim filetype
--- @param extension string|nil File extension
--- @return string|nil Detected language name
local function detect_language(filetype, extension)
  -- Prefer filetype if available
  if filetype and filetype ~= "" then
    return filetype
  end

  -- Fall back to extension-based detection
  if extension then
    -- Try vim.filetype.match for extension-based detection
    local detected = vim.filetype.match({ filename = "file." .. extension })
    if detected then
      return detected
    end
  end

  return nil
end

--- Extract file extension from path
--- @param path string|nil File path
--- @return string|nil Extension without leading dot, or nil
local function get_extension(path)
  if not path or path == "" then
    return nil
  end
  local ext = path:match("%.([^%.]+)$")
  return ext
end

--- Check if a buffer is a special buffer type
--- @param bufnr number Buffer number
--- @return boolean True if special buffer
local function is_special_buffer(bufnr)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
  -- Special buftypes: nofile, nowrite, acwrite, quickfix, help, terminal, prompt, popup
  return buftype ~= "" and buftype ~= nil
end

--- Get visual selection text and range from current buffer
--- Must be called while in visual mode or immediately after exiting
--- @param bufnr number Buffer number
--- @return string|nil selection_text The selected text
--- @return GhostSelectionRange|nil range Selection range info
local function get_visual_selection(bufnr)
  -- Get visual selection marks
  -- '<' and '>' are the start and end of the visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  -- getpos returns {bufnum, lnum, col, off}
  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  -- Check if marks are valid (they have been set)
  if start_line == 0 or end_line == 0 then
    return nil, nil
  end

  -- Get the visual mode that was used
  local mode = vim.fn.visualmode()
  if mode == "" then
    return nil, nil
  end

  -- Get the selected lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil, nil
  end

  local selection_text
  if mode == "V" then
    -- Line-wise visual mode: full lines
    selection_text = table.concat(lines, "\n")
  elseif mode == "v" then
    -- Character-wise visual mode
    if #lines == 1 then
      -- Single line selection
      selection_text = lines[1]:sub(start_col, end_col)
    else
      -- Multi-line selection
      lines[1] = lines[1]:sub(start_col)
      lines[#lines] = lines[#lines]:sub(1, end_col)
      selection_text = table.concat(lines, "\n")
    end
  else
    -- Block mode (Ctrl-V) - treat as line-wise for simplicity
    -- (Block mode is complex to handle perfectly)
    selection_text = table.concat(lines, "\n")
  end

  --- @type GhostSelectionRange
  local range = {
    start_line = start_line,
    end_line = end_line,
    start_col = start_col,
    end_col = end_col,
    mode = mode,
  }

  return selection_text, range
end

--- Capture context from the current buffer
--- @param bufnr number|nil Buffer number (defaults to current buffer)
--- @param include_selection boolean|nil Whether to capture visual selection (default false)
--- @return GhostContext Captured context
function M.capture(bufnr, include_selection) -- luacheck: ignore 561
  -- Safely get buffer number with fallback
  local ok, bufnr_result = pcall(function()
    return bufnr or vim.api.nvim_get_current_buf()
  end)
  if not ok or not bufnr_result then
    vim.notify("Ghost: Failed to get current buffer", vim.log.levels.ERROR)
    -- Return minimal context to avoid crashes
    return {
      file_path = nil,
      file_name = nil,
      file_extension = nil,
      filetype = "",
      language = nil,
      content = "",
      cursor = { line = 1, col = 1 },
      bufnr = 0,
      is_special = true,
      is_unnamed = true,
      selection = nil,
      selection_range = nil,
      has_selection = false,
    }
  end
  bufnr = bufnr_result

  -- Get buffer name (file path) - safely
  local buf_name_ok, buf_name_result = pcall(vim.api.nvim_buf_get_name, bufnr)
  local buf_name = buf_name_ok and buf_name_result or ""
  local has_name = buf_name ~= ""

  -- Determine file path and name
  local file_path = has_name and buf_name or nil
  local file_name = nil
  if file_path then
    file_name = vim.fn.fnamemodify(file_path, ":t")
  end

  -- Get file extension
  local extension = get_extension(file_path)

  -- Get filetype - safely
  local ft_ok, ft_result = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  local filetype = ft_ok and ft_result or ""

  -- Detect language
  local language = detect_language(filetype, extension)

  -- Get buffer content - safely handle empty or invalid buffers
  local lines_ok, lines_result = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  local lines = lines_ok and lines_result or {}
  local content = table.concat(lines, "\n")

  -- Get cursor position (1-based for both line and col) - safely
  local cursor_ok, cursor_result = pcall(vim.api.nvim_win_get_cursor, 0)
  local cursor = cursor_ok and cursor_result or { 1, 0 }
  local cursor_pos = {
    line = cursor[1] or 1,
    col = (cursor[2] or 0) + 1, -- nvim_win_get_cursor returns 0-based col
  }

  -- Check if special buffer
  local is_special = is_special_buffer(bufnr)

  -- Capture visual selection if requested - safely
  local selection_text = nil
  local selection_range = nil
  if include_selection then
    local sel_ok, sel_text, sel_range = pcall(function()
      return get_visual_selection(bufnr)
    end)
    if sel_ok then
      selection_text = sel_text
      selection_range = sel_range
    end
  end

  --- @type GhostContext
  local context = {
    file_path = file_path,
    file_name = file_name,
    file_extension = extension,
    filetype = filetype or "",
    language = language,
    content = content,
    cursor = cursor_pos,
    bufnr = bufnr,
    is_special = is_special,
    is_unnamed = not has_name,
    selection = selection_text,
    selection_range = selection_range,
    has_selection = selection_text ~= nil,
  }

  -- Store in module state
  M.current = context

  return context
end

--- Get the current stored context
--- @return GhostContext|nil Current context or nil if not captured
function M.get()
  return M.current
end

--- Clear the stored context
function M.clear()
  M.current = nil
end

--- Check if context has been captured
--- @return boolean True if context exists
function M.has_context()
  return M.current ~= nil
end

--- Get a summary string of the current context (for debugging/display)
--- @return string Summary of current context
function M.summary()
  if not M.current then
    return "No context captured"
  end

  local ctx = M.current
  local parts = {}

  if ctx.file_name then
    table.insert(parts, "File: " .. ctx.file_name)
  elseif ctx.is_unnamed then
    table.insert(parts, "File: [unnamed]")
  else
    table.insert(parts, "File: [special buffer]")
  end

  if ctx.language then
    table.insert(parts, "Lang: " .. ctx.language)
  end

  table.insert(parts, string.format("Cursor: %d:%d", ctx.cursor.line, ctx.cursor.col))
  table.insert(parts, string.format("Lines: %d", #vim.split(ctx.content, "\n", { plain = true })))

  -- Add selection info if present
  if ctx.has_selection and ctx.selection_range then
    local range = ctx.selection_range
    local mode_name = range.mode == "V" and "line" or (range.mode == "v" and "char" or "block")
    table.insert(
      parts,
      string.format(
        "Selection: %d:%d-%d:%d (%s)",
        range.start_line,
        range.start_col,
        range.end_line,
        range.end_col,
        mode_name
      )
    )
  end

  return table.concat(parts, " | ")
end

return M
