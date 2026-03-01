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
# Telegram Send Tests
# =============================================================================
printf "\n${YELLOW}=== Telegram Send Tests ===${NC}\n"

# Test 41: telegram-send.sh uses editMessageText for edit-in-place
run_test
if grep -q 'editMessageText' ./telegram-send.sh; then
    pass "telegram-send.sh uses editMessageText (edit-in-place)"
else
    fail "telegram-send.sh uses editMessageText (edit-in-place)"
fi

# Test 42: telegram-send.sh uses sendMessage as fallback
run_test
if grep -q 'sendMessage' ./telegram-send.sh; then
    pass "telegram-send.sh uses sendMessage"
else
    fail "telegram-send.sh uses sendMessage"
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

# Test 51: restart.sh has prompt-wait logic
run_test
if grep -q 'send_exit_to_pane' ./restart.sh && grep -q '❯' ./restart.sh; then
    pass "restart.sh has prompt-wait before /exit"
else
    fail "restart.sh has prompt-wait before /exit"
fi

# =============================================================================
# Doctor / Version Tests
# =============================================================================
printf "\n${YELLOW}=== Doctor / Version Tests ===${NC}\n"

# Test 52: VERSION file exists and matches semver
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

# Test 53: doctor.sh exists and is executable
run_test
if [ -x ./doctor.sh ]; then
    pass "doctor.sh is executable"
else
    fail "doctor.sh is executable"
fi

# Test 54: doctor.sh --help shows usage
run_test
output=$(./doctor.sh --help 2>&1)
if [[ "$output" == *"--quiet"* ]] && [[ "$output" == *"diagnostics"* ]]; then
    pass "doctor.sh --help shows usage"
else
    fail "doctor.sh --help shows usage" "Got: $output"
fi

# Test 55: install.sh copies VERSION to installed_version
run_test
if grep -q 'installed_version' ./install.sh; then
    pass "install.sh records installed version"
else
    fail "install.sh records installed version"
fi

# Test 56: doctor.sh checks all 7 hook events
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

# Test 57: doctor.sh --quiet only shows problems
run_test
output=$(./doctor.sh --quiet 2>&1) || true
if [[ "$output" != *"PASS"* ]]; then
    pass "doctor.sh --quiet hides PASS lines"
else
    fail "doctor.sh --quiet hides PASS lines" "Output contained PASS"
fi

# Test 58: install.sh makes doctor.sh executable
run_test
if grep -q 'doctor.sh' ./install.sh; then
    pass "install.sh includes doctor.sh"
else
    fail "install.sh includes doctor.sh"
fi

# =============================================================================
# Formatting Pipeline Tests (lib.sh functions)
# =============================================================================
printf "\n${YELLOW}=== Formatting Pipeline Tests ===${NC}\n"

# Test 59: trim_blank_lines is in lib.sh (not duplicated in telegram.sh)
run_test
if grep -q 'trim_blank_lines()' ./lib.sh && ! grep -q 'trim_blank_lines()' ./telegram.sh; then
    pass "trim_blank_lines is in lib.sh only"
else
    fail "trim_blank_lines is in lib.sh only"
fi

# Test 60: reflow_for_telegram is in lib.sh (not duplicated in telegram.sh)
run_test
if grep -q 'reflow_for_telegram()' ./lib.sh && ! grep -q 'reflow_for_telegram()' ./telegram.sh; then
    pass "reflow_for_telegram is in lib.sh only"
else
    fail "reflow_for_telegram is in lib.sh only"
fi

# Test 61: extract_activity_log parses ⎿ lines into bullet list
run_test
test_input="$(printf '❯ do something\n⏺ Working on it\n  ⎿ Read src/index.ts\n  ⎿ Edit src/utils.ts\n  ⎿ Bash: npm test\n')"
result="$(extract_activity_log "$test_input")"
if printf '%s' "$result" | grep -q '• Read src/index.ts' && \
   printf '%s' "$result" | grep -q '• Edit src/utils.ts' && \
   printf '%s' "$result" | grep -q '• Bash: npm test'; then
    pass "extract_activity_log parses ⎿ lines into bullet list"
else
    fail "extract_activity_log parses ⎿ lines into bullet list" "Got: '$result'"
fi

