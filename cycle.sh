#!/usr/bin/env bash
# Claude Code Notifier — cycle through Claude Code sessions
# Cycles through all tmux panes running Claude Code
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
CYCLE_FILE="${DATA_DIR}/last_cycle"
mkdir -p "$DATA_DIR"

# Discover Claude Code sessions by pane_current_command (shows version like 2.1.29)
SESSIONS=()
while IFS='|' read -r sess win cmd; do
    # Match version pattern X.Y.Z (Claude Code shows its version as the command)
    [[ "$cmd" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    SESSIONS+=("${sess}:${win}")
done < <(tmux list-panes -a -F "#{session_name}|#{window_index}|#{pane_current_command}" 2>/dev/null)

# Exit silently if no Claude sessions found
[ "${#SESSIONS[@]}" -eq 0 ] && exit 0

# Find the next session after the last visited one (or wrap to first)
CURRENT="$(cat "$CYCLE_FILE" 2>/dev/null || echo "")"
NEXT=""
FOUND=0

for s in "${SESSIONS[@]}"; do
    if [ "$FOUND" -eq 1 ]; then
        NEXT="$s"
        break
    fi
    [ "$s" = "$CURRENT" ] && FOUND=1
done

# Wrap around to first if we hit the end or current not found
[ -z "$NEXT" ] && NEXT="${SESSIONS[0]}"

# Save the new position and switch
printf '%s' "$NEXT" > "$CYCLE_FILE"

# Extract session and window from "sess:win" format
SESS="${NEXT%%:*}"
WIN="${NEXT#*:}"

tmux switch-client -t "$SESS" 2>/dev/null || true
tmux select-window -t "${SESS}:${WIN}" 2>/dev/null || true
