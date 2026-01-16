--- Ghost response display module - Floating buffer for streaming output
--- Implements smooth typewriter-style rendering with timer-based updates
--- @module ghost.response

local M = {}

local config = require("ghost.config")

-- Streaming render constants (not exposed to user config)
local RENDER_INTERVAL_MS = 16 -- ~60fps for smooth typewriter effect
local MAX_CHARS_PER_TICK = 128 -- Max chars to process per timer tick (when catching up)
local MIN_CHARS_PER_TICK = 12 -- Min chars per tick (~750 chars/sec for natural typing feel)

--- @class GhostResponseState
--- @field buf number|nil The response buffer number
--- @field win number|nil The response window number
--- @field lines string[] Committed lines in the buffer
--- @field current_line string Current line being built (incomplete)
--- @field tool_calls table<string, table> Active tool calls by ID
--- @field is_streaming boolean Whether response is currently streaming
--- @field is_complete boolean Whether response is complete
--- @field current_session_id string|nil Session ID whose transcript is currently displayed
--- @field pending_chunks string[] Queue of text chunks waiting to be rendered
--- @field pending_bytes number Total bytes in pending_chunks
--- @field render_timer userdata|nil The libuv timer for smooth rendering
--- @field rendered_line_count number Number of state.lines already rendered to buffer
--- @field rendered_current_line string|nil The current_line value last rendered
--- @field needs_full_redraw boolean Force full buffer redraw on next tick
local state = {
  buf = nil,
  win = nil,
  lines = {},
  current_line = "",
  tool_calls = {},
  is_streaming = false,
  is_complete = false,
  on_reply = nil, -- Callback when user wants to reply
  current_session_id = nil, -- Track which session is displayed
  -- Smooth streaming state
  pending_chunks = {},
  pending_bytes = 0,
  render_timer = nil,
  rendered_line_count = 0,
  rendered_current_line = nil,
  needs_full_redraw = false,
}

-- Forward declarations
local update_buffer
local flush_pending
local start_render_timer
local stop_render_timer

--- Start the render timer for smooth streaming
start_render_timer = function()
  if state.render_timer then
    return -- Already running
  end

  local timer = vim.loop.new_timer()
  if not timer then
    return
  end

  state.render_timer = timer
  timer:start(0, RENDER_INTERVAL_MS, vim.schedule_wrap(function()
    flush_pending()
  end))
end

--- Stop the render timer
stop_render_timer = function()
  if state.render_timer then
    state.render_timer:stop()
    state.render_timer:close()
    state.render_timer = nil
  end
end