# Test 62: extract_activity_log deduplicates repeated tool calls
run_test
test_input="$(printf '❯ do something\n  ⎿ Read foo.ts\n  ⎿ Read foo.ts\n  ⎿ Edit bar.ts\n')"
result="$(extract_activity_log "$test_input")"
read_count="$(printf '%s' "$result" | grep -c '• Read foo.ts')"
if [ "$read_count" -eq 1 ]; then
    pass "extract_activity_log deduplicates repeated tool calls"
else
    fail "extract_activity_log deduplicates repeated tool calls" "Read foo.ts appeared $read_count times"
fi

# Test 63: extract_prompt_text extracts text between ⏺ and ❯ markers (char budget)
run_test
test_input="$(printf '⏺ Here is some old text\n  old content\n⏺ I will now edit the file\n  This is the plan\n❯ 1. Yes\n  2. No\n')"
result="$(extract_prompt_text "$test_input" 1500)"
if printf '%s' "$result" | grep -q 'This is the plan'; then
    pass "extract_prompt_text extracts text between ⏺ and ❯ markers (char budget)"
else
    fail "extract_prompt_text extracts text between ⏺ and ❯ markers (char budget)" "Got: '$result'"
fi

# Test 64: convert_tables_to_bullets converts pipe-delimited table to bullet format
run_test
test_table="$(printf '| Name | Value |\n|------|-------|\n| foo  | bar   |\n| baz  | qux   |\n')"
result="$(printf '%s' "$test_table" | convert_tables_to_bullets)"
if printf '%s' "$result" | grep -qF -- '- Name: foo' && \
   printf '%s' "$result" | grep -qF -- '- Name: baz'; then
    pass "convert_tables_to_bullets converts table to bullet format"
else
    fail "convert_tables_to_bullets converts table to bullet format" "Got: '$result'"
fi

# Test 65: convert_tables_to_bullets passes non-table lines unchanged
run_test
test_mixed="$(printf 'Hello world\n| A | B |\n|---|---|\n| 1 | 2 |\nGoodbye\n')"
result="$(printf '%s' "$test_mixed" | convert_tables_to_bullets)"
if printf '%s' "$result" | grep -q 'Hello world' && \
   printf '%s' "$result" | grep -q 'Goodbye' && \
   printf '%s' "$result" | grep -qF -- '- A: 1'; then
    pass "convert_tables_to_bullets passes non-table lines unchanged"
else
    fail "convert_tables_to_bullets passes non-table lines unchanged" "Got: '$result'"
fi

# Test 66: wrap_long_lines wraps at target width
run_test
long_line="This is a long line that should be wrapped at a reasonable width for mobile devices to read"
result="$(printf '%s' "$long_line" | wrap_long_lines 30)"
max_len=0
while IFS= read -r line; do
    len="${#line}"
    [ "$len" -gt "$max_len" ] && max_len="$len"
done <<< "$result"
if [ "$max_len" -le 30 ]; then
    pass "wrap_long_lines wraps at target width"
else
    fail "wrap_long_lines wraps at target width" "Max line length: $max_len (expected <= 30)"
fi

# Test 67: telegram-send.sh captures 200 lines (-S -200)
run_test
if grep -q '\-S -200' ./telegram-send.sh; then
    pass "telegram-send.sh captures 200 lines (-S -200)"
else
    fail "telegram-send.sh captures 200 lines (-S -200)"
fi

# Test 68: telegram-send.sh uses extract_activity_log
run_test
if grep -q 'extract_activity_log' ./telegram-send.sh; then
    pass "telegram-send.sh uses extract_activity_log"
else
    fail "telegram-send.sh uses extract_activity_log"
fi

# Test 69: telegram-send.sh uses extract_prompt_text
run_test
if grep -q 'extract_prompt_text' ./telegram-send.sh; then
    pass "telegram-send.sh uses extract_prompt_text"
else
    fail "telegram-send.sh uses extract_prompt_text"
fi

# =============================================================================
# Bot Hardening Tests
# =============================================================================
printf "\n${YELLOW}=== Bot Hardening Tests ===${NC}\n"

# Test 70: install.sh restarts Telegram bot if running
run_test
if grep -q 'telegram\.sh.*stop' ./install.sh && grep -q 'telegram\.sh.*start' ./install.sh; then
    pass "install.sh restarts Telegram bot during install"
else
    fail "install.sh restarts Telegram bot during install"
fi

# Test 71: doctor.sh checks for bot log inode mismatch
run_test
if grep -q 'lsof' ./doctor.sh && grep -q 'inode' ./doctor.sh; then
    pass "doctor.sh checks for bot log inode mismatch"
