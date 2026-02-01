#!/usr/bin/env bash
# Claude Code Notifier — quick-jump to most recent notification
# Finds the notification with the newest TIMESTAMP, switches to that window,
# and clears the notification. Next press cycles to the next one.
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
NOTIF_DIR="${DATA_DIR}/notifications"

[ -d "$NOTIF_DIR" ] || exit 0

# Find the notification file with the highest TIMESTAMP
BEST_FILE=""
BEST_TS=0

for f in "$NOTIF_DIR"/*; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in
            TIMESTAMP=*)
                ts="${line#TIMESTAMP=}"
                if [ "$ts" -gt "$BEST_TS" ] 2>/dev/null; then
                    BEST_TS="$ts"
                    BEST_FILE="$f"
                fi
                break
                ;;
        esac
    done < "$f"
done

[ -z "$BEST_FILE" ] && exit 0

# Parse session and window from the best match
_sess="" _win=""
while IFS= read -r line; do
    case "$line" in
        SESSION=*) _sess="${line#SESSION=}" ;;
        WINDOW=*) _win="${line#WINDOW=}" ;;
    esac
done < "$BEST_FILE"

[ -z "$_sess" ] && exit 0
[ -z "$_win" ] && exit 0

# Clear the notification
rm -f "$BEST_FILE"

# Switch to that session and window
tmux switch-client -t "$_sess" 2>/dev/null || true
tmux select-window -t "${_sess}:${_win}" 2>/dev/null || true
