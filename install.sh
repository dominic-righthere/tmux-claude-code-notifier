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

# Check dependencies
if ! command -v jq &>/dev/null; then
    printf '  Error: jq is required but not installed.\n'
    printf '  Install with:\n'
    printf '    macOS:  brew install jq\n'
    printf '    Ubuntu: sudo apt install jq\n'
    exit 1
fi

# 1. Create data directories
printf '  Creating data directories...\n'
mkdir -p "${DATA_DIR}/active" "${DATA_DIR}/notifications"

# 2. Install default backends.conf (preserve existing)
if [ ! -f "${DATA_DIR}/backends.conf" ]; then
    cp "${SCRIPT_DIR}/backends.conf" "${DATA_DIR}/backends.conf"
    printf '  Installed default backends.conf\n'
else
    printf '  backends.conf already exists, skipping\n'
fi

# 3. Make scripts executable
printf '  Making scripts executable...\n'
chmod +x "${SCRIPT_DIR}/lib.sh"
chmod +x "${SCRIPT_DIR}/notify.sh"
chmod +x "${SCRIPT_DIR}/dispatch.sh"
chmod +x "${SCRIPT_DIR}/dashboard.sh"
chmod +x "${SCRIPT_DIR}/status.sh"
chmod +x "${SCRIPT_DIR}/clear.sh"
chmod +x "${SCRIPT_DIR}/jump.sh"
chmod +x "${SCRIPT_DIR}/cycle.sh"
chmod +x "${SCRIPT_DIR}/scan.sh"
chmod +x "${SCRIPT_DIR}/popup.sh"
chmod +x "${SCRIPT_DIR}/telegram-setup.sh"
chmod +x "${SCRIPT_DIR}/telegram-send.sh"
chmod +x "${SCRIPT_DIR}/telegram.sh"
chmod +x "${SCRIPT_DIR}/restart.sh"
chmod +x "${SCRIPT_DIR}/doctor.sh"

# 4. Merge hooks into ~/.claude/settings.json
printf '  Configuring Claude Code hooks...\n'

if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

jq --arg cmd "${SCRIPT_DIR}/notify.sh" '
  .hooks = (.hooks // {}) |
  .hooks.SessionStart = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}] |
  .hooks.SessionEnd = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}] |
  .hooks.UserPromptSubmit = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}] |
  .hooks.PreToolUse = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}] |
  .hooks.Stop = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}] |
  .hooks.Notification = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}] |
  .hooks.PermissionRequest = [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"

printf '  Hooks configured for: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, Stop, Notification, PermissionRequest\n'

# 5. Add tmux configuration
printf '  Configuring tmux...\n'

if [ ! -f "$TMUX_CONF" ]; then
    touch "$TMUX_CONF"
fi

# Remove existing claude-notifier block if present (between begin/end markers)
if grep -q "$MARKER_BEGIN" "$TMUX_CONF" 2>/dev/null; then
    printf '  Removing existing config block...\n'
    # Pipe through sed (not -i) to support symlinked tmux.conf
    sed '/# claude-notifier-begin/,/# claude-notifier-end/d' "$TMUX_CONF" > "${TMUX_CONF}.tmp"
    # Collapse consecutive blank lines, write back through symlink
    cat -s "${TMUX_CONF}.tmp" > "$TMUX_CONF"
    rm -f "${TMUX_CONF}.tmp"
fi

# Build the config block
NOTIFIER_BLOCK="${MARKER_BEGIN}
set-hook -g after-select-window 'run-shell \"${SCRIPT_DIR}/clear.sh #{session_name} #{window_index}\"'
set -g @rose_pine_status_right_append_section '#(${SCRIPT_DIR}/status.sh)'
bind-key N run-shell '${SCRIPT_DIR}/popup.sh'
bind-key J run-shell '${SCRIPT_DIR}/jump.sh'
bind-key K run-shell '${SCRIPT_DIR}/cycle.sh'
${MARKER_END}"

# Insert before the TPM init line if it exists, otherwise append
CONTENT="$(<"$TMUX_CONF")"
TPM_LINE="run '~/.tmux/plugins/tpm/tpm'"
if [[ "$CONTENT" == *"$TPM_LINE"* ]]; then
    NL=$'\n'
    CONTENT="${CONTENT/"$TPM_LINE"/${NOTIFIER_BLOCK}${NL}${NL}${TPM_LINE}}"
    printf '%s\n' "$CONTENT" > "$TMUX_CONF"
else
    # Strip trailing newlines and append
    while [[ "$CONTENT" == *$'\n' ]]; do
        CONTENT="${CONTENT%$'\n'}"
    done
    printf '%s\n\n%s\n' "$CONTENT" "$NOTIFIER_BLOCK" > "$TMUX_CONF"
fi

# 6. Record installed version
if [ -f "${SCRIPT_DIR}/VERSION" ]; then
    cp "${SCRIPT_DIR}/VERSION" "${DATA_DIR}/installed_version"
    printf '  Recorded version %s\n' "$(<"${SCRIPT_DIR}/VERSION")"
fi

# 7. Restart Telegram bot if it's currently running (picks up new code)
if [ -f "${DATA_DIR}/telegram.pid" ]; then
    old_pid="$(<"${DATA_DIR}/telegram.pid")"
    if kill -0 "$old_pid" 2>/dev/null; then
        printf '  Restarting Telegram bot...\n'
        "${SCRIPT_DIR}/telegram.sh" stop
        "${SCRIPT_DIR}/telegram.sh" start
    else
        rm -f "${DATA_DIR}/telegram.pid"
    fi
fi

printf '\n  Installation complete!\n\n'
printf '  Next steps:\n'
printf '    1. tmux source ~/.tmux.conf\n'
printf '    2. Restart Claude Code (hooks load at startup)\n'
printf '    3. prefix + N to open the notification dashboard\n'
printf '    4. prefix + J to jump to the most recent notification\n'
printf '    5. prefix + K to cycle through Claude Code sessions\n\n'
printf '  Optional — Telegram notifications:\n'
printf '    %s/telegram-setup.sh\n\n' "$SCRIPT_DIR"