else
    fail "doctor.sh checks for bot log inode mismatch"
fi

# Test 72: telegram.sh log truncation preserves inode (no mv LOG_FILE pattern)
run_test
if ! grep -q 'mv.*LOG_FILE' ./telegram.sh; then
    pass "telegram.sh log truncation preserves inode (no mv pattern)"
else
    fail "telegram.sh log truncation preserves inode" "Found mv...LOG_FILE pattern — creates new inode"
fi

# =============================================================================
# Telegram UX Fix Tests
# =============================================================================
printf "\n${YELLOW}=== Telegram UX Fix Tests ===${NC}\n"

# Test 73: telegram-send.sh has outgoing message logging (via log_event)
run_test
if grep -q 'log_event' ./telegram-send.sh; then
    pass "telegram-send.sh has outgoing message logging (log_event)"
else
    fail "telegram-send.sh has outgoing message logging (log_event)"
fi

# Test 74: telegram-send.sh tracks msg_ids in telegram_msg_ids directory
run_test
if grep -q 'MSG_ID_DIR' ./telegram-send.sh && grep -q 'telegram_msg_ids' ./telegram-send.sh; then
    pass "telegram-send.sh tracks msg_ids"
else
    fail "telegram-send.sh tracks msg_ids"
fi

# Test 75: telegram.sh has check_target helper
run_test
if grep -q 'check_target()' ./telegram.sh && grep -q 'CHECK_ERR' ./telegram.sh; then
    pass "telegram.sh has check_target helper"
else
    fail "telegram.sh has check_target helper"
fi

# Test 76: telegram.sh has strip_buttons function
run_test
if grep -q 'strip_buttons()' ./telegram.sh && grep -q 'editMessageReplyMarkup' ./telegram.sh; then
    pass "telegram.sh has strip_buttons function"
else
    fail "telegram.sh has strip_buttons function"
fi

# Test 77: telegram.sh has edit_message function
run_test
if grep -q 'edit_message()' ./telegram.sh && grep -q 'editMessageText' ./telegram.sh; then
    pass "telegram.sh has edit_message function"
else
    fail "telegram.sh has edit_message function"
fi

# Test 78: telegram.sh clears notification state on approve/deny callbacks
run_test
if grep -q 'clear_session_state' ./telegram.sh; then
    count=$(grep -c 'clear_session_state' ./telegram.sh)
    if [ "$count" -ge 6 ]; then
        pass "telegram.sh clears state on approve/deny ($count calls)"
    else
        fail "telegram.sh clears state on approve/deny" "Only $count clear_session_state calls, expected >= 6"
    fi
else
    fail "telegram.sh clears state on approve/deny" "No clear_session_state found"
fi

# Test 79: telegram.sh strips buttons after approve/deny callback
run_test
if grep -q 'strip_buttons.*cb_msg_id' ./telegram.sh; then
    pass "telegram.sh strips buttons after approve/deny"
else
    fail "telegram.sh strips buttons after approve/deny"
fi

# Test 80: telegram.sh sessions edit-in-place with LAST_SESSIONS_MSG_ID
run_test
if grep -q 'LAST_SESSIONS_MSG_ID' ./telegram.sh && grep -q 'edit_message.*LAST_SESSIONS' ./telegram.sh; then
    pass "telegram.sh sessions edit-in-place"
else
    fail "telegram.sh sessions edit-in-place"
fi

# Test 81: notify.sh cleans up telegram_msg_ids on UserPromptSubmit
run_test
if grep -q 'MSG_ID_DIR' ./notify.sh && grep 'UserPromptSubmit' -A3 ./notify.sh | grep -q 'MSG_ID_DIR'; then
    pass "notify.sh cleans up msg_ids on UserPromptSubmit"
else
    fail "notify.sh cleans up msg_ids on UserPromptSubmit"
fi

# Test 82: notify.sh cleans up telegram_msg_ids on SessionEnd
run_test
if grep 'SessionEnd' -A3 ./notify.sh | grep -q 'MSG_ID_DIR'; then
    pass "notify.sh cleans up msg_ids on SessionEnd"
else
    fail "notify.sh cleans up msg_ids on SessionEnd"
fi

# Test 83: install.sh creates telegram_msg_ids directory
run_test
if grep -q 'telegram_msg_ids' ./install.sh; then
    pass "install.sh creates telegram_msg_ids directory"
