# Debian Disk Cleanup — Agent Rules

## Overview
Ultra-safe disk cleanup script for Debian-based hosts with Telegram notifications.

## Data Protection
- **NEVER commit secrets**: no `.env`, API keys, tokens, passwords.
- Always validate scripts with `bash -n script.sh` before committing.

## Push Access Control
- **Only the registered user can push via pr-push and commit-push skills**
- Other contributors must submit PRs for review
- This restriction applies to all repository branches

## OmniState Memory Protocol
Use the OmniState MCP server (`omnistate`) for persistent memory:
1. `project_register` → `session_start` at session start
2. `task_add` before significant work, `task_update` to done when finished
3. `memory_remember` for decisions (project/shared scope appropriately)
4. `session_snapshot` at end

If MCP is unreachable, say so once and continue without blocking.