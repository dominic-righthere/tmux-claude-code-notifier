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

# Build compact message header
if [ "$TYPE" = "waiting" ]; then
    if [ -n "$TOOL_NAME" ]; then
        text="⏳ <b>Permission Request</b>"
    else
        text="⏳ <b>Waiting for Input</b>"
    fi
else
    text="● <b>Task Finished</b>"
fi

# Compact session line: session · project
session_line="\n${SESSION}:${WINDOW}"
[ -n "$project_name" ] && session_line="${session_line} · ${project_name}"
text="${text}${session_line}"

# Tool on its own line (for permission requests)
if [ "$TYPE" = "waiting" ] && [ -n "$TOOL_NAME" ]; then
    text="${text}\n<b>Tool:</b> ${TOOL_NAME}"
fi

# Mode on its own line only if non-normal
[ -n "$mode_label" ] && text="${text}\n${mode_label}"

# Convert literal \n to real newlines
text="$(printf '%b' "$text")"

# Extract structured content from raw context
if [ -n "$raw_context" ]; then
    # Reflow and convert tables (but do NOT wrap yet — wrapping inflates line count)
    reflowed="$(printf '%s' "$raw_context" | reflow_for_telegram "$pane_width" | convert_tables_to_bullets)"

    # Calculate character budget for prompt text: 4096 - header - activity reserve
    header_len="${#text}"
    prompt_budget=$(( 4096 - header_len - 600 ))
    [ "$prompt_budget" -lt 200 ] && prompt_budget=200
    [ "$prompt_budget" -gt 3000 ] && prompt_budget=3000

    # Extract prompt text with char budget (from unwrapped text)
    prompt_text="$(extract_prompt_text "$reflowed" "$prompt_budget")"
    prompt_escaped=""
    if [ -n "$prompt_text" ]; then
        # Wrap for display AFTER extraction
        prompt_text="$(printf '%s' "$prompt_text" | wrap_long_lines 50)"
        prompt_escaped="$(html_escape "$prompt_text")"
    fi

    # Extract activity log (tool calls since last user input)
    activity="$(extract_activity_log "$raw_context" 15)"
    activity_escaped=""
    if [ -n "$activity" ]; then
        activity_escaped="$(html_escape "$activity")"
    fi

    # Build the message body
    # 1. Prompt text as visible preview
    if [ -n "$prompt_escaped" ]; then
        text="${text}

${prompt_escaped}"
    fi

    # 2. Activity log or raw fallback in expandable blockquote
    if [ -n "$activity_escaped" ]; then
        # Recalculate budget from actual space used
        cur_len="${#text}"
        max_activity=$(( 4096 - cur_len - 200 ))
        if [ "$max_activity" -gt 100 ] && [ "${#activity_escaped}" -le "$max_activity" ]; then
            text="${text}

<blockquote expandable>Activity:
${activity_escaped}</blockquote>"
        fi
    else
        # Fallback: raw context in expandable blockquote
        formatted="$(printf '%s' "$reflowed" | wrap_long_lines 50)"
        pane_context="$(html_escape "$formatted")"
        cur_len="${#text}"
        max_context=$(( 4096 - cur_len - 100 ))
        if [ "$max_context" -gt 100 ]; then
            if [ "${#pane_context}" -gt "$max_context" ]; then
                pane_context="...${pane_context:$((${#pane_context} - max_context))}"
            fi
            text="${text}

<blockquote expandable>${pane_context}</blockquote>"
        fi
    fi
fi

# Enforce Telegram 4096 char limit
if [ "${#text}" -gt 4096 ]; then
    text="${text:0:4093}..."
fi

# Build inline keyboard — parse numbered options for permission requests
if [ "$TYPE" = "waiting" ] && [ -n "$TOOL_NAME" ]; then
    # Try to detect numbered options from pane context (e.g. "❯ 1. Yes", "  2. No")
    option_buttons=""
    if [ -n "$raw_context" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*(❯[[:space:]]+)?([0-9]+)\.[[:space:]]+(.+)$ ]]; then
                opt_num="${BASH_REMATCH[2]}"
                opt_label="${BASH_REMATCH[3]}"
                # Trim trailing whitespace from label
                opt_label="${opt_label%"${opt_label##*[![:space:]]}"}"
                # Build button JSON
                btn="$(jq -n --arg t "${opt_num}. ${opt_label}" --arg d "opt:${SESSION}:${WINDOW}:${opt_num}" \
                    '{text: $t, callback_data: $d}')"
                if [ -n "$option_buttons" ]; then
                    option_buttons="${option_buttons},${btn}"
                else
                    option_buttons="${btn}"
                fi
            fi
        done <<< "$raw_context"
    fi

    if [ -n "$option_buttons" ]; then
        # Dynamic buttons: options on first row, view on second row
        view_btn="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" \
            '{text: "👁 View", callback_data: ("view:" + $s + ":" + $w)}')"
        keyboard="{\"inline_keyboard\":[[${option_buttons}],[${view_btn}]]}"
    else
        # Fallback: Approve + Deny on row 1, View on row 2
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
    # Finished or notification: View Output
    keyboard="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" '{
        inline_keyboard: [[
            {text: "👁 View Output", callback_data: ("view:" + $s + ":" + $w)}
        ]]
    }')"
fi

# Edit-or-send: try editing previous message for this session, fall back to new message
send_result=""
prev_msg_id=""
[ -f "${MSG_ID_DIR}/${MSG_KEY}" ] && prev_msg_id="$(<"${MSG_ID_DIR}/${MSG_KEY}")"

if [ -n "$prev_msg_id" ]; then
    # Try to edit the previous message in-place
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

    edit_ok="$(printf '%s' "$edit_response" | jq -r '.ok // false' 2>/dev/null)" || edit_ok="false"
    if [ "$edit_ok" = "true" ]; then
        log_event src send event edit type "$TYPE" session "$SESSION" window "$WINDOW" msg_id "$prev_msg_id" text "$text"
        exit 0
    fi
    log_event src send event edit_fail type "$TYPE" session "$SESSION" window "$WINDOW" msg_id "$prev_msg_id"
fi

# Send new message
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

# Extract and store message_id for future edits
new_msg_id="$(printf '%s' "$send_result" | jq -r '.result.message_id // empty' 2>/dev/null)" || new_msg_id=""
if [ -n "$new_msg_id" ]; then
    printf '%s' "$new_msg_id" > "${MSG_ID_DIR}/${MSG_KEY}"
    log_event src send event new type "$TYPE" session "$SESSION" window "$WINDOW" msg_id "$new_msg_id" text "$text"
else
    log_event src send event send_fail type "$TYPE" session "$SESSION" window "$WINDOW"
fi
