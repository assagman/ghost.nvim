--- Ghost transcript module
--- Handles writing full conversation transcripts to disk per session
--- Implements batched writes to reduce IO during streaming
--- @module ghost.transcript

local M = {}

local persist = require("ghost.persist")
local session = require("ghost.session")

-- Batching constants (not exposed to user config)
local FLUSH_THRESHOLD_BYTES = 4096 -- Flush when buffer exceeds this size
local FLUSH_INTERVAL_MS = 250 -- Max time between flushes during streaming

--- @class TranscriptEntry
--- @field timestamp number Unix timestamp
--- @field type "prompt"|"response"|"tool_call"|"tool_update"|"status"|"error"
--- @field content string The content
--- @field session_id string The session ID this entry belongs to
--- @field tool_name string|nil Tool name for tool_call entries
--- @field tool_status string|nil Tool status for tool_call entries

--- @class ResponseBuffer
--- @field chunks string[] Table of text chunks (avoids repeated string concat)
--- @field bytes number Total bytes in chunks
--- @field last_flush_time number Timestamp of last flush (ms, from vim.loop.now())

--- Buffer to accumulate streaming response text before writing
--- @type table<string, ResponseBuffer> Map of session_id -> buffer state
local response_buffers = {}

--- Format timestamp for transcript
--- @param timestamp number Unix timestamp
--- @return string Formatted timestamp
local function format_timestamp(timestamp)
  return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

--- Append a line to the transcript file
--- @param session_id string The session ID
--- @param line string The line to append
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
local function append_to_transcript(session_id, line)
  local sess = session.get_session(session_id)
  if not sess then
    return false, "Session not found: " .. session_id
  end

  local transcript_path, err = persist.get_transcript_path(sess.created_at)
  if not transcript_path then
    return false, err
  end

  -- Append to file
  local file = io.open(transcript_path, "a")
  if not file then
    return false, "Failed to open transcript for writing: " .. transcript_path
  end

  file:write(line)
  file:close()

  return true, nil
end

--- Write a prompt to the transcript
--- @param session_id string The session ID
--- @param prompt string The prompt text
--- @param request_id string|nil The request ID (optional)
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
function M.write_prompt(session_id, prompt, request_id)
  local timestamp = os.time()
  local lines = {
    "\n---\n\n",
    "### Prompt (" .. format_timestamp(timestamp) .. ")\n\n",
  }

  if request_id then
    table.insert(lines, "*Request ID: " .. request_id .. "*\n\n")
  end

  table.insert(lines, prompt .. "\n")

  local content = table.concat(lines, "")
  return append_to_transcript(session_id, content)
end

--- Start a response section in the transcript
--- @param session_id string The session ID
--- @param request_id string|nil The request ID (optional)
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
function M.start_response(session_id, request_id)
  local timestamp = os.time()
  local lines = {
    "\n### Response (" .. format_timestamp(timestamp) .. ")\n\n",
  }

  if request_id then
    table.insert(lines, "*Request ID: " .. request_id .. "*\n\n")
  end

  local content = table.concat(lines, "")

  -- Initialize response buffer for this session (table-based for efficiency)
  response_buffers[session_id] = {
    chunks = {},
    bytes = 0,
    last_flush_time = vim.loop.now(),
  }

  return append_to_transcript(session_id, content)
end

--- Append streaming text to the response buffer
--- Does not write to disk - use flush or maybe_flush to persist
--- @param session_id string The session ID
--- @param text string The text chunk to append
function M.append_response_text(session_id, text)
  if not text or text == "" then
    return
  end

  local buf = response_buffers[session_id]
  if not buf then
    -- Initialize buffer if not already done (defensive)
    buf = {
      chunks = {},
      bytes = 0,
      last_flush_time = vim.loop.now(),
    }
    response_buffers[session_id] = buf
  end

  table.insert(buf.chunks, text)
  buf.bytes = buf.bytes + #text
end

