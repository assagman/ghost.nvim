--- Ghost ACP Instance Manager - Manages multiple ACP subprocess instances (one per session)
--- Each Ghost session gets its own ACP subprocess for concurrent streaming
--- @module ghost.acp_manager

local M = {}

local config = require("ghost.config")

--- Map of ghost_session_id -> ACP instance
--- @type table<string, table>
local instances = {}

--- Get the current backend name
--- @return "opencode"|"codex" The current backend
local function current_backend()
  local backend = config.options and config.options.backend
  if backend == "codex" then
    return "codex"
  end
  return "opencode"
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

--- Create a new ACP instance for a Ghost session
--- @param ghost_session_id string The Ghost session ID
--- @param opts table|nil Options for the instance
--- @return table instance The ACP instance
function M.create_instance(ghost_session_id, opts)
  opts = opts or {}

  --- @class ACPInstance
  local instance = {
    ghost_session_id = ghost_session_id,
    job_id = nil,
    initialized = false,
    acp_session_id = nil, -- ACP's own session ID
    agent_info = nil,
    agent_capabilities = nil,
    request_id = 0,
    pending_requests = {},
    response_buffer = "",
    on_notification = opts.on_notification,
    on_error = opts.on_error,
    on_connect = opts.on_connect,
    on_disconnect = opts.on_disconnect,
    initializing = false,
    initialize_callbacks = {},
    stopping = false,
    last_error = nil,
    last_error_time = nil,
  }

  --- Generate a new JSON-RPC request ID
  --- @return number Unique request ID
  local function next_request_id()
    instance.request_id = instance.request_id + 1
    return instance.request_id
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

  local function complete_initialize(err, capabilities)
    local callbacks = instance.initialize_callbacks
    instance.initialize_callbacks = {}
    instance.initializing = false

    if err then
      instance.last_error = err
      instance.last_error_time = os.time()
      if instance.on_error then
        instance.on_error(err)
      end
    end

    for _, cb in ipairs(callbacks) do
      vim.schedule(function()
        cb(err, capabilities)
      end)
    end
  end

  --- Process a complete JSON-RPC message
  --- @param message table The parsed JSON message
  local function process_message(message)
    -- Check if it's a response (has id and result/error)
    if message.id then
      local callback = instance.pending_requests[message.id]
      if callback then
        instance.pending_requests[message.id] = nil
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
      if instance.on_notification then
        -- Add ghost_session_id to notification for routing
        if message.params and type(message.params) == "table" then
          message.params.__ghost_session_id = ghost_session_id
        end
        instance.on_notification(message)
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
        instance.response_buffer = instance.response_buffer .. line

        -- Try to parse complete JSON objects
        -- OpenCode sends one JSON object per line
        local ok, message = pcall(vim.json.decode, instance.response_buffer)
        if ok then
          instance.response_buffer = ""
          vim.schedule(function()
            process_message(message)
          end)
        end
      end
    end
  end

  --- Handle subprocess exit
  --- @param code number The exit code
  local function on_exit(_, code)
    vim.schedule(function()
      local backend = current_backend()

      -- Capture pending requests before clearing state
      local pending = instance.pending_requests
      local was_stopping = instance.stopping

      local error_msg = code ~= 0 and ("ACP subprocess exited with code " .. code .. " (backend=" .. backend .. ")")
        or ("ACP subprocess exited (backend=" .. backend .. ")")

      -- Track error for status display (only for non-zero exits and not manual stop)
      if code ~= 0 and not was_stopping then
        instance.last_error = error_msg
        instance.last_error_time = os.time()
      end

      -- Clear state
      instance.job_id = nil
      instance.initialized = false
      instance.acp_session_id = nil
      instance.agent_info = nil
      instance.agent_capabilities = nil
      instance.pending_requests = {}
      instance.response_buffer = ""
      instance.stopping = false

      -- Notify all pending requests of the error
      for _, callbacks in pairs(pending) do
        if callbacks.on_error then
          pcall(callbacks.on_error, error_msg)
        end
      end

      if instance.on_disconnect then
        instance.on_disconnect()
      end

      -- Manual disconnect/reconnect should not surface exit errors or trigger retries.
      if was_stopping then
        return
      end

      -- Never auto-retry while Neovim is exiting.
      if is_nvim_exiting() then
        return
      end

      -- Auto-retry startup/crash failures by reconnecting in the background (if not manual disconnect).
      if code ~= 0 and not instance.initializing then
        instance.initialize(function() end)
      end
    end)
  end

  --- Start the opencode acp subprocess
  --- @return boolean success True if started successfully
  --- @return string|nil error Error message if failed
  local function start_subprocess()
    if instance.job_id then
      return true, nil -- Already running
    end

    local backend = current_backend()
    local cmd, args = build_subprocess_command()
    local argv = { cmd, unpack(args) }

    -- Add working directory if specified
    local cwd = (config.options and config.options.acp_cwd) or vim.fn.getcwd()

    instance.job_id = vim.fn.jobstart(argv, {
      cwd = cwd,
      on_stdout = on_stdout,
      on_stderr = function() end, -- Ignore stderr
      on_exit = on_exit,
      stdout_buffered = false,
      stderr_buffered = false,
    })

    if instance.job_id <= 0 then
      instance.job_id = nil

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
    if not instance.job_id then
      if callbacks and callbacks.on_error then
        vim.schedule(function()
          callbacks.on_error("Not connected to ACP (backend=" .. current_backend() .. ")")
        end)
      end
      return false
    end

    -- Store callbacks for response handling
    if message.id and callbacks then
      instance.pending_requests[message.id] = callbacks
    end

    -- Encode and send
    local json = vim.json.encode(message) .. "\n"
    local bytes_written = vim.fn.chansend(instance.job_id, json)

    if bytes_written == 0 then
      if message.id then
        instance.pending_requests[message.id] = nil
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
  --- @param callback fun(err: string|nil, capabilities: table|nil) Callback with result
  function instance.initialize(callback)
    if is_nvim_exiting() then
      callback("Neovim is exiting", nil)
      return
    end

    if instance.initialized then
      vim.schedule(function()
        callback(nil, instance.agent_capabilities)
      end)
      return
    end

    if instance.initializing then
      table.insert(instance.initialize_callbacks, callback)
      return
    end

    instance.initializing = true
    instance.initialize_callbacks = { callback }

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
            fs = {
              readTextFile = true,
              writeTextFile = true,
            },
            terminal = false,
          },
        })

        send_message(request, {
          on_success = function(result)
            instance.initialized = true
            instance.agent_info = result.agentInfo
            instance.agent_capabilities = result.agentCapabilities
            -- Clear last error on successful connection
            instance.last_error = nil
            instance.last_error_time = nil

            if instance.on_connect then
              instance.on_connect()
            end

            complete_initialize(nil, result.agentCapabilities)
          end,
          on_error = function(init_err)
            if is_retryable_start_error(init_err) and attempt < MAX_START_RETRIES then
              local job_id = instance.job_id
              instance.job_id = nil
              instance.stopping = true

              if job_id then
                pcall(vim.fn.jobstop, job_id)
              end

              instance.initialized = false
              instance.acp_session_id = nil
              instance.agent_info = nil
              instance.agent_capabilities = nil
              instance.pending_requests = {}
              instance.response_buffer = ""

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

  --- Set the agent mode for the current ACP session
  --- @param mode string The agent/mode name (e.g., "NULL", "plan", "YOLO")
  --- @param callback fun(err: string|nil) Callback with result
  function instance.set_mode(mode, callback)
    if not instance.acp_session_id then
      callback("No active session")
      return
    end

    local request, id = build_request("session/set_mode", {
      sessionId = instance.acp_session_id,
      modeId = mode,
    })

    local settled = false

    local function finish(err)
      if settled then
        return
      end
      settled = true
      if id then
        instance.pending_requests[id] = nil
      end
      callback(err)
    end

    -- Defensive timeout: some backends emit notifications before replying.
    vim.defer_fn(function()
      if settled then
        return
      end
      finish("Timed out waiting for session/set_mode response")
    end, 5000)

    send_message(request, {
      on_success = function()
        finish(nil)
      end,
      on_error = function(err)
        finish(err)
      end,
    })
  end

  --- Set the model for the current ACP session
  --- @param model string Model name/id (e.g., "gpt-5.2", "o1")
  --- @param callback fun(err: string|nil) Callback with result
  function instance.set_model(model, callback)
    if not instance.acp_session_id then
      callback("No active session")
      return
    end

    local request, id = build_request("session/set_model", {
      sessionId = instance.acp_session_id,
      modelId = model,
    })

    local settled = false

    local function finish(err)
      if settled then
        return
      end
      settled = true
      if id then
        instance.pending_requests[id] = nil
      end
      callback(err)
    end

    vim.defer_fn(function()
      if settled then
        return
      end
      finish("Timed out waiting for session/set_model response")
    end, 5000)

    send_message(request, {
      on_success = function()
        finish(nil)
      end,
      on_error = function(err)
        finish(err)
      end,
    })
  end

  --- Create a new ACP session
  --- @param session_opts table|nil Session options
  --- @param callback fun(err: string|nil, session_id: string|nil) Callback with result
  function instance.create_session(session_opts, callback)
    session_opts = session_opts or {}

    if not instance.initialized then
      instance.initialize(function(err)
        if err then
          callback(err, nil)
          return
        end
        instance.create_session(session_opts, callback)
      end)
      return
    end

    -- OpenCode uses session/new with required cwd and mcpServers params
    local params = {
      cwd = session_opts.cwd or vim.fn.getcwd(),
      mcpServers = {}, -- Empty array for now
    }

    local request, _ = build_request("session/new", params)

    send_message(request, {
      on_success = function(result)
        if not (result and result.sessionId) then
          callback("Invalid session response", nil)
          return
        end

        instance.acp_session_id = result.sessionId

        -- Apply requested agent (mode) and model after session creation.
        local agent = session_opts.agent or (config.options and config.options.agent)
        local model = session_opts.model or (config.options and config.options.model)

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
          local caps = instance.agent_capabilities
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

          if result.models and result.models.currentModelId == model then
            done()
            return
          end

          local supported = supports_session_setting("model")
          if supported == false then
            warn("Ghost: Backend does not support setting model; ignoring")
            done()
            return
          end

          instance.set_model(model, function(model_err)
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

        if result.modes and result.modes.currentModeId == agent then
          set_model_then_done()
          return
        end

        local supported = supports_session_setting("mode")
        if supported == false then
          warn("Ghost: Backend does not support setting agent mode; ignoring")
          set_model_then_done()
          return
        end

        instance.set_mode(agent, function(mode_err)
          if mode_err then
            if is_method_not_found(mode_err) then
              warn("Ghost: Backend does not support setting agent mode; ignoring")
            else
              warn("Ghost: Failed to set agent mode: " .. mode_err)
            end
          end
          set_model_then_done()
        end)
      end,
      on_error = function(err)
        callback(err, nil)
      end,
    })
  end

  --- Send a prompt to the ACP session
  --- @param prompt_text string The prompt text
  --- @param context table|nil Additional context (files, selection, etc.)
  --- @param callbacks table Callbacks: on_update, on_complete, on_error
  function instance.send_prompt(prompt_text, context, callbacks)
    callbacks = callbacks or {}

    -- Ensure we have a session
    if not instance.acp_session_id then
      instance.create_session({ cwd = vim.fn.getcwd() }, function(err)
        if err then
          if callbacks.on_error then
            callbacks.on_error(err)
          end
          return
        end
        instance.send_prompt(prompt_text, context, callbacks)
      end)
      return
    end

    -- Build prompt with file reference notation (@file :L#)
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
      sessionId = instance.acp_session_id,
      prompt = content,
    })

    -- Set up notification handler for streaming updates
    local ghost_request_id = context and context.request_id or nil
    local original_notification_handler = instance.on_notification
    instance.on_notification = function(notification)
      if notification.method == "session/update" and notification.params and type(notification.params) == "table" then
        if ghost_request_id then
          notification.params.__ghost_request_id = ghost_request_id
        end
        -- Ensure ghost_session_id is set
        notification.params.__ghost_session_id = ghost_session_id
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
        instance.on_notification = original_notification_handler
        if callbacks.on_complete then
          callbacks.on_complete(result)
        end
      end,
      on_error = function(err)
        -- Restore original notification handler
        instance.on_notification = original_notification_handler
        if callbacks.on_error then
          callbacks.on_error(err)
        end
      end,
    })
  end

  --- Disconnect and stop the subprocess
  function instance.disconnect()
    if instance.job_id then
      local job_id = instance.job_id
      instance.job_id = nil
      instance.stopping = true
      pcall(vim.fn.jobstop, job_id)
      vim.defer_fn(function()
        instance.stopping = false
      end, 100)
    end

    instance.initialized = false
    instance.acp_session_id = nil
    instance.agent_info = nil
    instance.agent_capabilities = nil
    instance.pending_requests = {}
    instance.response_buffer = ""

    if instance.on_disconnect then
      instance.on_disconnect()
    end
  end

  --- Check if initialized and ready
  --- @return boolean True if initialized
  function instance.is_connected()
    return instance.initialized and instance.job_id ~= nil
  end

  --- Check if subprocess is running
  --- @return boolean True if subprocess is running
  function instance.is_running()
    return instance.job_id ~= nil
  end

  --- Get connection status info
  --- @return table Status information
  function instance.status()
    return {
      backend = current_backend(),
      running = instance.job_id ~= nil,
      initializing = instance.initializing,
      initialized = instance.initialized,
      acp_session_id = instance.acp_session_id,
      agent_info = instance.agent_info,
      capabilities = instance.agent_capabilities,
      pending_requests = vim.tbl_count(instance.pending_requests),
      last_error = instance.last_error,
      last_error_time = instance.last_error_time,
    }
  end

  return instance
end

--- Get an instance for a Ghost session
--- @param ghost_session_id string The Ghost session ID
--- @return table|nil instance The ACP instance or nil if not found
function M.get_instance(ghost_session_id)
  return instances[ghost_session_id]
end

--- Store an instance for a Ghost session
--- @param ghost_session_id string The Ghost session ID
--- @param instance table The ACP instance
function M.set_instance(ghost_session_id, instance)
  instances[ghost_session_id] = instance
end

--- Remove an instance for a Ghost session
--- @param ghost_session_id string The Ghost session ID
function M.remove_instance(ghost_session_id)
  local instance = instances[ghost_session_id]
  if instance then
    -- Disconnect the instance
    if instance.disconnect then
      instance.disconnect()
    end
    instances[ghost_session_id] = nil
  end
end

--- Get all instances
--- @return table<string, table> Map of ghost_session_id -> instance
function M.get_all_instances()
  return instances
end

--- Clear all instances (for testing)
function M.clear_all()
  for ghost_session_id, _ in pairs(instances) do
    M.remove_instance(ghost_session_id)
  end
  instances = {}
end

return M
