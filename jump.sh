#!/usr/bin/env bash
# Agent Notifier quick-jump to the most recent notification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NOTIF_DIR="${DATA_DIR}/notifications"
[ -d "$NOTIF_DIR" ] || exit 0

CURRENT="$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null)" || CURRENT=""
CANDIDATES=()

for f in "$NOTIF_DIR"/*; do
    [ -f "$f" ] || continue
    local_ts="$(read_state_field "$f" TIMESTAMP 2>/dev/null || true)"
    local_sess="$(read_state_field "$f" SESSION 2>/dev/null || true)"
    local_win="$(read_state_field "$f" WINDOW 2>/dev/null || true)"
    [ -n "$local_ts" ] || continue
    [ -n "$local_sess" ] || continue
    [ -n "$local_win" ] || continue
    CANDIDATES+=("${local_ts}|${f}|${local_sess}|${local_win}")
done

[ "${#CANDIDATES[@]}" -eq 0 ] && exit 0

IFS=$'\n' SORTED=($(printf '%s\n' "${CANDIDATES[@]}" | sort -t'|' -k1 -rn)); unset IFS

for entry in "${SORTED[@]}"; do
    IFS='|' read -r _ts _file _sess _win <<< "$entry"
    if [ "${#SORTED[@]}" -gt 1 ] && [ "${_sess}:${_win}" = "$CURRENT" ]; then
        continue
    fi
    rm -f "$_file"
    tmux switch-client -t "$_sess" 2>/dev/null || true
    tmux select-window -t "${_sess}:${_win}" 2>/dev/null || true
    exit 0
done

IFS='|' read -r _ts _file _sess _win <<< "${SORTED[0]}"
rm -f "$_file"
tmux switch-client -t "$_sess" 2>/dev/null || true
tmux select-window -t "${_sess}:${_win}" 2>/dev/null || true
