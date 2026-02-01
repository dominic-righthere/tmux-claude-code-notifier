#!/usr/bin/env bash
# Claude Code hook handler — tracks working/finished/waiting state in tmux
# Reads hook JSON from stdin, manages files in ~/.local/share/claude-notifier/
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"

# Read JSON from stdin
INPUT="$(cat)"

# Parse JSON fields with python3 (available on macOS, handles escapes correctly)
eval "$(printf '%s' "$INPUT" | python3 -c "
import json, sys, shlex
data = json.load(sys.stdin)
print('EVENT=' + shlex.quote(data.get('hook_event_name', '')))
print('MSG=' + shlex.quote(data.get('message', '')))
print('TOOL_NAME=' + shlex.quote(data.get('tool_name', '')))
" 2>/dev/null)" || exit 0

# Get tmux context — if not in tmux, exit silently
if [ -z "${TMUX:-}" ]; then
    exit 0
fi

# Use TMUX_PANE to identify Claude's pane, so we always resolve the correct
# session/window even when the user is viewing a different window.
PANE_TARGET="${TMUX_PANE:-%0}"
SESSION="$(tmux display-message -t "$PANE_TARGET" -p '#{session_name}' 2>/dev/null)" || exit 0
WINDOW="$(tmux display-message -t "$PANE_TARGET" -p '#{window_index}' 2>/dev/null)" || exit 0
WINDOW_NAME="$(tmux display-message -t "$PANE_TARGET" -p '#{window_name}' 2>/dev/null)" || exit 0

[ -z "$SESSION" ] && exit 0
[ -z "$WINDOW" ] && exit 0

# Sanitize session name for filename (replace / and spaces with _)
SAFE_SESSION="$(printf '%s' "$SESSION" | tr '/ ' '__')"
KEY="${SAFE_SESSION}_${WINDOW}"

NOW="$(date +%s)"

write_file() {
    local dir="$1" type="$2" message="$3"
    python3 -c "
import sys
fields = {
    'SESSION': sys.argv[1],
    'WINDOW': sys.argv[2],
    'WINDOW_NAME': sys.argv[3],
    'MESSAGE': sys.argv[4],
    'TYPE': sys.argv[5],
    'TIMESTAMP': sys.argv[6],
}
with open(sys.argv[7], 'w') as f:
    for k, v in fields.items():
        f.write(f'{k}={v}\n')
" "$SESSION" "$WINDOW" "$WINDOW_NAME" "$message" "$type" "$NOW" "${dir}/${KEY}"
}

read_type() {
    local file="$1"
    [ -f "$file" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            TYPE=*) printf '%s' "${line#TYPE=}"; return 0 ;;
        esac
    done < "$file"
    return 1
}

case "$EVENT" in
    UserPromptSubmit)
        # Claude is working — mark active, clear any existing notification
        write_file "$ACTIVE_DIR" "working" "Working..."
        rm -f "${NOTIF_DIR}/${KEY}"
        ;;
    Stop)
        # Claude finished — remove active marker
        rm -f "${ACTIVE_DIR}/${KEY}"
        # Don't overwrite a waiting notification (permission request / notification)
        EXISTING_TYPE="$(read_type "${NOTIF_DIR}/${KEY}" 2>/dev/null)" || EXISTING_TYPE=""
        if [ "$EXISTING_TYPE" = "waiting" ]; then
            # Keep the existing waiting notification, just ring bell
            printf '\a'
        else
            write_file "$NOTIF_DIR" "finished" "Finished"
            printf '\a'
        fi
        ;;
    Notification)
        [ -z "$MSG" ] && MSG="Notification"
        # Truncate long messages
        if [ "${#MSG}" -gt 40 ]; then
            MSG="${MSG:0:37}..."
        fi
        write_file "$NOTIF_DIR" "waiting" "$MSG"
        printf '\a'
        ;;
    PermissionRequest)
        # Permission needed — record as waiting with tool name
        local_msg="Waiting"
        if [ -n "$TOOL_NAME" ]; then
            local_msg="Waiting: ${TOOL_NAME}"
        fi
        write_file "$NOTIF_DIR" "waiting" "$local_msg"
        printf '\a'
        ;;
esac

exit 0
