--- Ghost - A lightweight Neovim plugin for AI-powered code assistance via OpenCode ACP
--- @module ghost

local M = {}

local config = require("ghost.config")
local context = require("ghost.context")
local ui = require("ghost.ui")
local sender = require("ghost.sender")
local receiver = require("ghost.receiver")
local status = require("ghost.status")
local response_display = require("ghost.response")
local session = require("ghost.session")
local transcript = require("ghost.transcript")
local list = require("ghost.list")

--- Setup keybinding for opening the prompt
local function setup_keymaps()
  local keybind = config.options.keybind

  -- Normal mode: create NEW session every time
  vim.keymap.set("n", keybind, function()
    -- Create a brand new session (US-001)
    local session_id, err = session.create_session()
    if not session_id then
      vim.notify("Ghost: Failed to create session - " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    -- Capture context from current buffer before opening prompt
    context.capture(nil, false)
    ui.open_prompt()
  end, { silent = true, desc = "Ghost: Create new session and open AI prompt" })

  -- Visual mode: create NEW session with selection
  vim.keymap.set("v", keybind, function()
    -- Create a brand new session (US-001)
    local session_id, err = session.create_session()
    if not session_id then
      vim.notify("Ghost: Failed to create session - " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    -- Exit visual mode first so '< and '> marks are set
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    -- Small delay to ensure marks are set, then capture with selection
    vim.schedule(function()
      context.capture(nil, true)
      ui.open_prompt()
    end)
  end, { silent = true, desc = "Ghost: Create new session and open AI prompt with selection" })

  -- Toggle response window - <leader>ar (ai response)
  vim.keymap.set("n", "<leader>ar", function()
    response_display.toggle()
  end, { silent = true, desc = "Ghost: Toggle response window" })
end

--- Register user commands
local function setup_commands()
  -- :GhostStatus command to show status window
  vim.api.nvim_create_user_command("GhostStatus", function()
    status.show_status_window()
  end, {
    desc = "Show Ghost status window with connection state and active requests",
  })

  -- :GhostClear command to clear stale requests
  vim.api.nvim_create_user_command("GhostClear", function(opts)
    local max_age = tonumber(opts.args) or 60 -- Default: 60 seconds
    local cleared = status.clear_stale(max_age)
    if cleared > 0 then
      vim.notify(string.format("Ghost: Cleared %d stale request(s)", cleared), vim.log.levels.INFO)
    else
      vim.notify("Ghost: No stale requests to clear", vim.log.levels.INFO)
    end
  end, {
    nargs = "?",
    desc = "Clear stale Ghost requests (optionally specify max age in seconds)",
  })

  -- :GhostReconnect command to reconnect ACP for active session
  vim.api.nvim_create_user_command("GhostReconnect", function()
    status.clear_active(true) -- Clear active requests as errors

    local active_session = session.get_active_session()
    if not active_session then
      vim.notify("Ghost: No active session to reconnect", vim.log.levels.WARN)
      return
    end

    local acp_instance = session.get_acp_instance(active_session.id)
    if not acp_instance then
      vim.notify("Ghost: No ACP instance for active session", vim.log.levels.ERROR)
      return
    end

    -- Disconnect and reinitialize
    acp_instance.disconnect()
    vim.defer_fn(function()
      acp_instance.initialize(function(err)
        if err then
          vim.notify("Ghost: Reconnect failed - " .. err, vim.log.levels.ERROR)
        else
          vim.notify("Ghost: Reconnected successfully", vim.log.levels.INFO)
        end
      end)
    end, 100)
  end, {
    desc = "Reconnect Ghost to OpenCode ACP for active session",
  })

  -- :GhostResponse command to toggle response window
  vim.api.nvim_create_user_command("GhostResponse", function()
    response_display.toggle()
  end, {
    desc = "Toggle Ghost response window",
  })

  -- :GhostResponseClose command to close and clear response
  vim.api.nvim_create_user_command("GhostResponseClose", function()
    response_display.close()
  end, {
    desc = "Close Ghost response window and clear content",
  })

  -- :GhostList command to list and switch sessions (US-004)
  vim.api.nvim_create_user_command("GhostList", function()
    list.open()
  end, {
    desc = "List and switch Ghost sessions",
  })
end

--- Track whether we're in reply mode (continuing conversation)
local is_reply_mode = false

--- Handle prompt submission
--- @param prompt string The prompt text from the UI
local function handle_prompt_send(prompt)
  -- Wrap in pcall to prevent any unhandled errors from crashing Neovim
  local ok, err = pcall(function()
    -- Get active session
    local active_session = session.get_active_session()
    if not active_session then
      vim.notify("Ghost: No active session", vim.log.levels.ERROR)
      return
    end
    local session_id = active_session.id

    -- Get current context for file path tracking
    local ctx = context.get()
    local file_path = ctx and ctx.file_path or nil

    -- For new prompts, clear and start fresh
    -- For replies, keep existing content and append
    if is_reply_mode then
      -- Reply mode: add separator and continue
      response_display.add_separator()
      response_display.add_header("Follow-up")
      response_display.append_text(prompt .. "\n\n")
      response_display.add_header("Response")
      response_display.open() -- Ensure window is open
      is_reply_mode = false -- Reset reply mode
    else
      -- New prompt: clear and start fresh
      response_display.clear()
      response_display.open()
      response_display.add_header("Prompt")
      response_display.append_text(prompt .. "\n\n")
      response_display.add_header("Response")
    end

    -- Track which session this response belongs to (US-008)
    response_display.set_current_session(session_id)

    sender.send(prompt, {
      on_success = function(request_id)
        -- Track the request in status module
        status.track_request(request_id, prompt, file_path)

        -- Write prompt to transcript (US-003)
        transcript.write_prompt(session_id, prompt, request_id)

        -- Start response section in transcript (US-003)
        transcript.start_response(session_id, request_id)
      end,
      -- Note: on_update is NOT needed here because the notification handler
      -- set in setup() already calls receiver.handle_update() which forwards
      -- to response_display. Having it here would cause duplicate processing.
      on_complete = function(result, request_id)
        -- Handle completion
        receiver.handle_complete(result, request_id)
      end,
      on_error = function(send_err)
        -- Show error via status module
        status.fail_request("unknown", send_err)
        -- Show error in response window
        response_display.add_separator()
        response_display.append_text("❌ Error: " .. send_err .. "\n")
        -- Write error to transcript (US-003)
        transcript.write_error(session_id, send_err)
      end,
    })
  end)

  if not ok then
    vim.notify("Ghost: Failed to send prompt - " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Default handler for ACP responses
--- Agent applies edits directly - we just display the response and reload buffers
--- @param response GhostResponse The response from ACP
local function handle_response(response)
  -- Wrap in pcall to prevent any unhandled errors from crashing Neovim
  local ok, err = pcall(function()
    local request_id = response.request_id or "unknown"

    -- Update response display
    response_display.handle_response(response)

    -- Mark request complete based on type
    if response.type == "explanation" then
      local summary = string.format("%d chars", #(response.text or ""))
      status.complete_request(request_id, "explanation", summary)
    else
      status.complete_request(request_id, response.type or "complete", nil)
    end

    -- Complete transcript entry for the correct session (US-009)
    local target_session_id = response.ghost_session_id
    if not target_session_id then
      local active_session = session.get_active_session()
      if active_session then
        target_session_id = active_session.id
      end
    end

    if target_session_id then
      transcript.complete_response(target_session_id)
    end

    -- Reload any buffers that may have been modified by the agent
    -- This picks up file changes made by OpenCode's file tools
    vim.schedule(function()
      vim.cmd("checktime")
    end)
  end)

  if not ok then
    vim.notify("Ghost: Failed to handle response - " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Setup autoread so buffers reload when agent edits files
local function setup_autoread()
  if config.options.autoread then
    -- Enable autoread globally
    vim.o.autoread = true -- luacheck: ignore

    -- Check for file changes when Neovim gains focus or buffer is entered
    local group = vim.api.nvim_create_augroup("GhostAutoread", { clear = true })
    vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
      group = group,
      pattern = "*",
      callback = function()
        if vim.fn.getcmdwintype() == "" then
          vim.cmd("checktime")
        end
      end,
    })
  end
end

local function setup_shutdown()
  local group = vim.api.nvim_create_augroup("GhostShutdown", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      vim.g.ghost_exiting = true

      pcall(function()
        require("ghost.acp_manager").clear_all()
      end)

      pcall(function()
        local ok, acp = pcall(require, "ghost.acp")
        if ok and acp and acp.disconnect then
          acp.disconnect()
        end
      end)
    end,
    desc = "Ghost: stop ACP jobs on exit",
  })
end

--- Setup Ghost with user configuration
--- @param opts table|nil User configuration options
function M.setup(opts)
  local ok, err = pcall(function()
    config.setup(opts)
    session.init() -- Load persisted sessions
    setup_keymaps()
    setup_commands()
    setup_autoread()
    setup_shutdown()
    -- Connect UI send callback to sender
    ui.set_on_send(handle_prompt_send)
    -- Set up receiver's update handler to forward processed updates to response display
    -- Note: ACP notification handlers are now set up per-session (US-009)
    receiver.set_on_update(function(update)
      response_display.handle_update(update)
    end)
    -- Set up response handler
    receiver.set_on_response(handle_response)
    -- Set up reply callback - when user presses 'r' in response window
    response_display.set_on_reply(function()
      -- Set reply mode so handle_prompt_send knows to append not clear
      is_reply_mode = true
      -- Open the prompt window for the reply
      ui.open_prompt()
    end)
  end)

  if not ok then
    vim.notify("Ghost: Setup failed - " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Get current configuration
--- @return table Current configuration
function M.get_config()
  return config.options
end

--- Open the Ghost prompt buffer
--- Captures context from current buffer before opening
--- @param include_selection boolean|nil Whether to capture visual selection (default false)
--- @return number|nil buf The buffer number
--- @return number|nil win The window number
function M.open_prompt(include_selection)
  -- Capture context from current buffer before opening prompt
  context.capture(nil, include_selection or false)
  return ui.open_prompt()
end

--- Close the Ghost prompt buffer
function M.close_prompt()
  ui.close_prompt()
end

--- Check if prompt is open
--- @return boolean
function M.is_prompt_open()
  return ui.is_open()
end

--- Get the current captured context
--- @return GhostContext|nil Current context or nil
function M.get_context()
  return context.get()
end

--- Clear the captured context
function M.clear_context()
  context.clear()
end

--- Get a summary of the current context
--- @return string Context summary
function M.context_summary()
  return context.summary()
end

--- Set the callback for when a prompt is sent
--- @param callback fun(prompt: string)|nil The callback function
function M.set_on_send(callback)
  ui.set_on_send(callback)
end

--- Send the current prompt (useful for programmatic sending)
--- Extracts prompt from buffer and triggers send flow
--- @return string|nil The prompt text or nil if buffer invalid
function M.get_prompt()
  return ui.get_prompt()
end

--- Send a prompt with context via ACP
--- @param prompt string The prompt text
--- @param opts table|nil Optional send options
--- @return string|nil request_id The request ID, or nil if send failed
--- @return string|nil error Error message if send failed
function M.send_prompt(prompt, opts)
  return sender.send(prompt, opts)
end

--- Get an active request by ID
--- @param request_id string Request ID
--- @return GhostRequest|nil The request or nil if not found
function M.get_request(request_id)
  return sender.get_request(request_id)
end

--- Get all active request IDs
--- @return string[] List of active request IDs
function M.get_active_requests()
  return sender.get_active_request_ids()
end

--- Get count of active requests
--- @return number Count of active requests
function M.get_active_request_count()
  return sender.get_active_count()
end

--- Build the message that would be sent for a prompt (for debugging)
--- @param prompt string The prompt text
--- @return table The formatted message table
function M.build_message(prompt)
  return sender.build_message(prompt)
end

--- Check if ACP is connected for active session
--- @return boolean True if connected
function M.is_connected()
  local active_session = session.get_active_session()
  if not active_session then
    return false
  end

  local acp_instance = session.get_acp_instance(active_session.id)
  if not acp_instance then
    return false
  end

  return acp_instance.is_connected()
end

--- Get ACP connection status summary for active session
--- @return string Status summary
function M.acp_status()
  local active_session = session.get_active_session()
  if not active_session then
    return "No active session"
  end

  local acp_instance = session.get_acp_instance(active_session.id)
  if not acp_instance then
    return "No ACP instance for active session"
  end

  local status_info = acp_instance.status()
  if status_info.initialized then
    local agent_name = status_info.agent_info and status_info.agent_info.name or "unknown"
    local version = status_info.agent_info and status_info.agent_info.version or ""
    if status_info.acp_session_id then
      local session_short = status_info.acp_session_id:sub(1, 8)
      return string.format("Connected to %s %s (session: %s)", agent_name, version, session_short)
    else
      return string.format("Connected to %s %s (no ACP session)", agent_name, version)
    end
  elseif status_info.running then
    return "Starting ACP subprocess..."
  else
    return "Disconnected (ACP subprocess not running; backend=" .. status_info.backend .. ")"
  end
end

--- Set the response handler callback
--- @param callback fun(response: GhostResponse)|nil Callback for responses
function M.set_on_response(callback)
  receiver.set_on_response(callback)
end

--- Set the error handler callback for ACP responses
--- @param callback fun(err: string)|nil Callback for errors
function M.set_on_response_error(callback)
  receiver.set_on_error(callback)
end

--- Get a summary of a response (for debugging/display)
--- @param response GhostResponse The response
--- @return string Summary string
function M.response_summary(response)
  return receiver.response_summary(response)
end

--- Check if there is pending data in the receive buffer
--- @return boolean True if buffer has data
function M.has_pending_response()
  return receiver.has_pending_data()
end

--- Track a request in the status module
--- @param request_id string The request ID
--- @param prompt string The prompt text
--- @param file_path string|nil The file path
function M.track_request(request_id, prompt, file_path)
  status.track_request(request_id, prompt, file_path)
end

--- Mark a request as completed
--- @param request_id string The request ID
--- @param response_type string The response type
--- @param response_summary string|nil Brief summary
function M.complete_request(request_id, response_type, response_summary)
  status.complete_request(request_id, response_type, response_summary)
end

--- Mark a request as failed
--- @param request_id string The request ID
--- @param error_message string The error message
function M.fail_request(request_id, error_message)
  status.fail_request(request_id, error_message)
end

--- Get count of active requests being tracked
--- @return number Count of active requests
function M.get_status_active_count()
  return status.get_active_count()
end

--- Get last completed request status
--- @return GhostRequestStatus|nil Last completed status
function M.get_last_completed()
  return status.get_last_completed()
end

--- Get status summary for display
--- @return string Status summary
function M.status_summary()
  return status.summary()
end

--- Get all active request statuses
--- @return GhostRequestStatus[] List of active statuses
function M.get_all_active_statuses()
  return status.get_all_active()
end

--- Show the Ghost status window
--- Opens a floating window with connection state, active requests, and last completed
function M.show_status()
  status.show_status_window()
end

--- Close the Ghost status window if open
function M.close_status()
  status.close_status_window()
end

--- Check if the status window is open
--- @return boolean True if status window is open
function M.is_status_open()
  return status.is_status_window_open()
end

-- Response display functions

--- Open the response display window
--- @return number|nil buf Buffer number
--- @return number|nil win Window number
function M.open_response()
  return response_display.open()
end

--- Close the response display window
function M.close_response()
  response_display.close()
end

--- Check if response display is open
--- @return boolean True if open
function M.is_response_open()
  return response_display.is_open()
end

--- Clear the response display
function M.clear_response()
  response_display.clear()
end

--- Get the current response content
--- @return string Content
function M.get_response_content()
  return response_display.get_content()
end

--- Toggle the response window
function M.toggle_response()
  response_display.toggle()
end

--- Show the response window (reopen if hidden)
function M.show_response()
  response_display.show()
end

--- Hide the response window (preserve content)
function M.hide_response()
  response_display.hide()
end

--- Check if response has content
--- @return boolean True if has content
function M.has_response_content()
  return response_display.has_content()
end

--- Check if response is currently streaming
--- @return boolean True if streaming
function M.is_response_streaming()
  return response_display.is_streaming()
end

--- Check if response is complete
--- @return boolean True if complete
function M.is_response_complete()
  return response_display.is_complete()
end

-- Session management functions

--- Create a new Ghost session
--- @param opts table|nil Optional session creation options
--- @return string|nil session_id The new session ID, or nil on error
--- @return string|nil error Error message if creation failed
function M.create_session(opts)
  return session.create_session(opts)
end

--- Get the currently active session
--- @return GhostSession|nil The active session or nil
function M.get_active_session()
  return session.get_active_session()
end

--- Get a session by ID
--- @param session_id string Session ID
--- @return GhostSession|nil The session or nil if not found
function M.get_session(session_id)
  return session.get_session(session_id)
end

--- Switch to a different session
--- @param session_id string Session ID to switch to
--- @return boolean success True if switched successfully
--- @return string|nil error Error message if switch failed
function M.switch_session(session_id)
  return session.switch_session(session_id)
end

--- List all sessions
--- @return GhostSession[] Array of sessions
function M.list_sessions()
  return session.list_sessions()
end

--- Delete a session
--- @param session_id string Session ID to delete
--- @return boolean success True if deleted successfully
--- @return string|nil error Error message if deletion failed
function M.delete_session(session_id)
  return session.delete_session(session_id)
end

--- Rename a session
--- @param session_id string Session ID to rename
--- @param new_name string New display name
--- @return boolean success True if renamed successfully
--- @return string|nil error Error message if rename failed
function M.rename_session(session_id, new_name)
  return session.rename_session(session_id, new_name)
end

--- Get session count
--- @return number Count of sessions
function M.get_session_count()
  return session.count()
end

return M
