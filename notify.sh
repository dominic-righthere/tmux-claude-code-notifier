#!/usr/bin/env bash
# Claude Code hook handler — tracks working/finished/waiting state in tmux
# Reads hook JSON from stdin, manages files in ~/.local/share/claude-notifier/
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
MSG_ID_DIR="${DATA_DIR}/telegram_msg_ids"
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
TOOL_INPUT="$(extract_json_value "$INPUT" "tool_input")"

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

SAFE_SESSION="$(sanitize_key "$SESSION")"
KEY="${SAFE_SESSION}_${WINDOW}"

NOW="$(date +%s)"

write_file() {
    local dir="$1" type="$2" message="$3"
    write_state_file "$dir" "$KEY" "$SESSION" "$WINDOW" "$WINDOW_NAME" "$type" "$message" "$NOW"
}


case "$EVENT" in
    SessionStart)
        # New Claude Code session — register immediately
        write_file "$ACTIVE_DIR" "working" "Starting..."
        log_event src hook event SessionStart session "$SESSION" window "$WINDOW"
        ;;
    SessionEnd)
        # Session closed — clean up all state
        rm -f "${ACTIVE_DIR}/${KEY}" "${NOTIF_DIR}/${KEY}" "${MSG_ID_DIR}/${KEY}"
        log_event src hook event SessionEnd session "$SESSION" window "$WINDOW"
        ;;
    UserPromptSubmit)
        # Claude is working — mark active, clear notification + msg_id
        write_file "$ACTIVE_DIR" "working" "Working..."
        rm -f "${NOTIF_DIR}/${KEY}" "${MSG_ID_DIR}/${KEY}"
        log_event src hook event UserPromptSubmit session "$SESSION" window "$WINDOW"
        ;;
    PreToolUse)
        # Live tool activity — show what Claude is doing instead of "Working..."
        tool_label="${TOOL_NAME:-tool}"
        write_file "$ACTIVE_DIR" "working" "${tool_label}..."
        log_event src hook event PreToolUse session "$SESSION" window "$WINDOW" tool "$TOOL_NAME"
        ;;
    Stop)
        # Claude finished — mark as idle (keep in active dir for visibility)
        write_file "$ACTIVE_DIR" "idle" "Idle"
        # Don't overwrite a waiting notification (permission request / notification)
        EXISTING_TYPE="$(read_state_field "${NOTIF_DIR}/${KEY}" "TYPE" 2>/dev/null)" || EXISTING_TYPE=""
        if [ "$EXISTING_TYPE" = "waiting" ]; then
            # Keep the existing waiting notification, just ring bell
            printf '\a'
            log_event src hook event Stop session "$SESSION" window "$WINDOW" message "skipped (waiting exists)"
        else
            write_file "$NOTIF_DIR" "finished" "Finished"
            printf '\a'
            "${SCRIPT_DIR}/dispatch.sh" "finished" "$SESSION" "$WINDOW" "Finished" &
            log_event src hook event Stop session "$SESSION" window "$WINDOW" type finished
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
        "${SCRIPT_DIR}/dispatch.sh" "waiting" "$SESSION" "$WINDOW" "$MSG" &
        log_event src hook event Notification session "$SESSION" window "$WINDOW" message "$MSG"
        ;;
    PermissionRequest)
        # Permission needed — record as waiting with tool name
        local_msg="Waiting"
        if [ -n "$TOOL_NAME" ]; then
            local_msg="Waiting: ${TOOL_NAME}"
        fi
        write_file "$NOTIF_DIR" "waiting" "$local_msg"
        printf '\a'
        "${SCRIPT_DIR}/dispatch.sh" "waiting" "$SESSION" "$WINDOW" "$local_msg" "$TOOL_NAME" &
        log_event src hook event PermissionRequest session "$SESSION" window "$WINDOW" tool "$TOOL_NAME"
        ;;
esac

# Force immediate tmux status bar refresh
tmux refresh-client -S 2>/dev/null || true

exit 0
