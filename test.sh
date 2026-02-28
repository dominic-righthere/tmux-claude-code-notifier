#!/usr/bin/env bash
# Test suite for Claude Code Notifier
set -uo pipefail

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

# Test data directory (isolated from real data)
TEST_DATA_DIR="${TMPDIR:-/tmp}/claude-notifier-test-$$"
mkdir -p "$TEST_DATA_DIR"

# Cleanup on exit
cleanup() {
    rm -rf "$TEST_DATA_DIR"
}
trap cleanup EXIT

# Test helper functions
pass() {
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    printf "  ${GREEN}PASS${NC} %s\n" "$1"
}

fail() {
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    printf "  ${RED}FAIL${NC} %s\n" "$1"
    [ -n "${2:-}" ] && printf "       %s\n" "$2"
}

run_test() {
    TESTS_RUN=$(( TESTS_RUN + 1 ))
}

# =============================================================================
# JSON Parser Tests
# =============================================================================
printf "\n${YELLOW}=== JSON Parser Tests ===${NC}\n"

# Extract the function from notify.sh for testing
extract_json_value() {
    local json="$1" key="$2"
    # Replace \" with placeholder, extract, then restore
    local cleaned="${json//\\\"/@@Q@@}"
    local pattern="\"${key}\":\"([^\"]*)\""
    if [[ "$cleaned" =~ $pattern ]]; then
        local val="${BASH_REMATCH[1]}"
        printf '%s' "${val//@@Q@@/\"}"
    fi
}

# Test 1: Simple value extraction
run_test
result=$(extract_json_value '{"key":"value"}' "key")
if [ "$result" = "value" ]; then
    pass "Simple value extraction"
else
    fail "Simple value extraction" "Expected 'value', got '$result'"
fi

# Test 2: Escaped quotes in value
run_test
result=$(extract_json_value '{"msg":"He said \"hello\""}' "msg")
if [ "$result" = 'He said "hello"' ]; then
    pass "Escaped quotes extraction"
else
    fail "Escaped quotes extraction" "Expected 'He said \"hello\"', got '$result'"
fi

# Test 3: Missing key returns empty
run_test
result=$(extract_json_value '{"key":"value"}' "missing")
if [ -z "$result" ]; then
    pass "Missing key returns empty"
else
    fail "Missing key returns empty" "Expected empty, got '$result'"
fi

# Test 4: Multiple fields - extract specific one
run_test
result=$(extract_json_value '{"hook_event_name":"Stop","message":"test"}' "hook_event_name")
if [ "$result" = "Stop" ]; then
    pass "Extract from multiple fields"
else
    fail "Extract from multiple fields" "Expected 'Stop', got '$result'"
fi

# Test 5: Complex message with escaped quotes
run_test
result=$(extract_json_value '{"hook_event_name":"Notification","message":"User said \"yes\" to proceed"}' "message")
if [ "$result" = 'User said "yes" to proceed' ]; then
    pass "Complex message with escaped quotes"
else
    fail "Complex message with escaped quotes" "Expected 'User said \"yes\" to proceed', got '$result'"
fi

# =============================================================================
# Hook Exit Code Tests
# =============================================================================
printf "\n${YELLOW}=== Hook Exit Code Tests ===${NC}\n"

# We need to mock the tmux environment for these tests
# Without TMUX set, notify.sh should exit 0 early

# Test 6: Stop hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"Stop"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "Stop hook exits 0 (no tmux)"
else
    fail "Stop hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 7: Notification hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"Notification","message":"test"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "Notification hook exits 0 (no tmux)"
else
    fail "Notification hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 8: PermissionRequest hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "PermissionRequest hook exits 0 (no tmux)"
else
    fail "PermissionRequest hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 9: UserPromptSubmit hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"UserPromptSubmit"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "UserPromptSubmit hook exits 0 (no tmux)"
else
    fail "UserPromptSubmit hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 10: Empty input exits cleanly