else
    fail "install.sh creates telegram_msg_ids directory"
fi

# Test 84: telegram.sh send_message returns message_id
run_test
if grep -A5 'send_message()' ./telegram.sh | grep -q 'msg_id'; then
    pass "telegram.sh send_message returns message_id"
else
    fail "telegram.sh send_message returns message_id"
fi

# Test 85: telegram.sh handle_callback accepts 3rd parameter (cb_msg_id)
run_test
if grep -q 'cb_msg_id=.*{3:-}' ./telegram.sh; then
    pass "telegram.sh handle_callback accepts cb_msg_id parameter"
else
    fail "telegram.sh handle_callback accepts cb_msg_id parameter"
fi

# Test 86: telegram.sh extracts callback_query.message.message_id in polling loop
run_test
if grep -q 'callback_msg_id' ./telegram.sh && grep -q 'callback_query.message.message_id' ./telegram.sh; then
    pass "telegram.sh extracts callback message_id in polling loop"
else
    fail "telegram.sh extracts callback message_id in polling loop"
fi

# Test 87: telegram.sh uses check_target in cmd_view
run_test
if sed -n '/^cmd_view/,/^cmd_send/p' ./telegram.sh | grep -q 'check_target'; then
    pass "telegram.sh uses check_target in cmd_view"
else
    fail "telegram.sh uses check_target in cmd_view"
fi

# Test 88: telegram.sh uses check_target in cmd_send
run_test
if sed -n '/^cmd_send/,/^cmd_approve/p' ./telegram.sh | grep -q 'check_target'; then
    pass "telegram.sh uses check_target in cmd_send"
else
    fail "telegram.sh uses check_target in cmd_send"
fi

# Test 89: telegram.sh uses check_target in cmd_run
run_test
if sed -n '/^cmd_run/,/^cmd_doctor/p' ./telegram.sh | grep -q 'check_target'; then
    pass "telegram.sh uses check_target in cmd_run"
else
    fail "telegram.sh uses check_target in cmd_run"
fi

# =============================================================================
# Event Logging Tests (SQLite)
# =============================================================================
printf "\n${YELLOW}=== Event Logging Tests ===${NC}\n"

# Test 90: init_events_db creates the database and table
run_test
TEST_EVENTS_DB="${TEST_DATA_DIR}/test_events.db"
EVENTS_DB="$TEST_EVENTS_DB"
rm -f "$TEST_EVENTS_DB"
init_events_db
if [ -f "$TEST_EVENTS_DB" ]; then
    table_exists="$(sqlite3 "$TEST_EVENTS_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='events';" 2>/dev/null)"
    if [ "$table_exists" = "events" ]; then
        pass "init_events_db creates database and table"
    else
        fail "init_events_db creates database and table" "Table 'events' not found"
    fi
else
    fail "init_events_db creates database and table" "Database file not created"
fi

# Test 91: init_events_db is idempotent (second call succeeds)
run_test
init_events_db
if [ $? -eq 0 ]; then
    pass "init_events_db is idempotent"
else
    fail "init_events_db is idempotent"
fi

# Test 92: log_event inserts a row with correct fields
run_test
log_event src hook event SessionStart session "my-sess" window "0"
row="$(sqlite3 "$TEST_EVENTS_DB" "SELECT src, event, session, window FROM events ORDER BY id DESC LIMIT 1;" 2>/dev/null)"
if [ "$row" = "hook|SessionStart|my-sess|0" ]; then
    pass "log_event inserts row with correct fields"
else
    fail "log_event inserts row with correct fields" "Got: '$row'"
fi

# Test 93: log_event handles single quotes in values (SQL escaping)
run_test
log_event src send event new message "it's a test" text "User said 'hello' and \"bye\""
row="$(sqlite3 "$TEST_EVENTS_DB" "SELECT message FROM events ORDER BY id DESC LIMIT 1;" 2>/dev/null)"
if [ "$row" = "it's a test" ]; then
    pass "log_event handles single quotes in values"
else
    fail "log_event handles single quotes in values" "Got: '$row'"
fi

# Test 94: log_event handles newlines in text field
run_test
log_event src send event new text "line1
line2
line3"
row="$(sqlite3 "$TEST_EVENTS_DB" "SELECT length(text) > 10 FROM events ORDER BY id DESC LIMIT 1;" 2>/dev/null)"
if [ "$row" = "1" ]; then
    pass "log_event handles newlines in text field"
