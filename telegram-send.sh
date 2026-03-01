#!/usr/bin/env bash
# Claude Code Notifier — Telegram notification sender
# Called from notify.sh: telegram-send.sh <type> <session> <window> <message> [tool_name]
# Sends a Telegram message with inline keyboard buttons.
# Exits silently if Telegram is not configured.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
DATA_DIR="${HOME}/.local/share/claude-notifier"
CONFIG_FILE="${DATA_DIR}/telegram.conf"
MSG_ID_DIR="${DATA_DIR}/telegram_msg_ids"

# Exit silently if not configured
[ -f "$CONFIG_FILE" ] || exit 0

# shellcheck source=/dev/null
source "$CONFIG_FILE"
[ -n "${BOT_TOKEN:-}" ] || exit 0
[ -n "${CHAT_ID:-}" ] || exit 0

TYPE="${1:-}"
SESSION="${2:-}"
WINDOW="${3:-}"
MESSAGE="${4:-}"
TOOL_NAME="${5:-}"

[ -z "$TYPE" ] && exit 0
[ -z "$SESSION" ] && exit 0

# Only send for waiting and finished events
case "$TYPE" in
    waiting|finished) ;;
    *) exit 0 ;;
esac

API_BASE="https://api.telegram.org/bot${BOT_TOKEN}"
mkdir -p "$MSG_ID_DIR"

SAFE_SESSION="$(sanitize_key "$SESSION")"
MSG_KEY="${SAFE_SESSION}_${WINDOW}"

log_event src send event dispatch type "$TYPE" session "$SESSION" window "$WINDOW" tool "$TOOL_NAME"

# Get project name from pane current path
project_name=""
pane_path="$(tmux display-message -t "${SESSION}:${WINDOW}" -p '#{pane_current_path}' 2>/dev/null)" || pane_path=""
[ -n "$pane_path" ] && project_name="$(basename "$pane_path")"

