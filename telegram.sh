#!/usr/bin/env bash
# Claude Code Notifier — Telegram bot daemon
# Long-polling loop that receives commands from Telegram and dispatches to tmux
# Usage: telegram.sh start|stop|status|run
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${HOME}/.local/share/claude-notifier"
CONFIG_FILE="${DATA_DIR}/telegram.conf"
PID_FILE="${DATA_DIR}/telegram.pid"
LOG_FILE="${DATA_DIR}/telegram.log"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"

# Check dependencies
for cmd in curl jq tmux; do
    command -v "$cmd" &>/dev/null || { printf 'Error: %s required\n' "$cmd"; exit 1; }
done

# Load config
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf 'Error: Telegram not configured. Run: %s/telegram-setup.sh\n' "$SCRIPT_DIR"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
        printf 'Error: Invalid config. Run: %s/telegram-setup.sh\n' "$SCRIPT_DIR"
        exit 1
    fi
    API_BASE="https://api.telegram.org/bot${BOT_TOKEN}"
}

# ─── Daemon management ───────────────────────────────────────────────────────

cmd_start() {
    load_config
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid="$(<"$PID_FILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            printf 'Bot already running (PID %s)\n' "$old_pid"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi
    printf 'Starting Telegram bot daemon...\n'
    nohup "$0" run >> "$LOG_FILE" 2>&1 &
    local new_pid=$!
    printf '%d' "$new_pid" > "$PID_FILE"
    printf 'Started (PID %d). Log: %s\n' "$new_pid" "$LOG_FILE"
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        printf 'Bot is not running.\n'
        return 0
    fi
    local pid
    pid="$(<"$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        # Wait briefly for clean exit
        local i=0
        while [ "$i" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 0.5
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        printf 'Bot stopped (PID %d).\n' "$pid"
    else
        printf 'Bot was not running (stale PID file).\n'
    fi
    rm -f "$PID_FILE"
}

cmd_status() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(<"$PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            printf 'Bot is running (PID %s)\n' "$pid"
            return 0
        fi
        printf 'Bot is not running (stale PID file)\n'
        rm -f "$PID_FILE"
        return 1
    fi
    printf 'Bot is not running.\n'
    return 1
}

# ─── Session helpers ──────────────────────────────────────────────────────────

# Build indexed session list in display order: working → waiting → finished → idle
# Sets SESSION_LIST array: "index|session|window|category|message"
build_session_list() {
    SESSION_LIST=()
    local idx=0
    local cat

    for cat in working waiting finished idle; do
        local dir files
        case "$cat" in
            working|idle) dir="$ACTIVE_DIR" ;;
            waiting|finished) dir="$NOTIF_DIR" ;;
        esac
        [ -d "$dir" ] || continue

        for f in "$dir"/*; do
            [ -f "$f" ] || continue
            local sess="" win="" msg="" type=""
            while IFS= read -r line; do
                case "$line" in
                    SESSION=*)   sess="${line#SESSION=}" ;;
                    WINDOW=*)    win="${line#WINDOW=}" ;;
                    MESSAGE=*)   msg="${line#MESSAGE=}" ;;
                    TYPE=*)      type="${line#TYPE=}" ;;
                esac
            done < "$f" || true
            [ -z "$sess" ] && continue

            # Map type to category
            local file_cat
            case "$type" in
                working) file_cat="working" ;;
                idle)    file_cat="idle" ;;
                waiting) file_cat="waiting" ;;
                *)       file_cat="finished" ;;
            esac
            [ "$file_cat" != "$cat" ] && continue

            idx=$((idx + 1))
            SESSION_LIST+=("${idx}|${sess}|${win}|${cat}|${msg}")
        done
    done
}

# Get session entry by index, sets S_SESS, S_WIN, S_CAT, S_MSG
get_session() {
    local target="$1"
    S_SESS="" S_WIN="" S_CAT="" S_MSG=""
    for entry in "${SESSION_LIST[@]}"; do
        IFS='|' read -r idx sess win cat msg <<< "$entry"
        if [ "$idx" = "$target" ]; then
            S_SESS="$sess" S_WIN="$win" S_CAT="$cat" S_MSG="$msg"
            return 0
        fi
    done
    return 1
}

icon_for() {
    case "$1" in
        working)  printf '⟳' ;;
        waiting)  printf '⏳' ;;
        finished) printf '●' ;;
        idle)     printf '○' ;;
    esac
}

# ─── Telegram API helpers ────────────────────────────────────────────────────

send_message() {
    local text="$1"
    local keyboard="${2:-}"
    local data

    if [ -n "$keyboard" ]; then
        data="$(jq -n \
            --arg chat "$CHAT_ID" \
            --arg text "$text" \
            --argjson kb "$keyboard" \
            '{chat_id: ($chat | tonumber), text: $text, parse_mode: "HTML", reply_markup: $kb}')"
    else
        data="$(jq -n \
            --arg chat "$CHAT_ID" \
            --arg text "$text" \
            '{chat_id: ($chat | tonumber), text: $text, parse_mode: "HTML"}')"
    fi

    curl -s --max-time 10 \
        -X POST "${API_BASE}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$data" >/dev/null 2>&1 || true
}

answer_callback() {
    local callback_id="$1"
    local text="${2:-}"
    curl -s --max-time 10 \
        -X POST "${API_BASE}/answerCallbackQuery" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg id "$callback_id" --arg text "$text" \
            '{callback_query_id: $id, text: $text}')" >/dev/null 2>&1 || true
}

# ─── Command handlers ────────────────────────────────────────────────────────

cmd_help() {
    send_message "$(cat <<'MSG'
<b>Claude Code Notifier</b>

<b>Commands:</b>
/status, /s — All sessions with status
/sessions, /ls — Numbered session list
/view &lt;n&gt;, /v &lt;n&gt; — Last 50 lines of output
/send &lt;n&gt; &lt;msg&gt; — Send text to Claude pane
/approve &lt;n&gt;, /a &lt;n&gt; — Send "y" to approve
/deny &lt;n&gt;, /d &lt;n&gt; — Send "n" to deny
/run &lt;n&gt; &lt;cmd&gt; — Run command in new window
/help — This message
MSG
)"
}

cmd_sessions() {
    build_session_list
    if [ "${#SESSION_LIST[@]}" -eq 0 ]; then
        send_message "No active Claude Code sessions."
        return
    fi
    local text="<b>Sessions:</b>\n"
    for entry in "${SESSION_LIST[@]}"; do
        IFS='|' read -r idx sess win cat msg <<< "$entry"
        local icon
        icon="$(icon_for "$cat")"
        text="${text}\n${idx}. ${icon} <b>${sess}:${win}</b>"
    done
    send_message "$text"
}

cmd_bot_status() {
    build_session_list
    if [ "${#SESSION_LIST[@]}" -eq 0 ]; then
        send_message "No active Claude Code sessions."
        return
    fi
    local text="<b>Session Status:</b>\n"
    local last_cat=""
    for entry in "${SESSION_LIST[@]}"; do
        IFS='|' read -r idx sess win cat msg <<< "$entry"
        if [ "$cat" != "$last_cat" ]; then
            local label
            case "$cat" in
                working) label="WORKING" ;; waiting) label="WAITING" ;;
                finished) label="FINISHED" ;; idle) label="IDLE" ;;
            esac
            text="${text}\n<b>${label}</b>"
            last_cat="$cat"
        fi
        local icon
        icon="$(icon_for "$cat")"
        text="${text}\n  ${idx}. ${icon} ${sess}:${win}"
        [ -n "$msg" ] && [ "$msg" != "Idle" ] && [ "$msg" != "Working..." ] && text="${text} — ${msg}"
    done
    send_message "$text"
}

cmd_view() {
    local num="$1"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found. Use /sessions to list."
        return
    fi
    # Capture last 50 lines, strip ANSI escape codes, cap at 4000 chars
    local output
    output="$(tmux capture-pane -t "${S_SESS}:${S_WIN}" -p -S -50 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')" || {
        send_message "Could not capture output from ${S_SESS}:${S_WIN}"
        return
    }
    # Trim trailing blank lines
    output="$(printf '%s' "$output" | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }')"
    if [ -z "$output" ]; then
        output="(empty)"
    fi
    # Cap at 4000 chars (Telegram message limit is 4096)
    if [ "${#output}" -gt 4000 ]; then
        output="${output:0:3997}..."
    fi
    send_message "<b>${S_SESS}:${S_WIN}</b>\n\n<pre>$(printf '%s' "$output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"
}

cmd_send() {
    local num="$1"
    shift
    local msg="$*"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found."
        return
    fi
    if [ -z "$msg" ]; then
        send_message "Usage: /send &lt;n&gt; &lt;message&gt;"
        return
    fi
    tmux send-keys -t "${S_SESS}:${S_WIN}" "$msg" Enter 2>/dev/null && \
        send_message "Sent to ${S_SESS}:${S_WIN}" || \
        send_message "Failed to send to ${S_SESS}:${S_WIN}"
}

cmd_approve() {
    local num="$1"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found."
        return
    fi
    tmux send-keys -t "${S_SESS}:${S_WIN}" "y" Enter 2>/dev/null && \
        send_message "✅ Approved ${S_SESS}:${S_WIN}" || \
        send_message "Failed to approve ${S_SESS}:${S_WIN}"
}

cmd_deny() {
    local num="$1"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found."
        return
    fi
    tmux send-keys -t "${S_SESS}:${S_WIN}" "n" Enter 2>/dev/null && \
        send_message "❌ Denied ${S_SESS}:${S_WIN}" || \
        send_message "Failed to deny ${S_SESS}:${S_WIN}"
}

cmd_run() {
    local num="$1"
    shift
    local run_cmd="$*"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found."
        return
    fi
    if [ -z "$run_cmd" ]; then
        send_message "Usage: /run &lt;n&gt; &lt;command&gt;"
        return
    fi
    # Create a new window adjacent to the target, run command, capture output
    local new_win
    new_win="$(tmux new-window -t "${S_SESS}" -a -P -F '#{window_index}' 2>/dev/null)" || {
        send_message "Failed to create window in ${S_SESS}"
        return
    }
    tmux send-keys -t "${S_SESS}:${new_win}" "$run_cmd" Enter 2>/dev/null
    send_message "Running in ${S_SESS}:${new_win}...\n<pre>$(printf '%s' "$run_cmd" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"

    # Wait for command to produce output, then capture
    sleep 2
    local output
    output="$(tmux capture-pane -t "${S_SESS}:${new_win}" -p -S -50 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')" || output=""
    output="$(printf '%s' "$output" | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }')"
    if [ -n "$output" ]; then
        if [ "${#output}" -gt 4000 ]; then
            output="${output:0:3997}..."
        fi
        send_message "<b>Output from ${S_SESS}:${new_win}</b>\n\n<pre>$(printf '%s' "$output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"
    fi
}

# ─── Callback handler (inline keyboard buttons) ──────────────────────────────

handle_callback() {
    local callback_id="$1" data="$2"
    local action sess win

    IFS=':' read -r action sess win <<< "$data"

    case "$action" in
        approve)
            tmux send-keys -t "${sess}:${win}" "y" Enter 2>/dev/null && \
                answer_callback "$callback_id" "Approved" || \
                answer_callback "$callback_id" "Failed"
            ;;
        deny)
            tmux send-keys -t "${sess}:${win}" "n" Enter 2>/dev/null && \
                answer_callback "$callback_id" "Denied" || \
                answer_callback "$callback_id" "Failed"
            ;;
        view)
            answer_callback "$callback_id" ""
            # Reuse cmd_view logic but need to find the session index
            local output
            output="$(tmux capture-pane -t "${sess}:${win}" -p -S -50 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')" || output="(could not capture)"
            output="$(printf '%s' "$output" | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }')"
            [ -z "$output" ] && output="(empty)"
            if [ "${#output}" -gt 4000 ]; then
                output="${output:0:3997}..."
            fi
            send_message "<b>${sess}:${win}</b>\n\n<pre>$(printf '%s' "$output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"
            ;;
        *)
            answer_callback "$callback_id" "Unknown action"
            ;;
    esac
}

# ─── Message dispatcher ──────────────────────────────────────────────────────

dispatch_message() {
    local text="$1"

    # Parse command and args
    local cmd args
    cmd="${text%% *}"
    if [ "$cmd" = "$text" ]; then
        args=""
    else
        args="${text#* }"
    fi

    case "$cmd" in
        /help|/start)
            cmd_help
            ;;
        /status|/s)
            cmd_bot_status
            ;;
        /sessions|/ls)
            cmd_sessions
            ;;
        /view|/v)
            if [ -z "$args" ]; then
                send_message "Usage: /view &lt;n&gt;"
                return
            fi
            cmd_view "${args%% *}"
            ;;
        /send)
            if [ -z "$args" ]; then
                send_message "Usage: /send &lt;n&gt; &lt;message&gt;"
                return
            fi
            local num="${args%% *}"
            local msg="${args#* }"
            [ "$msg" = "$num" ] && msg=""
            cmd_send "$num" "$msg"
            ;;
        /approve|/a)
            if [ -z "$args" ]; then
                send_message "Usage: /approve &lt;n&gt;"
                return
            fi
            cmd_approve "${args%% *}"
            ;;
        /deny|/d)
            if [ -z "$args" ]; then
                send_message "Usage: /deny &lt;n&gt;"
                return
            fi
            cmd_deny "${args%% *}"
            ;;
        /run)
            if [ -z "$args" ]; then
                send_message "Usage: /run &lt;n&gt; &lt;command&gt;"
                return
            fi
            local num="${args%% *}"
            local run_cmd="${args#* }"
            [ "$run_cmd" = "$num" ] && run_cmd=""
            cmd_run "$num" "$run_cmd"
            ;;
        *)
            send_message "Unknown command. Type /help for available commands."
            ;;
    esac
}

# ─── Main polling loop ───────────────────────────────────────────────────────

cmd_run_daemon() {
    load_config
    printf '[%s] Telegram bot started (PID %d)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$"

    local offset=0

    # Clean shutdown on signals
    trap 'printf "[%s] Bot stopping\n" "$(date "+%Y-%m-%d %H:%M:%S")"; exit 0' INT TERM

    while true; do
        local url="${API_BASE}/getUpdates?timeout=30&offset=${offset}"
        local response
        response="$(curl -s --max-time 35 "$url" 2>/dev/null)" || {
            sleep 5
            continue
        }

        local ok
        ok="$(printf '%s' "$response" | jq -r '.ok' 2>/dev/null)" || ok="false"
        [ "$ok" = "true" ] || { sleep 5; continue; }

        local count
        count="$(printf '%s' "$response" | jq '.result | length' 2>/dev/null)" || count=0
        [ "$count" -gt 0 ] || continue

        local i=0
        while [ "$i" -lt "$count" ]; do
            local update
            update="$(printf '%s' "$response" | jq ".result[$i]" 2>/dev/null)"
            local update_id
            update_id="$(printf '%s' "$update" | jq -r '.update_id' 2>/dev/null)"

            # Advance offset
            if [ -n "$update_id" ]; then
                offset=$((update_id + 1))
            fi

            # Check for callback query (inline keyboard button press)
            local callback_id callback_data callback_chat
            callback_id="$(printf '%s' "$update" | jq -r '.callback_query.id // empty' 2>/dev/null)"
            if [ -n "$callback_id" ]; then
                callback_chat="$(printf '%s' "$update" | jq -r '.callback_query.from.id // empty' 2>/dev/null)"
                if [ "$callback_chat" = "$CHAT_ID" ]; then
                    callback_data="$(printf '%s' "$update" | jq -r '.callback_query.data // empty' 2>/dev/null)"
                    [ -n "$callback_data" ] && handle_callback "$callback_id" "$callback_data"
                fi
                i=$((i + 1))
                continue
            fi

            # Check for regular message
            local from_id msg_text
            from_id="$(printf '%s' "$update" | jq -r '.message.from.id // empty' 2>/dev/null)"
            if [ -z "$from_id" ]; then
                i=$((i + 1))
                continue
            fi

            # Security: validate sender
            if [ "$from_id" != "$CHAT_ID" ]; then
                printf '[%s] Rejected message from unauthorized user: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$from_id"
                i=$((i + 1))
                continue
            fi

            msg_text="$(printf '%s' "$update" | jq -r '.message.text // empty' 2>/dev/null)"
            if [ -n "$msg_text" ]; then
                printf '[%s] Command: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg_text"
                dispatch_message "$msg_text"
            fi

            i=$((i + 1))
        done
    done
}

# ─── Entry point ──────────────────────────────────────────────────────────────

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    run)    cmd_run_daemon ;;
    *)
        printf 'Usage: %s start|stop|status|run\n' "$(basename "$0")"
        printf '  start  — Start bot as background daemon\n'
        printf '  stop   — Stop running daemon\n'
        printf '  status — Check if daemon is running\n'
        printf '  run    — Run in foreground (for debugging)\n'
        exit 1
        ;;
esac
