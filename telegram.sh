#!/usr/bin/env bash
# Claude Code Notifier — Telegram bot daemon
# Long-polling loop that receives commands from Telegram and dispatches to tmux
# Usage: telegram.sh start|stop|status|run
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
DATA_DIR="${HOME}/.local/share/claude-notifier"
CONFIG_FILE="${DATA_DIR}/telegram.conf"
PID_FILE="${DATA_DIR}/telegram.pid"
LOG_FILE="${DATA_DIR}/telegram.log"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
MSG_ID_DIR="${DATA_DIR}/telegram_msg_ids"

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




# Get enriched session info: project name, mode, task hint
# Usage: get_session_info "session" "window"
# Sets: CTX_PROJECT, CTX_MODE, CTX_MODE_ICON, CTX_TASK
get_session_info() {
    local sess="$1" win="$2"
    CTX_PROJECT="" CTX_MODE="" CTX_MODE_ICON="" CTX_TASK=""

    # Get project name from pane current path
    local pane_path
    pane_path="$(tmux display-message -t "${sess}:${win}" -p '#{pane_current_path}' 2>/dev/null)" || pane_path=""
    if [ -n "$pane_path" ]; then
        CTX_PROJECT="$(basename "$pane_path")"
    fi

    # Capture bottom ~5 lines for mode and task detection
    local bottom
    bottom="$(tmux capture-pane -t "${sess}:${win}" -J -p -S -8 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')" || bottom=""

    if [ -n "$bottom" ]; then
        # Mode detection
        if printf '%s' "$bottom" | grep -qi 'plan mode'; then
            CTX_MODE="plan mode"
            CTX_MODE_ICON="⏸"
        elif printf '%s' "$bottom" | grep -qi 'auto-accept\|accept edits'; then
            CTX_MODE="auto-accept"
            CTX_MODE_ICON="⏵⏵"
        fi

        # Task hint: find last line starting with ❯ (user's prompt)
        local task_line
        task_line="$(printf '%s' "$bottom" | grep '❯' | tail -1)" || task_line=""
        if [ -n "$task_line" ]; then
            # Strip the ❯ prefix and trim
            CTX_TASK="${task_line#*❯}"
            CTX_TASK="${CTX_TASK#"${CTX_TASK%%[![:space:]]*}"}"
            # Truncate to 60 chars
            if [ "${#CTX_TASK}" -gt 60 ]; then
                CTX_TASK="${CTX_TASK:0:57}..."
            fi
        fi
    fi
}

# ─── Telegram API helpers ────────────────────────────────────────────────────

send_message() {
    local text
    # Convert literal \n to real newlines (bash string builders use \n)
    text="$(printf '%b' "$1")"
    local keyboard="${2:-}"
    local data response msg_id

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

    response="$(curl -s --max-time 10 \
        -X POST "${API_BASE}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$data")" || response=""

    # Return message_id via stdout
    msg_id="$(printf '%s' "$response" | jq -r '.result.message_id // empty' 2>/dev/null)" || msg_id=""
    printf '%s' "$msg_id"
}

edit_message() {
    local msg_id="$1" text keyboard="${3:-}"
    text="$(printf '%b' "$2")"
    local data response

    if [ -n "$keyboard" ]; then
        data="$(jq -n \
            --arg chat "$CHAT_ID" \
            --arg msg_id "$msg_id" \
            --arg text "$text" \
            --argjson kb "$keyboard" \
            '{chat_id: ($chat | tonumber), message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML", reply_markup: $kb}')"
    else
        data="$(jq -n \
            --arg chat "$CHAT_ID" \
            --arg msg_id "$msg_id" \
            --arg text "$text" \
            '{chat_id: ($chat | tonumber), message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML"}')"
    fi

    response="$(curl -s --max-time 10 \
        -X POST "${API_BASE}/editMessageText" \
        -H "Content-Type: application/json" \
        -d "$data")" || response=""

    local ok
    ok="$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" || ok="false"
    [ "$ok" = "true" ]
}

