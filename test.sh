#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf "${GREEN}PASS${NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}FAIL${NC} %s\n" "$1"; }

assert_file() {
    [ -e "$1" ] && pass "$2" || fail "$2"
}

assert_missing() {
    [ ! -e "$1" ] && pass "$2" || fail "$2"
}

assert_grep() {
    grep -q "$1" "$2" && pass "$3" || fail "$3"
}

assert_not_grep() {
    grep -q "$1" "$2" && fail "$3" || pass "$3"
}

printf 'Agent Notifier tests\n\n'

assert_file archive/telegram/python "Telegram Python package archived"
assert_file archive/telegram/telegram.sh "Telegram shell command archived"
assert_file archive/claude/restart.sh "Claude restart helper archived"
assert_missing telegram.sh "Telegram command removed from root"
assert_missing telegram-send.sh "Telegram sender removed from root"
assert_missing restart.sh "Bulk restart removed from root"

assert_file providers/claude-hook.sh "Claude provider hook exists"
assert_file providers/codex-hook.sh "Codex provider hook exists"
assert_file providers/pi-extension.ts "Pi extension template exists"
assert_file agent-monitor.sh "Agent monitor exists"
assert_file cc-monitor.sh "Old monitor wrapper exists"

assert_grep 'AGENT_NOTIFIER_AGENT=claude' providers/claude-hook.sh "Claude wrapper labels agent"
assert_grep 'AGENT_NOTIFIER_AGENT=codex' providers/codex-hook.sh "Codex wrapper labels agent"
assert_grep 'hook_event_name.*agent_end' providers/pi-extension.ts "Pi extension sends agent_end"

assert_grep 'agent-notifier' lib.sh "Library uses agent-notifier state root"
assert_grep 'AGENT=%s' lib.sh "State files include AGENT field"
assert_grep 'LEGACY_DATA_DIR' lib.sh "Library knows legacy state path"
assert_not_grep 'dispatch.sh' notify.sh "Hook handler does not dispatch remote notifications"
assert_not_grep 'telegram' notify.sh "Hook handler has no Telegram references"
assert_not_grep 'printf.*\\a' notify.sh "Hook handler does not write bell/control output to stdout"
assert_grep 'AGENT' notify.sh "Hook handler parses provider"

assert_grep 'providers/claude-hook.sh' install.sh "Installer configures Claude provider"
assert_grep 'providers/codex-hook.sh' install.sh "Installer configures Codex provider"
assert_grep 'for event in UserPromptSubmit Stop' install.sh "Installer limits Codex hooks to supported lifecycle events"
assert_grep 'remove_hook "$CODEX_HOOKS"' install.sh "Installer removes prior unsupported Codex hook registrations"
assert_grep 'pi-extension.ts' install.sh "Installer installs Pi extension"
assert_grep 'agent-monitor.sh' install.sh "Installer binds agent monitor"
assert_not_grep 'uv sync' install.sh "Installer no longer installs Telegram dependencies"
assert_not_grep 'telegram-bot' install.sh "Installer no longer restarts Telegram bot"
assert_not_grep 'restart.sh' install.sh "Installer does not expose bulk restart"

assert_not_grep '^telegram=' backends.conf "No Telegram backend enabled by default"
assert_grep 'agent-monitor' dashboard.sh "Dashboard opens agent monitor"
assert_not_grep 'pane_current_command' cycle.sh "Cycle uses tracked state, not Claude version heuristic"

TMP_HOME="${TMPDIR:-/tmp}/agent-notifier-test-$$"
mkdir -p "$TMP_HOME"
HOME="$TMP_HOME" AGENT_NOTIFIER_DATA_DIR="$TMP_HOME/state" bash -c 'source ./lib.sh; ensure_data_dirs; key="$(agent_key codex s 1)"; write_state_file "$DATA_DIR/active" "$key" codex s 1 w working "Working" 123 sid /tmp; grep -q "AGENT=codex" "$DATA_DIR/active/$key"'
[ "$?" -eq 0 ] && pass "write_state_file writes AGENT" || fail "write_state_file writes AGENT"

printf '{}' | HOME="$TMP_HOME" AGENT_NOTIFIER_DATA_DIR="$TMP_HOME/state" ./notify.sh >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "notify.sh exits cleanly outside tmux" || fail "notify.sh exits cleanly outside tmux"

HOME="$TMP_HOME" AGENT_NOTIFIER_DATA_DIR="$TMP_HOME/state" ./status.sh >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "status.sh runs without tmux" || fail "status.sh runs without tmux"

rm -rf "$TMP_HOME"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