--- Flush the response buffer to disk (unconditional - called on completion or before tool calls)
--- @param session_id string The session ID
--- @return boolean success True if flushed successfully
--- @return string|nil error Error message if flush failed
function M.flush_response_buffer(session_id)
  local buf = response_buffers[session_id]
  if not buf or buf.bytes == 0 then
    return true, nil -- Nothing to flush
  end

  -- Combine chunks efficiently
  local content = table.concat(buf.chunks)

  local ok, err = append_to_transcript(session_id, content)
  if ok then
    -- Clear buffer after successful write
    buf.chunks = {}
    buf.bytes = 0
    buf.last_flush_time = vim.loop.now()
  end
  return ok, err
end

--- Conditionally flush the response buffer based on size/time thresholds
--- Called during streaming to batch writes without blocking UI
--- @param session_id string The session ID
--- @return boolean success True if no flush needed or flush succeeded
--- @return string|nil error Error message if flush failed
function M.maybe_flush_response_buffer(session_id)
  local buf = response_buffers[session_id]
  if not buf or buf.bytes == 0 then
    return true, nil -- Nothing to flush
  end

  local now = vim.loop.now()
  local time_since_flush = now - buf.last_flush_time

  -- Flush if buffer exceeds threshold OR enough time has passed
  if buf.bytes >= FLUSH_THRESHOLD_BYTES or time_since_flush >= FLUSH_INTERVAL_MS then
    return M.flush_response_buffer(session_id)
  end

  return true, nil -- No flush needed yet
end

--- Write a tool call to the transcript
--- @param session_id string The session ID
--- @param tool_name string The tool name
--- @param tool_id string The tool call ID
--- @param status string The tool status (pending, in_progress, completed, failed)
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
function M.write_tool_call(session_id, tool_name, tool_id, status)
  local status_icon = ({
    pending = "⏳",
    in_progress = "🔄",
    completed = "✅",
    failed = "❌",
  })[status] or "❓"

  local line = string.format("\n%s **Tool Call**: %s (ID: %s) - %s\n", status_icon, tool_name, tool_id, status)

  -- Flush any pending response text before writing tool call
  M.flush_response_buffer(session_id)

  return append_to_transcript(session_id, line)
end

--- Write an error to the transcript
--- @param session_id string The session ID
--- @param error_message string The error message
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
function M.write_error(session_id, error_message)
  local timestamp = os.time()
  local line = string.format(
    "\n❌ **Error** (%s): %s\n\n",
    format_timestamp(timestamp),
    error_message
  )

  -- Flush any pending response text before writing error
  M.flush_response_buffer(session_id)

  return append_to_transcript(session_id, line)
end

--- Write a status message to the transcript
--- @param session_id string The session ID
--- @param status_message string The status message
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
function M.write_status(session_id, status_message)
  local line = string.format("\n*Status*: %s\n", status_message)

  -- Flush any pending response text before writing status
  M.flush_response_buffer(session_id)

  return append_to_transcript(session_id, line)
end

--- Complete a response section (flushes buffer and adds completion marker)
--- @param session_id string The session ID
--- @return boolean success True if written successfully
--- @return string|nil error Error message if write failed
function M.complete_response(session_id)
  -- Flush any remaining text in the buffer
  local ok, err = M.flush_response_buffer(session_id)
  if not ok then
    return false, err
  end

  -- Add completion marker
  local line = "\n\n*Response complete*\n"
  return append_to_transcript(session_id, line)
end

--- Clean up buffers for a session (e.g., when session is deleted)
--- @param session_id string The session ID
--- @param flush boolean|nil Whether to flush before cleanup (default true for data safety)
function M.cleanup_session(session_id, flush)
  -- Default to flushing to avoid accidental data loss
  if flush == nil then
    flush = true
  end
  if flush then
    M.flush_response_buffer(session_id)
  end
  response_buffers[session_id] = nil
end

--- Get the transcript content for a session (for reading)
--- @param session_id string The session ID
--- @return string|nil content The transcript content, or nil if error
--- @return string|nil error Error message if read failed
function M.read_transcript(session_id)
  local sess = session.get_session(session_id)
  if not sess then
    return nil, "Session not found: " .. session_id
  end

  local transcript_path, err = persist.get_transcript_path(sess.created_at)
  if not transcript_path then
    return nil, err
  end

  local file = io.open(transcript_path, "r")
  if not file then
    return nil, "Failed to open transcript for reading: " .. transcript_path
  end

  local content = file:read("*a")
  file:close()

  return content, nil
end

return M
