#!/usr/bin/env bash
# Claude Code Notifier — quick-jump to most recent notification
# Finds the notification with the newest TIMESTAMP, switches to that window,
# and clears the notification. Skips the current window unless it's the only one.
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
NOTIF_DIR="${DATA_DIR}/notifications"

[ -d "$NOTIF_DIR" ] || exit 0

# Get current session:window so we can skip it
CURRENT="$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null)" || CURRENT=""

# Collect all notification candidates as "timestamp|filepath|session|window"
CANDIDATES=()
for f in "$NOTIF_DIR"/*; do
    [ -f "$f" ] || continue
    local_ts="" local_sess="" local_win=""
    while IFS= read -r line; do
        case "$line" in
            TIMESTAMP=*) local_ts="${line#TIMESTAMP=}" ;;
            SESSION=*)   local_sess="${line#SESSION=}" ;;
            WINDOW=*)    local_win="${line#WINDOW=}" ;;
        esac
    done < "$f"
    [ -z "$local_ts" ] && continue
    [ -z "$local_sess" ] && continue
    [ -z "$local_win" ] && continue
    CANDIDATES+=("${local_ts}|${f}|${local_sess}|${local_win}")
done

[ "${#CANDIDATES[@]}" -eq 0 ] && exit 0

# Sort descending by timestamp
IFS=$'\n' SORTED=($(printf '%s\n' "${CANDIDATES[@]}" | sort -t'|' -k1 -rn)); unset IFS

# Iterate: skip entries matching current window (unless it's the only candidate)
for entry in "${SORTED[@]}"; do
    IFS='|' read -r _ts _file _sess _win <<< "$entry"
    if [ "${#SORTED[@]}" -gt 1 ] && [ "${_sess}:${_win}" = "$CURRENT" ]; then
        continue
    fi
    # Found our target — clear notification and jump
    rm -f "$_file"
    tmux switch-client -t "$_sess" 2>/dev/null || true
    tmux select-window -t "${_sess}:${_win}" 2>/dev/null || true
    exit 0
done

# All candidates matched current window (shouldn't happen, but handle gracefully)
# Jump to the most recent one anyway
IFS='|' read -r _ts _file _sess _win <<< "${SORTED[0]}"
rm -f "$_file"
tmux switch-client -t "$_sess" 2>/dev/null || true
tmux select-window -t "${_sess}:${_win}" 2>/dev/null || true
