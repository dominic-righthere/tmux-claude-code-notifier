#!/usr/bin/env bash
# Best-effort scan for visible Claude panes that started before hooks loaded.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
ensure_data_dirs

ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
NOW="$(date +%s)"
REGISTERED=0

while IFS='|' read -r sess win wname title; do
    [ "$sess" = "agent-monitor" ] && continue
    [[ "$title" =~ ^[✳⠂⠐⠄⠆⠇⠋⠙⠸⠴⠦⠧⠏⠛]\ .+ ]] || [[ "$title" =~ Claude\ Code ]] || continue
    key="$(agent_key claude "$sess" "$win")"
    [ -f "${ACTIVE_DIR}/${key}" ] && continue
    [ -f "${NOTIF_DIR}/${key}" ] && continue
    write_state_file "$ACTIVE_DIR" "$key" "claude" "$sess" "$win" "$wname" "idle" "Idle" "$NOW"
    REGISTERED=$(( REGISTERED + 1 ))
done < <(tmux list-panes -a -F "#{session_name}|#{window_index}|#{window_name}|#{pane_title}" 2>/dev/null)

printf '%d' "$REGISTERED"