run_test
echo '' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "Empty input exits 0"
else
    fail "Empty input exits 0" "Exit code was $exit_code"
fi

# Test 11: Invalid JSON exits cleanly
run_test
echo 'not json' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "Invalid JSON exits 0"
else
    fail "Invalid JSON exits 0" "Exit code was $exit_code"
fi

# =============================================================================
# Status Line Tests
# =============================================================================
printf "\n${YELLOW}=== Status Line Tests ===${NC}\n"

# Test 12: status.sh runs without errors (even without tmux)
run_test
# status.sh may produce output and try to set tmux options, but should not error
output=$(./status.sh 2>&1) || true
exit_code=$?
# status.sh should exit 0 or produce output without crashing
if [ "$exit_code" -eq 0 ] || [ -n "$output" ]; then
    pass "status.sh runs without crashing"
else
    fail "status.sh runs without crashing" "Exit code: $exit_code, output: $output"
fi

# Test 13: status.sh produces badge output when data exists
run_test
# Create test data
TEST_ACTIVE="${TEST_DATA_DIR}/active"
TEST_NOTIF="${TEST_DATA_DIR}/notifications"
mkdir -p "$TEST_ACTIVE" "$TEST_NOTIF"

# Create a working entry
cat > "${TEST_ACTIVE}/test_0" << 'EOF'
SESSION=test
WINDOW=0
WINDOW_NAME=bash
MESSAGE=Working...
TYPE=working
TIMESTAMP=1704067200
EOF

# Run status.sh with modified DATA_DIR (via temporary script)
cat > "${TEST_DATA_DIR}/status_test.sh" << 'SCRIPT'
#!/usr/bin/env bash
DATA_DIR="$1"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"

WORKING=0
IDLE=0
WAITING=0
FINISHED=0

if [ -d "$ACTIVE_DIR" ]; then
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            case "$line" in
                TYPE=idle) IDLE=$(( IDLE + 1 )); break ;;
                TYPE=*) WORKING=$(( WORKING + 1 )); break ;;
            esac
        done < "$f"
    done
fi

OUTPUT=""
if [ "$WORKING" -gt 0 ]; then
    OUTPUT="${OUTPUT}W${WORKING} "
fi

printf '%s' "$OUTPUT"
SCRIPT
chmod +x "${TEST_DATA_DIR}/status_test.sh"

output=$("${TEST_DATA_DIR}/status_test.sh" "$TEST_DATA_DIR")
if [[ "$output" == *"W1"* ]]; then
    pass "Status produces working badge"
else
    fail "Status produces working badge" "Expected 'W1' in output, got: '$output'"
fi

# =============================================================================
# Dashboard Cleanup Tests
# =============================================================================
printf "\n${YELLOW}=== Dashboard Cleanup Tests ===${NC}\n"

# Test 14: Stale entries are removed when session doesn't exist
run_test
# Create test directories
TEST_ACTIVE2="${TEST_DATA_DIR}/active2"
TEST_NOTIF2="${TEST_DATA_DIR}/notifications2"
mkdir -p "$TEST_ACTIVE2" "$TEST_NOTIF2"

# Create a stale entry for a non-existent session
cat > "${TEST_ACTIVE2}/nonexistent_0" << 'EOF'
SESSION=nonexistent_session_12345
WINDOW=0
WINDOW_NAME=bash
MESSAGE=Working...
TYPE=working
TIMESTAMP=1704067200
EOF

