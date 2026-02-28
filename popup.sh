#!/usr/bin/env bash
# Claude Code Notifier — popup wrapper
# Calculates dynamic height based on entry count and opens tmux popup
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"

# Discover untracked sessions before counting (so first-open height is correct)
"${SCRIPT_DIR}/scan.sh" >/dev/null 2>&1 || true

n=0
for f in "$DATA_DIR"/active/* "$DATA_DIR"/notifications/*; do
    [ -f "$f" ] && n=$((n + 1))
done

# Height = entries + section headers (max 4) + chrome (header, footer, spacing)
cats=4
[ "$n" -lt 4 ] && cats=$n
h=$((n + cats + 8))
[ "$h" -lt 10 ] && h=10

# Clamp to 80% of terminal height
th=$(tput lines 2>/dev/null || echo 40)
mh=$((th * 80 / 100))
[ "$mh" -lt 10 ] && mh=10
[ "$h" -gt "$mh" ] && h=$mh

tmux display-popup -E -w 80% -h "$h" "${SCRIPT_DIR}/dashboard.sh"
