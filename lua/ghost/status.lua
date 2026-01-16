--- Ghost status module - Progress and status indicator for requests
--- @module ghost.status

local M = {}

--- @class GhostRequestStatus
--- @field request_id string Unique request identifier
--- @field started_at number Unix timestamp when request started
--- @field completed_at number|nil Unix timestamp when request completed
--- @field status "pending" | "completed" | "error" Status of the request
--- @field error_message string|nil Error message if status is "error"
--- @field prompt_preview string First 50 chars of the prompt
--- @field file_path string|nil File path associated with the request
--- @field response_type string|nil Type of response received ("edit" or "explanation")
--- @field response_summary string|nil Brief summary of the response

--- @class GhostStatusState
--- @field requests table<string, GhostRequestStatus> Map of request_id to status
--- @field last_completed GhostRequestStatus|nil Last completed request
local state = {
  requests = {},
  last_completed = nil,
}

--- Show a notification using Snacks if available, fallback to vim.notify
--- @param msg string Message to display
--- @param level number vim.log.levels value
local function notify(msg, level)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.notify then
    snacks.notify(msg, { level = level })
  else
    vim.notify(msg, level)
  end
end

--- Create a preview of the prompt (first 50 chars)
--- @param prompt string The full prompt
--- @return string Preview of the prompt
local function create_prompt_preview(prompt)
  if not prompt then
    return ""
  end
  local preview = prompt:sub(1, 50)
  if #prompt > 50 then
    preview = preview .. "..."
  end
  -- Remove newlines for cleaner display
  preview = preview:gsub("\n", " ")
  return preview
end

--- Track a new request being sent
--- Shows "Sending..." notification
--- @param request_id string The unique request ID
--- @param prompt string The prompt text
--- @param file_path string|nil The file path associated with the request
function M.track_request(request_id, prompt, file_path)
  --- @type GhostRequestStatus
  local status = {
    request_id = request_id,
    started_at = os.time(),
    completed_at = nil,
    status = "pending",
    error_message = nil,
    prompt_preview = create_prompt_preview(prompt),
    file_path = file_path,
    response_type = nil,
    response_summary = nil,
  }

  state.requests[request_id] = status

  -- Show sending notification
  notify("Ghost: Sending...", vim.log.levels.INFO)
end

--- Mark a request as completed successfully
--- Shows completion notification with brief summary
--- @param request_id string The request ID
--- @param response_type string The type of response ("edit" or "explanation")
--- @param response_summary string|nil Brief summary of what was done
function M.complete_request(request_id, response_type, response_summary)
  local status = state.requests[request_id]
  if not status then
    -- Request not tracked, still show notification
    local msg = M.format_success_message(response_type, response_summary)
    notify(msg, vim.log.levels.INFO)
    return
  end

  status.completed_at = os.time()
  status.status = "completed"
  status.response_type = response_type
  status.response_summary = response_summary

  -- Store as last completed
  state.last_completed = status

  -- Remove from active requests
  state.requests[request_id] = nil

  -- Show completion notification
  local msg = M.format_success_message(response_type, response_summary, status)
  notify(msg, vim.log.levels.INFO)
end

--- Mark a request as failed
--- Shows error notification with message
--- @param request_id string The request ID
--- @param error_message string The error message
function M.fail_request(request_id, error_message)
  local status = state.requests[request_id]
  if not status then
    -- Request not tracked, still show notification
    notify("Ghost: Error - " .. error_message, vim.log.levels.ERROR)
    return
  end

  status.completed_at = os.time()
  status.status = "error"
  status.error_message = error_message

  -- Store as last completed (even if errored)
  state.last_completed = status

  -- Remove from active requests
  state.requests[request_id] = nil

  -- Show error notification
  local elapsed = status.completed_at - status.started_at
  local msg = string.format("Ghost: Error after %ds - %s", elapsed, error_message)
  notify(msg, vim.log.levels.ERROR)
end

