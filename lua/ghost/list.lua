--- Ghost session list picker module
--- Provides a picker UI for listing and switching between Ghost sessions
--- @module ghost.list

local M = {}

local session = require("ghost.session")
local response_display = require("ghost.response")

--- Check if Snacks is available
--- @return boolean True if Snacks.picker is available
local function has_snacks()
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks.picker ~= nil
end

--- Format a session for display in the picker
--- @param sess GhostSession Session to format
--- @return table Picker item with text, value, and metadata
local function format_session_item(sess)
  local is_active = session.active_session_id == sess.id
  local status_icon = ({
    active = "🟢",
    disconnected = "⚪",
    error = "🔴",
  })[sess.status] or "⚪"

  local active_marker = is_active and "▶ " or "  "
  local timestamp = os.date("%Y-%m-%d %H:%M:%S", sess.created_at)

  -- Format: [status] [active?] Display Name (timestamp)
  local text = string.format("%s %s%s (%s)", status_icon, active_marker, sess.display_name, timestamp)

  return {
    text = text,
    value = sess.id,
    session = sess,
  }
end

--- Open the session list picker using Snacks
local function open_snacks_picker()
  local snacks = require("snacks")
  local sessions = session.list_sessions()

  if #sessions == 0 then
    vim.notify("Ghost: No sessions to list", vim.log.levels.INFO)
    return
  end

  -- Format sessions for picker
  local items = {}
  for _, sess in ipairs(sessions) do
    table.insert(items, format_session_item(sess))
  end

  -- Create picker
  snacks.picker({
    items = items,
    title = "Ghost Sessions",
    layout = { preset = "select", preview = false },
    confirm = function(picker, item)
      picker:close()
      if not item or not item.session then
        return
      end

      local sess = item.session
      local ok, err = session.switch_session(sess.id)
      if not ok then
        vim.notify("Ghost: Failed to switch session - " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end

      vim.notify("Ghost: Switched to session: " .. sess.display_name, vim.log.levels.INFO)

      -- Load the session's transcript and open the response window (US-007)
      vim.schedule(function()
        local load_ok, load_err = response_display.load_transcript(sess.id)
        if not load_ok then
          vim.notify("Ghost: Failed to load transcript - " .. (load_err or "unknown error"), vim.log.levels.WARN)
        end
        response_display.open()
      end)
    end,
    format = function(item, _)
      return { { item.text } }
    end,
    win = {
      input = {
        keys = {
          ["r"] = { "rename_session", mode = { "n", "i" } },
          ["d"] = { "delete_session", mode = { "n", "i" } },
        },
      },
    },
    actions = {
      rename_session = function(picker)
        local item = picker.list:current()
        if not item or not item.session then
          return
        end

        local sess = item.session
        vim.ui.input({
          prompt = "Rename session: ",
          default = sess.display_name,
        }, function(new_name)
          if not new_name or new_name == "" or new_name == sess.display_name then
            return
          end

          local ok, err = session.rename_session(sess.id, new_name)
          if not ok then
            vim.notify("Ghost: Failed to rename session - " .. (err or "unknown error"), vim.log.levels.ERROR)
            return
          end

          vim.notify("Ghost: Renamed session to: " .. new_name, vim.log.levels.INFO)

          -- Refresh the picker to show the updated name
          picker:find()
        end)
      end,
      delete_session = function(picker)
        local item = picker.list:current()
        if not item or not item.session then
          return
        end

        local sess = item.session
        -- Ask for confirmation (US-006)
        vim.ui.select({ "Yes", "No" }, {
          prompt = string.format("Delete session '%s'? (This cannot be undone)", sess.display_name),
        }, function(choice)
          if choice ~= "Yes" then
            return
          end

          -- Delete the session (US-006)
          local ok, err = session.delete_session(sess.id)
          if not ok then
            vim.notify("Ghost: Failed to delete session - " .. (err or "unknown error"), vim.log.levels.ERROR)
            return
          end

          vim.notify("Ghost: Deleted session: " .. sess.display_name, vim.log.levels.INFO)

          -- Refresh the picker to remove the deleted session
          picker:find()
        end)
      end,
    },
  })
end

--- Handle session switch action
--- @param sess GhostSession Session to switch to
local function do_switch_session(sess)
  local ok, err = session.switch_session(sess.id)
  if not ok then
    vim.notify("Ghost: Failed to switch session - " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end

  vim.notify("Ghost: Switched to session: " .. sess.display_name, vim.log.levels.INFO)

  -- Load the session's transcript and open the response window
  vim.schedule(function()
    local load_ok, load_err = response_display.load_transcript(sess.id)
    if not load_ok then
      vim.notify("Ghost: Failed to load transcript - " .. (load_err or "unknown error"), vim.log.levels.WARN)
    end
    response_display.open()
  end)
end

--- Handle session rename action
--- @param sess GhostSession Session to rename
--- @param on_complete function|nil Callback after rename completes
local function do_rename_session(sess, on_complete)
  vim.ui.input({
    prompt = "Rename session: ",
    default = sess.display_name,
  }, function(new_name)
    if not new_name or new_name == "" or new_name == sess.display_name then
      return
    end

    local ok, err = session.rename_session(sess.id, new_name)
    if not ok then
      vim.notify("Ghost: Failed to rename session - " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    vim.notify("Ghost: Renamed session to: " .. new_name, vim.log.levels.INFO)
    if on_complete then
      on_complete()
    end
  end)
end

--- Handle session delete action
--- @param sess GhostSession Session to delete
--- @param on_complete function|nil Callback after delete completes
local function do_delete_session(sess, on_complete)
  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Delete session '%s'? (This cannot be undone)", sess.display_name),
  }, function(choice)
    if choice ~= "Yes" then
      return
    end

    local ok, err = session.delete_session(sess.id)
    if not ok then
      vim.notify("Ghost: Failed to delete session - " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    vim.notify("Ghost: Deleted session: " .. sess.display_name, vim.log.levels.INFO)
    if on_complete then
      on_complete()
    end
  end)
end

--- Open the session list picker using vim.ui.select (fallback)
local function open_vim_ui_picker()
  local sessions = session.list_sessions()

  if #sessions == 0 then
    vim.notify("Ghost: No sessions to list", vim.log.levels.INFO)
    return
  end

  -- Format sessions for vim.ui.select
  local items = {}
  local session_map = {}
  for _, sess in ipairs(sessions) do
    local item = format_session_item(sess)
    table.insert(items, item.text)
    session_map[item.text] = sess
  end

  vim.ui.select(items, {
    prompt = "Ghost Sessions:",
  }, function(choice)
    if not choice then
      return
    end

    local sess = session_map[choice]
    if not sess then
      return
    end

    -- Show action menu for the selected session
    vim.ui.select({ "Switch", "Rename", "Delete", "Cancel" }, {
      prompt = "Action for '" .. sess.display_name .. "':",
    }, function(action)
      if not action or action == "Cancel" then
        return
      end

      if action == "Switch" then
        do_switch_session(sess)
      elseif action == "Rename" then
        do_rename_session(sess, function()
          -- Reopen picker after rename
          vim.schedule(open_vim_ui_picker)
        end)
      elseif action == "Delete" then
        do_delete_session(sess, function()
          -- Reopen picker after delete
          vim.schedule(open_vim_ui_picker)
        end)
      end
    end)
  end)
end

--- Open the session list picker
--- Uses Snacks.picker if available, otherwise falls back to vim.ui.select
function M.open()
  -- Hide response window if it's open (US-004)
  if response_display.is_open() then
    response_display.hide()
  end

  -- Check for Snacks
  if has_snacks() then
    open_snacks_picker()
    return
  end

  -- Fallback: use vim.ui.select
  open_vim_ui_picker()
end

return M