# Capture pane context (deep scrollback for activity extraction)
sleep 0.3  # ensure prompt is rendered
raw_context=""
pane_width="$(tmux display-message -t "${SESSION}:${WINDOW}" -p '#{pane_width}' 2>/dev/null)" || pane_width="120"
if raw_context="$(tmux capture-pane -t "${SESSION}:${WINDOW}" -J -p -S -200 2>/dev/null)"; then
    raw_context="$(strip_ansi "$raw_context")"
    # Trim leading/trailing blank lines
    raw_context="$(printf '%s' "$raw_context" | sed '/./,$!d')"
    while [[ "$raw_context" =~ [[:space:]]*$'\n'$ ]]; do
        raw_context="${raw_context%$'\n'}"
        raw_context="${raw_context%"${raw_context##*[![:space:]]}"}"
    done
fi

# Detect mode from raw_context
mode_label=""
if [ -n "$raw_context" ]; then
    if printf '%s' "$raw_context" | grep -qi 'plan mode'; then
        mode_label="⏸ plan mode"
    elif printf '%s' "$raw_context" | grep -qi 'auto-accept\|accept edits'; then
        mode_label="⏵⏵ auto-accept"
    fi
fi

# ─── Modular message pipeline ────────────────────────────────────────────────

# Build message header: type badge, session, project, tool, mode
# Sets: header
build_header() {
    if [ "$TYPE" = "waiting" ]; then
        if [ -n "$TOOL_NAME" ]; then
            header="⏳ <b>Permission Request</b>"
        else
            header="⏳ <b>Waiting for Input</b>"
        fi
    else
        header="● <b>Task Finished</b>"
    fi

    # Compact session line: session · project
    local session_line="\n${SESSION}:${WINDOW}"
    [ -n "$project_name" ] && session_line="${session_line} · ${project_name}"
    header="${header}${session_line}"

    # Tool on its own line (for permission requests)
    if [ "$TYPE" = "waiting" ] && [ -n "$TOOL_NAME" ]; then
        header="${header}\n<b>Tool:</b> ${TOOL_NAME}"
    fi

    # Mode on its own line only if non-normal
    [ -n "$mode_label" ] && header="${header}\n${mode_label}"

    # Convert literal \n to real newlines
    header="$(printf '%b' "$header")"
}

# Build message body: prompt text, activity/fallback blockquote
# Sets: body
build_body() {
    body=""
    [ -z "$raw_context" ] && return

    # Reflow and convert tables (but do NOT wrap yet — wrapping inflates line count)
    local reflowed
    reflowed="$(printf '%s' "$raw_context" | reflow_for_telegram "$pane_width" | convert_tables_to_bullets)"

    # Calculate character budget for prompt text: 4096 - header - activity reserve
    local header_len="${#header}"
    local prompt_budget=$(( 4096 - header_len - 600 ))
    [ "$prompt_budget" -lt 200 ] && prompt_budget=200
    [ "$prompt_budget" -gt 3000 ] && prompt_budget=3000

    # Extract prompt text with char budget (from unwrapped text)
    local prompt_text
    prompt_text="$(extract_prompt_text "$reflowed" "$prompt_budget")"
    local prompt_escaped=""
    if [ -n "$prompt_text" ]; then
        # Wrap for display AFTER extraction
        prompt_text="$(printf '%s' "$prompt_text" | wrap_long_lines 50)"
        prompt_escaped="$(html_escape "$prompt_text")"
    fi

    # Extract activity log (tool calls since last user input)
    local activity
    activity="$(extract_activity_log "$raw_context" 15)"
    local activity_escaped=""
    if [ -n "$activity" ]; then
        activity_escaped="$(html_escape "$activity")"
    fi

    # 1. Prompt text as visible preview
    if [ -n "$prompt_escaped" ]; then
        body="

${prompt_escaped}"
    fi

    # 2. Activity log or raw fallback in expandable blockquote
    if [ -n "$activity_escaped" ]; then
        local cur_len=$(( ${#header} + ${#body} ))
        local max_activity=$(( 4096 - cur_len - 200 ))
        if [ "$max_activity" -gt 100 ] && [ "${#activity_escaped}" -le "$max_activity" ]; then
            body="${body}

<blockquote expandable>Activity:
${activity_escaped}</blockquote>"
        fi
    else
        # Fallback: raw context in expandable blockquote
        local formatted
        formatted="$(printf '%s' "$reflowed" | wrap_long_lines 50)"
        local pane_context
        pane_context="$(html_escape "$formatted")"
        local cur_len=$(( ${#header} + ${#body} ))
        local max_context=$(( 4096 - cur_len - 100 ))
        if [ "$max_context" -gt 100 ]; then
            if [ "${#pane_context}" -gt "$max_context" ]; then
                pane_context="...${pane_context:$((${#pane_context} - max_context))}"
            fi
            body="${body}

<blockquote expandable>${pane_context}</blockquote>"
        fi
    fi
}

# Build inline keyboard JSON
# Scopes option detection to the prompt block (after last ⏺ marker)
# One button per row, max 4 options
# Sets: keyboard, kb_style
build_keyboard() {
    kb_style="default"
    local btn_count=0

    if [ "$TYPE" = "waiting" ] && [ -n "$TOOL_NAME" ]; then
        # Extract prompt block: lines after last ⏺ marker (same scoping as extract_prompt_text)
        local prompt_block=""
        if [ -n "$raw_context" ]; then
            prompt_block="$(printf '%s' "$raw_context" | awk '
                /⏺/ { buf = ""; next }
                { buf = buf "\n" $0 }
                END { print buf }
            ')"
        fi

        # Try to detect numbered options from prompt block only
        local option_rows=""
        if [ -n "$prompt_block" ]; then
            while IFS= read -r line; do
                [ "$btn_count" -ge 4 ] && break
                if [[ "$line" =~ ^[[:space:]]*(❯[[:space:]]+)?([0-9]+)\.[[:space:]]+(.+)$ ]]; then
                    local opt_num="${BASH_REMATCH[2]}"
                    local opt_label="${BASH_REMATCH[3]}"
                    # Trim trailing whitespace from label
                    opt_label="${opt_label%"${opt_label##*[![:space:]]}"}"
                    # Build button JSON — one button per row
                    local btn
                    btn="$(jq -n --arg t "${opt_num}. ${opt_label}" --arg d "opt:${SESSION}:${WINDOW}:${opt_num}" \
                        '{text: $t, callback_data: $d}')"
                    if [ -n "$option_rows" ]; then
                        option_rows="${option_rows},[${btn}]"
                    else
                        option_rows="[${btn}]"
                    fi
                    btn_count=$((btn_count + 1))
                fi
            done <<< "$prompt_block"
        fi

        if [ -n "$option_rows" ]; then
            kb_style="options"
            local view_btn
            view_btn="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" \
                '{text: "👁 View", callback_data: ("view:" + $s + ":" + $w)}')"
            keyboard="{\"inline_keyboard\":[${option_rows},[${view_btn}]]}"
        else
            kb_style="approve_deny"
            keyboard="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" '{
                inline_keyboard: [
                    [
                        {text: "✅ Approve", callback_data: ("approve:" + $s + ":" + $w)},
                        {text: "❌ Deny", callback_data: ("deny:" + $s + ":" + $w)}
                    ],
                    [
                        {text: "👁 View", callback_data: ("view:" + $s + ":" + $w)}
                    ]
                ]
            }')"
        fi
    else
        kb_style="view_only"
        keyboard="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" '{
            inline_keyboard: [[
                {text: "👁 View Output", callback_data: ("view:" + $s + ":" + $w)}
            ]]
        }')"
    fi

    log_event src send event keyboard type "$TYPE" session "$SESSION" window "$WINDOW" \
        action "$kb_style" extra "buttons=$btn_count"
}

# Send new message or edit previous, with type guard to prevent race conditions.
# Stores msg_id:type in the msg_id file. A "finished" dispatch will not edit
# over a "waiting" message — it sends a new message instead.
# Sets: nothing (exits on success when editing)
send_or_edit() {
    local prev_entry=""
    [ -f "${MSG_ID_DIR}/${MSG_KEY}" ] && prev_entry="$(<"${MSG_ID_DIR}/${MSG_KEY}")"

    local prev_msg_id="${prev_entry%%:*}"
    local prev_type="${prev_entry#*:}"
    # If no colon in entry, prev_type equals prev_msg_id (legacy format)
    [ "$prev_type" = "$prev_msg_id" ] && prev_type=""

    if [ -n "$prev_msg_id" ]; then
        # Type guard: don't edit a waiting message with a finished message
        # This prevents the race where a backgrounded finished dispatch overwrites
        # a waiting message that arrived later
        if [ "$prev_type" = "waiting" ] && [ "$TYPE" = "finished" ]; then
            log_event src send event skip_edit type "$TYPE" session "$SESSION" window "$WINDOW" \
                msg_id "$prev_msg_id" extra "prev_type=waiting"
        else
            # Try to edit the previous message in-place
            local edit_response
            edit_response="$(curl -s --max-time 10 \
                -X POST "${API_BASE}/editMessageText" \
                -H "Content-Type: application/json" \
                -d "$(jq -n \
                    --arg chat "$CHAT_ID" \
                    --arg msg_id "$prev_msg_id" \
                    --arg text "$text" \
                    --argjson keyboard "$keyboard" \
                    '{
                        chat_id: ($chat | tonumber),
                        message_id: ($msg_id | tonumber),
                        text: $text,
                        parse_mode: "HTML",
                        reply_markup: $keyboard
                    }')")" || edit_response=""

            local edit_ok
            edit_ok="$(printf '%s' "$edit_response" | jq -r '.ok // false' 2>/dev/null)" || edit_ok="false"
            if [ "$edit_ok" = "true" ]; then
                # Update stored type (msg_id stays the same)
                printf '%s' "${prev_msg_id}:${TYPE}" > "${MSG_ID_DIR}/${MSG_KEY}"
                log_event src send event edit type "$TYPE" session "$SESSION" window "$WINDOW" msg_id "$prev_msg_id"
                exit 0
            fi
            log_event src send event edit_fail type "$TYPE" session "$SESSION" window "$WINDOW" msg_id "$prev_msg_id"
        fi
    fi

    # Send new message
    local send_result
    send_result="$(curl -s --max-time 10 \
        -X POST "${API_BASE}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg chat "$CHAT_ID" \
            --arg text "$text" \
            --argjson keyboard "$keyboard" \
            '{
                chat_id: ($chat | tonumber),
                text: $text,
                parse_mode: "HTML",
                reply_markup: $keyboard
            }')")" || send_result=""

    # Extract and store message_id:type for future edits
    local new_msg_id
    new_msg_id="$(printf '%s' "$send_result" | jq -r '.result.message_id // empty' 2>/dev/null)" || new_msg_id=""
    if [ -n "$new_msg_id" ]; then
        printf '%s' "${new_msg_id}:${TYPE}" > "${MSG_ID_DIR}/${MSG_KEY}"
        log_event src send event new type "$TYPE" session "$SESSION" window "$WINDOW" msg_id "$new_msg_id"
    else
        log_event src send event send_fail type "$TYPE" session "$SESSION" window "$WINDOW"
    fi
}

# ─── Main pipeline ───────────────────────────────────────────────────────────

build_header
build_body

# Assemble final text
text="${header}${body}"

# Enforce Telegram 4096 char limit
if [ "${#text}" -gt 4096 ]; then
    text="${text:0:4093}..."
fi

build_keyboard
send_or_edit