--- Format a success message for a completed request
--- @param response_type string The type of response
--- @param response_summary string|nil Brief summary
--- @param status GhostRequestStatus|nil The request status
--- @return string The formatted message
function M.format_success_message(response_type, response_summary, status)
  local parts = { "Ghost:" }

  if response_type == "edit" then
    table.insert(parts, "Edit applied")
  elseif response_type == "explanation" then
    table.insert(parts, "Explanation added")
  else
    table.insert(parts, "Complete")
  end

  if response_summary then
    table.insert(parts, "- " .. response_summary)
  end

  if status then
    local elapsed = (status.completed_at or os.time()) - status.started_at
    table.insert(parts, string.format("(%ds)", elapsed))
  end

  return table.concat(parts, " ")
end

--- Get elapsed time for an active request
--- @param request_id string The request ID
--- @return number|nil Elapsed seconds, or nil if not found
function M.get_elapsed(request_id)
  local status = state.requests[request_id]
  if not status then
    return nil
  end
  return os.time() - status.started_at
end

--- Get all active request IDs
--- @return string[] List of active request IDs
function M.get_active_request_ids()
  local ids = {}
  for id, _ in pairs(state.requests) do
    table.insert(ids, id)
  end
  return ids
end

--- Get count of active requests
--- @return number Count of active requests
function M.get_active_count()
  local count = 0
  for _, _ in pairs(state.requests) do
    count = count + 1
  end
  return count
end

--- Get status for an active request
--- @param request_id string The request ID
--- @return GhostRequestStatus|nil The status or nil if not found
function M.get_request_status(request_id)
  return state.requests[request_id]
end

--- Get the last completed request status
--- @return GhostRequestStatus|nil The last completed status or nil
function M.get_last_completed()
  return state.last_completed
end

--- Get all active request statuses
--- @return GhostRequestStatus[] List of active request statuses
function M.get_all_active()
  local statuses = {}
  for _, status in pairs(state.requests) do
    table.insert(statuses, status)
  end
  -- Sort by started_at (oldest first)
  table.sort(statuses, function(a, b)
    return a.started_at < b.started_at
  end)
  return statuses
end

--- Clear all tracked requests (for cleanup/testing)
function M.clear()
  state.requests = {}
  state.last_completed = nil
end

--- Clear all active requests, optionally marking them as timed out
--- @param mark_as_error boolean|nil If true, mark them as errors instead of just removing
function M.clear_active(mark_as_error)
  if mark_as_error then
    for request_id, req in pairs(state.requests) do
      req.completed_at = os.time()
      req.status = "error"
      req.error_message = "Request cleared (timed out or disconnected)"
      state.last_completed = req
    end
  end
  state.requests = {}
end

--- Clear requests older than a given threshold
--- @param max_age_seconds number Maximum age in seconds
--- @return number count Number of requests cleared
function M.clear_stale(max_age_seconds)
  local now = os.time()
  local cleared = 0
  local to_remove = {}

  for request_id, req in pairs(state.requests) do
    local age = now - req.started_at
    if age > max_age_seconds then
      table.insert(to_remove, request_id)
      req.completed_at = now
      req.status = "error"
      req.error_message = string.format("Timed out after %ds", age)
      state.last_completed = req
      cleared = cleared + 1
    end
  end

  for _, request_id in ipairs(to_remove) do
    state.requests[request_id] = nil
  end

  return cleared
end

--- Get a summary of a request status for display
--- @param status GhostRequestStatus The status to summarize
--- @return string Summary string
function M.status_summary(status)
  local elapsed = (status.completed_at or os.time()) - status.started_at
  local parts = {
    string.format("ID: %s", status.request_id),
    string.format("Status: %s", status.status),
    string.format("Elapsed: %ds", elapsed),
    string.format("Prompt: %s", status.prompt_preview),
  }

  if status.file_path then
    table.insert(parts, string.format("File: %s", vim.fn.fnamemodify(status.file_path, ":t")))
  end

  if status.error_message then
    table.insert(parts, string.format("Error: %s", status.error_message))
  end

  if status.response_type then
    table.insert(parts, string.format("Response: %s", status.response_type))
  end

  return table.concat(parts, " | ")
