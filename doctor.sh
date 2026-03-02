#!/usr/bin/env bash
# Claude Code Notifier — diagnostics and drift detection
# Checks that the installed configuration matches the repo and is healthy.
# Usage: doctor.sh [--quiet|-q] [--help|-h]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"
SETTINGS_FILE="${HOME}/.claude/settings.json"
TMUX_CONF="${HOME}/.tmux.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

QUIET=0
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        --help|-h)
            printf 'Usage: %s [--quiet|-q] [--help|-h]\n\n' "$(basename "$0")"
            printf 'Runs diagnostics on Claude Code Notifier installation.\n\n'
            printf 'Checks:\n'
            printf '  1. Version — repo vs installed version\n'
            printf '  2. Dependencies — jq, tmux, curl\n'
            printf '  3. Data directories — active, notifications\n'
            printf '  4. Hooks — all 7 events in settings.json\n'
            printf '  5. Tmux block — markers and paths in tmux.conf\n'
            printf '  6. Scripts — all .sh files are executable\n'
            printf '  7. Telegram — config file has required keys (optional)\n\n'
            printf 'Flags:\n'
            printf '  --quiet, -q   Only show WARN/FAIL lines; exit 1 if any FAIL\n'
            printf '  --help, -h    Show this help\n'
            exit 0
            ;;
    esac
done

result_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    [ "$QUIET" -eq 0 ] && printf "  ${GREEN}PASS${NC} %s\n" "$1"
}

result_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf "  ${YELLOW}WARN${NC} %s\n" "$1"
}

result_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "  ${RED}FAIL${NC} %s\n" "$1"
}

[ "$QUIET" -eq 0 ] && printf 'Claude Code Notifier — Doctor\n\n'

# ─── 1. Version check ────────────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Version${NC}\n"

REPO_VERSION=""
INSTALLED_VERSION=""

if [ -f "${SCRIPT_DIR}/VERSION" ]; then
    REPO_VERSION="$(<"${SCRIPT_DIR}/VERSION")"
    REPO_VERSION="${REPO_VERSION%$'\n'}"
fi

if [ -f "${DATA_DIR}/installed_version" ]; then
    INSTALLED_VERSION="$(<"${DATA_DIR}/installed_version")"
    INSTALLED_VERSION="${INSTALLED_VERSION%$'\n'}"
fi

if [ -z "$REPO_VERSION" ]; then
    result_fail "VERSION file missing from repo"
elif [ -z "$INSTALLED_VERSION" ]; then
    result_warn "No installed version found — run install.sh (repo: ${REPO_VERSION})"
elif [ "$REPO_VERSION" != "$INSTALLED_VERSION" ]; then
    result_warn "Version mismatch — repo: ${REPO_VERSION}, installed: ${INSTALLED_VERSION} — re-run install.sh"
else
    result_pass "Version ${REPO_VERSION}"
fi

# ─── 2. Dependencies ─────────────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Dependencies${NC}\n"

for dep in jq tmux curl uv; do
    if command -v "$dep" &>/dev/null; then
        result_pass "${dep} found"
    else
        if [ "$dep" = "uv" ]; then
            result_fail "${dep} not found — install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
        else
            result_fail "${dep} not found"
        fi
    fi
done

# Check Python telegram package
if [ -d "${SCRIPT_DIR}/telegram" ] && [ -f "${SCRIPT_DIR}/telegram/pyproject.toml" ]; then
    if [ -d "${SCRIPT_DIR}/telegram/.venv" ]; then
        result_pass "Python venv present"
    else
        result_warn "Python venv missing — run: cd ${SCRIPT_DIR}/telegram && uv sync"
    fi
else
    result_fail "telegram/ Python package missing"
fi

# ─── 3. Data directories ─────────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Data directories${NC}\n"

for dir in "${DATA_DIR}/active" "${DATA_DIR}/notifications"; do
    dir_name="${dir#"${DATA_DIR}/"}"
    if [ -d "$dir" ]; then
        result_pass "${dir_name}/ exists"
    else
        result_fail "${dir_name}/ missing — run install.sh"
    fi
done

# ─── 4. Hooks ─────────────────────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Hooks${NC}\n"

HOOK_EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse Stop Notification PermissionRequest"

if [ ! -f "$SETTINGS_FILE" ]; then
    result_fail "settings.json not found at ${SETTINGS_FILE}"
else
    for hook in $HOOK_EVENTS; do
        # Check hook exists and points to notify.sh in this repo
        hook_cmd="$(jq -r ".hooks.${hook}[0].hooks[0].command // empty" "$SETTINGS_FILE" 2>/dev/null)"
        if [ -z "$hook_cmd" ]; then
            result_fail "Hook ${hook} not configured"
        elif [ "$hook_cmd" != "${SCRIPT_DIR}/notify.sh" ]; then
            result_fail "Hook ${hook} points to wrong path: ${hook_cmd}"
        else
            result_pass "Hook ${hook}"
        fi
    done
