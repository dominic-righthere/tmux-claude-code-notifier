#!/usr/bin/env bash
# Claude Code Notifier — Telegram notification sender
# Called from notify.sh: telegram-send.sh <type> <session> <window> <message> [tool_name]
# Sends a Telegram message with inline keyboard buttons.
# Exits silently if Telegram is not configured.
set -uo pipefail

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

# Build message text
if [ "$TYPE" = "waiting" ]; then
    if [ -n "$TOOL_NAME" ]; then
        text="⏳ <b>Permission Request</b>\n\n<b>Session:</b> ${SESSION}:${WINDOW}\n<b>Tool:</b> ${TOOL_NAME}\n<b>Message:</b> ${MESSAGE}"
    else
        text="⏳ <b>Waiting for Input</b>\n\n<b>Session:</b> ${SESSION}:${WINDOW}\n<b>Message:</b> ${MESSAGE}"
    fi
else
    text="● <b>Task Finished</b>\n\n<b>Session:</b> ${SESSION}:${WINDOW}"
fi

# Build inline keyboard
if [ "$TYPE" = "waiting" ] && [ -n "$TOOL_NAME" ]; then
    # Permission request: Approve / Deny / View Output
    keyboard="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" '{
        inline_keyboard: [[
            {text: "✅ Approve", callback_data: ("approve:" + $s + ":" + $w)},
            {text: "❌ Deny", callback_data: ("deny:" + $s + ":" + $w)},
            {text: "👁 View", callback_data: ("view:" + $s + ":" + $w)}
        ]]
    }')"
else
    # Finished or notification: View Output
    keyboard="$(jq -n --arg s "$SESSION" --arg w "$WINDOW" '{
        inline_keyboard: [[
            {text: "👁 View Output", callback_data: ("view:" + $s + ":" + $w)}
        ]]
    }')"
fi

# Send message (backgrounded by caller, but add safety timeout)
curl -s --max-time 10 \
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
        }')" >/dev/null 2>&1 || true