strip_buttons() {
    local msg_id="$1"
    curl -s --max-time 10 \
        -X POST "${API_BASE}/editMessageReplyMarkup" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg chat "$CHAT_ID" --arg msg_id "$msg_id" \
            '{chat_id: ($chat | tonumber), message_id: ($msg_id | tonumber), reply_markup: {inline_keyboard: []}}')" \
        >/dev/null 2>&1 || true
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

# Check if a tmux session:window target exists
# Returns 0 if valid, 1 if not (with specific error in CHECK_ERR)
check_target() {
    local sess="$1" win="$2"
    CHECK_ERR=""
    if ! tmux has-session -t "$sess" 2>/dev/null; then
        CHECK_ERR="Session '${sess}' closed"
        return 1
    fi
    if ! tmux display-message -t "${sess}:${win}" -p '' 2>/dev/null; then
        CHECK_ERR="Window ${win} not found in '${sess}'"
        return 1
    fi
    return 0
}

# Clear notification state + msg_id for a session key
clear_session_state() {
    local sess="$1" win="$2"
    local key
    key="$(sanitize_key "$sess")_${win}"
    rm -f "${NOTIF_DIR}/${key}" "${MSG_ID_DIR}/${key}"
}

# ─── Command handlers ────────────────────────────────────────────────────────

cmd_help() {
    send_message "$(cat <<'MSG'
<b>Claude Code Notifier</b>

<b>Commands:</b>
/s — Interactive session list
/v &lt;n&gt; — View session output
/a &lt;n&gt; — Approve (send "y")
/d &lt;n&gt; — Deny (send "n")
/send &lt;n&gt; &lt;msg&gt; — Send text to session
/run &lt;n&gt; &lt;cmd&gt; — Run command in session
/restart — Restart all Claude Code sessions
/restart &lt;ver&gt; — Install version, then restart
/doctor — Run diagnostics
/help — This message
MSG
)" >/dev/null
}

LAST_SESSIONS_MSG_ID=""

cmd_sessions() {
    build_session_list
    if [ "${#SESSION_LIST[@]}" -eq 0 ]; then
        send_message "No active Claude Code sessions." >/dev/null
        return
    fi

    local text="<b>Sessions:</b>\n"
    local last_cat=""
    local keyboard_rows=""

    for entry in "${SESSION_LIST[@]}"; do
        IFS='|' read -r idx sess win cat msg <<< "$entry"

        # Category header
        if [ "$cat" != "$last_cat" ]; then
            local label
            case "$cat" in
                working) label="WORKING" ;; waiting) label="WAITING" ;;
                finished) label="FINISHED" ;; idle) label="IDLE" ;;
            esac
            text="${text}\n<b>${label}</b>"
            last_cat="$cat"
        fi

        # Enrich with project/mode/task
        get_session_info "$sess" "$win"
        local icon
        icon="$(icon_for "$cat")"

        local line="${idx}. ${icon}"
        [ -n "$CTX_MODE_ICON" ] && line="${line} ${CTX_MODE_ICON}"
        line="${line} ${sess}:${win}"
        [ -n "$CTX_PROJECT" ] && line="${line} (${CTX_PROJECT})"
        text="${text}\n  ${line}"
        if [ -n "$CTX_TASK" ]; then
            text="${text}\n     $(html_escape "$CTX_TASK")"
        elif [ -n "$msg" ] && [ "$msg" != "Idle" ] && [ "$msg" != "Working..." ]; then
            text="${text}\n     $(html_escape "$msg")"
        fi

        # Button label: use project name if available, truncated to 12 chars
        local btn_label="$idx"
        if [ -n "$CTX_PROJECT" ]; then
            local proj_short="$CTX_PROJECT"
            [ "${#proj_short}" -gt 12 ] && proj_short="${proj_short:0:12}"
            btn_label="$proj_short"
        fi

        # Build keyboard row for this session
        local row=""
        if [ "$cat" = "waiting" ]; then
            row="$(jq -n --arg bl "$btn_label" --arg s "$sess" --arg w "$win" \
                '[{text: ("✅ " + $bl), callback_data: ("approve:" + $s + ":" + $w)},
                  {text: ("❌ " + $bl), callback_data: ("deny:" + $s + ":" + $w)},
                  {text: ("👁 " + $bl), callback_data: ("view:" + $s + ":" + $w)}]')"
        else
            row="$(jq -n --arg bl "$btn_label" --arg s "$sess" --arg w "$win" \
                '[{text: ("👁 " + $bl), callback_data: ("view:" + $s + ":" + $w)}]')"
        fi

        if [ -n "$keyboard_rows" ]; then
            keyboard_rows="${keyboard_rows},${row}"
        else
            keyboard_rows="${row}"
        fi
    done

    # Add refresh button row
    local refresh_row='[{"text":"🔄 Refresh","callback_data":"sessions:refresh"}]'
    keyboard_rows="${keyboard_rows},${refresh_row}"

    local keyboard="{\"inline_keyboard\":[${keyboard_rows}]}"

    # Try edit-in-place if we have a previous sessions message
    if [ -n "$LAST_SESSIONS_MSG_ID" ]; then
        if edit_message "$LAST_SESSIONS_MSG_ID" "$text" "$keyboard"; then
            return
        fi
    fi
    LAST_SESSIONS_MSG_ID="$(send_message "$text" "$keyboard")"
}