end

--- Get an overall status summary for display
--- @return string Summary of current status
function M.summary()
  local active_count = M.get_active_count()
  local parts = {}

  if active_count == 0 then
    table.insert(parts, "No active requests")
  elseif active_count == 1 then
    table.insert(parts, "1 active request")
  else
    table.insert(parts, string.format("%d active requests", active_count))
  end

  if state.last_completed then
    local last = state.last_completed
    local ago = os.time() - (last.completed_at or os.time())
    local ago_str
    if ago < 60 then
      ago_str = string.format("%ds ago", ago)
    elseif ago < 3600 then
      ago_str = string.format("%dm ago", math.floor(ago / 60))
    else
      ago_str = string.format("%dh ago", math.floor(ago / 3600))
    end

    if last.status == "completed" then
      table.insert(parts, string.format("Last: %s %s", last.response_type or "complete", ago_str))
    else
      table.insert(parts, string.format("Last: error %s", ago_str))
    end
  end

  return table.concat(parts, " | ")
end

--- @class GhostStatusWindowState
--- @field buf number|nil The status buffer number
--- @field win number|nil The status window number
local window_state = {
  buf = nil,
  win = nil,
}

--- Format elapsed time as human-readable string
--- @param seconds number Elapsed seconds
--- @return string Formatted time string
local function format_elapsed(seconds)
  if seconds < 60 then
    return string.format("%ds", seconds)
  elseif seconds < 3600 then
    return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
  else
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    return string.format("%dh %dm", hours, mins)
  end
end

--- Format time ago as human-readable string
--- @param seconds number Seconds ago
--- @return string Formatted time ago string
local function format_ago(seconds)
  if seconds < 60 then
    return string.format("%ds ago", seconds)
  elseif seconds < 3600 then
    return string.format("%dm ago", math.floor(seconds / 60))
  else
    return string.format("%dh ago", math.floor(seconds / 3600))
  end
end

