# ghost.nvim Makefile
# Development tasks for code quality

.PHONY: all format format-check lint check precommit precommit-install help

# Default target
all: check

# Format all Lua files with stylua
format:
	@echo "Formatting Lua files..."
	stylua lua

# Check formatting without modifying files
format-check:
	@echo "Checking Lua formatting..."
	stylua --check lua

# Run luacheck linter
lint:
	@echo "Linting Lua files..."
	luacheck lua

# Run all checks (format + lint)
check: format-check lint
	@echo "All checks passed!"

# Install pre-commit hooks
precommit-install:
	@echo "Installing pre-commit hooks..."
	pre-commit install

# Run pre-commit on all files
precommit:
	@echo "Running pre-commit on all files..."
	pre-commit run --all-files

# Show help
help:
	@echo "Available targets:"
	@echo "  make format          - Format Lua files with stylua"
	@echo "  make format-check    - Check Lua formatting (no changes)"
	@echo "  make lint            - Run luacheck linter"
	@echo "  make check           - Run format-check + lint"
	@echo "  make precommit-install - Install pre-commit hooks"
	@echo "  make precommit       - Run pre-commit on all files"
	@echo "  make help            - Show this help message"