cmd_view() {
    local num="$1"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found. Use /sessions to list." >/dev/null
        return
    fi
    if ! check_target "$S_SESS" "$S_WIN"; then
        send_message "${CHECK_ERR}" >/dev/null
        return
    fi
    # Capture last 200 lines, strip ANSI, reflow for phone readability
    local rw="${REFLOW_WIDTH:-$(tmux display-message -t "${S_SESS}:${S_WIN}" -p '#{pane_width}' 2>/dev/null || echo 120)}"
    local output
    output="$(tmux capture-pane -t "${S_SESS}:${S_WIN}" -J -p -S -200 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | reflow_for_telegram "$rw" \
        | convert_tables_to_bullets | wrap_long_lines 50)" || {
        send_message "Could not capture output from ${S_SESS}:${S_WIN}" >/dev/null
        return
    }
    # Trim trailing blank lines
    output="$(printf '%s' "$output" | trim_blank_lines)"
    if [ -z "$output" ]; then
        send_message "<b>${S_SESS}:${S_WIN}</b>\n\n(empty)" >/dev/null
        return
    fi

    # Compact header: session · project
    get_session_info "$S_SESS" "$S_WIN"
    local header="${S_SESS}:${S_WIN}"
    [ -n "$CTX_PROJECT" ] && header="${header} · ${CTX_PROJECT}"

    # Extract preview lines
    local preview_raw
    preview_raw="$(extract_preview "$output" 3)"
    local preview_escaped
    preview_escaped="$(html_escape "$preview_raw")"

    # Keep the LAST 3800 chars for the expandable section
    local max_content=3800
    if [ "${#output}" -gt "$max_content" ]; then
        output="...${output:$((${#output} - max_content))}"
    fi
    local output_escaped
    output_escaped="$(html_escape "$output")"

    send_message "<b>${header}</b>

${preview_escaped}

<blockquote expandable>${output_escaped}</blockquote>" >/dev/null
}

cmd_send() {
    local num="$1"
    shift
    local msg="$*"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found." >/dev/null
        return
    fi
    if [ -z "$msg" ]; then
        send_message "Usage: /send &lt;n&gt; &lt;message&gt;" >/dev/null
        return
    fi
    if ! check_target "$S_SESS" "$S_WIN"; then
        send_message "${CHECK_ERR}" >/dev/null
        return
    fi
    tmux send-keys -t "${S_SESS}:${S_WIN}" "$msg" Enter 2>/dev/null && \
        send_message "Sent to ${S_SESS}:${S_WIN}" >/dev/null || \
        send_message "Failed to send to ${S_SESS}:${S_WIN}" >/dev/null
}

cmd_approve() {
    local num="$1"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found." >/dev/null
        return
    fi
    if ! check_target "$S_SESS" "$S_WIN"; then
        send_message "${CHECK_ERR}" >/dev/null
        clear_session_state "$S_SESS" "$S_WIN"
        return
    fi
    if tmux send-keys -t "${S_SESS}:${S_WIN}" "y" Enter 2>/dev/null; then
        send_message "✅ Approved ${S_SESS}:${S_WIN}" >/dev/null
        clear_session_state "$S_SESS" "$S_WIN"
    else
        send_message "Failed to approve ${S_SESS}:${S_WIN}" >/dev/null
    fi
}

