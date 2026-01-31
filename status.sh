#!/usr/bin/env bash
# Claude Code Notifier — status bar widget
# Outputs "● N" if there are notifications, empty string otherwise
NOTIF_DIR="${HOME}/.local/share/claude-notifier/notifications"

[ -d "$NOTIF_DIR" ] || exit 0

COUNT=0
for f in "$NOTIF_DIR"/*; do
    [ -f "$f" ] && COUNT=$(( COUNT + 1 ))
done

if [ "$COUNT" -gt 0 ]; then
    printf '● %d ' "$COUNT"
fi
