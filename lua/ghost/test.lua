--- Ghost test module - Manual test helpers for Ghost functionality
--- Run tests from Neovim: :lua require('ghost.test').test_prompt()
--- @module ghost.test

local M = {}

--- Test basic ACP connection and initialization
--- Usage: :lua require('ghost.test').test_connection()
function M.test_connection()
  local acp = require("ghost.acp")

  print("=== Ghost ACP Connection Test ===")
  print("Starting subprocess...")

  acp.initialize(function(err, capabilities)
    if err then
      print("ERROR: " .. err)
      return
    end

    print("SUCCESS: Connected to OpenCode ACP!")
    print("Capabilities: " .. vim.inspect(capabilities))

    local status = acp.status()
    print("Status: " .. vim.inspect(status))
  end)
end

--- Test session creation
--- Usage: :lua require('ghost.test').test_session()
function M.test_session()
  local acp = require("ghost.acp")

  print("=== Ghost Session Test ===")

  acp.create_session({ cwd = vim.fn.getcwd() }, function(err, session_id)
    if err then
      print("ERROR: " .. err)
      return
    end

    print("SUCCESS: Session created!")
    print("Session ID: " .. session_id)
    print("Summary: " .. acp.summary())
  end)
end

--- Test sending a simple prompt with streaming output
--- Usage: :lua require('ghost.test').test_prompt()
function M.test_prompt(prompt_text)
  local acp = require("ghost.acp")

  prompt_text = prompt_text or "Say hello in one short sentence."

  print("=== Ghost Prompt Test ===")
  print("Prompt: " .. prompt_text)
  print("---")

  -- Track streaming output
  local output_lines = {}

  acp.send_prompt(prompt_text, nil, {
    on_update = function(update) -- luacheck: ignore 561
      -- ACP update format: update.update.sessionUpdate indicates type
      local inner = update.update or update
      local update_type = inner.sessionUpdate

      if update_type == "message_delta" or update_type == "message" then
        -- Handle streaming text content
        local content = inner.content
        if content and type(content) == "table" then
          for _, item in ipairs(content) do
            if item.type == "text" and item.text then
              io.write(item.text)
              io.flush()
              table.insert(output_lines, item.text)
            end
          end
        end
      elseif update_type == "tool_call" then
        -- New tool invocation
        print("\n[Tool: " .. (inner.title or "unknown") .. " (" .. (inner.kind or "?") .. ")]")
      elseif update_type == "tool_call_update" then
        -- Tool progress/completion
        local status = inner.status or "unknown"
        print("[Tool update: " .. (inner.toolCallId or "?") .. " - " .. status .. "]")
      elseif update_type == "plan_update" or update_type == "plan" then
        print("[Plan updated]")
      else
        -- Debug: print raw update for unknown types
        print("[Update: " .. vim.inspect(update):sub(1, 200) .. "]")
      end
    end,

    on_complete = function(result)
      print("\n---")
      print("COMPLETE!")
      if result then
        print("Result: " .. vim.inspect(result))
      end
    end,

    on_error = function(err)
      print("\nERROR: " .. err)
    end,
  })
end

