#!/usr/bin/env bash
# Compatibility wrapper for the old Claude Code monitor command.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${SCRIPT_DIR}/agent-monitor.sh" "$@"
