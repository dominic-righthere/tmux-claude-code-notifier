#!/usr/bin/env bash
# Agent Notifier diagnostics.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CODEX_HOOKS="${HOME}/.codex/hooks.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
PI_EXTENSION_FILE="${HOME}/.pi/agent/extensions/agent-notifier.ts"
TMUX_CONF="${HOME}/.tmux.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
QUIET=0
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        --help|-h)
            printf 'Usage: %s [--quiet|-q] [--help|-h]\n' "$(basename "$0")"
            exit 0
            ;;
    esac
done

result_pass() { PASS_COUNT=$((PASS_COUNT + 1)); [ "$QUIET" -eq 0 ] && printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
result_warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  ${YELLOW}WARN${NC} %s\n" "$1"; }
result_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  ${RED}FAIL${NC} %s\n" "$1"; }

[ "$QUIET" -eq 0 ] && printf 'Agent Notifier - Doctor\n\n'

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Dependencies${NC}\n"
for dep in jq tmux; do
    command -v "$dep" >/dev/null 2>&1 && result_pass "${dep} found" || result_fail "${dep} not found"
done

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Data${NC}\n"
for dir in "${DATA_DIR}/active" "${DATA_DIR}/notifications"; do
    [ -d "$dir" ] && result_pass "${dir#"${DATA_DIR}/"} exists" || result_warn "${dir#"${DATA_DIR}/"} missing - run install.sh"
done
[ -d "$LEGACY_DATA_DIR" ] && [ "$LEGACY_DATA_DIR" != "$DATA_DIR" ] && result_warn "Legacy state still exists at ${LEGACY_DATA_DIR}; install migrates but leaves it untouched"

check_hook_file() {
    local label="$1" file="$2" cmd="$3"
    [ "$QUIET" -eq 0 ] && printf "${YELLOW}%s${NC}\n" "$label"
    if [ ! -f "$file" ]; then
        result_warn "${file} missing"
        return
    fi
    if jq --arg cmd "$cmd" '[.hooks[]?[]? | .hooks[]? | select(.command == $cmd)] | length > 0' "$file" 2>/dev/null | grep -qx true; then
        result_pass "${label} hook configured"
    else
        result_warn "${label} hook not found for ${cmd}"
    fi
}

check_hook_file "Claude" "$CLAUDE_SETTINGS" "${SCRIPT_DIR}/providers/claude-hook.sh"
check_hook_file "Codex" "$CODEX_HOOKS" "${SCRIPT_DIR}/providers/codex-hook.sh"

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Codex config${NC}\n"
if [ -f "$CODEX_CONFIG" ] && grep -q '^codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX_CONFIG"; then
    result_pass "codex_hooks enabled"
else
    result_warn "codex_hooks not enabled in ${CODEX_CONFIG}"
fi

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Pi${NC}\n"
if [ -f "$PI_EXTENSION_FILE" ] && grep -q "$SCRIPT_DIR" "$PI_EXTENSION_FILE" 2>/dev/null; then
    result_pass "Pi extension installed"
else
    result_warn "Pi extension not installed"
fi

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Tmux${NC}\n"
if [ -f "$TMUX_CONF" ] && grep -q '# agent-notifier-begin' "$TMUX_CONF" && grep -q "${SCRIPT_DIR}/agent-monitor.sh" "$TMUX_CONF"; then
    result_pass "tmux block configured"
else
    result_warn "tmux block missing - run install.sh"
fi

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Scripts${NC}\n"
for script in notify.sh status.sh dashboard.sh jump.sh cycle.sh clear.sh agent-monitor.sh providers/claude-hook.sh providers/codex-hook.sh; do
    [ -x "${SCRIPT_DIR}/${script}" ] && result_pass "${script} executable" || result_warn "${script} not executable"
done

printf "\n"
[ "$QUIET" -eq 0 ] && printf "  ${GREEN}%d passed${NC}  ${YELLOW}%d warnings${NC}  ${RED}%d failed${NC}\n\n" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
