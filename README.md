# ghost.nvim

Lightweight Neovim plugin connecting to AI agents via ACP (Agent Client Protocol).

## Features

- Connect to AI agents (OpenCode, Codex) via ACP protocol
- Floating prompt window with context capture
- Streaming response display
- Multi-session support with persistence
- Project-scoped sessions (git-aware, with cwd fallback)

## Requirements

- Neovim 0.10+
- One of the supported backends:
  - [OpenCode](https://github.com/sst/opencode) (default)
  - [Codex ACP](https://github.com/zed-industries/codex-acp) (requires `bun`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "assagman/ghost.nvim",
  event = "VeryLazy",
  opts = {
    backend = "opencode",  -- or "codex"
  },
  keys = {
    { "<leader>aq", desc = "Ghost: Open AI prompt" },
    { "<leader>aq", mode = "v", desc = "Ghost: Open AI prompt with selection" },
    { "<leader>ar", desc = "Ghost: Toggle response window" },
    { "<leader>ag", "<cmd>GhostStatus<cr>", desc = "Ghost: Show status" },
  },
  cmd = { "GhostStatus", "GhostClear", "GhostReconnect", "GhostResponse", "GhostResponseClose", "GhostList" },
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "assagman/ghost.nvim",
  config = function()
    require("ghost").setup({
      backend = "opencode",
    })
  end
}
```

## Backends

Ghost supports two ACP backends:

| Backend    | Subprocess Command                  | Auth                                        |
| ---------- | ----------------------------------- | ------------------------------------------- |
| `opencode` | `opencode acp`                      | Configured via opencode itself              |
| `codex`    | `bunx -y @zed-industries/codex-acp` | `CODEX_API_KEY` or `OPENAI_API_KEY` env var |

### Using opencode (default)

1. Install [OpenCode](https://github.com/sst/opencode)
2. Configure ghost:
   ```lua
   require("ghost").setup({
     backend = "opencode",  -- default
     -- acp_command = "opencode",  -- optional: override binary path
   })
   ```

### Using codex

1. **Install bun** (required to run `bunx`):
   ```bash
   curl -fsSL https://bun.sh/install | bash
   ```

2. **Set API key** (choose one):
   ```bash
   export CODEX_API_KEY="your-api-key"
   # or
   export OPENAI_API_KEY="your-api-key"
   ```

3. **Configure ghost**:
   ```lua
   require("ghost").setup({
     backend = "codex",
   })
   ```

## Configuration

```lua
require("ghost").setup({
  -- Backend: "opencode" or "codex"
  backend = "opencode",

  -- Agent/mode name (nil = backend default)
  -- Options: "NULL", "plan", "explore", "general", etc.
  agent = nil,

  -- Model name/id (nil = backend default)
  -- Examples: "gpt-4.1", "o1", "claude-sonnet-4-20250514"
  model = nil,

  -- Keybind to open prompt
  keybind = "<leader>aq",

  -- Enable autoread (buffers reload when agent edits files)
  autoread = true,

  -- Prompt window size (as fraction of editor)
  window = { width = 0.6, height = 0.3 },

  -- Response window size
  response_window = { width = 0.7, height = 0.5 },
})
```

## Commands

| Command               | Description                      |
| --------------------- | -------------------------------- |
| `:GhostStatus`        | Show backend, connection, errors |
| `:GhostReconnect`     | Reconnect to ACP subprocess      |
| `:GhostClear`         | Clear stale requests             |
| `:GhostResponse`      | Toggle response window           |
| `:GhostResponseClose` | Close response window            |
| `:GhostList`          | List and switch sessions         |

## Keymaps

| Key          | Mode | Action                        |
| ------------ | ---- | ----------------------------- |
| `<leader>aq` | n    | Open AI prompt (new session)  |
| `<leader>aq` | v    | Open AI prompt with selection |
| `<leader>ar` | n    | Toggle response window        |
| `<leader>ag` | n    | Show Ghost status             |

## Session Persistence

Ghost stores sessions per-project under `~/.local/share/nvim/ghost/projects/<project>/sessions/`.

- **Git repositories**: Uses the git root directory name as the project key
- **Non-git directories**: Uses the full cwd path (sanitized) as the project key

## Health Check

Run `:checkhealth ghost` to verify your setup:

```vim
:checkhealth ghost
```

This checks:
- Neovim version
- Backend executable availability
- Git availability (for session persistence)
- Snacks.nvim availability (optional, for enhanced picker)
- ACP connection status

## Optional Dependencies

- [Snacks.nvim](https://github.com/folke/snacks.nvim): Enhanced session picker with rename/delete keybinds
  - Without Snacks: Falls back to `vim.ui.select` for session management

## Tests

Run unit tests from Neovim:

```vim
:lua require('ghost.test').unit_tests()
```

Run interactive tests:

```vim
:lua require('ghost.test').test_connection()
:lua require('ghost.test').test_prompt("Say hello")
```

## Troubleshooting

### Backend subprocess fails to start

- **codex**: Ensure `bunx` is in `$PATH` (install bun first)
- **opencode**: Ensure `opencode` binary is in `$PATH`

### Auth errors with codex

Set one of these environment variables before starting Neovim:

```bash
export CODEX_API_KEY="sk-..."
# or
export OPENAI_API_KEY="sk-..."
```

### Check status

```vim
:GhostStatus
```

Shows:
- Active backend (opencode/codex)
- Connection state (CONNECTED/INITIALIZING/DISCONNECTED)
- Last error message (if any)

## Development

### Prerequisites

Install code quality tools:

```bash
# macOS
brew install stylua luacheck
pip install pre-commit

# Or manually:
# stylua: https://github.com/JohnnyMorganz/StyLua
# luacheck: https://github.com/mpeterv/luacheck
# pre-commit: https://pre-commit.com/
```

### Setup

```bash
# Install pre-commit hooks (runs stylua + luacheck on commit)
make precommit-install
```

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make format` | Format Lua files with stylua |
| `make format-check` | Check formatting (no changes) |
| `make lint` | Run luacheck linter |
| `make check` | Run format-check + lint |
| `make precommit` | Run pre-commit on all files |

### Code Style

- **Formatter**: [StyLua](https://github.com/JohnnyMorganz/StyLua) - 2-space indent, double quotes
- **Linter**: [luacheck](https://github.com/mpeterv/luacheck) - LuaJIT std, strict warnings

Configuration files: `.stylua.toml`, `.luacheckrc`

## License

MIT
