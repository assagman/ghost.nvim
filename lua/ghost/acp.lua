--- Ghost ACP module - Client connection to OpenCode via ACP (Agent Client Protocol)
--- Uses stdio transport with JSON-RPC 2.0 messages (spawns opencode acp subprocess)
--- @module ghost.acp

local M = {}

local config = require("ghost.config")

--- Get the current backend name
--- @return "opencode"|"codex" The current backend
local function current_backend()
  local backend = config.options and config.options.backend
  if backend == "codex" then
    return "codex"
  end
  return "opencode"
end

--- Public getter for the current backend
--- @return "opencode"|"codex" The current backend
function M.get_backend()
  return current_backend()
end

local function is_nvim_exiting()
  if vim.g.ghost_exiting then
    return true
  end

  local ok, exiting = pcall(vim.api.nvim_get_vvar, "exiting")
  if ok and type(exiting) == "number" and exiting ~= 0 then
    return true
  end

  local ok2, dying = pcall(vim.api.nvim_get_vvar, "dying")
  if ok2 and type(dying) == "number" and dying ~= 0 then
    return true
  end

  return false
end

local function build_subprocess_command()
  local backend = current_backend()

  if backend == "codex" then
    return "bunx", { "-y", "@zed-industries/codex-acp" }
  end

  local acp_cmd = (config.options and config.options.acp_command) or "opencode"

  -- Support table format for custom commands (bypasses "acp" argument)
  if type(acp_cmd) == "table" then
    local cmd = acp_cmd[1]
    local args = {}
    for i = 2, #acp_cmd do
      table.insert(args, acp_cmd[i])
    end
    return cmd, args
  end

  -- String format: append "acp" argument
  return acp_cmd, { "acp" }
end

--- ACP Protocol version (numeric as required by OpenCode)
local PROTOCOL_VERSION = 1

-- Bounded automatic retries for startup/crash failures.
local MAX_START_RETRIES = 3
local RETRY_BASE_DELAY_MS = 200

--- Client information
local CLIENT_INFO = {
  name = "ghost.nvim",
  version = "0.1.0",
}

--- @class GhostACPState
--- @field job_id number|nil The job ID for the subprocess
--- @field initialized boolean Whether we have completed initialization
--- @field session_id string|nil Current session ID
--- @field agent_info table|nil Agent information from initialize response
--- @field agent_capabilities table|nil Agent capabilities from initialize response
--- @field request_id number Counter for JSON-RPC request IDs
--- @field pending_requests table<number, table> Map of request ID to callbacks
--- @field response_buffer string Buffer for incomplete responses
--- @field on_notification fun(notification: table)|nil Notification handler
--- @field on_error fun(err: string)|nil Error callback
--- @field on_connect fun()|nil Connect success callback
--- @field on_disconnect fun()|nil Disconnect callback
--- @field last_error string|nil Last error message for status display
--- @field last_error_time number|nil Unix timestamp of last error
local state = {
  job_id = nil,
  initialized = false,
  session_id = nil,
  agent_info = nil,
  agent_capabilities = nil,
  request_id = 0,
  pending_requests = {},
  response_buffer = "",
  on_notification = nil,
  on_error = nil,
  on_connect = nil,
  on_disconnect = nil,
  initializing = false,
  initialize_callbacks = {},
  stopping = false,
  last_error = nil,
  last_error_time = nil,
}

--- Generate a new JSON-RPC request ID
--- @return number Unique request ID
local function next_request_id()
  state.request_id = state.request_id + 1
  return state.request_id
end

local function retry_delay_ms(attempt)
  return RETRY_BASE_DELAY_MS * attempt * attempt
end

local function is_retryable_start_error(err)
  if type(err) ~= "string" then
    return false
  end

  local lower = err:lower()
  return lower:find("failed to start acp subprocess", 1, true) ~= nil
    or lower:find("not connected to acp", 1, true) ~= nil
    or lower:find("failed to send message", 1, true) ~= nil
    or lower:find("subprocess exited", 1, true) ~= nil
end

local function complete_initialize(err, capabilities)
  local callbacks = state.initialize_callbacks
  state.initialize_callbacks = {}
  state.initializing = false

  if err then
    state.last_error = err
    state.last_error_time = os.time()
    if state.on_error then
      state.on_error(err)
    end
  end

  for _, cb in ipairs(callbacks) do
    vim.schedule(function()
      cb(err, capabilities)
    end)
  end
end