cmd_deny() {
    local num="$1"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found." >/dev/null
        return
    fi
    if ! check_target "$S_SESS" "$S_WIN"; then
        send_message "${CHECK_ERR}" >/dev/null
        clear_session_state "$S_SESS" "$S_WIN"
        return
    fi
    if tmux send-keys -t "${S_SESS}:${S_WIN}" "n" Enter 2>/dev/null; then
        send_message "❌ Denied ${S_SESS}:${S_WIN}" >/dev/null
        clear_session_state "$S_SESS" "$S_WIN"
    else
        send_message "Failed to deny ${S_SESS}:${S_WIN}" >/dev/null
    fi
}

cmd_run() {
    local num="$1"
    shift
    local run_cmd="$*"
    build_session_list
    if ! get_session "$num"; then
        send_message "Session #${num} not found." >/dev/null
        return
    fi
    if [ -z "$run_cmd" ]; then
        send_message "Usage: /run &lt;n&gt; &lt;command&gt;" >/dev/null
        return
    fi
    if ! check_target "$S_SESS" "$S_WIN"; then
        send_message "${CHECK_ERR}" >/dev/null
        return
    fi
    # Create a new window adjacent to the target, run command, capture output
    local new_win
    new_win="$(tmux new-window -t "${S_SESS}" -a -P -F '#{window_index}' 2>/dev/null)" || {
        send_message "Failed to create window in ${S_SESS}" >/dev/null
        return
    }
    tmux send-keys -t "${S_SESS}:${new_win}" "$run_cmd" Enter 2>/dev/null
    send_message "Running in ${S_SESS}:${new_win}...\n$(html_escape "$run_cmd")" >/dev/null

    # Wait for command to produce output, then capture
    sleep 2
    local rw="${REFLOW_WIDTH:-$(tmux display-message -t "${S_SESS}:${new_win}" -p '#{pane_width}' 2>/dev/null || echo 120)}"
    local output
    output="$(tmux capture-pane -t "${S_SESS}:${new_win}" -J -p -S -50 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | reflow_for_telegram "$rw")" || output=""
    output="$(printf '%s' "$output" | trim_blank_lines)"
    if [ -n "$output" ]; then
        if [ "${#output}" -gt 3800 ]; then
            output="...${output:$((${#output} - 3800))}"
        fi
        send_message "<b>Output from ${S_SESS}:${new_win}</b>\n\n$(html_escape "$output")" >/dev/null
    fi
}

cmd_doctor() {
    local output
    output="$("${SCRIPT_DIR}/doctor.sh" --quiet 2>&1)" || true
    if [ -z "$output" ]; then
        output="All checks passed."
    fi
    if [ "${#output}" -gt 3800 ]; then
        output="...${output:$((${#output} - 3800))}"
    fi
    send_message "<pre>$(html_escape "$output")</pre>" >/dev/null
}

cmd_restart() {
    local version="${1:-}"
    local args="--yes"
    if [ -n "$version" ]; then
        args="$args --version $version"
        send_message "Restarting all Claude Code sessions (installing v${version})..." >/dev/null
    else
        send_message "Restarting all Claude Code sessions..." >/dev/null
    fi
    local output
    output="$("${SCRIPT_DIR}/restart.sh" $args 2>&1)" || true
    if [ -z "$output" ]; then
        output="No output from restart script."
    fi
    # Truncate if needed
    if [ "${#output}" -gt 3800 ]; then
        output="...${output:$((${#output} - 3800))}"
    fi
    send_message "<pre>$(html_escape "$output")</pre>" >/dev/null
}

# ─── Callback handler (inline keyboard buttons) ──────────────────────────────

