#!/usr/bin/env bash
# Agent Notifier hook handler. Reads hook JSON on stdin and updates tmux-local state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_data_dirs
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .event // .type // empty' 2>/dev/null)" || exit 0
[ -n "$EVENT" ] || exit 0

AGENT="$(printf '%s' "$INPUT" | jq -r '.agent // .provider // empty' 2>/dev/null)"
AGENT="${AGENT:-${AGENT_NOTIFIER_AGENT:-claude}}"
AGENT="$(printf '%s' "$AGENT" | tr '[:upper:]' '[:lower:]')"

MSG="$(printf '%s' "$INPUT" | jq -r '.message // .text // empty' 2>/dev/null)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // .tool // .tool_call.name // empty' 2>/dev/null)"
TOOL_INPUT="$(printf '%s' "$INPUT" | jq -r '(.tool_input // .toolInput // .tool_call.arguments // empty) | if type == "object" or type == "array" then tostring else . end' 2>/dev/null)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // .conversation_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // .working_directory // .worktree // empty' 2>/dev/null)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)"
PERMISSION_MODE="$(printf '%s' "$INPUT" | jq -r '.permission_mode // .permissionMode // empty' 2>/dev/null)"

[ -n "${TMUX:-}" ] || exit 0

PANE_TARGET="${TMUX_PANE:-%0}"
_tmux_info="$(tmux display-message -t "$PANE_TARGET" -p '#{session_name}|#{window_index}|#{window_name}' 2>/dev/null)" || exit 0
IFS='|' read -r SESSION WINDOW WINDOW_NAME <<< "$_tmux_info"
[ -n "${SESSION:-}" ] || exit 0
[ -n "${WINDOW:-}" ] || exit 0

KEY="$(agent_key "$AGENT" "$SESSION" "$WINDOW")"
NOW="$(date +%s)"

write_file() {
    local dir="$1" type="$2" message="$3"
    write_state_file "$dir" "$KEY" "$AGENT" "$SESSION" "$WINDOW" "$WINDOW_NAME" "$type" "$message" "$NOW" "$SESSION_ID" "$CWD"
}

clear_notification() {
    rm -f "${NOTIF_DIR}/${KEY}"
}

refresh_monitor() {
    [ -f "${DATA_DIR}/agent-monitor.disabled" ] && return 0
    if tmux has-session -t agent-monitor 2>/dev/null; then
        "${SCRIPT_DIR}/agent-monitor.sh" refresh &
    fi
}

notify_locally() {
    # Hook stdout can be interpreted by the host agent as control output.
    # Keep this handler silent and let tmux status/dashboard surface state.
    :
}

case "$EVENT" in
    SessionStart|session_start)
        write_file "$ACTIVE_DIR" "idle" "Idle"
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" extra "sid=$SESSION_ID cwd=$CWD"
        refresh_monitor
        ;;
    SessionEnd|session_shutdown)
        rm -f "${ACTIVE_DIR}/${KEY}" "${NOTIF_DIR}/${KEY}"
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" extra "sid=$SESSION_ID"
        refresh_monitor
        ;;
    UserPromptSubmit|user_prompt_submit|before_agent_start|agent_start|turn_start)
        write_file "$ACTIVE_DIR" "working" "Working..."
        clear_notification
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" text "$PROMPT" extra "sid=$SESSION_ID cwd=$CWD"
        ;;
    PreToolUse|pre_tool_use|tool_execution_start|tool_call)
        tool_label="${TOOL_NAME:-tool}"
        write_file "$ACTIVE_DIR" "working" "$(short_message "${tool_label}..." 80)"
        clear_notification
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" tool "$TOOL_NAME" text "$TOOL_INPUT" extra "sid=$SESSION_ID cwd=$CWD"
        ;;
    PostToolUse|post_tool_use|tool_execution_end|tool_execution_update|turn_end|message_end)
        write_file "$ACTIVE_DIR" "working" "Working..."
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" tool "$TOOL_NAME" extra "sid=$SESSION_ID cwd=$CWD"
        ;;
    Stop|stop|agent_end)
        write_file "$ACTIVE_DIR" "idle" "Idle"
        write_file "$NOTIF_DIR" "finished" "Finished"
        notify_locally
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" type finished message "$MSG" extra "sid=$SESSION_ID cwd=$CWD"
        refresh_monitor
        ;;
    Notification|notification|PermissionRequest|permission_request|waiting)
        if [ "$EVENT" = "PermissionRequest" ] || [ "$EVENT" = "permission_request" ] || [ "$EVENT" = "waiting" ]; then
            MSG="Waiting"
            [ -n "$TOOL_NAME" ] && MSG="Waiting: ${TOOL_NAME}"
        fi
        [ -n "$MSG" ] || MSG="Notification"
        write_file "$NOTIF_DIR" "waiting" "$(short_message "$MSG" 80)"
        notify_locally
        log_event src hook event "$EVENT" agent "$AGENT" session "$SESSION" window "$WINDOW" tool "$TOOL_NAME" message "$MSG" extra "sid=$SESSION_ID cwd=$CWD mode=$PERMISSION_MODE"
        refresh_monitor
        ;;
esac

tmux refresh-client -S 2>/dev/null || true
exit 0
