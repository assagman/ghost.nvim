--- Ghost receiver module - Receive and parse ACP session/update notifications
--- Handles streaming responses from the ACP protocol
--- Agent handles file edits directly - we just display text responses
--- @module ghost.receiver

local M = {}

local sender = require("ghost.sender")
local session = require("ghost.session")
local transcript = require("ghost.transcript")

--- @class GhostExplanationResponse
--- @field type "explanation" Response type
--- @field request_id string|nil Original request ID
--- @field text string The explanation text

--- @class GhostTextChunk
--- @field type "text_chunk" Response type for streaming text
--- @field request_id string|nil Original request ID
--- @field text string The text chunk

--- @alias GhostResponse GhostExplanationResponse | GhostTextChunk

--- @class GhostReceiverState
--- @field accumulated_text string Accumulated text from streaming chunks
--- @field current_request_id string|nil Current request ID being processed
--- @field on_response fun(response: GhostResponse)|nil Callback for complete responses
--- @field on_update fun(update: table)|nil Callback for streaming updates
--- @field on_error fun(err: string)|nil Callback for parse errors
local state = {
  accumulated_text = "",
  current_request_id = nil,
  on_response = nil,
  on_update = nil,
  on_error = nil,
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

--- Process a text content item from ACP
--- @param content table The content item
--- @param request_id string|nil The request ID
--- @param ghost_session_id string|nil The ghost session ID from the update
local function process_text_content(content, request_id, ghost_session_id)
  if content.text then
    state.accumulated_text = state.accumulated_text .. content.text

    -- Write to transcript for the correct session (US-009)
    -- Use ghost_session_id from update params, fallback to active session
    local target_session_id = ghost_session_id
    if not target_session_id then
      local active_session = session.get_active_session()
      if active_session then
        target_session_id = active_session.id
      end
    end

    if target_session_id then
      transcript.append_response_text(target_session_id, content.text)
      -- Periodically flush transcript buffer to disk (every ~1KB)
      -- This ensures streaming updates are persisted without waiting for completion
      transcript.flush_response_buffer(target_session_id)
    end

    -- Emit text chunk for streaming display
    if state.on_update then
      state.on_update({
        type = "text_chunk",
        request_id = request_id,
        text = content.text,
        ghost_session_id = ghost_session_id,
      })
    end
  end
end

--- Process an ACP session/update notification
--- @param update table The update notification params
--- @param request_id string|nil The request ID
local function process_session_update(update, request_id)
  state.current_request_id = request_id

  -- Extract ghost_session_id from update (US-009)
  local ghost_session_id = update.__ghost_session_id

  -- Get the inner update object (ACP format: params.update.sessionUpdate)
  local inner = update.update or update
  local update_type = inner.sessionUpdate

  -- Handle message_delta (streaming text)
  if update_type == "message_delta" or update_type == "message" then
    local content = inner.content
    if content and type(content) == "table" then
      for _, item in ipairs(content) do
        if item.type == "text" then
          process_text_content(item, request_id, ghost_session_id)
        end
      end
    end
    return
  end

  -- Handle agent_message_chunk (OpenCode's streaming message text)
  if update_type == "agent_message_chunk" then
    local chunk_text = nil

    if inner.content and type(inner.content) == "table" then
      if inner.content[1] then
        for _, item in ipairs(inner.content) do
          if type(item) == "table" then
            if item.type == "text" and item.text then
              chunk_text = (chunk_text or "") .. item.text
            elseif item.text then
              chunk_text = (chunk_text or "") .. item.text
            elseif item.content and type(item.content) == "string" then
              chunk_text = (chunk_text or "") .. item.content
            end
          elseif type(item) == "string" then
            chunk_text = (chunk_text or "") .. item
          end
        end
      else
        chunk_text = inner.content.text or inner.content.content or inner.content.chunk
      end
    end

    if not chunk_text then
      chunk_text = inner.chunk or inner.text or inner.delta
    end

    if chunk_text and type(chunk_text) == "string" and #chunk_text > 0 then
      process_text_content({ text = chunk_text }, request_id, ghost_session_id)
    end
    return
  end

  -- Handle agent_thought_chunk (OpenCode's streaming thought/reasoning)
  if update_type == "agent_thought_chunk" then
    local chunk_text = inner.chunk or inner.text or inner.delta

    -- Handle content as single object: { type: "text", text: "..." }
    if not chunk_text and inner.content and type(inner.content) == "table" then
      if inner.content.type == "text" and inner.content.text then
        -- Single content object (ACP format)
        chunk_text = inner.content.text
      elseif inner.content[1] then
        -- Array of content items (fallback)
        for _, item in ipairs(inner.content) do
          if item.type == "text" and item.text then
            chunk_text = item.text
            break
          end
        end
      end
    end

    if chunk_text and type(chunk_text) == "string" and #chunk_text > 0 then
      process_text_content({ text = chunk_text }, request_id, ghost_session_id)
    end
    return
  end

  -- Handle agent_thought / agent_message (complete versions)
  if update_type == "agent_thought" or update_type == "agent_message" then
    local text = inner.thought or inner.message or inner.text or inner.content
    if text and type(text) == "string" then
      process_text_content({ text = text }, request_id, ghost_session_id)
    end
    return
  end

  -- Handle tool_call (notify about tool usage for status display)
  if update_type == "tool_call" then
    local tool_id = inner.toolCallId or ""
    local tool_name = inner.title or "unknown"
    local tool_status = inner.status or "pending"

    -- Write tool call to transcript for the correct session (US-009)
    local target_session_id = ghost_session_id
    if not target_session_id then
      local active_session = session.get_active_session()
      if active_session then
        target_session_id = active_session.id
      end
    end

    if target_session_id then
      transcript.write_tool_call(target_session_id, tool_name, tool_id, tool_status)
    end

    if state.on_update then
      state.on_update({
        type = "tool_call",
        request_id = request_id,
        tool_name = tool_name,
        tool_id = tool_id,
        status = tool_status,
        ghost_session_id = ghost_session_id,
      })
    end
    return
  end

  -- Handle tool_call_update (tool progress/completion)
  if update_type == "tool_call_update" then
    local tool_id = inner.toolCallId or ""
    local tool_status = inner.status
    local tool_name = inner.title

    -- Write tool call update to transcript for the correct session (US-009)
    local target_session_id = ghost_session_id
    if not target_session_id then
      local active_session = session.get_active_session()
      if active_session then
        target_session_id = active_session.id
      end
    end

    if target_session_id and tool_name and tool_status then
      transcript.write_tool_call(target_session_id, tool_name, tool_id, tool_status)
    end

    if state.on_update then
      state.on_update({
        type = "tool_call_update",
        request_id = request_id,
        tool_id = tool_id,
        status = tool_status,
        tool_name = tool_name,
        ghost_session_id = ghost_session_id,
      })
    end
    return
  end

  -- Fallback: Try to extract text from unknown update types
  if update_type then
    local text = inner.text or inner.chunk or inner.content
    if text and type(text) == "string" and #text > 0 then
      process_text_content({ text = text }, request_id, ghost_session_id)
    end
  end
end

--- Process the completion of a prompt
--- @param result table The final result
--- @param request_id string|nil The request ID
--- @param ghost_session_id string|nil The ghost session ID
local function process_completion(result, request_id, ghost_session_id)
  -- Flush any remaining transcript buffer for the correct session (US-009)
  local target_session_id = ghost_session_id
  if not target_session_id then
    local active_session = session.get_active_session()
    if active_session then
      target_session_id = active_session.id
    end
  end

  if target_session_id then
    transcript.flush_response_buffer(target_session_id)
  end

  -- Emit completion as an explanation (even if empty)
  --- @type GhostExplanationResponse
  local response = {
    type = "explanation",
    request_id = request_id,
    text = state.accumulated_text,
    ghost_session_id = ghost_session_id,
  }

  if state.on_response then
    pcall(state.on_response, response)
  end

  -- Reset state
  state.accumulated_text = ""
  state.current_request_id = nil

  -- Remove from active requests
  if request_id then
    pcall(sender.remove_request, request_id)
  end
end

--- Handle an ACP update notification
--- @param update table The update params from session/update notification
function M.handle_update(update)
  local ok, err = pcall(function()
    local request_id = (type(update) == "table" and update.__ghost_request_id)
      or update.sessionId
      or state.current_request_id
    process_session_update(update, request_id)
  end)

  if not ok then
    notify("Ghost: Error handling update - " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Handle prompt completion
--- @param result table The final result
--- @param request_id string|nil The Ghost request ID (optional)
--- @param ghost_session_id string|nil The Ghost session ID (optional)
function M.handle_complete(result, request_id, ghost_session_id)
  local ok, err = pcall(function()
    local id = request_id or state.current_request_id
    -- Extract ghost_session_id from result if present
    local session_id = ghost_session_id
    if not session_id and type(result) == "table" then
      session_id = result.__ghost_session_id
    end
    process_completion(result, id, session_id)
  end)

  if not ok then
    notify("Ghost: Error handling completion - " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Set the response handler callback
--- @param callback fun(response: GhostResponse)|nil Callback for responses
function M.set_on_response(callback)
  state.on_response = callback
end

--- Set the update handler callback
--- @param callback fun(update: table)|nil Callback for updates
function M.set_on_update(callback)
  state.on_update = callback
end

--- Set the error handler callback
--- @param callback fun(err: string)|nil Callback for errors
function M.set_on_error(callback)
  state.on_error = callback
end

--- Clear accumulated state
function M.clear()
  state.accumulated_text = ""
  state.current_request_id = nil
end

--- Get current accumulated text (for debugging)
--- @return string Accumulated text
function M.get_accumulated_text()
  return state.accumulated_text
end

--- Check if there is pending data being accumulated
--- @return boolean True if accumulating data
function M.has_pending_data()
  return state.accumulated_text ~= ""
end

--- Get response info for a given response (for debugging/display)
--- @param response GhostResponse The response
--- @return string Summary string
function M.response_summary(response)
  if response.type == "explanation" then
    return string.format("Explanation: %d chars", #(response.text or ""))
  elseif response.type == "text_chunk" then
    return string.format("Text chunk: %d chars", #(response.text or ""))
  elseif response.type == "tool_call" then
    return string.format("Tool: %s (%s)", response.tool_name or "unknown", response.status or "unknown")
  else
    return "Unknown response type"
  end
end

return M
