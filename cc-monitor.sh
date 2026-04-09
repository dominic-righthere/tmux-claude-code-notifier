#!/usr/bin/env bash
# cc-monitor.sh — Link all active Claude Code windows into a single navigable session
#
# Creates (or refreshes) a "cc-monitor" tmux session where every tracked
# Claude Code pane is linked in as its own window. The windows are fully
# interactive — you can type into any pane from the monitor session.
# Killing the monitor session never affects the original sessions.
#
# Usage: ./cc-monitor.sh          (build and switch into cc-monitor)
#        ./cc-monitor.sh refresh  (rebuild without switching)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

MONITOR="cc-monitor"
ACTIVE_DIR="${HOME}/.local/share/claude-notifier/active"
REFRESH_ONLY="${1:-}"

# ── Collect valid active CC windows ──────────────────────────────────────────

entries=()   # "SESSION|WINDOW" pairs (indexed array, bash 3.2 safe)

for f in "${ACTIVE_DIR}"/*; do
    [ -f "$f" ] || continue

    sess="$(read_state_field "$f" SESSION)" || continue
    win="$(read_state_field "$f" WINDOW)"   || continue
    [ -z "${sess:-}" ] || [ -z "${win:-}" ] && continue

    # Verify the window still exists in tmux
    tmux list-windows -t "$sess" -F "#{window_index}" 2>/dev/null \
        | grep -qx "$win" || continue

    # Skip the monitor session itself (its linked panes look like CC panes to scan.sh)
    [ "$sess" = "$MONITOR" ] && continue

    entries+=("${sess}|${win}")
done

count="${#entries[@]}"

if [ "$count" -eq 0 ]; then
    tmux display-message "cc-monitor: no active Claude Code sessions found" 2>/dev/null \
        || printf 'cc-monitor: no active Claude Code sessions found\n'
    exit 0
fi

# ── Rebuild monitor session ───────────────────────────────────────────────────

# Safe to kill — linked windows don't affect the originals
tmux kill-session -t "$MONITOR" 2>/dev/null || true

# Create a fresh session with a placeholder window; record its index
tmux new-session -d -s "$MONITOR" -n "__placeholder__"
placeholder_idx="$(tmux display-message -t "${MONITOR}:__placeholder__" -p '#{window_index}' 2>/dev/null || echo '')"

# Disable automatic-rename for the whole monitor session so our names stick
tmux set-option -t "$MONITOR" automatic-rename off 2>/dev/null || true

# Track session names already used (bash 3.2 compatible — plain string list)
seen_names=" "
linked=0

for entry in "${entries[@]}"; do
    IFS='|' read -r sess win <<< "$entry"

    tmux link-window -s "${sess}:${win}" -t "${MONITOR}:" 2>/dev/null || continue

    # Get the index of the newly linked window (highest index after the link)
    new_idx="$(tmux list-windows -t "$MONITOR" -F "#{window_index}" | sort -n | tail -1)"

    # Unique window name: "sess" first time, "sess:win" for duplicates
    if [[ "$seen_names" == *" ${sess} "* ]]; then
        wname="${sess}:${win}"
    else
        wname="$sess"
        seen_names="${seen_names}${sess} "
    fi
    tmux rename-window -t "${MONITOR}:${new_idx}" "$wname" 2>/dev/null || true
    tmux set-window-option -t "${MONITOR}:${new_idx}" automatic-rename off 2>/dev/null || true

    linked=$(( linked + 1 ))
done

# Remove the placeholder window
if [ -n "${placeholder_idx:-}" ]; then
    tmux kill-window -t "${MONITOR}:${placeholder_idx}" 2>/dev/null || true
fi

if [ "$linked" -eq 0 ]; then
    tmux kill-session -t "$MONITOR" 2>/dev/null || true
    tmux display-message "cc-monitor: failed to link any windows" 2>/dev/null \
        || printf 'cc-monitor: failed to link any windows\n'
    exit 1
fi

# ── Switch to monitor session ─────────────────────────────────────────────────

[ "$REFRESH_ONLY" = "refresh" ] && exit 0

current="$(tmux display-message -p '#S' 2>/dev/null || true)"
if [ -n "${TMUX:-}" ]; then
    [ "$current" != "$MONITOR" ] && tmux switch-client -t "$MONITOR"
else
    tmux attach-session -t "$MONITOR"
fi