fi

# ─── 5. Tmux block ───────────────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Tmux config${NC}\n"

if [ ! -f "$TMUX_CONF" ]; then
    result_fail "~/.tmux.conf not found"
else
    if grep -q '# claude-notifier-begin' "$TMUX_CONF" && grep -q '# claude-notifier-end' "$TMUX_CONF"; then
        # Check that paths reference the correct SCRIPT_DIR
        if grep -q "${SCRIPT_DIR}/" "$TMUX_CONF"; then
            result_pass "Tmux block present with correct paths"
        else
            result_fail "Tmux block present but paths don't match repo (${SCRIPT_DIR})"
        fi
    else
        result_fail "Tmux block markers missing — run install.sh"
    fi
fi

# ─── 6. Scripts executable ───────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Scripts${NC}\n"

non_exec=""
for f in "${SCRIPT_DIR}"/*.sh; do
    [ -f "$f" ] || continue
    if [ ! -x "$f" ]; then
        non_exec="${non_exec} $(basename "$f")"
    fi
done

if [ -z "$non_exec" ]; then
    result_pass "All .sh files are executable"
else
    result_fail "Not executable:${non_exec}"
fi

# ─── 7. Telegram (optional) ──────────────────────────────────────────────────

[ "$QUIET" -eq 0 ] && printf "${YELLOW}Telegram${NC}\n"

TELEGRAM_CONF="${DATA_DIR}/telegram.conf"

if [ ! -f "$TELEGRAM_CONF" ]; then
    result_warn "Telegram not configured (optional)"
else
    has_token=0
    has_chat=0
    while IFS= read -r line; do
        case "$line" in
            BOT_TOKEN=?*) has_token=1 ;;
            CHAT_ID=?*) has_chat=1 ;;
        esac
    done < "$TELEGRAM_CONF"

    if [ "$has_token" -eq 1 ] && [ "$has_chat" -eq 1 ]; then
        result_pass "Telegram config has BOT_TOKEN and CHAT_ID"
    else
        result_warn "Telegram config incomplete (missing BOT_TOKEN or CHAT_ID)"
    fi

    # Check bot process health
    bot_pid_file="${DATA_DIR}/telegram.pid"
    if [ -f "$bot_pid_file" ]; then
        bot_pid="$(<"$bot_pid_file")"
        if kill -0 "$bot_pid" 2>/dev/null; then
            result_pass "Telegram bot running (PID ${bot_pid})"

            # Stale code check: compare installed_version mtime vs process start time
            version_file="${DATA_DIR}/installed_version"
            if [ -f "$version_file" ]; then
                version_mtime="$(stat -f %m "$version_file" 2>/dev/null || stat -c %Y "$version_file" 2>/dev/null)" || version_mtime=""
                proc_start="$(ps -o lstart= -p "$bot_pid" 2>/dev/null)" || proc_start=""
                if [ -n "$version_mtime" ] && [ -n "$proc_start" ]; then
                    proc_epoch="$(date -jf '%a %b %d %T %Y' "$proc_start" +%s 2>/dev/null || date -d "$proc_start" +%s 2>/dev/null)" || proc_epoch=""
                    if [ -n "$proc_epoch" ] && [ "$version_mtime" -gt "$proc_epoch" ]; then
                        result_warn "Telegram bot running stale code — restart with: telegram-bot.sh stop && telegram-bot.sh start"
                    else
                        result_pass "Telegram bot code is up to date"
                    fi
                fi
            fi

            # Log inode mismatch check
            log_file="${DATA_DIR}/telegram.log"
            if [ -f "$log_file" ] && command -v lsof &>/dev/null; then
                disk_inode="$(stat -f %i "$log_file" 2>/dev/null || stat -c %i "$log_file" 2>/dev/null)" || disk_inode=""
                proc_inode="$(lsof -p "$bot_pid" 2>/dev/null | grep 'telegram\.log' | awk '{print $8}' | head -1)" || proc_inode=""
                if [ -n "$disk_inode" ] && [ -n "$proc_inode" ] && [ "$disk_inode" != "$proc_inode" ]; then
                    result_warn "Telegram bot log inode mismatch — bot output not reaching log file"
                elif [ -n "$disk_inode" ] && [ -n "$proc_inode" ]; then
                    result_pass "Telegram bot log inode matches"
                fi
            fi
        else
            result_warn "Telegram bot not running (stale PID file)"
            rm -f "$bot_pid_file"
        fi
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

printf "\n"
if [ "$QUIET" -eq 0 ]; then
    printf "  ${GREEN}%d passed${NC}  " "$PASS_COUNT"
    [ "$WARN_COUNT" -gt 0 ] && printf "${YELLOW}%d warnings${NC}  " "$WARN_COUNT"
    [ "$FAIL_COUNT" -gt 0 ] && printf "${RED}%d failed${NC}  " "$FAIL_COUNT"
    printf "\n\n"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
