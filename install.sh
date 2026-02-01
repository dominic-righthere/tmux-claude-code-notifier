#!/usr/bin/env bash
# Claude Code Notifier — installer
# Sets up data dirs, configures Claude Code hooks, and adds tmux config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"
SETTINGS_FILE="${HOME}/.claude/settings.json"
TMUX_CONF="${HOME}/.tmux.conf"

MARKER_BEGIN='# claude-notifier-begin'
MARKER_END='# claude-notifier-end'

printf 'Claude Code Notifier — Install\n\n'

# 1. Create data directories
printf '  Creating data directories...\n'
mkdir -p "${DATA_DIR}/active" "${DATA_DIR}/notifications"

# 2. Make scripts executable
printf '  Making scripts executable...\n'
chmod +x "${SCRIPT_DIR}/notify.sh"
chmod +x "${SCRIPT_DIR}/dashboard.sh"
chmod +x "${SCRIPT_DIR}/status.sh"
chmod +x "${SCRIPT_DIR}/clear.sh"
chmod +x "${SCRIPT_DIR}/jump.sh"

# 3. Merge hooks into ~/.claude/settings.json
printf '  Configuring Claude Code hooks...\n'

if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

# Use python3 (available on macOS) to merge JSON safely
python3 -c "
import json, sys

settings_path = sys.argv[1]
notify_cmd = sys.argv[2]

with open(settings_path, 'r') as f:
    settings = json.load(f)

hook_entry = lambda: [{'matcher': '', 'hooks': [{'type': 'command', 'command': notify_cmd}]}]

if 'hooks' not in settings:
    settings['hooks'] = {}

for event in ['UserPromptSubmit', 'Stop', 'Notification', 'PermissionRequest']:
    settings['hooks'][event] = hook_entry()

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" "$SETTINGS_FILE" "${SCRIPT_DIR}/notify.sh"

printf '  Hooks configured for: UserPromptSubmit, Stop, Notification, PermissionRequest\n'

# 4. Add tmux configuration
printf '  Configuring tmux...\n'

if [ ! -f "$TMUX_CONF" ]; then
    touch "$TMUX_CONF"
fi

# Remove existing claude-notifier block if present (between begin/end markers)
if grep -q "$MARKER_BEGIN" "$TMUX_CONF" 2>/dev/null; then
    printf '  Removing existing config block...\n'
    python3 -c "
import re, sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
# Remove block including markers and surrounding blank lines
content = re.sub(r'\n*# claude-notifier-begin\n.*?# claude-notifier-end\n*', '\n', content, flags=re.DOTALL)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$TMUX_CONF"
fi

# Build the config block
NOTIFIER_BLOCK="${MARKER_BEGIN}
set-hook -g after-select-window 'run-shell \"${SCRIPT_DIR}/clear.sh #{session_name} #{window_index}\"'
set -g @rose_pine_status_right_append_section '#(${SCRIPT_DIR}/status.sh)'
bind-key N display-popup -E -w 80% -h 60% '${SCRIPT_DIR}/dashboard.sh'
bind-key J run-shell '${SCRIPT_DIR}/jump.sh'
${MARKER_END}"

# Insert before the TPM init line if it exists, otherwise append
python3 -c "
import sys

conf_path = sys.argv[1]
block = sys.argv[2]

with open(conf_path, 'r') as f:
    content = f.read()

tpm_line = \"run '~/.tmux/plugins/tpm/tpm'\"
if tpm_line in content:
    content = content.replace(tpm_line, block + '\n\n' + tpm_line)
else:
    content = content.rstrip('\n') + '\n\n' + block + '\n'

with open(conf_path, 'w') as f:
    f.write(content)
" "$TMUX_CONF" "$NOTIFIER_BLOCK"

printf '\n  Installation complete!\n\n'
printf '  Next steps:\n'
printf '    1. tmux source ~/.tmux.conf\n'
printf '    2. Restart Claude Code (hooks load at startup)\n'
printf '    3. prefix + N to open the notification dashboard\n'
printf '    4. prefix + J to jump to the most recent notification\n\n'
