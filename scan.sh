#!/usr/bin/env bash
# Claude Code Notifier — scan for untracked Claude Code sessions
# Discovers all tmux panes running Claude Code and registers untracked ones as idle
set -uo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"

NOW="$(date +%s)"
REGISTERED=0

while IFS='|' read -r sess win wname cmd; do
    # Match version pattern X.Y.Z (Claude Code shows its version as the command)
    [[ "$cmd" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue

    # Build file key (same format as notify.sh)
    safe_sess="$(printf '%s' "$sess" | tr '/ ' '__')"
    key="${safe_sess}_${win}"

    # Skip if already tracked (active or notification)
    [ -f "${ACTIVE_DIR}/${key}" ] && continue
    [ -f "${NOTIF_DIR}/${key}" ] && continue

    # Register as idle
    printf 'SESSION=%s\nWINDOW=%s\nWINDOW_NAME=%s\nMESSAGE=%s\nTYPE=%s\nTIMESTAMP=%s\n' \
        "$sess" "$win" "$wname" "Idle" "idle" "$NOW" \
        > "${ACTIVE_DIR}/${key}"
    REGISTERED=$(( REGISTERED + 1 ))
done < <(tmux list-panes -a -F "#{session_name}|#{window_index}|#{window_name}|#{pane_current_command}" 2>/dev/null)

printf '%d' "$REGISTERED"