--- Process pending chunks and update buffer incrementally
flush_pending = function()
  -- Nothing to do if no pending data and no forced redraw
  if #state.pending_chunks == 0 and not state.needs_full_redraw then
    -- Stop timer if not streaming anymore
    if not state.is_streaming then
      stop_render_timer()
    end
    return
  end

  -- Determine how many chars to process this tick (adaptive based on backlog)
  local chars_to_process = MIN_CHARS_PER_TICK
  if state.pending_bytes > 1000 then
    -- Large backlog: process more to catch up (but still smooth)
    chars_to_process = MAX_CHARS_PER_TICK
  elseif state.pending_bytes > 300 then
    -- Medium backlog: moderate speed
    chars_to_process = 48
  elseif state.pending_bytes > 100 then
    -- Small backlog: slightly faster
    chars_to_process = 24
  end

  -- Consume text from pending queue
  local processed = 0
  local text_to_process = {}

  while #state.pending_chunks > 0 and processed < chars_to_process do
    local chunk = state.pending_chunks[1]
    local remaining = chars_to_process - processed

    if #chunk <= remaining then
      -- Take whole chunk
      table.insert(text_to_process, chunk)
      processed = processed + #chunk
      state.pending_bytes = state.pending_bytes - #chunk
      table.remove(state.pending_chunks, 1)
    else
      -- Take partial chunk
      table.insert(text_to_process, chunk:sub(1, remaining))
      state.pending_chunks[1] = chunk:sub(remaining + 1)
      state.pending_bytes = state.pending_bytes - remaining
      processed = remaining
      break
    end
  end

  -- Process text into lines (newline-aware, avoiding per-char concatenation)
  local combined = table.concat(text_to_process)
  if #combined > 0 then
    -- Split by newlines
    local segments = vim.split(combined, "\n", { plain = true })

    for i, segment in ipairs(segments) do
      if i == 1 then
        -- First segment: append to current_line
        state.current_line = state.current_line .. segment
      else
        -- Subsequent segments: commit current_line and start new
        table.insert(state.lines, state.current_line)
        state.current_line = segment
      end
    end
  end

  -- Update buffer (incremental or full redraw)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- Skip buffer updates if window is hidden (just accumulate state)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    state.needs_full_redraw = true
    return
  end

  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = state.buf })

  if state.needs_full_redraw then
    -- Full redraw required
    local display_lines = vim.deepcopy(state.lines)
    if state.current_line ~= "" then
      table.insert(display_lines, state.current_line)
    end
    if #display_lines == 0 then
      display_lines = { "" }
    end
    pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, display_lines)
    state.rendered_line_count = #state.lines
    state.rendered_current_line = state.current_line
    state.needs_full_redraw = false
  else
    -- Incremental update
    local new_committed_count = #state.lines

    -- Append any new committed lines
    if new_committed_count > state.rendered_line_count then
      local new_lines = {}
      for i = state.rendered_line_count + 1, new_committed_count do
        table.insert(new_lines, state.lines[i])
      end
      -- Append new committed lines after existing content
      local insert_at = state.rendered_line_count
      if state.rendered_current_line ~= nil then
        -- There was a current_line rendered; replace it + append
        insert_at = state.rendered_line_count
      end
      pcall(vim.api.nvim_buf_set_lines, state.buf, insert_at, insert_at + (state.rendered_current_line ~= nil and 1 or 0), false, new_lines)
      state.rendered_line_count = new_committed_count
      state.rendered_current_line = nil -- Will be set below if needed
    end

    -- Update or add current_line
    if state.current_line ~= "" then
      local line_idx = state.rendered_line_count
      if state.rendered_current_line ~= nil then
        -- Update existing last line
        pcall(vim.api.nvim_buf_set_lines, state.buf, line_idx, line_idx + 1, false, { state.current_line })
      else
        -- Append new current_line
        pcall(vim.api.nvim_buf_set_lines, state.buf, line_idx, line_idx, false, { state.current_line })
      end
      state.rendered_current_line = state.current_line
    elseif state.rendered_current_line ~= nil then
      -- current_line was cleared (became committed); already handled above
      state.rendered_current_line = nil
    end
  end

  -- Scroll to bottom
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local line_count = vim.api.nvim_buf_line_count(state.buf)
    pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, line_count), 0 })
  end

  -- Stop timer if no more pending data and not streaming
  if #state.pending_chunks == 0 and not state.is_streaming then
    stop_render_timer()
  end
end

--- Calculate window dimensions for response display
--- @return table Window configuration for nvim_open_win
local function get_window_config()
  local opts = config.options
  local width = math.floor(vim.o.columns * (opts.response_window and opts.response_window.width or 0.6))
  local height = math.floor(vim.o.lines * (opts.response_window and opts.response_window.height or 0.4))
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
    title = " Ghost Response ",
    title_pos = "center",
  }
end

