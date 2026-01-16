--- Ghost session persistence module
--- Handles saving and loading sessions to/from disk
--- @module ghost.persist

local M = {}

--- Get the base directory for all Ghost data
--- @return string Base directory path
function M.get_base_dir()
  local data_home = vim.fn.stdpath("data")
  return data_home .. "/ghost"
end

--- Sanitize a path for use as a directory name
--- Replaces / with _ and removes other filesystem-unsafe characters
--- @param path string The path to sanitize
--- @return string Sanitized path suitable for use as directory name
local function sanitize_path(path)
  -- Remove leading slash to avoid leading underscore
  local sanitized = path:gsub("^/", "")
  -- Replace remaining slashes with underscores
  sanitized = sanitized:gsub("/", "_")
  -- Remove or replace other potentially problematic characters
  sanitized = sanitized:gsub("[<>:\"|?*\\]", "_")
  -- Collapse multiple underscores
  sanitized = sanitized:gsub("_+", "_")
  -- Remove trailing underscore
  sanitized = sanitized:gsub("_$", "")
  return sanitized
end

--- Try to get git project root
--- @return string|nil Project root directory, or nil if not in a git repo
local function try_git_root()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not handle then
    return nil
  end

  local result = handle:read("*a")
  handle:close()

  if result and result ~= "" then
    -- Remove trailing newline
    result = result:gsub("%s+$", "")
    return result
  end

  return nil
end

--- Get the current project root
--- First tries git, then falls back to current working directory
--- @return string Project root directory (git root or cwd)
--- @return boolean is_git True if this is a git repository
function M.get_project_root()
  local git_root = try_git_root()
  if git_root then
    return git_root, true
  end

  -- Fallback to current working directory
  return vim.fn.getcwd(), false
end

--- Get the project name/key for storage
--- For git repos: uses the last component of the git root path
--- For non-git: uses the full sanitized cwd path
--- @param project_root string The project root directory path
--- @param is_git boolean Whether this is a git repository
--- @return string Project key for storage
local function get_project_key(project_root, is_git)
  if is_git then
    -- For git repos, use just the directory name (backwards compatible)
    return project_root:match("([^/]+)$") or "unknown"
  else
    -- For non-git, use full sanitized path to avoid collisions
    return sanitize_path(project_root)
  end
end

--- Get the sessions directory for the current project
--- @return string Sessions directory path
function M.get_sessions_dir()
  local project_root, is_git = M.get_project_root()
  local project_key = get_project_key(project_root, is_git)
  local base_dir = M.get_base_dir()
  return base_dir .. "/projects/" .. project_key .. "/sessions"
end

--- Get the directory path for a specific session
--- @param timestamp number Unix timestamp for the session
--- @return string Session directory path
function M.get_session_dir(timestamp)
  local sessions_dir = M.get_sessions_dir()
  return sessions_dir .. "/" .. timestamp
end

--- Ensure a directory exists, creating it if necessary
--- @param dir_path string Directory path to create
--- @return boolean success True if directory exists or was created
--- @return string|nil error Error message if creation failed
local function ensure_dir(dir_path)
  local stat = vim.loop.fs_stat(dir_path)
  if stat and stat.type == "directory" then
    return true, nil
  end

  -- Create directory recursively
  local ok = vim.fn.mkdir(dir_path, "p")
  if ok == 0 then
    return false, "Failed to create directory: " .. dir_path
  end

  return true, nil
end

--- Save session metadata to disk
--- @param session GhostSession The session to save
--- @return boolean success True if saved successfully
--- @return string|nil error Error message if save failed
function M.save_session_meta(session)
  local session_dir = M.get_session_dir(session.created_at)

  -- Ensure session directory exists
  local ok, dir_err = ensure_dir(session_dir)
  if not ok then
    return false, dir_err
  end

  -- Prepare metadata
  local meta = {
    id = session.id,
    created_at = session.created_at,
    display_name = session.display_name,
    status = session.status,
  }

  -- Write meta.json
  local meta_path = session_dir .. "/meta.json"
  local json = vim.fn.json_encode(meta)
  local file = io.open(meta_path, "w")
  if not file then
    return false, "Failed to open file for writing: " .. meta_path
  end

  file:write(json)
  file:close()

  -- Create empty transcript.md if it doesn't exist
  local transcript_path = session_dir .. "/transcript.md"
  local transcript_stat = vim.loop.fs_stat(transcript_path)
  if not transcript_stat then
    local transcript_file = io.open(transcript_path, "w")
    if transcript_file then
      transcript_file:write("# Session: " .. session.display_name .. "\n")
      transcript_file:write("Created: " .. os.date("%Y-%m-%d %H:%M:%S", session.created_at) .. "\n\n")
      transcript_file:close()
    end
  end

  return true, nil
