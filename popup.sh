#!/usr/bin/env bash
# Agent Notifier popup wrapper.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

tmux display-popup -E -w 82 -h 28 -T "Agent Notifications" "${SCRIPT_DIR}/dashboard.sh" 2>/dev/null || "${SCRIPT_DIR}/dashboard.sh"