--- Create and open the response buffer
--- @param enter boolean|nil Whether to enter the window (default true)
--- @return number|nil buf The buffer number
--- @return number|nil win The window number
function M.open(enter)
  -- Default to entering the window
  if enter == nil then
    enter = true
  end

  -- If window already open and valid, just focus it
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    if enter then
      vim.api.nvim_set_current_win(state.win)
    end
    return state.buf, state.win
  end

  -- Create a new scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  if buf == 0 then
    vim.notify("Ghost: Failed to create response buffer", vim.log.levels.ERROR)
    return nil, nil
  end

  -- Set buffer options
  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "bufhidden", "hide", { buf = buf }) -- hide, not wipe - preserve content
  pcall(vim.api.nvim_set_option_value, "swapfile", false, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })

  -- Open the floating window - ENTER it for focus
  local win_config = get_window_config()
  local win = vim.api.nvim_open_win(buf, enter, win_config)
  if win == 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify("Ghost: Failed to create response window", vim.log.levels.ERROR)
    return nil, nil
  end

  -- Store state (preserve existing content state)
  state.buf = buf
  state.win = win
  -- Only reset content if we don't have existing content
  if #state.lines == 0 and state.current_line == "" then
    state.tool_calls = {}
  end

  -- Set window options
  pcall(vim.api.nvim_set_option_value, "wrap", true, { win = win })
  pcall(vim.api.nvim_set_option_value, "linebreak", true, { win = win })
  pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = win })

  -- Set up buffer-local keymaps
  pcall(vim.keymap.set, "n", "q", function()
    M.hide() -- hide instead of close to preserve content
  end, { buffer = buf, silent = true, desc = "Hide Ghost response" })

  pcall(vim.keymap.set, "n", "<Esc>", function()
    M.hide() -- hide instead of close to preserve content
  end, { buffer = buf, silent = true, desc = "Hide Ghost response" })

  -- Reply keymap - continue the conversation (US-008)
  pcall(vim.keymap.set, "n", "r", function()
    if not state.on_reply then
      vim.notify("Ghost: Reply not available", vim.log.levels.WARN)
      return
    end

    -- Ensure we reply to the session whose transcript is displayed (US-008)
    if state.current_session_id then
      local session = require("ghost.session")
      local ok, err = session.switch_session(state.current_session_id)
      if not ok then
        vim.notify("Ghost: Failed to switch to session - " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
    end

    state.on_reply()
  end, { buffer = buf, silent = true, desc = "Reply to Ghost response" })

  -- Also map Enter to reply for convenience (US-008)
  pcall(vim.keymap.set, "n", "<CR>", function()
    if not state.on_reply then
      vim.notify("Ghost: Reply not available", vim.log.levels.WARN)
      return
    end

    -- Ensure we reply to the session whose transcript is displayed (US-008)
    if state.current_session_id then
      local session = require("ghost.session")
      local ok, err = session.switch_session(state.current_session_id)
      if not ok then
        vim.notify("Ghost: Failed to switch to session - " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
    end

    state.on_reply()
  end, { buffer = buf, silent = true, desc = "Reply to Ghost response" })

  -- Restore existing content if we have any
  if #state.lines > 0 or state.current_line ~= "" or #state.pending_chunks > 0 then
    -- New buffer needs full redraw, reset render tracking
    state.rendered_line_count = 0
    state.rendered_current_line = nil
    state.needs_full_redraw = true
    update_buffer()

    -- Restart timer if there are pending chunks
    if #state.pending_chunks > 0 then
      start_render_timer()
    end
  end

  return buf, win
end

--- Hide the response window (preserves content for later viewing)
function M.hide()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  -- Keep buf, lines, current_line, tool_calls - content is preserved
end

--- Close the response window and clear all content
function M.close()
  -- Stop any in-progress rendering
  stop_render_timer()

  M.hide()
  -- Now clear everything
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.lines = {}
  state.current_line = ""
  state.tool_calls = {}
  state.is_streaming = false
  state.is_complete = false
  state.current_session_id = nil
  -- Reset streaming queue state
  state.pending_chunks = {}
  state.pending_bytes = 0
  state.rendered_line_count = 0
  state.rendered_current_line = nil
  state.needs_full_redraw = false
end

--- Check if response window is open
--- @return boolean True if open
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Check if there is content (even if window is hidden)
--- @return boolean True if has content
function M.has_content()
  return #state.lines > 0 or state.current_line ~= "" or #state.pending_chunks > 0
end

--- Check if response is currently streaming
--- @return boolean True if streaming
function M.is_streaming()
  return state.is_streaming
end

--- Check if response is complete
--- @return boolean True if complete
function M.is_complete()
  return state.is_complete
end

--- Toggle the response window visibility
--- Opens if closed (and has content), closes if open
function M.toggle()
  if M.is_open() then
    M.hide()
  elseif M.has_content() then
    M.open()
  else
    vim.notify("Ghost: No response to show", vim.log.levels.INFO)
  end
end

--- Show the response window (re-open if hidden)
function M.show()
  if M.has_content() then
    M.open()
  else
    vim.notify("Ghost: No response to show", vim.log.levels.INFO)
  end
end

--- Update the buffer content (full redraw for non-streaming updates)
--- Used by tool calls, separators, headers, and transcript loading
update_buffer = function()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- Mark for full redraw and trigger via timer or immediate
  state.needs_full_redraw = true

  -- If timer is running, let it handle the redraw
  if state.render_timer then
    return
  end

  -- Otherwise do immediate full redraw
  vim.schedule(function()
    if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
      return
    end

    local display_lines = vim.deepcopy(state.lines)
    if state.current_line ~= "" then
      table.insert(display_lines, state.current_line)
    end
    if #display_lines == 0 then
      display_lines = { "" }
    end

    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = state.buf })
    pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, display_lines)

    -- Update render tracking
    state.rendered_line_count = #state.lines
    state.rendered_current_line = state.current_line ~= "" and state.current_line or nil
    state.needs_full_redraw = false

    -- Scroll to bottom
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      local line_count = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, line_count), 0 })
    end
  end)
end