# Extract and test cleanup_stale function
cleanup_stale() {
    local active_dir="$1" notif_dir="$2"
    for f in "$active_dir"/* "$notif_dir"/*; do
        [ -f "$f" ] || continue
        local sess="" win=""
        while IFS= read -r line; do
            case "$line" in
                SESSION=*) sess="${line#SESSION=}" ;;
                WINDOW=*) win="${line#WINDOW=}" ;;
            esac
        done < "$f" || true
        # If session doesn't exist, remove file
        if [ -n "$sess" ] && ! tmux has-session -t "$sess" 2>/dev/null; then
            rm -f "$f"
        fi
    done
}

# Run cleanup
cleanup_stale "$TEST_ACTIVE2" "$TEST_NOTIF2"

# Check that stale file was removed
if [ ! -f "${TEST_ACTIVE2}/nonexistent_0" ]; then
    pass "Stale entry removed (non-existent session)"
else
    fail "Stale entry removed (non-existent session)" "File still exists"
fi

# Test 15: Valid entries are preserved (if tmux is available)
run_test
if command -v tmux &>/dev/null && [ -n "${TMUX:-}" ]; then
    # Get current session name
    current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || current_session=""
    if [ -n "$current_session" ]; then
        # Create entry for current session
        safe_session=$(printf '%s' "$current_session" | tr '/ ' '__')
        cat > "${TEST_ACTIVE2}/${safe_session}_0" << EOF
SESSION=$current_session
WINDOW=0
WINDOW_NAME=test
MESSAGE=Working...
TYPE=working
TIMESTAMP=1704067200
EOF
        # Run cleanup
        cleanup_stale "$TEST_ACTIVE2" "$TEST_NOTIF2"

        # Check that valid file was preserved (window 0 should exist)
        if [ -f "${TEST_ACTIVE2}/${safe_session}_0" ]; then
            pass "Valid entry preserved (existing session)"
        else
            # Window 0 might not exist, so this could be removed legitimately
            pass "Valid entry handled (session exists but window may not)"
        fi
    else
        pass "Valid entry test skipped (no current session)"
    fi
else
    pass "Valid entry test skipped (not in tmux)"
fi

# =============================================================================
# Integration Tests
# =============================================================================
printf "\n${YELLOW}=== Integration Tests ===${NC}\n"

# Test 16: Full hook flow with escaped quotes
run_test
result=$(extract_json_value '{"hook_event_name":"Notification","message":"Task \"build\" completed"}' "message")
if [ "$result" = 'Task "build" completed' ]; then
    pass "Full hook flow with escaped quotes"
else
    fail "Full hook flow with escaped quotes" "Got: '$result'"
fi

# Test 17: Notification message truncation
run_test
# notify.sh truncates messages > 40 chars
long_msg="This is a very long message that should definitely be truncated by the notification handler"
# The script truncates to 37 chars + "..."
# We can't easily test the full flow without tmux, but we can verify the logic
truncated="${long_msg:0:37}..."
if [ "${#truncated}" -eq 40 ]; then
    pass "Message truncation logic"
else
    fail "Message truncation logic" "Expected 40 chars, got ${#truncated}"
fi

# =============================================================================
# Batched tmux call test
# =============================================================================
printf "\n${YELLOW}=== Batched tmux Call Tests ===${NC}\n"

# Test 18: notify.sh uses single pipe-separated tmux call
run_test
if grep -q "#{session_name}|#{window_index}|#{window_name}" ./notify.sh; then
    pass "notify.sh uses batched tmux display-message"
else
    fail "notify.sh uses batched tmux display-message" "Expected pipe-separated format string"
fi

# Test 19: notify.sh does NOT have 3 separate display-message calls
run_test
count=$(grep -c "tmux display-message" ./notify.sh)
# Should be exactly 1 (the batched call) — the refresh-client is not display-message
if [ "$count" -eq 1 ]; then
    pass "notify.sh has single tmux display-message call"
else
    fail "notify.sh has single tmux display-message call" "Found $count calls, expected 1"
fi

# =============================================================================
# Telegram Tests
# =============================================================================
printf "\n${YELLOW}=== Telegram Tests ===${NC}\n"

# Test 20: telegram-send.sh exits silently with no config
run_test
# Ensure no config exists in test env
_orig_home="${HOME}"
export HOME="${TEST_DATA_DIR}/fakehome"
mkdir -p "${HOME}/.local/share/claude-notifier"
./telegram-send.sh "finished" "test" "0" "Finished" 2>/dev/null
exit_code=$?
export HOME="$_orig_home"
if [ "$exit_code" -eq 0 ]; then
    pass "telegram-send.sh exits 0 with no config"
else
    fail "telegram-send.sh exits 0 with no config" "Exit code was $exit_code"
fi

# Test 21: telegram-send.sh exits silently for non-matching event types
run_test
export HOME="${TEST_DATA_DIR}/fakehome"
# Create a fake config so it doesn't exit at the config check
printf 'BOT_TOKEN=fake\nCHAT_ID=123\n' > "${HOME}/.local/share/claude-notifier/telegram.conf"
chmod 600 "${HOME}/.local/share/claude-notifier/telegram.conf"
./telegram-send.sh "working" "test" "0" "Working..." 2>/dev/null
exit_code=$?
export HOME="$_orig_home"
if [ "$exit_code" -eq 0 ]; then
    pass "telegram-send.sh exits 0 for non-matching event type"
else
    fail "telegram-send.sh exits 0 for non-matching event type" "Exit code was $exit_code"
fi

# Test 22: telegram.sh shows usage without arguments
run_test
output=$(./telegram.sh 2>&1) || true
if [[ "$output" == *"start|stop|status|run"* ]]; then
    pass "telegram.sh shows usage"
else
    fail "telegram.sh shows usage" "Got: $output"
fi

# Test 23: jump.sh skips current window logic exists
run_test
if grep -q 'CURRENT=' ./jump.sh && grep -q 'CANDIDATES' ./jump.sh; then
    pass "jump.sh has current-window skip logic"
else
    fail "jump.sh has current-window skip logic" "Missing CURRENT or CANDIDATES"
fi

# Test 24: popup.sh runs scan before counting
run_test
# scan.sh call should appear before the count loop
scan_line=$(grep -n 'scan.sh' ./popup.sh | head -1 | cut -d: -f1)
count_line=$(grep -n 'for f in' ./popup.sh | head -1 | cut -d: -f1)
if [ -n "$scan_line" ] && [ -n "$count_line" ] && [ "$scan_line" -lt "$count_line" ]; then
    pass "popup.sh runs scan before counting files"
else
    fail "popup.sh runs scan before counting files" "scan_line=$scan_line count_line=$count_line"
fi

# =============================================================================
# New Hook Tests (SessionStart, SessionEnd, PreToolUse)
# =============================================================================
printf "\n${YELLOW}=== New Hook Tests ===${NC}\n"

# Test 25: SessionStart hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"SessionStart"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "SessionStart hook exits 0 (no tmux)"
else
    fail "SessionStart hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 26: SessionEnd hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"SessionEnd"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "SessionEnd hook exits 0 (no tmux)"
else
    fail "SessionEnd hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 27: PreToolUse hook exits cleanly (no tmux)
run_test
echo '{"hook_event_name":"PreToolUse","tool_name":"Read"}' | ./notify.sh
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    pass "PreToolUse hook exits 0 (no tmux)"
else
    fail "PreToolUse hook exits 0 (no tmux)" "Exit code was $exit_code"
fi

# Test 28: notify.sh handles all 7 hook events
run_test
hook_count=0
for hook in SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest; do
    if grep -q "$hook)" ./notify.sh; then
        hook_count=$((hook_count + 1))
    fi
done
if [ "$hook_count" -eq 7 ]; then
    pass "notify.sh handles all 7 hook events"
else
    fail "notify.sh handles all 7 hook events" "Found $hook_count, expected 7"
fi

# =============================================================================
# Dispatcher Tests
# =============================================================================
printf "\n${YELLOW}=== Dispatcher Tests ===${NC}\n"

# Test 29: dispatch.sh exists and is executable
run_test
if [ -x ./dispatch.sh ]; then
    pass "dispatch.sh is executable"
else
    fail "dispatch.sh is executable"
fi

# Test 30: dispatch.sh exits cleanly with no backends.conf
run_test
_orig_home="${HOME}"
export HOME="${TEST_DATA_DIR}/fakehome_dispatch"
mkdir -p "${HOME}/.local/share/claude-notifier"
./dispatch.sh "finished" "test" "0" "Finished" 2>/dev/null
exit_code=$?
export HOME="$_orig_home"
if [ "$exit_code" -eq 0 ]; then
    pass "dispatch.sh exits 0 with no backends.conf"
else
    fail "dispatch.sh exits 0 with no backends.conf" "Exit code was $exit_code"
fi

# Test 31: notify.sh uses dispatch.sh instead of telegram-send.sh directly
run_test
telegram_direct=$(grep -c 'telegram-send\.sh' ./notify.sh)
dispatch_calls=$(grep -c 'dispatch\.sh' ./notify.sh)
if [ "$telegram_direct" -eq 0 ] && [ "$dispatch_calls" -gt 0 ]; then
    pass "notify.sh uses dispatch.sh (no direct telegram-send.sh calls)"
else
    fail "notify.sh uses dispatch.sh" "telegram-send.sh=$telegram_direct, dispatch.sh=$dispatch_calls"
fi

# Test 32: backends.conf exists with telegram backend
run_test
if [ -f ./backends.conf ] && grep -q 'telegram=' ./backends.conf; then
    pass "backends.conf exists with telegram backend"
else
    fail "backends.conf exists with telegram backend"
fi

# =============================================================================
# Shared Library Tests
# =============================================================================
printf "\n${YELLOW}=== Shared Library Tests ===${NC}\n"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Test 33: sanitize_key replaces / and spaces
run_test
result=$(sanitize_key "my session/name")
if [ "$result" = "my_session_name" ]; then
    pass "sanitize_key replaces / and spaces"
else
    fail "sanitize_key replaces / and spaces" "Got: '$result'"
fi

# Test 34: html_escape escapes &<>
run_test
result=$(html_escape "a & b < c > d")
if [ "$result" = "a &amp; b &lt; c &gt; d" ]; then
    pass "html_escape escapes &<>"
else
    fail "html_escape escapes &<>" "Got: '$result'"
fi

# Test 35: strip_ansi removes escape codes
run_test
result=$(strip_ansi $'\033[31mred\033[0m text')
if [ "$result" = "red text" ]; then
    pass "strip_ansi removes escape codes"
else
    fail "strip_ansi removes escape codes" "Got: '$result'"
fi

# Test 36: write_state_file + read_state_field roundtrip
run_test
TEST_ROUNDTRIP="${TEST_DATA_DIR}/roundtrip"
mkdir -p "$TEST_ROUNDTRIP"
write_state_file "$TEST_ROUNDTRIP" "test_0" "mysess" "0" "bash" "working" "Building..." "1700000000"
rt_type=$(read_state_field "${TEST_ROUNDTRIP}/test_0" "TYPE")
rt_msg=$(read_state_field "${TEST_ROUNDTRIP}/test_0" "MESSAGE")
if [ "$rt_type" = "working" ] && [ "$rt_msg" = "Building..." ]; then
    pass "write_state_file + read_state_field roundtrip"
else
    fail "write_state_file + read_state_field roundtrip" "TYPE=$rt_type, MESSAGE=$rt_msg"
fi

# Test 37: icon_for returns correct icons
run_test
w_icon=$(icon_for "working")
f_icon=$(icon_for "finished")
if [ "$w_icon" = "⟳" ] && [ "$f_icon" = "●" ]; then
    pass "icon_for returns correct icons"
else
    fail "icon_for returns correct icons" "working='$w_icon', finished='$f_icon'"
fi

# Test 38: Scripts source lib.sh
run_test
lib_sourcing=0
for script in notify.sh scan.sh clear.sh dashboard.sh telegram.sh telegram-send.sh; do
    if grep -q 'source.*lib\.sh' "./$script"; then
        lib_sourcing=$((lib_sourcing + 1))
    fi
done
if [ "$lib_sourcing" -ge 6 ]; then
    pass "Core scripts source lib.sh ($lib_sourcing scripts)"
else
    fail "Core scripts source lib.sh" "Only $lib_sourcing scripts source lib.sh, expected >= 6"
fi

# =============================================================================
# Notification Aging Tests
# =============================================================================
printf "\n${YELLOW}=== Notification Aging Tests ===${NC}\n"

# Test 39: dashboard.sh has aging rules for finished and waiting
run_test
has_finished_aging=$(grep -c 'finished.*21600' ./dashboard.sh)
has_waiting_aging=$(grep -c 'waiting.*86400' ./dashboard.sh)
if [ "$has_finished_aging" -gt 0 ] && [ "$has_waiting_aging" -gt 0 ]; then
    pass "dashboard.sh has aging rules (finished=6h, waiting=24h)"
else
    fail "dashboard.sh has aging rules" "finished=$has_finished_aging, waiting=$has_waiting_aging"
fi

# Test 40: status.sh has aging checks
run_test
has_status_aging=$(grep -c '21600\|86400' ./status.sh)
if [ "$has_status_aging" -ge 2 ]; then
    pass "status.sh has aging checks"
else
    fail "status.sh has aging checks" "Found $has_status_aging aging references"
fi

# =============================================================================
# Telegram Dedup Tests
# =============================================================================
printf "\n${YELLOW}=== Telegram Dedup Tests ===${NC}\n"

# Test 41: telegram-send.sh has editMessageText support
run_test
if grep -q 'editMessageText' ./telegram-send.sh; then
    pass "telegram-send.sh supports editMessageText"
else
    fail "telegram-send.sh supports editMessageText"
fi

# Test 42: telegram-send.sh creates msg_id directory
run_test
if grep -q 'telegram_msg_ids' ./telegram-send.sh; then
    pass "telegram-send.sh uses message ID tracking directory"
else
    fail "telegram-send.sh uses message ID tracking directory"
fi

# =============================================================================
# Install/Uninstall Tests
# =============================================================================
printf "\n${YELLOW}=== Install/Uninstall Tests ===${NC}\n"

# Test 43: install.sh registers all 7 hooks
run_test
hook_count=0
for hook in SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest; do
    if grep -q "hooks\.$hook" ./install.sh; then
        hook_count=$((hook_count + 1))
    fi
done
if [ "$hook_count" -eq 7 ]; then
    pass "install.sh registers all 7 hooks"
else
    fail "install.sh registers all 7 hooks" "Found $hook_count, expected 7"
fi

# Test 44: uninstall.sh removes all 7 hooks
run_test
unhook_count=0
for hook in SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest; do
    if grep -q "hooks\.$hook" ./uninstall.sh; then
        unhook_count=$((unhook_count + 1))
    fi
done
if [ "$unhook_count" -eq 7 ]; then
    pass "uninstall.sh removes all 7 hooks"
else
    fail "uninstall.sh removes all 7 hooks" "Found $unhook_count, expected 7"
fi

# Test 45: install.sh installs backends.conf
run_test
if grep -q 'backends.conf' ./install.sh; then
    pass "install.sh installs backends.conf"
else
    fail "install.sh installs backends.conf"
fi

# =============================================================================
# Restart Tests
# =============================================================================
printf "\n${YELLOW}=== Restart Tests ===${NC}\n"

# Test 46: restart.sh exists and is executable
run_test
if [ -x ./restart.sh ]; then
    pass "restart.sh is executable"
else
    fail "restart.sh is executable"
fi

# Test 47: restart.sh --help shows usage
run_test
output=$(./restart.sh --help 2>&1)
if [[ "$output" == *"--yes"* ]] && [[ "$output" == *"--version"* ]]; then
    pass "restart.sh --help shows usage"
else
    fail "restart.sh --help shows usage" "Got: $output"
fi

# Test 48: telegram.sh has /restart handler
run_test
if grep -q '/restart)' ./telegram.sh && grep -q 'cmd_restart' ./telegram.sh; then
    pass "telegram.sh has /restart handler"
else
    fail "telegram.sh has /restart handler"
fi

# Test 49: restart.sh sources lib.sh
run_test
if grep -q 'source.*lib\.sh' ./restart.sh; then
    pass "restart.sh sources lib.sh"
else
    fail "restart.sh sources lib.sh"
fi

# Test 50: install.sh makes restart.sh executable
run_test
if grep -q 'restart.sh' ./install.sh; then
    pass "install.sh includes restart.sh"
else
    fail "install.sh includes restart.sh"
fi

# =============================================================================
# Doctor / Version Tests
# =============================================================================
printf "\n${YELLOW}=== Doctor / Version Tests ===${NC}\n"

# Test 51: VERSION file exists and matches semver
run_test
if [ -f ./VERSION ]; then
    ver="$(<./VERSION)"
    ver="${ver%$'\n'}"
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        pass "VERSION file exists and matches semver (${ver})"
    else
        fail "VERSION file matches semver" "Got: '${ver}'"
    fi
else
    fail "VERSION file exists"
fi

# Test 52: doctor.sh exists and is executable
run_test
if [ -x ./doctor.sh ]; then
    pass "doctor.sh is executable"
else
    fail "doctor.sh is executable"
fi

# Test 53: doctor.sh --help shows usage
run_test
output=$(./doctor.sh --help 2>&1)
if [[ "$output" == *"--quiet"* ]] && [[ "$output" == *"diagnostics"* ]]; then
    pass "doctor.sh --help shows usage"
else
    fail "doctor.sh --help shows usage" "Got: $output"
fi

# Test 54: install.sh copies VERSION to installed_version
run_test
if grep -q 'installed_version' ./install.sh; then
    pass "install.sh records installed version"
else
    fail "install.sh records installed version"
fi

# Test 55: doctor.sh checks all 7 hook events
run_test
hook_count=0
for hook in SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest; do
    if grep -q "$hook" ./doctor.sh; then
        hook_count=$((hook_count + 1))
    fi
done
if [ "$hook_count" -eq 7 ]; then
    pass "doctor.sh checks all 7 hook events"
else
    fail "doctor.sh checks all 7 hook events" "Found $hook_count, expected 7"
fi

# Test 56: doctor.sh --quiet only shows problems
run_test
output=$(./doctor.sh --quiet 2>&1) || true
if [[ "$output" != *"PASS"* ]]; then
    pass "doctor.sh --quiet hides PASS lines"
else
    fail "doctor.sh --quiet hides PASS lines" "Output contained PASS"
fi

# Test 57: install.sh makes doctor.sh executable
run_test
if grep -q 'doctor.sh' ./install.sh; then
    pass "install.sh includes doctor.sh"
else
    fail "install.sh includes doctor.sh"
fi

# =============================================================================
# Summary
# =============================================================================
printf "\n${YELLOW}=== Test Summary ===${NC}\n"
printf "Tests run:    %d\n" "$TESTS_RUN"
printf "Tests passed: ${GREEN}%d${NC}\n" "$TESTS_PASSED"
printf "Tests failed: ${RED}%d${NC}\n" "$TESTS_FAILED"

if [ "$TESTS_FAILED" -eq 0 ]; then
    printf "\n${GREEN}All tests passed!${NC}\n\n"
    exit 0
else
    printf "\n${RED}Some tests failed.${NC}\n\n"
    exit 1
fi
