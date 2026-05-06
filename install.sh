#!/usr/bin/env bash
# Agent Notifier installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CODEX_HOOKS="${HOME}/.codex/hooks.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
PI_EXTENSION_DIR="${HOME}/.pi/agent/extensions"
PI_EXTENSION_FILE="${PI_EXTENSION_DIR}/agent-notifier.ts"
TMUX_CONF="${HOME}/.tmux.conf"

MARKER_BEGIN='# agent-notifier-begin'
MARKER_END='# agent-notifier-end'
OLD_MARKER_BEGIN='# claude-notifier-begin'
OLD_MARKER_END='# claude-notifier-end'

printf 'Agent Notifier - Install\n\n'

if ! command -v jq >/dev/null 2>&1; then
    printf '  Error: jq is required but not installed.\n'
    exit 1
fi

migrate_legacy_state
ensure_data_dirs

if [ ! -f "${DATA_DIR}/backends.conf" ]; then
    cp "${SCRIPT_DIR}/backends.conf" "${DATA_DIR}/backends.conf"
fi

printf '  Making scripts executable...\n'
chmod +x "${SCRIPT_DIR}/"*.sh
chmod +x "${SCRIPT_DIR}/providers/"*.sh

add_hook() {
    local file="$1" event="$2" cmd="$3"
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || printf '{}\n' > "$file"
    jq --arg ev "$event" --arg cmd "$cmd" '
      def add_notifier(ev):
        .hooks[ev] as $existing |
        if ([($existing // [])[] | .hooks[]? | .command] | index($cmd)) != null then .
        else .hooks[ev] = (($existing // []) + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}])
        end;
      .hooks = (.hooks // {}) | add_notifier($ev)
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

remove_hook() {
    local file="$1" event="$2" cmd="$3"
    [ -f "$file" ] || return 0
    jq --arg ev "$event" --arg cmd "$cmd" '
      if .hooks[$ev] == null then .
      else
        .hooks[$ev] = [
          .hooks[$ev][]? |
          .hooks = ([.hooks[]? | select(.command != $cmd)]) |
          select((.hooks | length) > 0)
        ] |
        if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
      end |
      if .hooks == {} then del(.hooks) else . end
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

printf '  Configuring Claude hooks...\n'
CLAUDE_CMD="${SCRIPT_DIR}/providers/claude-hook.sh"
for event in SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest; do
    add_hook "$CLAUDE_SETTINGS" "$event" "$CLAUDE_CMD"
done

printf '  Configuring Codex hooks...\n'
CODEX_CMD="${SCRIPT_DIR}/providers/codex-hook.sh"
for event in SessionStart SessionEnd PreToolUse PostToolUse Notification PermissionRequest; do
    remove_hook "$CODEX_HOOKS" "$event" "$CODEX_CMD"
done
for event in UserPromptSubmit Stop; do
    add_hook "$CODEX_HOOKS" "$event" "$CODEX_CMD"
done
mkdir -p "$(dirname "$CODEX_CONFIG")"
touch "$CODEX_CONFIG"
if ! grep -q '^codex_hooks[[:space:]]*=' "$CODEX_CONFIG" 2>/dev/null; then
    # Must be a top-level key, so prepend rather than append — appending after a
    # [table] header would make TOML parse it as a member of that table.
    { printf 'codex_hooks = true\n'; cat "$CODEX_CONFIG"; } > "${CODEX_CONFIG}.tmp" \
        && mv "${CODEX_CONFIG}.tmp" "$CODEX_CONFIG"
fi

printf '  Installing Pi extension...\n'
mkdir -p "$PI_EXTENSION_DIR"
sed "s#__AGENT_NOTIFIER_SCRIPT_DIR__#${SCRIPT_DIR}#g" "${SCRIPT_DIR}/providers/pi-extension.ts" > "$PI_EXTENSION_FILE"

printf '  Configuring tmux...\n'
touch "$TMUX_CONF"
if grep -q "$OLD_MARKER_BEGIN" "$TMUX_CONF" 2>/dev/null; then
    sed "/${OLD_MARKER_BEGIN}/,/${OLD_MARKER_END}/d" "$TMUX_CONF" > "${TMUX_CONF}.tmp"
    cat -s "${TMUX_CONF}.tmp" > "$TMUX_CONF"
    rm -f "${TMUX_CONF}.tmp"
fi
if grep -q "$MARKER_BEGIN" "$TMUX_CONF" 2>/dev/null; then
    sed "/${MARKER_BEGIN}/,/${MARKER_END}/d" "$TMUX_CONF" > "${TMUX_CONF}.tmp"
    cat -s "${TMUX_CONF}.tmp" > "$TMUX_CONF"
    rm -f "${TMUX_CONF}.tmp"
fi

NOTIFIER_BLOCK="${MARKER_BEGIN}
set-hook -g after-select-window 'run-shell \"${SCRIPT_DIR}/clear.sh #{session_name} #{window_index}\"'
set -g @rose_pine_status_right_append_section '#(${SCRIPT_DIR}/status.sh)'
bind-key N run-shell '${SCRIPT_DIR}/popup.sh'
bind-key J run-shell '${SCRIPT_DIR}/jump.sh'
bind-key K run-shell '${SCRIPT_DIR}/cycle.sh'
bind-key M run-shell '${SCRIPT_DIR}/agent-monitor.sh'
${MARKER_END}"

CONTENT="$(<"$TMUX_CONF")"
TPM_LINE="run '~/.tmux/plugins/tpm/tpm'"
if [[ "$CONTENT" == *"$TPM_LINE"* ]]; then
    NL=$'\n'
    CONTENT="${CONTENT/"$TPM_LINE"/${NOTIFIER_BLOCK}${NL}${NL}${TPM_LINE}}"
    printf '%s\n' "$CONTENT" > "$TMUX_CONF"
else
    while [[ "$CONTENT" == *$'\n' ]]; do CONTENT="${CONTENT%$'\n'}"; done
    printf '%s\n\n%s\n' "$CONTENT" "$NOTIFIER_BLOCK" > "$TMUX_CONF"
fi

[ -f "${SCRIPT_DIR}/VERSION" ] && cp "${SCRIPT_DIR}/VERSION" "${DATA_DIR}/installed_version"

printf '\n  Installation complete.\n\n'
printf '  Next steps:\n'
printf '    1. tmux source ~/.tmux.conf\n'
printf '    2. Restart Claude, Codex, and Pi sessions so hooks/extensions load\n'
printf '    3. prefix + N dashboard, J jump, K cycle, M monitor\n\n'