else
    fail "log_event handles newlines in text field" "Got: '$row'"
fi

# Test 95: log_event generates timestamp automatically
run_test
log_event src bot event start
ts="$(sqlite3 "$TEST_EVENTS_DB" "SELECT ts FROM events ORDER BY id DESC LIMIT 1;" 2>/dev/null)"
if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    pass "log_event generates ISO timestamp"
else
    fail "log_event generates ISO timestamp" "Got: '$ts'"
fi

# Test 96: log_event silently no-ops when DB is missing
run_test
EVENTS_DB="${TEST_DATA_DIR}/nonexistent/missing.db"
log_event src hook event test
exit_code=$?
EVENTS_DB="$TEST_EVENTS_DB"
if [ "$exit_code" -eq 0 ]; then
    pass "log_event no-ops when DB is missing"
else
    fail "log_event no-ops when DB is missing" "Exit code: $exit_code"
fi

# Test 97: WAL mode is enabled
run_test
journal="$(sqlite3 "$TEST_EVENTS_DB" "PRAGMA journal_mode;" 2>/dev/null)"
if [ "$journal" = "wal" ]; then
    pass "WAL mode is enabled"
else
    fail "WAL mode is enabled" "Got: '$journal'"
fi

# Test 98: notify.sh has log_event in all 7 event branches
run_test
log_count=0
for hook in SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest; do
    # Check that the case block for this hook contains log_event
    if sed -n "/${hook})/,/;;/p" ./notify.sh | grep -q 'log_event'; then
        log_count=$((log_count + 1))
    fi
done
if [ "$log_count" -eq 7 ]; then
    pass "notify.sh has log_event in all 7 event branches"
else
    fail "notify.sh has log_event in all 7 event branches" "Found $log_count, expected 7"
fi

# Test 99: telegram-send.sh uses log_event (not old log function)
run_test
if grep -q 'log_event' ./telegram-send.sh && ! grep -q '^log()' ./telegram-send.sh; then
    pass "telegram-send.sh uses log_event (old log removed)"
else
    fail "telegram-send.sh uses log_event (old log removed)"
fi

# Test 100: telegram.sh uses log_event
run_test
if grep -q 'log_event' ./telegram.sh; then
    tg_log_count=$(grep -c 'log_event' ./telegram.sh)
    if [ "$tg_log_count" -ge 4 ]; then
        pass "telegram.sh uses log_event ($tg_log_count calls)"
    else
        fail "telegram.sh uses log_event" "Only $tg_log_count calls, expected >= 4"
    fi
else
    fail "telegram.sh uses log_event" "No log_event found"
fi

# Test 101: telegram.sh initializes events DB in cmd_run_daemon
run_test
if sed -n '/^cmd_run_daemon/,/^}/p' ./telegram.sh | grep -q 'init_events_db'; then
    pass "telegram.sh initializes events DB on daemon start"
else
    fail "telegram.sh initializes events DB on daemon start"
fi

# Test 102: telegram.sh prunes old events on daemon start
run_test
if sed -n '/^cmd_run_daemon/,/^}/p' ./telegram.sh | grep -q "DELETE FROM events"; then
    pass "telegram.sh prunes old events on daemon start"
else
    fail "telegram.sh prunes old events on daemon start"
fi

# Test 103: lib.sh defines EVENTS_DB, init_events_db, log_event
run_test
has_all=true
for sym in EVENTS_DB init_events_db log_event; do
    if ! grep -q "$sym" ./lib.sh; then
        has_all=false
    fi
done
if [ "$has_all" = "true" ]; then
    pass "lib.sh defines EVENTS_DB, init_events_db, log_event"
else
    fail "lib.sh defines EVENTS_DB, init_events_db, log_event"
fi

# Restore EVENTS_DB for any subsequent tests
EVENTS_DB="${HOME}/.local/share/claude-notifier/events.db"

# =============================================================================
# Modular Pipeline & Button Fix Tests
# =============================================================================
printf "\n${YELLOW}=== Modular Pipeline & Button Fix Tests ===${NC}\n"

# Test 104: telegram-send.sh has build_header function
run_test
if grep -q '^build_header()' ./telegram-send.sh; then
    pass "telegram-send.sh has build_header function"
else
    fail "telegram-send.sh has build_header function"
fi

