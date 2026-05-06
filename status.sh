#!/usr/bin/env bash
# Agent Notifier status bar widget.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_data_dirs
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"

STATUS2_PERSISTENT=1
[ -f "${DATA_DIR}/status2.disabled" ] && STATUS2_PERSISTENT=0

NOW="$(date +%s)"
WORKING=0
IDLE=0
WAITING=0
FINISHED=0

count_state_file() {
    local file="$1" kind="$2"
    local _type="" _ts=""
    while IFS= read -r line; do
        case "$line" in
            TYPE=*) _type="${line#TYPE=}" ;;
            TIMESTAMP=*) _ts="${line#TIMESTAMP=}" ;;
        esac
    done < "$file"
    if [ -n "$_ts" ]; then
        _age=$(( NOW - _ts ))
        [ "$_type" = "working" ] && [ "$_age" -gt 3600 ] && return 0
        [ "$_type" = "idle" ] && [ "$_age" -gt 43200 ] && return 0
        [ "$_type" = "finished" ] && [ "$_age" -gt 21600 ] && return 0
        [ "$_type" = "waiting" ] && [ "$_age" -gt 86400 ] && return 0
    fi
    if [ "$kind" = "active" ]; then
        case "$_type" in
            idle) IDLE=$(( IDLE + 1 )) ;;
            *) WORKING=$(( WORKING + 1 )) ;;
        esac
    else
        case "$_type" in
            waiting) WAITING=$(( WAITING + 1 )) ;;
            *) FINISHED=$(( FINISHED + 1 )) ;;
        esac
    fi
}

if [ -d "$ACTIVE_DIR" ]; then
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] && count_state_file "$f" active
    done
fi

if [ -d "$NOTIF_DIR" ]; then
    for f in "$NOTIF_DIR"/*; do
        [ -f "$f" ] && count_state_file "$f" notification
    done
fi

TOTAL=$(( WORKING + IDLE + WAITING + FINISHED ))
OUTPUT=""
[ "$WORKING" -gt 0 ] && OUTPUT="${OUTPUT}⟳${WORKING} "
[ "$WAITING" -gt 0 ] && OUTPUT="${OUTPUT}⏳${WAITING} "
[ "$FINISHED" -gt 0 ] && OUTPUT="${OUTPUT}●${FINISHED} "
[ "$IDLE" -gt 0 ] && OUTPUT="${OUTPUT}○${IDLE} "

printf '%s' "$OUTPUT"

DETAIL=""
if [ "$WAITING" -gt 0 ] || [ "$FINISHED" -gt 0 ]; then
    for f in "$NOTIF_DIR"/*; do
        [ -f "$f" ] || continue
        _agent="$(read_state_field "$f" AGENT 2>/dev/null || printf claude)"
        _sess="$(read_state_field "$f" SESSION 2>/dev/null || true)"
        _win="$(read_state_field "$f" WINDOW 2>/dev/null || true)"
        _msg="$(read_state_field "$f" MESSAGE 2>/dev/null || true)"
        _type="$(read_state_field "$f" TYPE 2>/dev/null || true)"
        [ -n "$_sess" ] || continue
        label="$(agent_label "$_agent")"
        if [ "$_type" = "waiting" ]; then
            _msg="${_msg#Waiting: }"
            _msg="${_msg#Waiting}"
            [ -n "$_msg" ] && entry="⏳ ${label} ${_sess}:${_win} - Waiting: ${_msg}" || entry="⏳ ${label} ${_sess}:${_win} - Waiting"
        else
            entry="● ${label} ${_sess}:${_win} - Task complete"
        fi
        [ -n "$DETAIL" ] && DETAIL="${DETAIL} | ${entry}" || DETAIL=" ${entry}"
    done
fi

if [ "$STATUS2_PERSISTENT" -eq 1 ] && [ "$TOTAL" -gt 0 ]; then
    tmux set -g status 2 2>/dev/null
    tmux set -g 'status-format[1]' "#[align=left]${OUTPUT}${DETAIL}" 2>/dev/null
elif [ -n "$DETAIL" ]; then
    tmux set -g status 2 2>/dev/null
    tmux set -g 'status-format[1]' "#[align=left]${OUTPUT}${DETAIL}" 2>/dev/null
else
    tmux set -g status on 2>/dev/null || true
fi
