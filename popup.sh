#!/usr/bin/env bash
# Claude Code Notifier — popup wrapper
# Calculates dynamic height based on entry count and opens tmux popup
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"

# Discover untracked sessions before opening
"${SCRIPT_DIR}/scan.sh" >/dev/null 2>&1 || true

# Dashboard handles scrolling internally — use a fixed tall popup
tmux display-popup -E -w 80% -h 90% "${SCRIPT_DIR}/dashboard.sh"
