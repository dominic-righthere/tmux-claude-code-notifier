#!/usr/bin/env bash
# Claude Code Notifier — auto-clear on window switch
# Called by tmux after-select-window hook
# Args: $1 = session name, $2 = window index
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
NOTIF_DIR="${HOME}/.local/share/claude-notifier/notifications"

[ -d "$NOTIF_DIR" ] || exit 0

SESSION="${1:-}"
WINDOW="${2:-}"
[ -z "$SESSION" ] && exit 0
[ -z "$WINDOW" ] && exit 0

SAFE_SESSION="$(sanitize_key "$SESSION")"
KEY="${SAFE_SESSION}_${WINDOW}"

rm -f "${NOTIF_DIR}/${KEY}"

exit 0