end

--- Load session metadata from disk
--- @param timestamp number Unix timestamp for the session
--- @return table|nil meta The session metadata, or nil if not found
--- @return string|nil error Error message if load failed
function M.load_session_meta(timestamp)
  local session_dir = M.get_session_dir(timestamp)
  local meta_path = session_dir .. "/meta.json"
  local file = io.open(meta_path, "r")
  if not file then
    return nil, "File not found: " .. meta_path
  end

  local content = file:read("*a")
  file:close()

  if not content or content == "" then
    return nil, "Empty metadata file: " .. meta_path
  end

  local ok, meta = pcall(vim.fn.json_decode, content)
  if not ok then
    return nil, "Failed to parse JSON: " .. meta_path
  end

  return meta, nil
end

--- List all session timestamps for the current project
--- @return number[] timestamps Array of session timestamps (empty if none)
function M.list_session_timestamps()
  local sessions_dir = M.get_sessions_dir()

  -- Check if sessions directory exists
  local stat = vim.loop.fs_stat(sessions_dir)
  if not stat or stat.type ~= "directory" then
    -- No sessions yet, return empty list
    return {}, nil
  end

  -- Read directory contents
  local handle = vim.loop.fs_scandir(sessions_dir)
  if not handle then
    return nil, "Failed to scan directory: " .. sessions_dir
  end

  local timestamps = {}
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    -- Only include directories with numeric names (timestamps)
    if type == "directory" then
      local timestamp = tonumber(name)
      if timestamp then
        table.insert(timestamps, timestamp)
      end
    end
  end

  -- Sort timestamps (newest first)
  table.sort(timestamps, function(a, b)
    return a > b
  end)

  return timestamps
end

--- Load all sessions for the current project
--- @return GhostSession[] sessions Array of sessions (empty if none)
function M.load_all_sessions()
  local timestamps = M.list_session_timestamps()
  local sessions = {}
  for _, timestamp in ipairs(timestamps) do
    local meta, load_err = M.load_session_meta(timestamp)
    if meta then
      -- Reconstruct session object
      local session = {
        id = meta.id,
        created_at = meta.created_at,
        display_name = meta.display_name,
        status = meta.status or "disconnected",
        acp_job_id = nil,
        acp_initialized = false,
        acp_session_id = nil,
      }
      table.insert(sessions, session)
    else
      -- Log warning but continue loading other sessions
      vim.notify(
        "Ghost: Failed to load session " .. timestamp .. ": " .. (load_err or "unknown error"),
        vim.log.levels.WARN
      )
    end
  end

  return sessions
end

--- Delete a session from disk
--- @param timestamp number Unix timestamp for the session
--- @return boolean success True if deleted successfully
--- @return string|nil error Error message if deletion failed
function M.delete_session(timestamp)
  local session_dir = M.get_session_dir(timestamp)

  -- Check if directory exists
  local stat = vim.loop.fs_stat(session_dir)
  if not stat then
    return false, "Session directory not found: " .. session_dir
  end

  -- Delete directory and contents recursively
  local ok = vim.fn.delete(session_dir, "rf")
  if ok ~= 0 then
    return false, "Failed to delete session directory: " .. session_dir
  end

  return true, nil
end

--- Get the transcript file path for a session
--- @param timestamp number Unix timestamp for the session
--- @return string transcript_path The transcript file path
function M.get_transcript_path(timestamp)
  local session_dir = M.get_session_dir(timestamp)
  return session_dir .. "/transcript.md"
end

return M