# Handle approve/deny/opt callback actions with shared logic
# Usage: handle_action <callback_id> <sess> <win> <keys> <label> <cb_msg_id>
handle_action() {
    local callback_id="$1" sess="$2" win="$3" keys="$4" label="$5" cb_msg_id="${6:-}"
    if ! check_target "$sess" "$win"; then
        answer_callback "$callback_id" "$CHECK_ERR"
        clear_session_state "$sess" "$win"
        [ -n "$cb_msg_id" ] && strip_buttons "$cb_msg_id"
        log_event src bot event callback_fail action "$label" session "$sess" window "$win"
        return
    fi
    if tmux send-keys -t "${sess}:${win}" $keys 2>/dev/null; then
        answer_callback "$callback_id" "$label"
        clear_session_state "$sess" "$win"
        [ -n "$cb_msg_id" ] && strip_buttons "$cb_msg_id"
        log_event src bot event callback_ok action "$label" session "$sess" window "$win"
    else
        answer_callback "$callback_id" "Failed to send keys"
        log_event src bot event callback_err action "$label" session "$sess" window "$win"
    fi
}

handle_callback() {
    local callback_id="$1" data="$2" cb_msg_id="${3:-}"
    local action sess win opt_num

    IFS=':' read -r action sess win opt_num <<< "$data"

    case "$action" in
        approve) handle_action "$callback_id" "$sess" "$win" "y Enter" "Approved" "$cb_msg_id" ;;
        deny)    handle_action "$callback_id" "$sess" "$win" "n Enter" "Denied" "$cb_msg_id" ;;
        opt)     handle_action "$callback_id" "$sess" "$win" "$opt_num" "Sent option $opt_num" "$cb_msg_id" ;;
        view)
            answer_callback "$callback_id" ""
            if ! check_target "$sess" "$win"; then
                send_message "<b>${sess}:${win}</b>\n\n${CHECK_ERR}" >/dev/null
                return
            fi
            local rw="${REFLOW_WIDTH:-$(tmux display-message -t "${sess}:${win}" -p '#{pane_width}' 2>/dev/null || echo 120)}"
            local output
            output="$(tmux capture-pane -t "${sess}:${win}" -J -p -S -200 2>/dev/null \
                | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | reflow_for_telegram "$rw" \
                | convert_tables_to_bullets | wrap_long_lines 50)" || output="(could not capture)"
            output="$(printf '%s' "$output" | trim_blank_lines)"
            if [ -z "$output" ]; then
                send_message "<b>${sess}:${win}</b>\n\n(empty)" >/dev/null
            else
                # Compact header: session · project
                get_session_info "$sess" "$win"
                local cb_header="${sess}:${win}"
                [ -n "$CTX_PROJECT" ] && cb_header="${cb_header} · ${CTX_PROJECT}"

                # Extract preview lines
                local cb_preview_raw
                cb_preview_raw="$(extract_preview "$output" 3)"
                local cb_preview_escaped
                cb_preview_escaped="$(html_escape "$cb_preview_raw")"

                if [ "${#output}" -gt 3800 ]; then
                    output="...${output:$((${#output} - 3800))}"
                fi
                local cb_output_escaped
                cb_output_escaped="$(html_escape "$output")"

                send_message "<b>${cb_header}</b>

${cb_preview_escaped}

<blockquote expandable>${cb_output_escaped}</blockquote>" >/dev/null >/dev/null
            fi
            ;;
        sessions)
            answer_callback "$callback_id" "Refreshing..."
            cmd_sessions
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
    # Strip @botname suffix (Telegram adds it in group chats)
    cmd="${cmd%%@*}"

    case "$cmd" in
        /help|/start)
            cmd_help
            ;;
        /s)
            cmd_sessions
            ;;
        /v)
            if [ -z "$args" ]; then
                send_message "Usage: /v &lt;n&gt;" >/dev/null
                return
            fi
            cmd_view "${args%% *}"
            ;;
        /send)
            if [ -z "$args" ]; then
                send_message "Usage: /send &lt;n&gt; &lt;message&gt;" >/dev/null
                return
            fi
            local num="${args%% *}"
            local msg="${args#* }"
            [ "$msg" = "$num" ] && msg=""
            cmd_send "$num" "$msg"
            ;;
        /a)
            if [ -z "$args" ]; then
                send_message "Usage: /a &lt;n&gt;" >/dev/null
                return
            fi
            cmd_approve "${args%% *}"
            ;;
        /d)
            if [ -z "$args" ]; then
                send_message "Usage: /d &lt;n&gt;" >/dev/null
                return
            fi
            cmd_deny "${args%% *}"
            ;;
        /run)
            if [ -z "$args" ]; then
                send_message "Usage: /run &lt;n&gt; &lt;command&gt;" >/dev/null
                return
            fi
            local num="${args%% *}"
            local run_cmd="${args#* }"
            [ "$run_cmd" = "$num" ] && run_cmd=""
            cmd_run "$num" "$run_cmd"
            ;;
        /restart)
            cmd_restart "$args"
            ;;
        /doctor)
            cmd_doctor
            ;;
        *)
            send_message "Unknown command. Type /help for available commands." >/dev/null
            ;;
    esac
}