--- Append text to the response (handles streaming)
--- Text is queued and rendered smoothly via timer-based updates
--- @param text string The text to append
function M.append_text(text)
  if not text or text == "" then
    return
  end

  -- Mark as streaming
  state.is_streaming = true
  state.is_complete = false

  -- Open window if not already open (don't steal focus if user closed it)
  -- Only open window for first content; if user closed it, just buffer the content
  if not M.is_open() and not M.has_content() and #state.pending_chunks == 0 then
    -- First content - open and focus
    M.open(true)
  end
  -- If window was closed but has content, we just queue the text
  -- Content will be available when user reopens with <leader>ar

  -- Queue text for smooth rendering
  table.insert(state.pending_chunks, text)
  state.pending_bytes = state.pending_bytes + #text

  -- Start render timer if not already running
  start_render_timer()
end

--- Add a tool call status line
--- @param tool_id string Tool call ID
--- @param tool_name string Tool name
--- @param status string Status (pending, in_progress, completed, failed)
--- @param kind string|nil Tool kind (read, edit, execute, etc.)
function M.update_tool_call(tool_id, tool_name, status, kind)
  if not M.is_open() then
    M.open()
  end

  -- Format tool status line
  local status_icon = ({
    pending = "⏳",
    in_progress = "🔄",
    completed = "✅",
    failed = "❌",
  })[status] or "❓"

  local kind_str = kind and (" [" .. kind .. "]") or ""
  local line = string.format("%s %s%s", status_icon, tool_name, kind_str)

  -- Track tool calls to update existing lines
  if state.tool_calls[tool_id] then
    -- Update existing line
    local line_num = state.tool_calls[tool_id].line_num
    if line_num <= #state.lines then
      state.lines[line_num] = line
    end
  else
    -- Add new tool call line
    -- Complete current line first if not empty
    if state.current_line ~= "" then
      table.insert(state.lines, state.current_line)
      state.current_line = ""
    end
    table.insert(state.lines, line)
    state.tool_calls[tool_id] = {
      line_num = #state.lines,
      tool_name = tool_name,
    }
  end

  update_buffer()
end

--- Flush all pending chunks synchronously (used before headers/separators)
local function flush_pending_sync()
  if #state.pending_chunks == 0 then
    return
  end

  -- Process all pending text immediately
  local combined = table.concat(state.pending_chunks)
  state.pending_chunks = {}
  state.pending_bytes = 0

  -- Process into lines
  local segments = vim.split(combined, "\n", { plain = true })
  for i, segment in ipairs(segments) do
    if i == 1 then
      state.current_line = state.current_line .. segment
    else
      table.insert(state.lines, state.current_line)
      state.current_line = segment
    end
  end
end

--- Add a separator line
function M.add_separator()
  if not M.is_open() then
    return
  end

  -- Flush any pending text first to maintain correct order
  flush_pending_sync()

  -- Complete current line first
  if state.current_line ~= "" then
    table.insert(state.lines, state.current_line)
    state.current_line = ""
  end

  table.insert(state.lines, "---")
  update_buffer()
end

--- Add a header line
--- @param header string The header text
function M.add_header(header)
  if not M.is_open() then
    M.open()
  end

  -- Flush any pending text first to maintain correct order
  flush_pending_sync()

  -- Complete current line first
  if state.current_line ~= "" then
    table.insert(state.lines, state.current_line)
    state.current_line = ""
  end

  table.insert(state.lines, "## " .. header)
  table.insert(state.lines, "")
  update_buffer()
end

--- Clear the response buffer content (but keep window open if it is)
function M.clear()
  -- Stop any in-progress rendering
  stop_render_timer()

  -- Reset all state
  state.lines = {}
  state.current_line = ""
  state.tool_calls = {}
  state.is_streaming = false
  state.is_complete = false
  state.current_session_id = nil
  -- Reset streaming queue state
  state.pending_chunks = {}
  state.pending_bytes = 0
  state.rendered_line_count = 0
  state.rendered_current_line = nil
  state.needs_full_redraw = false

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.schedule(function()
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = state.buf })
        pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, { "" })
      end
    end)
  end
end

--- Get the current content
--- @return string The content as a single string
function M.get_content()
  local all_lines = vim.deepcopy(state.lines)
  if state.current_line ~= "" then
    table.insert(all_lines, state.current_line)
  end
  return table.concat(all_lines, "\n")
end

