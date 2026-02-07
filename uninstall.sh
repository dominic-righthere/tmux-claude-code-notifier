#!/usr/bin/env bash
# Claude Code Notifier — uninstaller
# Removes hooks from settings.json, config block from tmux.conf, and data directory
set -euo pipefail

SETTINGS_FILE="${HOME}/.claude/settings.json"
TMUX_CONF="${HOME}/.tmux.conf"
DATA_DIR="${HOME}/.local/share/claude-notifier"

printf 'Claude Code Notifier — Uninstall\n\n'

# 1. Remove hooks from ~/.claude/settings.json
if [ -f "$SETTINGS_FILE" ]; then
    if ! command -v jq &>/dev/null; then
        printf '  Warning: jq not found, skipping settings.json cleanup.\n'
        printf '  Manually remove hook entries from %s\n' "$SETTINGS_FILE"
    else
        printf '  Removing hooks from settings.json...\n'
        jq '
          del(.hooks.UserPromptSubmit) |
          del(.hooks.Stop) |
          del(.hooks.Notification) |
          del(.hooks.PermissionRequest) |
          if .hooks == {} then del(.hooks) else . end
        ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    fi
else
    printf '  No settings.json found, skipping.\n'
fi

# 2. Remove config block from ~/.tmux.conf
if [ -f "$TMUX_CONF" ] && grep -q '# claude-notifier-begin' "$TMUX_CONF" 2>/dev/null; then
    printf '  Removing tmux config block...\n'
    sed -i.bak '/# claude-notifier-begin/,/# claude-notifier-end/d' "$TMUX_CONF"
    rm -f "${TMUX_CONF}.bak"
    # Collapse consecutive blank lines left behind
    cat -s "$TMUX_CONF" > "${TMUX_CONF}.tmp" && mv "${TMUX_CONF}.tmp" "$TMUX_CONF"
else
    printf '  No tmux config block found, skipping.\n'
fi

# 3. Remove data directory
if [ -d "$DATA_DIR" ]; then
    printf '  Removing data directory...\n'
    rm -rf "$DATA_DIR"
else
    printf '  No data directory found, skipping.\n'
fi

printf '\n  Uninstall complete!\n\n'
printf '  Run: tmux source ~/.tmux.conf\n\n'
