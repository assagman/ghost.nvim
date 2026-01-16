--- Ghost sender module - Format and send prompts via ACP
--- Agent reads files directly using @file notation - we just send the prompt
--- @module ghost.sender

local M = {}

local context = require("ghost.context")
local session = require("ghost.session")

--- @class GhostRequest
--- @field request_id string Unique request identifier
--- @field timestamp number Unix timestamp when request was created
--- @field prompt string The user's prompt text
--- @field file_path string|nil Current file path
--- @field selection string|nil Selected text (if any)
--- @field selection_range GhostSelectionRange|nil Selection range (if any)

--- State for tracking active requests
--- @type table<string, GhostRequest>
M.active_requests = {}

--- Counter for generating unique request IDs
local request_counter = 0

--- Generate a unique request ID
--- @return string Unique request ID
local function generate_request_id()
  request_counter = request_counter + 1
  local timestamp = os.time()
  return string.format("ghost-%d-%d", timestamp, request_counter)
end

--- Build minimal context for ACP (just file path and selection info)
--- @param ctx GhostContext|nil The context
--- @return table The context table for ACP
local function build_context(ctx)
  ctx = ctx or context.get()
  if not ctx then
    return {}
  end

  -- Only send what's needed for @file :L# notation
  return {
    file_path = ctx.file_path,
    selection = ctx.selection,
    selection_range = ctx.selection_range,
  }
end

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

--- Send a prompt via ACP
--- @param prompt string The user's prompt text
--- @param opts table|nil Optional send options
--- @field opts.on_success fun(request_id: string)|nil Called when send completes
--- @field opts.on_error fun(err: string)|nil Called on send error
--- @field opts.on_update fun(update: table)|nil Called for streaming updates
--- @field opts.on_complete fun(result: table)|nil Called when response is complete
--- @return string|nil request_id The request ID, or nil if send failed immediately
--- @return string|nil error Error message if send failed immediately
function M.send(prompt, opts)
  opts = opts or {}

  -- Validate prompt
  if not prompt or prompt:match("^%s*$") then
    local err = "Cannot send empty prompt"
    notify("Ghost: " .. err, vim.log.levels.WARN)
    if opts.on_error then
      opts.on_error(err)
    end
    return nil, err
  end

  -- Get current context
  local ctx = context.get()

  -- Build minimal context for ACP
  local acp_context = build_context(ctx)

  -- Generate request ID for tracking
  local request_id = generate_request_id()
  acp_context.request_id = request_id

  -- Store the request for tracking
  --- @type GhostRequest
  local request = {
    request_id = request_id,
    timestamp = os.time(),
    prompt = prompt,
    file_path = ctx and ctx.file_path or nil,
    selection = acp_context.selection,
    selection_range = acp_context.selection_range,
  }
  M.active_requests[request_id] = request

  -- Get the active session's ACP instance (US-009)
  local active_session = session.get_active_session()
  if not active_session then
    local err = "No active session"
    notify("Ghost: " .. err, vim.log.levels.ERROR)
    if opts.on_error then
      opts.on_error(err)
    end
    return nil, err
  end

  local acp_instance = session.get_acp_instance(active_session.id)
  if not acp_instance then
    local err = "No ACP instance for active session"
    notify("Ghost: " .. err, vim.log.levels.ERROR)
    if opts.on_error then
      opts.on_error(err)
    end
    return nil, err
  end

  -- Send via the session's ACP instance (US-009)
  acp_instance.send_prompt(prompt, acp_context, {
    on_update = function(update)
      if opts.on_update then
        opts.on_update(update)
      end
    end,

    on_complete = function(result)
      M.active_requests[request_id] = nil
      if opts.on_complete then
        opts.on_complete(result, request_id)
      end
    end,

    on_error = function(err)
      M.active_requests[request_id] = nil
      notify("Ghost: " .. err, vim.log.levels.ERROR)
      if opts.on_error then
        opts.on_error(err)
      end
    end,
  })

  -- Call on_success immediately since request was initiated
  if opts.on_success then
    opts.on_success(request_id)
  end

  return request_id, nil
end

--- Get an active request by ID
--- @param request_id string Request ID
--- @return GhostRequest|nil The request or nil if not found
function M.get_request(request_id)
  return M.active_requests[request_id]
end

--- Remove a request from tracking
--- @param request_id string Request ID
function M.remove_request(request_id)
  M.active_requests[request_id] = nil
end

--- Get all active request IDs
--- @return string[] List of active request IDs
function M.get_active_request_ids()
  local ids = {}
  for id, _ in pairs(M.active_requests) do
    table.insert(ids, id)
  end
  return ids
end

--- Get count of active requests
--- @return number Count of active requests
function M.get_active_count()
  local count = 0
  for _, _ in pairs(M.active_requests) do
    count = count + 1
  end
  return count
end

--- Clear all active requests
function M.clear_requests()
  M.active_requests = {}
end

--- Get a summary of an active request
--- @param request_id string Request ID
--- @return string Summary string
function M.request_summary(request_id)
  local req = M.active_requests[request_id]
  if not req then
    return "Request not found: " .. request_id
  end

  local elapsed = os.time() - req.timestamp
  local prompt_preview = req.prompt:sub(1, 50) .. (req.prompt:len() > 50 and "..." or "")

  local parts = {
    string.format("ID: %s", request_id),
    string.format("Elapsed: %ds", elapsed),
    string.format("Prompt: %s", prompt_preview),
    string.format("File: %s", req.file_path or "[none]"),
  }

  if req.selection then
    table.insert(parts, "Has selection: yes")
  end

  return table.concat(parts, " | ")
end

return M