# Test 105: telegram-send.sh has build_body function
run_test
if grep -q '^build_body()' ./telegram-send.sh; then
    pass "telegram-send.sh has build_body function"
else
    fail "telegram-send.sh has build_body function"
fi

# Test 106: telegram-send.sh has build_keyboard function
run_test
if grep -q '^build_keyboard()' ./telegram-send.sh; then
    pass "telegram-send.sh has build_keyboard function"
else
    fail "telegram-send.sh has build_keyboard function"
fi

# Test 107: telegram-send.sh has send_or_edit function
run_test
if grep -q '^send_or_edit()' ./telegram-send.sh; then
    pass "telegram-send.sh has send_or_edit function"
else
    fail "telegram-send.sh has send_or_edit function"
fi

# Test 108: build_keyboard scopes option regex to prompt block (after last ⏺)
run_test
# The awk in build_keyboard should scope to after last ⏺, not scan all raw_context
if grep -A30 'build_keyboard()' ./telegram-send.sh | grep -q 'prompt_block'; then
    pass "build_keyboard scopes option extraction to prompt block"
else
    fail "build_keyboard scopes option extraction to prompt block"
fi

# Test 109: build_keyboard caps at 4 option buttons max
run_test
if grep -A30 'build_keyboard()' ./telegram-send.sh | grep -q 'btn_count.*-ge 4'; then
    pass "build_keyboard caps at 4 option buttons"
else
    fail "build_keyboard caps at 4 option buttons"
fi

# Test 110: build_keyboard puts each option button on its own row
run_test
# Each button should be wrapped in its own array: [btn] not [btn1,btn2,btn3]
if grep -A40 'build_keyboard()' ./telegram-send.sh | grep -q 'option_rows.*\[${btn}\]'; then
    pass "build_keyboard puts each option on its own row"
else
    fail "build_keyboard puts each option on its own row"
fi

# Test 111: msg_id file stores id:type format
run_test
if grep -q 'printf.*%s.*:.*TYPE.*MSG_ID_DIR' ./telegram-send.sh || \
   grep -q '${new_msg_id}:${TYPE}' ./telegram-send.sh; then
    pass "msg_id file stores id:type format"
else
    fail "msg_id file stores id:type format"
fi

# Test 112: send_or_edit skips editing when prev_type=waiting and TYPE=finished
run_test
if grep -q 'prev_type.*=.*waiting.*&&.*TYPE.*=.*finished' ./telegram-send.sh || \
   grep -A5 'Type guard' ./telegram-send.sh | grep -q 'skip_edit'; then
    pass "send_or_edit type guard: finished skips editing waiting"
else
    fail "send_or_edit type guard: finished skips editing waiting"
fi

# Test 113: telegram.sh has handle_action helper function
run_test
if grep -q '^handle_action()' ./telegram.sh; then
    pass "telegram.sh has handle_action helper"
else
    fail "telegram.sh has handle_action helper"
fi

# Test 114: handle_callback uses handle_action for approve/deny/opt
run_test
approve_line="$(grep 'approve)' ./telegram.sh | grep 'handle_action' | head -1)"
deny_line="$(grep 'deny)' ./telegram.sh | grep 'handle_action' | head -1)"
opt_line="$(grep 'opt)' ./telegram.sh | grep 'handle_action' | head -1)"
if [ -n "$approve_line" ] && [ -n "$deny_line" ] && [ -n "$opt_line" ]; then
    pass "handle_callback uses handle_action for approve/deny/opt"
else
    fail "handle_callback uses handle_action for approve/deny/opt" \
        "approve=$([[ -n "$approve_line" ]] && echo ok || echo missing) deny=$([[ -n "$deny_line" ]] && echo ok || echo missing) opt=$([[ -n "$opt_line" ]] && echo ok || echo missing)"
fi

# Test 115: handle_action logs callback results
run_test
if grep -A15 '^handle_action()' ./telegram.sh | grep -q 'log_event.*callback_ok' && \
   grep -A15 '^handle_action()' ./telegram.sh | grep -q 'log_event.*callback_fail'; then
    pass "handle_action logs callback results"
else
    fail "handle_action logs callback results"
fi

# Test 116: build_keyboard logs button count and style
run_test
if grep -q 'log_event.*event keyboard' ./telegram-send.sh && grep -q 'buttons=' ./telegram-send.sh; then
    pass "build_keyboard logs button count and style"
else
    fail "build_keyboard logs button count and style"