--- Test the full sender flow (with context)
--- Usage: :lua require('ghost.test').test_sender()
function M.test_sender(prompt_text)
  local sender = require("ghost.sender")
  local receiver = require("ghost.receiver")

  prompt_text = prompt_text or "What file am I editing? Just answer with the filename."

  print("=== Ghost Sender Test ===")
  print("Prompt: " .. prompt_text)
  print("---")

  -- Set up receiver callbacks
  receiver.set_on_update(function(update)
    if update.type == "text_chunk" then
      io.write(update.text)
      io.flush()
    elseif update.type == "tool_call" then
      print("\n[Tool: " .. (update.tool_name or "unknown") .. " (" .. (update.kind or "?") .. ")]")
    elseif update.type == "tool_call_update" then
      print("[Tool " .. (update.tool_id or "?"):sub(1, 8) .. ": " .. (update.status or "unknown") .. "]")
    elseif update.type == "plan" then
      print("\n[Plan updated]")
    elseif update.type == "mode_update" then
      print("[Mode: " .. vim.inspect(update.mode) .. "]")
    elseif update.type == "commands_update" then
      print("[Commands available]")
    end
  end)

  receiver.set_on_response(function(response)
    print("\n---")
    print("Response type: " .. response.type)
    if response.type == "explanation" then
      print("Text: " .. (response.text or ""):sub(1, 200))
    elseif response.type == "edit" then
      print("File: " .. (response.file_path or "unknown"))
      print("Content length: " .. #(response.content or ""))
    end
  end)

  local request_id, err = sender.send(prompt_text, {
    on_success = function(req_id)
      print("Request initiated: " .. req_id)
    end,
    on_update = function(update)
      receiver.handle_update(update)
    end,
    on_complete = function(result)
      receiver.handle_complete(result)
      print("\nCOMPLETE!")
    end,
    on_error = function(send_err)
      print("\nERROR: " .. send_err)
    end,
  })

  if not request_id then
    print("Failed to send: " .. (err or "unknown error"))
  end
end

--- Test the UI flow - open prompt, verify it works
--- Usage: :lua require('ghost.test').test_ui()
function M.test_ui()
  local ghost = require("ghost")

  print("=== Ghost UI Test ===")
  print("Opening prompt buffer...")
  print("Type a prompt and press :w to send")

  ghost.open_prompt()
end

--- Test the response display window
--- Usage: :lua require('ghost.test').test_response_display()
function M.test_response_display()
  local response = require("ghost.response")

  print("=== Ghost Response Display Test ===")

  -- Open the response window
  response.open()

  -- Add a header
  response.add_header("Test Response")

  -- Simulate streaming text
  local text = "This is a simulated streaming response from the AI agent. "
  for i = 1, #text do
    response.append_text(text:sub(i, i))
    vim.cmd("redraw")
    vim.wait(20) -- 20ms delay between characters
  end

  -- Add a tool call
  response.update_tool_call("tool_001", "Reading file", "pending", "read")
  vim.wait(500)

  response.update_tool_call("tool_001", "Reading file", "in_progress", "read")
  vim.wait(500)

  response.update_tool_call("tool_001", "Reading file", "completed", "read")

  -- Add more streaming text
  response.append_text("\n\nThe tool has finished reading the file.\n")

  -- Add separator and completion
  response.add_separator()
  response.append_text("*Response complete*\n")

  print("Response display test complete. Press q to close the window.")
end

--- Test the full flow: prompt -> response display
--- Usage: :lua require('ghost.test').test_full_flow()
function M.test_full_flow(prompt_text)
  local ghost = require("ghost")

  prompt_text = prompt_text or "Say hello and tell me what you can help with in 2 sentences."

  print("=== Ghost Full Flow Test ===")
  print("Sending prompt and displaying response...")

  -- Use the main ghost send_prompt which uses sender and response display
  ghost.send_prompt(prompt_text, {
    on_success = function(request_id)
      print("Request started: " .. request_id)
    end,
    on_complete = function()
      print("Request complete!")
    end,
    on_error = function(err)
      print("Error: " .. err)
    end,
  })
end

--- Show current ACP status
--- Usage: :lua require('ghost.test').status()
function M.status()
  local acp = require("ghost.acp")
  local ghost_status = require("ghost.status")

  print("=== Ghost Status ===")
  print("ACP: " .. acp.summary())
  print("Ghost: " .. ghost_status.summary())

  local acp_status = acp.status()
  print("\nACP Details:")
  print("  Running: " .. tostring(acp_status.running))
  print("  Initialized: " .. tostring(acp_status.initialized))
  print("  Session ID: " .. (acp_status.session_id or "none"))
  print("  Pending requests: " .. acp_status.pending_requests)

  if acp_status.agent_info then
    print("  Agent: " .. (acp_status.agent_info.name or "unknown") .. " " .. (acp_status.agent_info.version or ""))
  end
end

--- Disconnect from ACP
--- Usage: :lua require('ghost.test').disconnect()
function M.disconnect()
  local acp = require("ghost.acp")

  print("Disconnecting from ACP...")
  acp.disconnect()
  print("Disconnected.")
end

--- Unit tests for backend config validation and command construction
--- Usage: :lua require('ghost.test').unit_tests()
function M.unit_tests()
  local config = require("ghost.config")
  local acp = require("ghost.acp")

  print("=== Ghost Unit Tests ===\n")

  local passed = 0
  local failed = 0

  local function assert_eq(name, expected, actual)
    if expected == actual then
      print("[PASS] " .. name)
      passed = passed + 1
    else
      print("[FAIL] " .. name)
      print("  Expected: " .. vim.inspect(expected))
      print("  Actual:   " .. vim.inspect(actual))
      failed = failed + 1
    end
  end

  local function assert_error(name, fn, pattern)
    local ok, err = pcall(fn)
    if not ok and (not pattern or tostring(err):find(pattern)) then
      print("[PASS] " .. name)
      passed = passed + 1
    else
      print("[FAIL] " .. name)
      if ok then
        print("  Expected error, but succeeded")
      else
        print("  Error did not match pattern: " .. tostring(err))
      end
      failed = failed + 1
    end
  end

  -- Test 1: Valid backend "opencode"
  config.setup({ backend = "opencode" })
  assert_eq("backend=opencode is valid", "opencode", config.options.backend)

  -- Test 2: Valid backend "codex"
  config.setup({ backend = "codex" })
  assert_eq("backend=codex is valid", "codex", config.options.backend)

  -- Test 3: Default backend (nil -> opencode)
  config.setup({})
  assert_eq("backend defaults to opencode", "opencode", config.options.backend)

  -- Test 4: Invalid backend throws error
  assert_error("invalid backend throws error", function()
    config.setup({ backend = "invalid" })
  end, "invalid backend")

  -- Test 5: Backend command construction for opencode
  config.setup({ backend = "opencode", acp_command = "opencode" })
  local cmd, args = acp._get_subprocess_command()
  assert_eq("opencode command is 'opencode'", "opencode", cmd)
  assert_eq("opencode args is {'acp'}", "acp", args[1])

  -- Test 6: Backend command construction for codex
  config.setup({ backend = "codex" })
  cmd, args = acp._get_subprocess_command()
  assert_eq("codex command is 'bunx'", "bunx", cmd)
  assert_eq("codex args[1] is '-y'", "-y", args[1])
  assert_eq("codex args[2] is '@zed-industries/codex-acp'", "@zed-industries/codex-acp", args[2])

  -- Summary
  print("\n=== Results ===")
  print(string.format("Passed: %d, Failed: %d", passed, failed))

  if failed > 0 then
    print("\nSome tests failed!")
    return false
  else
    print("\nAll tests passed!")
    return true
  end
end

--- Run all tests in sequence
--- Usage: :lua require('ghost.test').run_all()
function M.run_all()
  print("=== Ghost Full Test Suite ===\n")

  -- Test 1: Connection
  print("[1/3] Testing connection...")
  local acp = require("ghost.acp")

  acp.initialize(function(err, _capabilities)
    if err then
      print("FAIL: Connection - " .. err)
      return
    end
    print("PASS: Connection\n")

    -- Test 2: Session
    print("[2/3] Testing session...")
    acp.create_session({ cwd = vim.fn.getcwd() }, function(session_err, session_id)
      if session_err then
        print("FAIL: Session - " .. session_err)
        return
      end
      print("PASS: Session (" .. session_id:sub(1, 12) .. "...)\n")

      -- Test 3: Prompt
      print("[3/3] Testing prompt...")
      acp.send_prompt("Reply with just the word 'success'", nil, {
        on_update = function(update)
          -- Handle ACP format: update.update.sessionUpdate
          local inner = update.update or update
          local update_type = inner.sessionUpdate

          if update_type == "message_delta" or update_type == "message" then
            local content = inner.content
            if content and type(content) == "table" then
              for _, item in ipairs(content) do
                if item.type == "text" and item.text then
                  io.write(item.text)
                  io.flush()
                end
              end
            end
          end
        end,
        on_complete = function()
          print("\nPASS: Prompt\n")
          print("=== All tests passed! ===")
        end,
        on_error = function(prompt_err)
          print("\nFAIL: Prompt - " .. prompt_err)
        end,
      })
    end)
  end)
end

return M
