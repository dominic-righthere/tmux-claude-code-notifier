#!/usr/bin/env bash
# Claude Code Notifier — Telegram notification sender
# Called from notify.sh: telegram-send.sh <type> <session> <window> <message> [tool_name]
# Sends a Telegram message with inline keyboard buttons.
# Exits silently if Telegram is not configured.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
CONFIG_FILE="${HOME}/.local/share/claude-notifier/telegram.conf"

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

# Message deduplication: store message_id per session key
MSG_ID_DIR="${HOME}/.local/share/claude-notifier/telegram_msg_ids"
mkdir -p "$MSG_ID_DIR"
SAFE_SESSION="$(sanitize_key "$SESSION")"
MSG_KEY="${SAFE_SESSION}_${WINDOW}"

# Get project name from pane current path
project_name=""
pane_path="$(tmux display-message -t "${SESSION}:${WINDOW}" -p '#{pane_current_path}' 2>/dev/null)" || pane_path=""
[ -n "$pane_path" ] && project_name="$(basename "$pane_path")"

# Capture pane context (last ~15 lines) for inline preview + mode/task detection
sleep 0.3  # ensure prompt is rendered
raw_context=""
pane_context=""
if raw_context="$(tmux capture-pane -t "${SESSION}:${WINDOW}" -J -p -S -15 2>/dev/null)"; then
    # Strip ANSI escape codes
    raw_context="$(strip_ansi "$raw_context")"
    # Trim leading/trailing blank lines
    raw_context="$(printf '%s' "$raw_context" | sed '/./,$!d')"
    while [[ "$raw_context" =~ [[:space:]]*$'\n'$ ]]; do
        raw_context="${raw_context%$'\n'}"
        raw_context="${raw_context%"${raw_context##*[![:space:]]}"}"
    done
    if [ -n "$raw_context" ]; then
        pane_context="$(html_escape "$raw_context")"
    fi
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

# Build preview + expandable context
if [ -n "$pane_context" ]; then
    # Extract 3 meaningful lines as compact preview
    preview_raw="$(extract_preview "$raw_context" 3)"
    preview_escaped="$(html_escape "$preview_raw")"

    # Respect Telegram's 4096 char limit
    header_len="${#text}"
    max_context=$(( 4096 - header_len - 100 ))  # reserve for tags + margin
    if [ "$max_context" -gt 100 ]; then
        if [ "${#pane_context}" -gt "$max_context" ]; then
            pane_context="...${pane_context:$((${#pane_context} - max_context))}"
        fi
        text="${text}

${preview_escaped}

<blockquote expandable>${pane_context}</blockquote>"
    fi
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

# Try to edit existing message for this session, fall back to sending new one
send_new() {
    local response
    response="$(curl -s --max-time 10 \
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
            }')" 2>/dev/null)" || return 0
    # Store message_id for future edits
    local msg_id
    msg_id="$(printf '%s' "$response" | jq -r '.result.message_id // empty' 2>/dev/null)"
    [ -n "$msg_id" ] && printf '%s' "$msg_id" > "${MSG_ID_DIR}/${MSG_KEY}"
}

prev_msg_id=""
[ -f "${MSG_ID_DIR}/${MSG_KEY}" ] && prev_msg_id="$(<"${MSG_ID_DIR}/${MSG_KEY}")"

if [ -n "$prev_msg_id" ]; then
    # Try editing the previous message
    edit_ok="$(curl -s --max-time 10 \
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
            }')" 2>/dev/null | jq -r '.ok // empty' 2>/dev/null)" || edit_ok=""
    if [ "$edit_ok" != "true" ]; then
        # Edit failed (message too old, deleted, etc.) — send new
        send_new
    fi
else
    send_new
fi
