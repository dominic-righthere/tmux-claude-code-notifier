#!/usr/bin/env bash
# Link all active agent windows into one navigable tmux session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

MONITOR="agent-monitor"
ACTIVE_DIR="${DATA_DIR}/active"
REFRESH_ONLY="${1:-}"

entries=()
for f in "${ACTIVE_DIR}"/*; do
    [ -f "$f" ] || continue
    agent="$(read_state_field "$f" AGENT 2>/dev/null || printf claude)"
    sess="$(read_state_field "$f" SESSION 2>/dev/null || true)"
    win="$(read_state_field "$f" WINDOW 2>/dev/null || true)"
    [ -n "$sess" ] || continue
    [ -n "$win" ] || continue
    [ "$sess" = "$MONITOR" ] && continue
    tmux list-windows -t "$sess" -F "#{window_index}" 2>/dev/null | grep -qx "$win" || continue
    entries+=("${agent}|${sess}|${win}")
done

count="${#entries[@]}"
if [ "$count" -eq 0 ]; then
    tmux display-message "agent-monitor: no active agent sessions found" 2>/dev/null || printf 'agent-monitor: no active agent sessions found\n'
    exit 0
fi

tmux kill-session -t "$MONITOR" 2>/dev/null || true
tmux new-session -d -s "$MONITOR" -n "__placeholder__"
placeholder_idx="$(tmux display-message -t "${MONITOR}:__placeholder__" -p '#{window_index}' 2>/dev/null || echo '')"
tmux set-option -t "$MONITOR" automatic-rename off 2>/dev/null || true

seen_names=" "
linked=0
for entry in "${entries[@]}"; do
    IFS='|' read -r agent sess win <<< "$entry"
    tmux link-window -s "${sess}:${win}" -t "${MONITOR}:" 2>/dev/null || continue
    new_idx="$(tmux list-windows -t "$MONITOR" -F "#{window_index}" | sort -n | tail -1)"
    label="$(agent_label "$agent")"
    base="${label}-${sess}"
    if [[ "$seen_names" == *" ${base} "* ]]; then
        wname="${base}:${win}"
    else
        wname="$base"
        seen_names="${seen_names}${base} "
    fi
    tmux rename-window -t "${MONITOR}:${new_idx}" "$wname" 2>/dev/null || true
    tmux set-window-option -t "${MONITOR}:${new_idx}" automatic-rename off 2>/dev/null || true
    linked=$(( linked + 1 ))
done

[ -n "${placeholder_idx:-}" ] && tmux kill-window -t "${MONITOR}:${placeholder_idx}" 2>/dev/null || true

if [ "$linked" -eq 0 ]; then
    tmux kill-session -t "$MONITOR" 2>/dev/null || true
    tmux display-message "agent-monitor: failed to link any windows" 2>/dev/null || printf 'agent-monitor: failed to link any windows\n'
    exit 1
fi

[ "$REFRESH_ONLY" = "refresh" ] && exit 0

current="$(tmux display-message -p '#S' 2>/dev/null || true)"
if [ -n "${TMUX:-}" ]; then
    [ "$current" != "$MONITOR" ] && tmux switch-client -t "$MONITOR"
else
    tmux attach-session -t "$MONITOR"
fi