# ─── Main polling loop ───────────────────────────────────────────────────────

cmd_run_daemon() {
    load_config
    # Truncate log to last 200 lines on restart (clears stale errors)
    if [ -f "$LOG_FILE" ]; then
        local tmp
        tmp="$(tail -200 "$LOG_FILE")"
        printf '%s\n' "$tmp" > "$LOG_FILE"
    fi
    # Initialize events database and prune old entries
    init_events_db
    sqlite3 "$EVENTS_DB" "DELETE FROM events WHERE ts < datetime('now', '-7 days', 'localtime');" 2>/dev/null || true

    printf '[%s] Telegram bot started (PID %d)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$"
    log_event src bot event start message "PID $$"

    # Register bot command menu with Telegram
    curl -s --max-time 10 \
        -X POST "${API_BASE}/setMyCommands" \
        -H "Content-Type: application/json" \
        -d '{
            "commands": [
                {"command": "s", "description": "Interactive session list"},
                {"command": "v", "description": "View session output"},
                {"command": "a", "description": "Approve (send y)"},
                {"command": "d", "description": "Deny (send n)"},
                {"command": "send", "description": "Send text to session"},
                {"command": "run", "description": "Run command in session"},
                {"command": "restart", "description": "Restart all Claude sessions"},
                {"command": "doctor", "description": "Run diagnostics"},
                {"command": "help", "description": "Show all commands"}
            ]
        }' >/dev/null 2>&1 || true

    # Notify that bot has started + run doctor
    local ver=""
    [ -f "${SCRIPT_DIR}/VERSION" ] && ver=" v$(<"${SCRIPT_DIR}/VERSION")" && ver="${ver%$'\n'}"
    send_message "Bot started${ver}" >/dev/null
    cmd_doctor

    local offset=0

    # Clean shutdown on signals
    trap 'log_event src bot event stop; printf "[%s] Bot stopping\n" "$(date "+%Y-%m-%d %H:%M:%S")"; exit 0' INT TERM

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
            local callback_id callback_data callback_chat callback_msg_id
            callback_id="$(printf '%s' "$update" | jq -r '.callback_query.id // empty' 2>/dev/null)"
            if [ -n "$callback_id" ]; then
                callback_chat="$(printf '%s' "$update" | jq -r '.callback_query.from.id // empty' 2>/dev/null)"
                if [ "$callback_chat" = "$CHAT_ID" ]; then
                    callback_data="$(printf '%s' "$update" | jq -r '.callback_query.data // empty' 2>/dev/null)"
                    callback_msg_id="$(printf '%s' "$update" | jq -r '.callback_query.message.message_id // empty' 2>/dev/null)"
                    if [ -n "$callback_data" ]; then
                        local cb_action cb_sess cb_win
                        IFS=':' read -r cb_action cb_sess cb_win _ <<< "$callback_data"
                        log_event src bot event callback action "$cb_action" session "$cb_sess" window "$cb_win" msg_id "$callback_msg_id"
                        handle_callback "$callback_id" "$callback_data" "$callback_msg_id"
                    fi
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
                log_event src bot event rejected message "$from_id"
                i=$((i + 1))
                continue
            fi

            msg_text="$(printf '%s' "$update" | jq -r '.message.text // empty' 2>/dev/null)"
            if [ -n "$msg_text" ]; then
                printf '[%s] Command: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg_text"
                log_event src bot event command message "$msg_text"
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