--- Build a JSON-RPC 2.0 request
--- @param method string The method name
--- @param params table|nil The parameters
--- @return table request The JSON-RPC request object
--- @return number id The request ID
local function build_request(method, params)
  local id = next_request_id()
  local request = {
    jsonrpc = "2.0",
    id = id,
    method = method,
  }
  if params then
    request.params = params
  end
  return request, id
end

--- Build a JSON-RPC 2.0 notification (no response expected)
--- @param method string The method name
--- @param params table|nil The parameters
--- @return table notification The JSON-RPC notification object
local function build_notification(method, params)
  local notification = {
    jsonrpc = "2.0",
    method = method,
  }
  if params then
    notification.params = params
  end
  return notification
end

--- Build file reference notation for OpenCode
--- Uses @filepath :L# notation that OpenCode understands
--- @param file_path string The file path
--- @param selection_range table|nil The selection range
--- @return string The formatted file reference
local function build_file_reference(file_path, selection_range)
  if not file_path then
    return ""
  end

  -- Just file reference
  if not selection_range then
    return string.format("@%s", file_path)
  end

  local range = selection_range
  -- Line-wise or multi-line selection: @file :L14-L20
  if range.start_line == range.end_line then
    -- Single line with column range: @file :L14:C1-C14
    if range.mode == "v" and range.start_col and range.end_col then
      return string.format("@%s :L%d:C%d-C%d", file_path, range.start_line, range.start_col, range.end_col)
    end
    -- Single line: @file :L14
    return string.format("@%s :L%d", file_path, range.start_line)
  end

  -- Multi-line: @file :L14-L20
  return string.format("@%s :L%d-L%d", file_path, range.start_line, range.end_line)
end

--- Process a complete JSON-RPC message
--- @param message table The parsed JSON message
local function process_message(message)
  -- Check if it's a response (has id and result/error)
  if message.id then
    local callback = state.pending_requests[message.id]
    if callback then
      state.pending_requests[message.id] = nil
      if message.error then
        if callback.on_error then
          callback.on_error(message.error.message or "Unknown error")
        end
      else
        if callback.on_success then
          callback.on_success(message.result)
        end
      end
    end
  end

  -- Check if it's a notification (has method but no id)
  if message.method and not message.id then
    if state.on_notification then
      state.on_notification(message)
    end
  end
end

--- Handle stdout data from the subprocess
--- @param data string The data received
local function on_stdout(_, data)
  if not data then
    return
  end

  for _, line in ipairs(data) do
    if line and line ~= "" then
      state.response_buffer = state.response_buffer .. line

      -- Try to parse complete JSON objects
      -- OpenCode sends one JSON object per line
      local ok, message = pcall(vim.json.decode, state.response_buffer)
      if ok then
        state.response_buffer = ""
        vim.schedule(function()
          process_message(message)
        end)
      end
    end
  end
end

--- Handle stderr data from the subprocess
--- @param data string The error data received
local function on_stderr(_, _data)
  -- OpenCode writes logs to stderr, we ignore them
  -- Uncomment below for debugging:
  -- if data then
  --   for _, line in ipairs(data) do
  --     if line and line ~= "" then
  --       vim.schedule(function()
  --         vim.notify("Ghost stderr: " .. line:sub(1, 100), vim.log.levels.DEBUG)
  --       end)
  --     end
  --   end
  -- end
end

--- Handle subprocess exit
--- @param code number The exit code
local function on_exit(_, code)
  vim.schedule(function()
    local backend = current_backend()

    -- Capture pending requests before clearing state
    local pending = state.pending_requests
    local was_stopping = state.stopping

    local error_msg = code ~= 0 and ("ACP subprocess exited with code " .. code .. " (backend=" .. backend .. ")")
      or ("ACP subprocess exited (backend=" .. backend .. ")")

    -- Track error for status display (only for non-zero exits and not manual stop)
    if code ~= 0 and not was_stopping then
      state.last_error = error_msg
      state.last_error_time = os.time()
    end

    -- Clear state
    state.job_id = nil
    state.initialized = false
    state.session_id = nil
    state.agent_info = nil
    state.agent_capabilities = nil
    state.pending_requests = {}
    state.response_buffer = ""
    state.stopping = false

    -- Notify all pending requests of the error
    for _, callbacks in pairs(pending) do
      if callbacks.on_error then
        pcall(callbacks.on_error, error_msg)
      end
    end

    if state.on_disconnect then
      state.on_disconnect()
    end

    -- Manual disconnect/reconnect should not surface exit errors or trigger retries.
    if was_stopping then
      return
    end

    -- Never auto-retry while Neovim is exiting.
    if is_nvim_exiting() then
      return
    end

    -- Auto-retry startup/crash failures by reconnecting in the background.
    if code ~= 0 and not state.initializing then
      M.initialize(function() end)
    end
  end)
