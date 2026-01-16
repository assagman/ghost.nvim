--- Ghost session management module
--- Manages multiple Ghost sessions, each with its own ACP subprocess
--- @module ghost.session

local M = {}
local persist = require("ghost.persist")
local acp_manager = require("ghost.acp_manager")
local transcript = nil -- Lazy load to avoid circular dependency

--- @class GhostSession
--- @field id string Unique session identifier
--- @field created_at number Unix timestamp when session was created
--- @field display_name string Human-readable session name
--- @field acp_job_id number|nil Job ID for the ACP subprocess
--- @field acp_initialized boolean Whether ACP is initialized for this session
--- @field acp_session_id string|nil ACP session ID from initialize
--- @field status "active"|"disconnected"|"error" Session status

--- Session counter for generating unique IDs
local session_counter = 0

--- Active sessions map (session_id -> GhostSession)
--- @type table<string, GhostSession>
M.sessions = {}

--- Currently active session ID
--- @type string|nil
M.active_session_id = nil

--- Generate a unique session ID
--- @return string Session ID
local function generate_session_id()
  session_counter = session_counter + 1
  local timestamp = os.time()
  return string.format("ghost-session-%d-%d", timestamp, session_counter)
end

--- Generate a display name for a session
--- @param timestamp number Unix timestamp
--- @return string Display name
local function generate_display_name(timestamp)
  return os.date("Session %H:%M:%S", timestamp)
end

--- Create a new Ghost session with its own ACP subprocess
--- @param opts table|nil Optional session creation options
--- @return string|nil session_id The new session ID, or nil on error
--- @return string|nil error Error message if creation failed
function M.create_session(opts)
  opts = opts or {}

  local session_id = generate_session_id()
  local timestamp = os.time()

  --- @type GhostSession
  local session = {
    id = session_id,
    created_at = timestamp,
    display_name = opts.display_name or generate_display_name(timestamp),
    acp_job_id = nil,
    acp_initialized = false,
    acp_session_id = nil,
    status = "active",
  }

  -- Store the session in memory
  M.sessions[session_id] = session

  -- Set as active session
  M.active_session_id = session_id

  -- Persist session to disk
  local ok, err = persist.save_session_meta(session)
  if not ok then
    vim.notify("Ghost: Failed to persist session - " .. (err or "unknown error"), vim.log.levels.WARN)
    -- Continue anyway - session will work in-memory
  end

  -- Create an ACP instance for this session (US-009)
  -- Each session gets its own ACP subprocess for concurrent streaming
  local acp_instance = acp_manager.create_instance(session_id, {
    on_notification = function(notification)
      -- Forward notifications with session context
      -- The global notification handler will route to correct receiver
      local receiver = require("ghost.receiver")
      if notification.method == "session/update" and notification.params then
        receiver.handle_update(notification.params)
      end
    end,
    on_connect = function()
      local s = M.sessions[session_id]
      if s then
        s.status = "active"
        s.acp_initialized = true
      end
    end,
    on_disconnect = function()
      local s = M.sessions[session_id]
      if s then
        s.status = "disconnected"
        s.acp_initialized = false
      end
    end,
    on_error = function(_error_msg)
      local s = M.sessions[session_id]
      if s then
        s.status = "error"
      end
    end,
  })

  -- Store the ACP instance
  acp_manager.set_instance(session_id, acp_instance)

  -- Initialize the ACP subprocess lazily (starts on first prompt send)
  -- This matches the current behavior

  return session_id, nil
end

--- Get the currently active session
--- @return GhostSession|nil The active session or nil
function M.get_active_session()
  if not M.active_session_id then
    return nil
  end
  return M.sessions[M.active_session_id]
end

--- Get a session by ID
--- @param session_id string Session ID
--- @return GhostSession|nil The session or nil if not found
function M.get_session(session_id)
  return M.sessions[session_id]
end

--- Switch to a different session
--- @param session_id string Session ID to switch to
--- @return boolean success True if switched successfully
--- @return string|nil error Error message if switch failed
function M.switch_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    return false, "Session not found: " .. session_id
  end

  M.active_session_id = session_id
  return true, nil
end

--- List all sessions
--- @return GhostSession[] Array of sessions
function M.list_sessions()
  local sessions = {}
  for _, session in pairs(M.sessions) do
    table.insert(sessions, session)
  end

  -- Sort by creation time (newest first)
  table.sort(sessions, function(a, b)
    return a.created_at > b.created_at
  end)

  return sessions
end

--- Delete a session
--- @param session_id string Session ID to delete
--- @return boolean success True if deleted successfully
--- @return string|nil error Error message if deletion failed
function M.delete_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    return false, "Session not found: " .. session_id
  end

  -- Stop and remove the ACP instance for this session (US-009)
  acp_manager.remove_instance(session_id)

  -- Clean up transcript buffers (US-003)
  if not transcript then
    transcript = require("ghost.transcript")
  end
  transcript.cleanup_session(session_id)

  -- Delete from disk first
  local ok, err = persist.delete_session(session.created_at)
  if not ok then
    vim.notify("Ghost: Failed to delete session from disk - " .. (err or "unknown error"), vim.log.levels.WARN)
    -- Continue anyway - we'll still remove from memory
  end

  -- Remove from memory
  M.sessions[session_id] = nil

  -- If this was the active session, clear active_session_id
  if M.active_session_id == session_id then
    M.active_session_id = nil
  end

  return true, nil
end

--- Rename a session
--- @param session_id string Session ID to rename
--- @param new_name string New display name
--- @return boolean success True if renamed successfully
--- @return string|nil error Error message if rename failed
function M.rename_session(session_id, new_name)
  local session = M.sessions[session_id]
  if not session then
    return false, "Session not found: " .. session_id
  end

  -- Update display name in memory
  session.display_name = new_name

  -- Persist to disk
  local ok, err = persist.save_session_meta(session)
  if not ok then
    vim.notify("Ghost: Failed to persist rename - " .. (err or "unknown error"), vim.log.levels.WARN)
    -- Continue anyway - name is updated in memory
  end

  return true, nil
end

--- Update session status
--- @param session_id string Session ID
--- @param status "active"|"disconnected"|"error" New status
function M.update_status(session_id, status)
  local session = M.sessions[session_id]
  if session then
    session.status = status
  end
end

--- Get the ACP instance for a session
--- @param session_id string Session ID
--- @return table|nil instance The ACP instance or nil if not found
function M.get_acp_instance(session_id)
  return acp_manager.get_instance(session_id)
end

--- Get session count
--- @return number Count of sessions
function M.count()
  local count = 0
  for _ in pairs(M.sessions) do
    count = count + 1
  end
  return count
end

--- Clear all sessions (for testing)
function M.clear_all()
  M.sessions = {}
  M.active_session_id = nil
  session_counter = 0
end

--- Load all persisted sessions from disk
--- @return boolean success True if loaded successfully
--- @return string|nil error Error message if loading failed
function M.load_sessions()
  local sessions, err = persist.load_all_sessions()
  if not sessions then
    -- If not in a git repo, that's okay - just skip loading
    if err and err:match("Not in a git repository") then
      return true, nil
    end
    return false, err
  end

  -- Load sessions into memory
  for _, session in ipairs(sessions) do
    M.sessions[session.id] = session
  end

  return true, nil
end

--- Initialize session management (called during plugin setup)
--- Loads persisted sessions from disk
function M.init()
  local ok, err = M.load_sessions()
  if not ok then
    vim.notify("Ghost: Failed to load sessions - " .. (err or "unknown error"), vim.log.levels.WARN)
  end
end

return M