--- Handle a Ghost update event
--- @param update table The update from receiver
function M.handle_update(update)
  if update.type == "text_chunk" then
    M.append_text(update.text)
  elseif update.type == "tool_call" then
    M.update_tool_call(update.tool_id, update.tool_name, update.status or "pending", update.kind)
  elseif update.type == "tool_call_update" then
    -- Look up existing tool call or create new entry
    local tool_info = state.tool_calls[update.tool_id]
    local tool_name = update.tool_name or (tool_info and tool_info.tool_name) or "tool"
    M.update_tool_call(update.tool_id, tool_name, update.status or "in_progress", nil)
  elseif update.type == "tool_output" then
    -- Summarize tool output instead of showing full content
    if update.output_type == "file_content" then
      -- Just show a summary, not the full file
      local line_count = update.line_count or 0
      M.append_text(string.format("  📄 (read %d lines)\n", line_count))
    else
      -- Show truncated output for other types
      local preview = (update.content or ""):sub(1, 100)
      if #(update.content or "") > 100 then
        preview = preview .. "..."
      end
      M.append_text("  → " .. preview .. "\n")
    end
  elseif update.type == "plan" then
    M.add_header("Plan")
    if update.plan and update.plan.entries then
      for _, entry in ipairs(update.plan.entries) do
        local status_icon = entry.completed and "✅" or "⬜"
        M.append_text(status_icon .. " " .. (entry.description or entry.title or "Step") .. "\n")
      end
    end
  end
end

--- Handle completion of a response
--- @param response table The final response from receiver
function M.handle_response(response)
  -- Flush all pending chunks immediately before completion
  while #state.pending_chunks > 0 do
    -- Process all remaining text directly (bypass timer for completion)
    local combined = table.concat(state.pending_chunks)
    state.pending_chunks = {}
    state.pending_bytes = 0

    -- Process into lines
    local segments = vim.split(combined, "\n", { plain = true })
    for i, segment in ipairs(segments) do
      if i == 1 then
        state.current_line = state.current_line .. segment
      else
        table.insert(state.lines, state.current_line)
        state.current_line = segment
      end
    end
  end

  -- Stop the render timer
  stop_render_timer()

  -- Add completion indicators directly (bypass append_text to avoid resetting state)
  if response.type == "explanation" then
    -- Complete current line first
    if state.current_line ~= "" then
      table.insert(state.lines, state.current_line)
      state.current_line = ""
    end
    table.insert(state.lines, "---")
    table.insert(state.lines, "*Response complete*")
  elseif response.type == "edit" then
    if state.current_line ~= "" then
      table.insert(state.lines, state.current_line)
      state.current_line = ""
    end
    table.insert(state.lines, "---")
    table.insert(state.lines, string.format("📝 *Edited: %s*", response.file_path or "unknown"))
  end

  -- Mark as complete (after adding content so it's not overwritten)
  state.is_streaming = false
  state.is_complete = true

  -- Force full redraw to ensure everything is displayed
  state.needs_full_redraw = true
  update_buffer()

  -- Notify user if window is closed
  if not M.is_open() and M.has_content() then
    vim.schedule(function()
      vim.notify("Ghost: Response complete. Press <leader>ar to view.", vim.log.levels.INFO)
    end)
  end
end

--- Set callback for when user wants to reply
--- @param callback fun()|nil Callback function
function M.set_on_reply(callback)
  state.on_reply = callback
end

--- Set the current session ID being displayed
--- @param session_id string|nil Session ID
function M.set_current_session(session_id)
  state.current_session_id = session_id
end

--- Get the current session ID being displayed
--- @return string|nil Session ID
function M.get_current_session()
  return state.current_session_id
end

--- Load transcript content from disk for a session
--- @param session_id string The session ID
--- @return boolean success True if loaded successfully
--- @return string|nil error Error message if load failed
function M.load_transcript(session_id)
  local transcript = require("ghost.transcript")

  -- Read transcript from disk
  local content, err = transcript.read_transcript(session_id)
  if not content then
    return false, err
  end

  -- Clear current response content (also stops timer and resets state)
  M.clear()

  -- Split content into lines and populate the response buffer
  local lines = vim.split(content, "\n", { plain = true })

  -- Set the lines directly into the state
  state.lines = lines
  state.current_line = ""
  state.is_streaming = false
  state.is_complete = true
  state.current_session_id = session_id -- Track which session is displayed (US-008)
  -- Mark for full redraw since we loaded content directly
  state.needs_full_redraw = true
  state.rendered_line_count = 0
  state.rendered_current_line = nil

  -- Update buffer if window is open
  if M.is_open() then
    update_buffer()
  end

  return true, nil
end

return M