--- Build the content lines for the status window
--- @return string[] Lines to display in the status window
function M.build_status_content()
  local acp = require("ghost.acp")
  local lines = {}

  -- Header
  table.insert(lines, "Ghost Status")
  table.insert(lines, string.rep("-", 40))
  table.insert(lines, "")

  -- Backend
  local acp_status = acp.status()
  table.insert(lines, "Backend:")
  table.insert(lines, string.format("  %s", acp_status.backend or "opencode"))
  table.insert(lines, "")

  -- Connection state with clear labels
  table.insert(lines, "Connection State:")
  if acp_status.initialized then
    table.insert(lines, "  Status: CONNECTED")
    local agent_name = acp_status.agent_info and acp_status.agent_info.name or "unknown"
    local version = acp_status.agent_info and acp_status.agent_info.version or ""
    table.insert(lines, string.format("  Agent: %s %s", agent_name, version))
    if acp_status.session_id then
      table.insert(lines, string.format("  Session: %s", acp_status.session_id:sub(1, 12) .. "..."))
    else
      table.insert(lines, "  Session: none")
    end
    table.insert(lines, "  Transport: stdio (acp subprocess)")
    if acp_status.pending_requests > 0 then
      table.insert(lines, string.format("  Pending requests: %d", acp_status.pending_requests))
    end
  elseif acp_status.initializing then
    table.insert(lines, "  Status: INITIALIZING")
    table.insert(lines, "  Starting ACP subprocess...")
  elseif acp_status.running then
    table.insert(lines, "  Status: INITIALIZING")
    table.insert(lines, "  Subprocess running, awaiting handshake...")
  else
    table.insert(lines, "  Status: DISCONNECTED")
    table.insert(lines, "  ACP subprocess not running")
    table.insert(lines, "  Will auto-start when you send a prompt")
  end
  table.insert(lines, "")

  -- Last Error (if present)
  if acp_status.last_error then
    table.insert(lines, "Last Error:")
    local error_ago = acp_status.last_error_time and (os.time() - acp_status.last_error_time) or 0
    table.insert(lines, string.format("  %s", acp_status.last_error))
    if error_ago > 0 then
      table.insert(lines, string.format("  (%s)", format_ago(error_ago)))
    end
    table.insert(lines, "")
  end

  -- Active requests
  table.insert(lines, "Active Requests:")
  local active = M.get_all_active()
  if #active == 0 then
    table.insert(lines, "  No active requests")
  else
    for _, req in ipairs(active) do
      local elapsed = os.time() - req.started_at
      local file_info = ""
      if req.file_path then
        file_info = string.format(" (%s)", vim.fn.fnamemodify(req.file_path, ":t"))
      end
      table.insert(
        lines,
        string.format("  [%s] %s - %s%s", format_elapsed(elapsed), req.request_id, req.prompt_preview, file_info)
      )
    end
  end
  table.insert(lines, "")

  -- Last completed request
  table.insert(lines, "Last Completed:")
  local last = state.last_completed
  if not last then
    table.insert(lines, "  None")
  else
    local ago = os.time() - (last.completed_at or os.time())
    local status_str
    if last.status == "completed" then
      status_str = string.format("%s", last.response_type or "complete")
      if last.response_summary then
        status_str = status_str .. " - " .. last.response_summary
      end
    else
      status_str = "error"
      if last.error_message then
        status_str = status_str .. " - " .. last.error_message
      end
    end
    table.insert(lines, string.format("  %s (%s)", status_str, format_ago(ago)))
    table.insert(lines, string.format("  Prompt: %s", last.prompt_preview))
    if last.file_path then
      table.insert(lines, string.format("  File: %s", vim.fn.fnamemodify(last.file_path, ":t")))
    end
  end
  table.insert(lines, "")
  table.insert(lines, string.rep("-", 40))
  table.insert(lines, "Press q or <Esc> to close")

  return lines
end

--- Calculate window dimensions for the status window
--- @param content_lines string[] The content lines to display
--- @return table Window configuration for nvim_open_win
local function get_status_window_config(content_lines)
  -- Calculate width based on longest line
  local max_width = 40
  for _, line in ipairs(content_lines) do
    max_width = math.max(max_width, #line)
  end
  -- Add padding
  local width = math.min(max_width + 4, math.floor(vim.o.columns * 0.8))
  local height = math.min(#content_lines, math.floor(vim.o.lines * 0.8))

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
    title = " Ghost Status ",
    title_pos = "center",
  }
end

--- Close the status window if open
function M.close_status_window()
  if window_state.win and vim.api.nvim_win_is_valid(window_state.win) then
    vim.api.nvim_win_close(window_state.win, true)
  end
  window_state.win = nil
  window_state.buf = nil
end

--- Open or refresh the status window
function M.show_status_window()
  -- Close existing window if open
  M.close_status_window()

  -- Build content
  local lines = M.build_status_content()

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  if buf == 0 then
    notify("Ghost: Failed to create status buffer", vim.log.levels.ERROR)
    return
  end

  -- Set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Set buffer options
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Open window
  local win_config = get_status_window_config(lines)
  local win = vim.api.nvim_open_win(buf, true, win_config)
  if win == 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    notify("Ghost: Failed to create status window", vim.log.levels.ERROR)
    return
  end

  -- Store state
  window_state.buf = buf
  window_state.win = win

  -- Set window options
  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Set up keymaps to close window
  vim.keymap.set("n", "q", function()
    M.close_status_window()
  end, { buffer = buf, silent = true, desc = "Close Ghost status" })

  vim.keymap.set("n", "<Esc>", function()
    M.close_status_window()
  end, { buffer = buf, silent = true, desc = "Close Ghost status" })
end

--- Check if status window is open
--- @return boolean True if status window is open
function M.is_status_window_open()
  return window_state.win ~= nil and vim.api.nvim_win_is_valid(window_state.win)
end

return M
