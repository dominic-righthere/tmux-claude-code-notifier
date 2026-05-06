#!/usr/bin/env bash
# Agent Notifier auto-clear on tmux window switch.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NOTIF_DIR="${DATA_DIR}/notifications"
[ -d "$NOTIF_DIR" ] || exit 0

SESSION="${1:-}"
WINDOW="${2:-}"
[ -n "$SESSION" ] || exit 0
[ -n "$WINDOW" ] || exit 0

for f in "$NOTIF_DIR"/*; do
    [ -f "$f" ] || continue
    _sess="$(read_state_field "$f" SESSION 2>/dev/null || true)"
    _win="$(read_state_field "$f" WINDOW 2>/dev/null || true)"
    [ "$_sess" = "$SESSION" ] && [ "$_win" = "$WINDOW" ] && rm -f "$f"
done

exit 0
