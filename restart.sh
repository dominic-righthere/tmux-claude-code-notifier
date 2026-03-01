#!/usr/bin/env bash
# Claude Code Notifier — bulk restart all Claude Code sessions
# Sends /exit to all sessions, waits for them to exit, then relaunches with claude -c
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SKIP_CONFIRM=0
INSTALL_VERSION=""
EXIT_TIMEOUT=15

usage() {
    printf 'Usage: %s [OPTIONS]\n\n' "$(basename "$0")"
    printf 'Restart all Claude Code sessions in tmux.\n\n'
    printf 'Options:\n'
    printf '  -y, --yes              Skip confirmation prompt\n'
    printf '  -v, --version <ver>    Install specific version before restarting\n'
    printf '  -h, --help             Show this help message\n'
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            SKIP_CONFIRM=1
            shift
            ;;
        -v|--version)
            if [ -z "${2:-}" ]; then
                printf 'Error: --version requires a version argument\n'
                exit 1
            fi
            INSTALL_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1"
            usage
            exit 1
            ;;
    esac
done

# Discover Claude Code panes
PANES=()
PANE_LABELS=()
while IFS='|' read -r sess win pane cmd; do
    [[ "$cmd" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    PANES+=("${sess}|${win}|${pane}")
    PANE_LABELS+=("${sess}:${win} (v${cmd})")
done < <(tmux list-panes -a -F "#{session_name}|#{window_index}|#{pane_id}|#{pane_current_command}" 2>/dev/null)

if [ "${#PANES[@]}" -eq 0 ]; then
    printf 'No Claude Code sessions found.\n'
    exit 0
fi

# Show what will be restarted
printf 'Found %d Claude Code session(s):\n' "${#PANES[@]}"
for label in "${PANE_LABELS[@]}"; do
    printf '  %s\n' "$label"
done

# Version install
if [ -n "$INSTALL_VERSION" ]; then
    printf '\nWill install Claude Code v%s before restarting.\n' "$INSTALL_VERSION"
fi

# Confirmation
if [ "$SKIP_CONFIRM" -eq 0 ]; then
    printf '\nRestart all? [y/N] '
    read -r confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
    esac
fi

# Install specific version if requested
if [ -n "$INSTALL_VERSION" ]; then
    printf '\nInstalling Claude Code v%s...\n' "$INSTALL_VERSION"
    if curl -fsSL https://claude.ai/install.sh | bash -s -- "$INSTALL_VERSION"; then
        printf 'Installation complete.\n'
    else
        printf 'Error: Installation failed. Aborting restart.\n'
        exit 1
    fi
fi

# Phase 1: Gracefully exit each pane — wait for prompt before sending /exit
send_exit_to_pane() {
    local pane="$1" sess="$2" win="$3"
    local max_wait=5 elapsed=0

    # Send Escape + Ctrl+C to dismiss any active dialog
    tmux send-keys -t "$pane" Escape 2>/dev/null || true
    tmux send-keys -t "$pane" C-c 2>/dev/null || true

    # Poll for the ❯ prompt (up to max_wait seconds)
    while [ "$elapsed" -lt "$max_wait" ]; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        local content
        content="$(tmux capture-pane -t "$pane" -p -S -3 2>/dev/null)" || continue
        if printf '%s' "$content" | grep -q '❯'; then
            # Prompt visible — send /exit
            tmux send-keys -t "$pane" "/exit" Enter 2>/dev/null || true
            printf '  Sent /exit to %s:%s\n' "$sess" "$win"
            return
        fi
    done

    # Prompt never appeared — retry Ctrl+C and send /exit anyway
    tmux send-keys -t "$pane" C-c 2>/dev/null || true
    sleep 0.3
    tmux send-keys -t "$pane" "/exit" Enter 2>/dev/null || true
    printf '  Sent /exit to %s:%s (prompt not detected)\n' "$sess" "$win"
}

printf '\nSending /exit to all sessions...\n'
for entry in "${PANES[@]}"; do
    IFS='|' read -r sess win pane <<< "$entry"
    send_exit_to_pane "$pane" "$sess" "$win"
done

# Phase 2: Poll until panes are no longer running Claude Code
printf 'Waiting for sessions to exit (timeout: %ds)...\n' "$EXIT_TIMEOUT"
REMAINING=("${PANES[@]}")
ELAPSED=0

while [ "${#REMAINING[@]}" -gt 0 ] && [ "$ELAPSED" -lt "$EXIT_TIMEOUT" ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    STILL_RUNNING=()
    for entry in "${REMAINING[@]}"; do
        IFS='|' read -r sess win pane <<< "$entry"
        local_cmd="$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null)" || local_cmd=""
        if [[ "$local_cmd" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            STILL_RUNNING+=("$entry")
        fi
    done
    REMAINING=("${STILL_RUNNING[@]+"${STILL_RUNNING[@]}"}")
done

# Report stuck sessions
if [ "${#REMAINING[@]}" -gt 0 ]; then
    printf 'Warning: %d session(s) did not exit within %ds:\n' "${#REMAINING[@]}" "$EXIT_TIMEOUT"
    for entry in "${REMAINING[@]}"; do
        IFS='|' read -r sess win pane <<< "$entry"
        printf '  %s:%s\n' "$sess" "$win"
    done
fi

# Phase 3: Relaunch all sessions
printf 'Relaunching Claude Code...\n'
LAUNCHED=0
FAILED=0
for entry in "${PANES[@]}"; do
    IFS='|' read -r sess win pane <<< "$entry"
    if tmux send-keys -t "$pane" "claude -c" Enter 2>/dev/null; then
        printf '  Launched in %s:%s\n' "$sess" "$win"
        LAUNCHED=$((LAUNCHED + 1))
    else
        printf '  Failed to launch in %s:%s\n' "$sess" "$win"
        FAILED=$((FAILED + 1))
    fi
done

# Summary
printf '\nDone: %d launched' "$LAUNCHED"
[ "$FAILED" -gt 0 ] && printf ', %d failed' "$FAILED"
[ "${#REMAINING[@]}" -gt 0 ] && printf ', %d stuck' "${#REMAINING[@]}"
printf '.\n'
