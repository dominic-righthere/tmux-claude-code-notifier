#!/usr/bin/env bash
# Claude Code Notifier — scan for untracked Claude Code sessions
# Discovers all tmux panes running Claude Code and registers untracked ones as idle
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"

NOW="$(date +%s)"
REGISTERED=0

while IFS='|' read -r sess win wname title; do
    # Skip the cc-monitor session — its linked panes have CC titles but are not real sessions
    [ "$sess" = "cc-monitor" ] && continue

    # Claude Code sets the pane title with a spinner prefix (✳ ⠂ ⠐ ⠄ etc.)
    # followed by a task name or "Claude Code". Match either form.
    # Fallback: also match old-style version number (X.Y.Z) as pane command.
    [[ "$title" =~ ^[✳⠂⠐⠄⠆⠇⠋⠙⠸⠴⠦⠧⠏⠛]\ .+ ]] || \
    [[ "$title" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue

    # Build file key (same format as notify.sh)
    safe_sess="$(sanitize_key "$sess")"
    key="${safe_sess}_${win}"

    # Skip if already tracked (active or notification)
    [ -f "${ACTIVE_DIR}/${key}" ] && continue
    [ -f "${NOTIF_DIR}/${key}" ] && continue

    # Register as idle
    write_state_file "$ACTIVE_DIR" "$key" "$sess" "$win" "$wname" "idle" "Idle" "$NOW"
    REGISTERED=$(( REGISTERED + 1 ))
done < <(tmux list-panes -a -F "#{session_name}|#{window_index}|#{window_name}|#{pane_title}" 2>/dev/null)

printf '%d' "$REGISTERED"