end

--- Start the opencode acp subprocess
--- @return boolean success True if started successfully
--- @return string|nil error Error message if failed
local function start_subprocess()
  if state.job_id then
    return true, nil -- Already running
  end

  local backend = current_backend()
  local cmd, args = build_subprocess_command()
  local argv = { cmd, unpack(args) }

  -- Add working directory if specified
  local cwd = (config.options and config.options.acp_cwd) or vim.fn.getcwd()

  state.job_id = vim.fn.jobstart(argv, {
    cwd = cwd,
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if state.job_id <= 0 then
    state.job_id = nil

    local cmdline = table.concat(argv, " ")
    local hint = backend == "codex" and ' (ensure "bunx" is available in $PATH)' or ""
    return false, string.format("Ghost: failed to start ACP subprocess (backend=%s): %s%s", backend, cmdline, hint)
  end

  return true, nil
end

--- Send a JSON-RPC message to the subprocess
--- @param message table The message to send
--- @param callbacks table|nil Callbacks: on_success, on_error
--- @return boolean success True if sent successfully
local function send_message(message, callbacks)
  if not state.job_id then
    if callbacks and callbacks.on_error then
      vim.schedule(function()
        callbacks.on_error("Not connected to ACP (backend=" .. current_backend() .. ")")
      end)
    end
    return false
  end

  -- Store callbacks for response handling
  if message.id and callbacks then
    state.pending_requests[message.id] = callbacks
  end

  -- Encode and send
  local json = vim.json.encode(message) .. "\n"
  local bytes_written = vim.fn.chansend(state.job_id, json)

  if bytes_written == 0 then
    if message.id then
      state.pending_requests[message.id] = nil
    end
    if callbacks and callbacks.on_error then
      vim.schedule(function()
        callbacks.on_error("Failed to send message to OpenCode ACP")
      end)
    end
    return false
  end

  return true
end

--- Initialize the ACP connection
--- Must be called before creating sessions
--- @param callback fun(err: string|nil, capabilities: table|nil) Callback with result
function M.initialize(callback)
  if is_nvim_exiting() then
    callback("Neovim is exiting", nil)
    return
  end

  if state.initialized then
    vim.schedule(function()
      callback(nil, state.agent_capabilities)
    end)
    return
  end

  if state.initializing then
    table.insert(state.initialize_callbacks, callback)
    return
  end

  state.initializing = true
  state.initialize_callbacks = { callback }

  local function attempt_initialize(attempt)
    -- Start subprocess if not running
    local ok, err = start_subprocess()
    if not ok then
      if attempt < MAX_START_RETRIES then
        vim.defer_fn(function()
          attempt_initialize(attempt + 1)
        end, retry_delay_ms(attempt))
      else
        complete_initialize(err, nil)
      end
      return
    end

    -- Small delay to let subprocess start
    vim.defer_fn(function()
      local request, _ = build_request("initialize", {
        protocolVersion = PROTOCOL_VERSION,
        clientInfo = CLIENT_INFO,
        capabilities = {
          -- Client capabilities we support
          -- Note: These tell OpenCode what WE can handle
          -- OpenCode will use its own tools for file operations
          -- and send us diffs/updates which we apply
          fs = {
            readTextFile = true, -- We can receive file content
            writeTextFile = true, -- We can apply file edits
          },
          terminal = false, -- We don't handle terminal operations
        },
      })

      send_message(request, {
        on_success = function(result)
          state.initialized = true
          state.agent_info = result.agentInfo
          state.agent_capabilities = result.agentCapabilities
          -- Clear last error on successful connection
          state.last_error = nil
          state.last_error_time = nil

          if state.on_connect then
            state.on_connect()
          end

          complete_initialize(nil, result.agentCapabilities)
        end,
        on_error = function(init_err)
          if is_retryable_start_error(init_err) and attempt < MAX_START_RETRIES then
            local job_id = state.job_id
            state.job_id = nil
            state.stopping = true

            if job_id then
              pcall(vim.fn.jobstop, job_id)
            end

            state.initialized = false
            state.session_id = nil
            state.agent_info = nil
            state.agent_capabilities = nil
            state.pending_requests = {}
            state.response_buffer = ""

            vim.defer_fn(function()
              attempt_initialize(attempt + 1)
            end, retry_delay_ms(attempt))
            return
          end

          complete_initialize(init_err, nil)
        end,
      })
    end, 100)
  end

  attempt_initialize(1)
end

--- Create a new session
--- @param opts table|nil Session options
--- @param callback fun(err: string|nil, session_id: string|nil) Callback with result
function M.create_session(opts, callback)
  opts = opts or {}

  if not state.initialized then
    M.initialize(function(err)
      if err then
        callback(err, nil)
        return
      end
      M.create_session(opts, callback)
    end)
    return
  end

  -- OpenCode uses session/new with required cwd and mcpServers params
  local params = {
    cwd = opts.cwd or vim.fn.getcwd(),
    mcpServers = {}, -- Empty array for now
  }

  local request, _ = build_request("session/new", params)

  send_message(request, {
    on_success = function(result)
      if result and result.sessionId then
        state.session_id = result.sessionId

        -- Apply requested agent (mode) and model after session creation.
        local agent = opts.agent or (config.options and config.options.agent)
        local model = opts.model or (config.options and config.options.model)

        local function done()
          callback(nil, result.sessionId)
        end

        local function warn(msg)
          vim.schedule(function()
            vim.notify(msg, vim.log.levels.WARN)
          end)
        end

        local function is_method_not_found(err)
          if type(err) ~= "string" then
            return false
          end
          local lower = err:lower()
          return lower:find("method not found", 1, true) ~= nil
            or lower:find("unknown method", 1, true) ~= nil
            or lower:find("does not exist", 1, true) ~= nil
        end

        --- Return true/false if explicitly reported, nil if unknown.
        --- @param kind "mode"|"model"
        --- @return boolean|nil
        local function supports_session_setting(kind)
          local caps = state.agent_capabilities
          if type(caps) ~= "table" then
            return nil
          end

          local session_caps = caps.session
          if type(session_caps) ~= "table" then
            return nil
          end

          local keys
          if kind == "mode" then
            keys = { "setMode", "set_mode" }
          else
            keys = { "setModel", "set_model" }
          end

          for _, k in ipairs(keys) do
            if session_caps[k] == true then
              return true
            end
            if session_caps[k] == false then
              return false
            end
          end

          return nil
        end

        local function set_model_then_done()
          if not model or model == "" then
            done()
            return
          end

          local supported = supports_session_setting("model")
          if supported == false then
            warn("Ghost: Backend does not support setting model; ignoring")
            done()
            return
          end

          M.set_model(model, function(model_err)
            if model_err then
              if is_method_not_found(model_err) then
                warn("Ghost: Backend does not support setting model; ignoring")
              else
                warn("Ghost: Failed to set model: " .. model_err)
              end
            end
            done()
          end)
        end

        if not agent or agent == "" then
          set_model_then_done()
          return
        end

        local supported = supports_session_setting("mode")
        if supported == false then
          warn("Ghost: Backend does not support setting agent mode; ignoring")
          set_model_then_done()
          return
        end

        M.set_mode(agent, function(mode_err)
          if mode_err then
            if is_method_not_found(mode_err) then
              warn("Ghost: Backend does not support setting agent mode; ignoring")
            else
              warn("Ghost: Failed to set agent mode: " .. mode_err)
            end
          end
          set_model_then_done()
        end)
      else
        callback("Invalid session response", nil)
      end
    end,
    on_error = function(err)
      callback(err, nil)
    end,
  })
end

--- Set the agent mode for the current session
--- @param mode string The agent/mode name (e.g., "NULL", "plan", "explore")
--- @param callback fun(err: string|nil) Callback with result
function M.set_mode(mode, callback)
  if not state.session_id then
    callback("No active session")
    return
  end

  -- ACP spec uses "modeId" not "mode"
  local params = {
    sessionId = state.session_id,
    modeId = mode,
  }

  local request, _ = build_request("session/set_mode", params)

  send_message(request, {
    on_success = function()
      callback(nil)
    end,
    on_error = function(err)
      callback(err)
    end,
  })
end

--- Set the model for the current session
--- @param model string Model name/id (e.g., "gpt-4.1", "o1")
--- @param callback fun(err: string|nil) Callback with result
function M.set_model(model, callback)
  if not state.session_id then
    callback("No active session")
    return
  end

  -- ACP schema typically uses "modelId" (mirrors modeId)
  local params = {
    sessionId = state.session_id,
    modelId = model,
  }

  local request, _ = build_request("session/set_model", params)

  send_message(request, {
    on_success = function()
      callback(nil)
    end,
    on_error = function(err)
      callback(err)
    end,
  })
end

--- Send a prompt to the current session
--- @param prompt_text string The prompt text
--- @param context table|nil Additional context (files, selection, etc.)
--- @param callbacks table Callbacks: on_update, on_complete, on_error
function M.send_prompt(prompt_text, context, callbacks)
  callbacks = callbacks or {}

  -- Ensure we have a session
  if not state.session_id then
    M.create_session({ cwd = vim.fn.getcwd() }, function(err)
      if err then
        if callbacks.on_error then
          callbacks.on_error(err)
        end
        return
      end
      M.send_prompt(prompt_text, context, callbacks)
    end)
    return
  end

  -- Build prompt with file reference notation (@file :L#)
  -- OpenCode can read files itself, so we just reference them
  local enhanced_prompt = prompt_text

  if context and context.file_path then
    local file_ref = build_file_reference(context.file_path, context.selection_range)

    if context.selection and context.selection_range then
      local full_file_ref = string.format("@%s", context.file_path)
      local target_ref = file_ref

      local range = context.selection_range
      local target_desc
      if range.start_line == range.end_line and range.mode == "v" and range.start_col and range.end_col then
        target_desc = string.format("L%d:C%d-C%d", range.start_line, range.start_col, range.end_col)
      elseif range.start_line == range.end_line then
        target_desc = string.format("L%d", range.start_line)
      else
        target_desc = string.format("L%d-L%d", range.start_line, range.end_line)
      end

      enhanced_prompt = table.concat({
        full_file_ref,
        target_ref,
        "",
        "Modify ONLY the selected region (" .. target_desc .. ") referenced above.",
        "Preserve all non-selected lines/characters exactly; do not reformat or adjust surrounding code.",
        "",
        "Selected text:",
        "```",
        context.selection,
        "```",
        "",
        prompt_text,
      }, "\n")
    else
      -- No selection: just reference the file
      enhanced_prompt = file_ref .. "\n\n" .. prompt_text
    end
  end

  -- Build content array - just the enhanced prompt text
  local content = {
    {
      type = "text",
      text = enhanced_prompt,
    },
  }

  local request, _ = build_request("session/prompt", {
    sessionId = state.session_id,
    prompt = content, -- ACP uses "prompt" not "content"
  })

  -- Set up notification handler for streaming updates
  local ghost_request_id = context and context.request_id or nil
  local original_notification_handler = state.on_notification
  state.on_notification = function(notification)
    if notification.method == "session/update" and notification.params and type(notification.params) == "table" then
      if ghost_request_id then
        notification.params.__ghost_request_id = ghost_request_id
      end
      if callbacks.on_update then
        callbacks.on_update(notification.params)
      end
    end
    -- Call original handler too
    if original_notification_handler then
      original_notification_handler(notification)
    end
  end

  send_message(request, {
    on_success = function(result)
      -- Restore original notification handler
      state.on_notification = original_notification_handler
      if callbacks.on_complete then
        callbacks.on_complete(result)
      end
    end,
    on_error = function(err)
      -- Restore original notification handler
      state.on_notification = original_notification_handler
      if callbacks.on_error then
        callbacks.on_error(err)
      end
    end,
  })
end

--- Cancel the current prompt
--- @param callback fun(err: string|nil)|nil Optional callback
function M.cancel_prompt(callback)
  if not state.session_id then
    if callback then
      callback("No active session")
    end
    return
  end

  local notification = build_notification("session/cancel", {
    sessionId = state.session_id,
  })

  send_message(notification, nil)

  if callback then
    callback(nil)
  end
end

--- Disconnect and stop the subprocess
function M.disconnect()
  if state.job_id then
    local job_id = state.job_id
    state.job_id = nil
    state.stopping = true
    pcall(vim.fn.jobstop, job_id)
    vim.defer_fn(function()
      state.stopping = false
    end, 100)
  end

  state.initialized = false
  state.session_id = nil
  state.agent_info = nil
  state.agent_capabilities = nil
  state.pending_requests = {}
  state.response_buffer = ""

  if state.on_disconnect then
    state.on_disconnect()
  end
end

--- Reconnect to the ACP server (disconnect and re-initialize)
--- @param callback fun(err: string|nil, capabilities: table|nil)|nil Callback with result
function M.reconnect(callback)
  -- Disconnect first
  M.disconnect()

  -- Small delay then reconnect
  vim.defer_fn(function()
    M.initialize(callback or function() end)
  end, 100)
end

--- Check if initialized and ready
--- @return boolean True if initialized
function M.is_connected()
  return state.initialized and state.job_id ~= nil
end

--- Check if subprocess is running
--- @return boolean True if subprocess is running
function M.is_running()
  return state.job_id ~= nil
end

--- Check if we have an active session
--- @return boolean True if session exists
function M.has_session()
  return state.session_id ~= nil
end

--- Get the current session ID
--- @return string|nil Session ID or nil
function M.get_session_id()
  return state.session_id
end

--- Set notification handler
--- @param callback fun(notification: table)|nil Handler function
function M.set_on_notification(callback)
  state.on_notification = callback
end

--- Set error callback
--- @param callback fun(err: string)|nil Error handler
function M.set_on_error(callback)
  state.on_error = callback
end

--- Set connect callback
--- @param callback fun()|nil Connect handler
function M.set_on_connect(callback)
  state.on_connect = callback
end

--- Set disconnect callback
--- @param callback fun()|nil Disconnect handler
function M.set_on_disconnect(callback)
  state.on_disconnect = callback
end

--- Get connection status info for debugging/display
--- @return table Status information
function M.status()
  return {
    backend = current_backend(),
    running = state.job_id ~= nil,
    initializing = state.initializing,
    initialized = state.initialized,
    session_id = state.session_id,
    agent_info = state.agent_info,
    capabilities = state.agent_capabilities,
    pending_requests = vim.tbl_count(state.pending_requests),
    last_error = state.last_error,
    last_error_time = state.last_error_time,
  }
end

--- Clear the last error (useful after successful reconnect)
function M.clear_last_error()
  state.last_error = nil
  state.last_error_time = nil
end

--- Get a summary string of the current status
--- @return string Status summary
function M.summary()
  local info = M.status()

  if info.initialized then
    local agent_name = info.agent_info and info.agent_info.name or "unknown"
    local version = info.agent_info and info.agent_info.version or ""
    if info.session_id then
      return string.format("Connected to %s %s (session: %s)", agent_name, version, info.session_id:sub(1, 8))
    else
      return string.format("Connected to %s %s (no session)", agent_name, version)
    end
  elseif info.running then
    return "Starting ACP subprocess..."
  else
    return "Disconnected (ACP subprocess not running; backend=" .. current_backend() .. ")"
  end
end

-- Legacy compatibility functions

--- Connect to the ACP server (legacy - now starts subprocess)
--- @param opts table|nil Connection options
--- @return boolean success True if connection attempt started
--- @return string|nil error Error message if failed
function M.connect(opts)
  opts = opts or {}

  if opts.on_connect then
    state.on_connect = opts.on_connect
  end
  if opts.on_error then
    state.on_error = opts.on_error
  end
  if opts.on_disconnect then
    state.on_disconnect = opts.on_disconnect
  end

  M.initialize(function(err)
    if err and state.on_error then
      state.on_error(err)
    end
  end)

  return true, nil
end

--- Legacy: Send raw data
--- @param data string The data to send
--- @param callback fun(err: string|nil)|nil Callback on completion
--- @return boolean success True if send was initiated
--- @return string|nil error Error message if send failed
function M.send(data, callback)
  if not state.job_id then
    if callback then
      callback("Not connected")
    end
    return false, "Not connected"
  end

  local bytes = vim.fn.chansend(state.job_id, data)
  if callback then
    if bytes > 0 then
      callback(nil)
    else
      callback("Failed to send data")
    end
  end

  return bytes > 0, nil
end

--- Legacy: Set data receive callback
--- @param callback fun(data: string)|nil The callback function
function M.set_on_data(_callback)
  -- This is handled by on_stdout now
end

--- Legacy: Get socket path (not applicable for stdio)
--- @return string Description
function M.get_socket_path()
  return "stdio (acp subprocess)"
end

--- Legacy: Get endpoint
--- @return string Description
function M.get_endpoint()
  return "stdio (acp subprocess)"
end

--- Legacy: Check if connecting
--- @return boolean True if starting up
function M.is_connecting()
  return state.job_id ~= nil and not state.initialized
end

--- Get the subprocess command for the current backend (test helper)
--- @return string cmd The command
--- @return table args The arguments
function M._get_subprocess_command()
  return build_subprocess_command()
end

return M
