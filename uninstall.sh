#!/usr/bin/env bash
# Agent Notifier uninstaller.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CODEX_HOOKS="${HOME}/.codex/hooks.json"
PI_EXTENSION_FILE="${HOME}/.pi/agent/extensions/agent-notifier.ts"
TMUX_CONF="${HOME}/.tmux.conf"
DATA_DIR="${AGENT_NOTIFIER_DATA_DIR:-${HOME}/.local/share/agent-notifier}"

printf 'Agent Notifier - Uninstall\n\n'

remove_hooks_from_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        printf '  Warning: jq not found; manually remove Agent Notifier hooks from %s\n' "$file"
        return 0
    fi
    jq --arg dir "$SCRIPT_DIR" '
      .hooks = ((.hooks // {}) | with_entries(
        .value = [
          .value[]? |
          .hooks = ([.hooks[]? | select((.command // "") | startswith($dir) | not)]) |
          select((.hooks | length) > 0)
        ] |
        select((.value | length) > 0)
      )) |
      if .hooks == {} then del(.hooks) else . end
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

printf '  Removing Claude hooks...\n'
remove_hooks_from_file "$CLAUDE_SETTINGS"

printf '  Removing Codex hooks...\n'
remove_hooks_from_file "$CODEX_HOOKS"

if [ -f "$PI_EXTENSION_FILE" ] && grep -q "$SCRIPT_DIR" "$PI_EXTENSION_FILE" 2>/dev/null; then
    printf '  Removing Pi extension...\n'
    rm -f "$PI_EXTENSION_FILE"
fi

if [ -f "$TMUX_CONF" ]; then
    if grep -q '# agent-notifier-begin' "$TMUX_CONF" 2>/dev/null; then
        printf '  Removing tmux config block...\n'
        sed '/# agent-notifier-begin/,/# agent-notifier-end/d' "$TMUX_CONF" > "${TMUX_CONF}.tmp"
        cat -s "${TMUX_CONF}.tmp" > "$TMUX_CONF"
        rm -f "${TMUX_CONF}.tmp"
    fi
    if grep -q '# claude-notifier-begin' "$TMUX_CONF" 2>/dev/null; then
        printf '  Removing legacy tmux config block...\n'
        sed '/# claude-notifier-begin/,/# claude-notifier-end/d' "$TMUX_CONF" > "${TMUX_CONF}.tmp"
        cat -s "${TMUX_CONF}.tmp" > "$TMUX_CONF"
        rm -f "${TMUX_CONF}.tmp"
    fi
fi

if [ -d "$DATA_DIR" ]; then
    printf '  Removing data directory...\n'
    rm -rf "$DATA_DIR"
fi

printf '\n  Uninstall complete. Run: tmux source ~/.tmux.conf\n\n'
