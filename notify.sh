#!/usr/bin/env bash
# Claude Code hook handler — tracks working/finished/waiting state in tmux
# Reads hook JSON from stdin, manages files in ~/.local/share/claude-notifier/
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"

# Read JSON from stdin
INPUT="$(cat)"

# Parse JSON fields with pure bash (avoids python3 spawn overhead ~50-80ms)
# JSON format: {"hook_event_name":"X","message":"Y","tool_name":"Z"}
extract_json_value() {
    local json="$1" key="$2"
    # Replace \" with placeholder, extract, then restore
    local cleaned="${json//\\\"/@@Q@@}"
    local pattern="\"${key}\":\"([^\"]*)\""
    if [[ "$cleaned" =~ $pattern ]]; then
        local val="${BASH_REMATCH[1]}"
        printf '%s' "${val//@@Q@@/\"}"
    fi
}

EVENT="$(extract_json_value "$INPUT" "hook_event_name")"
MSG="$(extract_json_value "$INPUT" "message")"
TOOL_NAME="$(extract_json_value "$INPUT" "tool_name")"

# Exit if we couldn't parse the event
[ -z "$EVENT" ] && exit 0

# Get tmux context — if not in tmux, exit silently
if [ -z "${TMUX:-}" ]; then
    exit 0
fi

# Use TMUX_PANE to identify Claude's pane, so we always resolve the correct
# session/window even when the user is viewing a different window.
PANE_TARGET="${TMUX_PANE:-%0}"
_tmux_info="$(tmux display-message -t "$PANE_TARGET" -p '#{session_name}|#{window_index}|#{window_name}' 2>/dev/null)" || exit 0
IFS='|' read -r SESSION WINDOW WINDOW_NAME <<< "$_tmux_info"

[ -z "$SESSION" ] && exit 0
[ -z "$WINDOW" ] && exit 0

# Sanitize session name for filename (replace / and spaces with _)
SAFE_SESSION="$(printf '%s' "$SESSION" | tr '/ ' '__')"
KEY="${SAFE_SESSION}_${WINDOW}"

NOW="$(date +%s)"

write_file() {
    local dir="$1" type="$2" message="$3"
    # Pure bash file write (avoids python3 spawn overhead ~50-80ms)
    printf 'SESSION=%s\nWINDOW=%s\nWINDOW_NAME=%s\nMESSAGE=%s\nTYPE=%s\nTIMESTAMP=%s\n' \
        "$SESSION" "$WINDOW" "$WINDOW_NAME" "$message" "$type" "$NOW" \
        > "${dir}/${KEY}"
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
        # Claude finished — mark as idle (keep in active dir for visibility)
        write_file "$ACTIVE_DIR" "idle" "Idle"
        # Don't overwrite a waiting notification (permission request / notification)
        EXISTING_TYPE="$(read_type "${NOTIF_DIR}/${KEY}" 2>/dev/null)" || EXISTING_TYPE=""
        if [ "$EXISTING_TYPE" = "waiting" ]; then
            # Keep the existing waiting notification, just ring bell
            printf '\a'
        else
            write_file "$NOTIF_DIR" "finished" "Finished"
            printf '\a'
            "${SCRIPT_DIR}/telegram-send.sh" "finished" "$SESSION" "$WINDOW" "Finished" &
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
        "${SCRIPT_DIR}/telegram-send.sh" "waiting" "$SESSION" "$WINDOW" "$MSG" &
        ;;
    PermissionRequest)
        # Permission needed — record as waiting with tool name
        local_msg="Waiting"
        if [ -n "$TOOL_NAME" ]; then
            local_msg="Waiting: ${TOOL_NAME}"
        fi
        write_file "$NOTIF_DIR" "waiting" "$local_msg"
        printf '\a'
        "${SCRIPT_DIR}/telegram-send.sh" "waiting" "$SESSION" "$WINDOW" "$local_msg" "$TOOL_NAME" &
        ;;
esac

# Force immediate tmux status bar refresh
tmux refresh-client -S 2>/dev/null || true

exit 0