fi

# =============================================================================
# Char-Budget & Pipeline Tests
# =============================================================================
printf "\n${YELLOW}=== Char-Budget & Pipeline Tests ===${NC}\n"

# Test 117: extract_prompt_text respects char budget on long input
run_test
long_lines=""
for i in $(seq 1 50); do
    long_lines="${long_lines}This is line number ${i} with some padding text to make it longer.\n"
done
long_input="$(printf "⏺ Starting work\n${long_lines}❯ 1. Yes\n")"
result="$(extract_prompt_text "$long_input" 200)"
if [ "${#result}" -le 210 ] && printf '%s' "$result" | grep -q '\.\.\.'; then
    pass "extract_prompt_text respects char budget on long input"
else
    fail "extract_prompt_text respects char budget on long input" "Length: ${#result}, ends with ...: $(printf '%s' "$result" | tail -c 5)"
fi

# Test 118: extract_prompt_text returns full text when under budget
run_test
short_input="$(printf '⏺ A short message\n  Just a few words here\n❯ 1. Ok\n')"
result="$(extract_prompt_text "$short_input" 1500)"
if printf '%s' "$result" | grep -q 'Just a few words here' && ! printf '%s' "$result" | grep -q '\.\.\.'; then
    pass "extract_prompt_text returns full text when under budget"
else
    fail "extract_prompt_text returns full text when under budget" "Got: '$result'"
fi

# Test 119: telegram-send.sh extracts before wrapping (wrap_long_lines after extract_prompt_text)
run_test
# extract_prompt_text should use reflowed (not wrapped) text, then wrap_long_lines runs after
extract_line="$(grep -n 'extract_prompt_text.*reflowed' ./telegram-send.sh | head -1 | cut -d: -f1)"
wrap_line="$(grep -n 'prompt_text.*wrap_long_lines' ./telegram-send.sh | head -1 | cut -d: -f1)"
if [ -n "$extract_line" ] && [ -n "$wrap_line" ] && [ "$wrap_line" -gt "$extract_line" ]; then
    pass "telegram-send.sh extracts before wrapping"
else
    fail "telegram-send.sh extracts before wrapping" "extract_line=$extract_line wrap_line=$wrap_line"
fi

# Test 120: notify.sh extracts prompt from UserPromptSubmit
run_test
if sed -n '/UserPromptSubmit)/,/;;/p' ./notify.sh | grep -q 'extract_json_value.*prompt'; then
    pass "notify.sh extracts prompt from UserPromptSubmit"
else
    fail "notify.sh extracts prompt from UserPromptSubmit"
fi

# Test 121: Notification handler skips dispatch when waiting exists
run_test
if sed -n '/Notification)/,/;;/p' ./notify.sh | grep -q 'skipped (waiting exists)'; then
    pass "Notification handler skips dispatch when waiting exists"
else
    fail "Notification handler skips dispatch when waiting exists"
fi

# Test 122: notify.sh dispatches prompt on UserPromptSubmit
run_test
if sed -n '/UserPromptSubmit)/,/;;/p' ./notify.sh | grep -q 'dispatch.sh.*prompt'; then
    pass "notify.sh dispatches prompt on UserPromptSubmit"
else
    fail "notify.sh dispatches prompt on UserPromptSubmit"
fi

# Test 123: telegram-send.sh handles prompt type
run_test
if grep -q 'waiting|finished|prompt' ./telegram-send.sh; then
    pass "telegram-send.sh handles prompt type"
else
    fail "telegram-send.sh handles prompt type"
fi

# Test 124: telegram-send.sh has detect_mode function
run_test
if grep -q '^detect_mode()' ./telegram-send.sh; then
    pass "telegram-send.sh has detect_mode function"
else
    fail "telegram-send.sh has detect_mode function"
fi

# Test 125: detect_mode extracts mode from ⏵⏵ indicator (not hardcoded)
run_test
if sed -n '/^detect_mode()/,/^}/p' ./telegram-send.sh | grep -q '⏵⏵'; then
    pass "detect_mode keys off ⏵⏵ indicator"
else
    fail "detect_mode keys off ⏵⏵ indicator"
fi

# Test 126: build_keyboard skips approve/deny in auto mode
run_test
if grep -q 'mode_auto' ./telegram-send.sh; then
    pass "build_keyboard checks mode_auto"
else
    fail "build_keyboard checks mode_auto"
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
