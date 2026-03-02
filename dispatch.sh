#!/usr/bin/env bash
# Claude Code Notifier — notification dispatcher
# Routes notifications to configured backends (Telegram, ntfy, Slack, etc.)
# Called from notify.sh: dispatch.sh <type> <session> <window> <message> [tool_name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"
BACKENDS_CONF="${DATA_DIR}/backends.conf"

# Exit silently if no backends configured
[ -f "$BACKENDS_CONF" ] || exit 0

# Read backends.conf, call each enabled backend in background
while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Parse name=path
    local_name="${line%%=*}"
    local_path="${line#*=}"

    # Expand ${SCRIPT_DIR} in path
    local_path="${local_path//\$\{SCRIPT_DIR\}/${SCRIPT_DIR}}"
    local_path="${local_path//\$SCRIPT_DIR/${SCRIPT_DIR}}"

    # Skip if backend script doesn't exist or isn't executable
    [ -x "$local_path" ] || continue

    # Call backend with same args, in background (stderr → log file for debugging)
    "$local_path" "$@" 2>>"${DATA_DIR}/send-errors.log" &
done < "$BACKENDS_CONF"

# Don't wait for backends — caller already backgrounded us if needed
exit 0
