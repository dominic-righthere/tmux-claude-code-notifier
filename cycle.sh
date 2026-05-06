#!/usr/bin/env bash
# Agent Notifier cycle through tracked agent windows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_data_dirs
CYCLE_FILE="${DATA_DIR}/last_cycle"
ACTIVE_DIR="${DATA_DIR}/active"

SESSIONS=()
for f in "$ACTIVE_DIR"/*; do
    [ -f "$f" ] || continue
    sess="$(read_state_field "$f" SESSION 2>/dev/null || true)"
    win="$(read_state_field "$f" WINDOW 2>/dev/null || true)"
    [ -n "$sess" ] || continue
    [ -n "$win" ] || continue
    [ "$sess" = "agent-monitor" ] && continue
    tmux list-windows -t "$sess" -F "#{window_index}" 2>/dev/null | grep -qx "$win" || continue
    item="${sess}:${win}"
    case " ${SESSIONS[*]} " in
        *" ${item} "*) ;;
        *) SESSIONS+=("$item") ;;
    esac
done

[ "${#SESSIONS[@]}" -eq 0 ] && exit 0

CURRENT="$(cat "$CYCLE_FILE" 2>/dev/null || true)"
NEXT=""
FOUND=0
for s in "${SESSIONS[@]}"; do
    if [ "$FOUND" -eq 1 ]; then
        NEXT="$s"
        break
    fi
    [ "$s" = "$CURRENT" ] && FOUND=1
done
[ -n "$NEXT" ] || NEXT="${SESSIONS[0]}"

printf '%s' "$NEXT" > "$CYCLE_FILE"
SESS="${NEXT%%:*}"
WIN="${NEXT#*:}"
tmux switch-client -t "$SESS" 2>/dev/null || true
tmux select-window -t "${SESS}:${WIN}" 2>/dev/null || true
