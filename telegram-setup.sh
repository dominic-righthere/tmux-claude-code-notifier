#!/usr/bin/env bash
# Claude Code Notifier — Telegram bot setup wizard
# Walks through BotFather token, chat_id detection, and sends a test message
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
CONFIG_FILE="${DATA_DIR}/telegram.conf"
API_BASE="https://api.telegram.org/bot"

mkdir -p "$DATA_DIR"

# Check dependencies
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        printf 'Error: %s is required but not installed.\n' "$cmd"
        exit 1
    fi
done

printf 'Claude Code Notifier — Telegram Setup\n\n'

# Step 1: Get bot token
printf '  Step 1: Create a Telegram bot\n\n'
printf '  1. Open Telegram and search for @BotFather\n'
printf '  2. Send /newbot and follow the prompts\n'
printf '  3. Copy the HTTP API token (looks like 123456:ABC-DEF...)\n\n'

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    if [ -n "${BOT_TOKEN:-}" ]; then
        printf '  Existing token found. Press Enter to keep it, or paste a new one.\n'
    fi
fi

printf '  Bot token: '
read -r input_token
if [ -n "$input_token" ]; then
    BOT_TOKEN="$input_token"
fi

if [ -z "${BOT_TOKEN:-}" ]; then
    printf '\n  Error: No token provided.\n'
    exit 1
fi

# Validate token via getMe
printf '\n  Validating token...'
response="$(curl -s --max-time 10 "${API_BASE}${BOT_TOKEN}/getMe" 2>/dev/null)" || {
    printf ' failed.\n  Error: Could not reach Telegram API.\n'
    exit 1
}

ok="$(printf '%s' "$response" | jq -r '.ok' 2>/dev/null)" || ok="false"
if [ "$ok" != "true" ]; then
    printf ' invalid.\n  Error: Token rejected by Telegram API.\n'
    exit 1
fi

bot_name="$(printf '%s' "$response" | jq -r '.result.username' 2>/dev/null)"
printf ' OK! Bot: @%s\n' "$bot_name"

# Step 2: Get chat_id
printf '\n  Step 2: Link your Telegram account\n\n'

if [ -n "${CHAT_ID:-}" ]; then
    printf '  Existing chat_id found: %s\n' "$CHAT_ID"
    printf '  Press Enter to keep it, or type "new" to detect a new one.\n  > '
    read -r chat_choice
    if [ "$chat_choice" != "new" ] && [ -n "$chat_choice" ]; then
        CHAT_ID="$chat_choice"
    elif [ "$chat_choice" = "new" ]; then
        CHAT_ID=""
    fi
fi

if [ -z "${CHAT_ID:-}" ]; then
    printf '  Send any message to @%s in Telegram, then press Enter here.\n' "$bot_name"
    printf '  (Waiting up to 60 seconds...)\n\n'
    read -r _

    # Clear old updates first
    curl -s --max-time 10 "${API_BASE}${BOT_TOKEN}/getUpdates?offset=-1" >/dev/null 2>&1 || true
    sleep 1

    # Poll for new messages
    CHAT_ID=""
    attempts=0
    max_attempts=12
    while [ "$attempts" -lt "$max_attempts" ]; do
        updates="$(curl -s --max-time 10 "${API_BASE}${BOT_TOKEN}/getUpdates?timeout=5" 2>/dev/null)" || {
            attempts=$((attempts + 1))
            continue
        }

        CHAT_ID="$(printf '%s' "$updates" | jq -r '.result[-1].message.chat.id // empty' 2>/dev/null)" || CHAT_ID=""
        if [ -n "$CHAT_ID" ]; then
            from_name="$(printf '%s' "$updates" | jq -r '.result[-1].message.from.first_name // "Unknown"' 2>/dev/null)"
            printf '  Detected chat from: %s (ID: %s)\n' "$from_name" "$CHAT_ID"
            # Acknowledge the update
            update_id="$(printf '%s' "$updates" | jq -r '.result[-1].update_id // empty' 2>/dev/null)"
            if [ -n "$update_id" ]; then
                curl -s --max-time 10 "${API_BASE}${BOT_TOKEN}/getUpdates?offset=$((update_id + 1))" >/dev/null 2>&1 || true
            fi
            break
        fi

        attempts=$((attempts + 1))
        printf '  Polling... (%d/%d)\n' "$attempts" "$max_attempts"
    done

    if [ -z "$CHAT_ID" ]; then
        printf '\n  Error: No message received. Make sure you sent a message to @%s.\n' "$bot_name"
        printf '  You can also set CHAT_ID manually in %s\n' "$CONFIG_FILE"
        exit 1
    fi
fi

# Step 3: Write config
printf '\n  Writing config to %s...\n' "$CONFIG_FILE"
printf 'BOT_TOKEN=%s\nCHAT_ID=%s\n' "$BOT_TOKEN" "$CHAT_ID" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Step 4: Send test message
printf '  Sending test message...'
test_response="$(curl -s --max-time 10 \
    -X POST "${API_BASE}${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat "$CHAT_ID" '{
        chat_id: ($chat | tonumber),
        text: "✅ Claude Code Notifier connected!\n\nYou will receive notifications when Claude needs attention.",
        parse_mode: "HTML"
    }')" 2>/dev/null)" || {
    printf ' failed.\n  Warning: Could not send test message, but config was saved.\n'
    printf '\n  Setup complete!\n\n'
    exit 0
}

ok="$(printf '%s' "$test_response" | jq -r '.ok' 2>/dev/null)" || ok="false"
if [ "$ok" = "true" ]; then
    printf ' sent!\n'
else
    printf ' failed.\n  Warning: %s\n' "$(printf '%s' "$test_response" | jq -r '.description // "Unknown error"' 2>/dev/null)"
fi

printf '\n  Setup complete!\n\n'
printf '  To start the bot daemon:\n'
printf '    %s/telegram.sh start\n\n' "$(cd "$(dirname "$0")" && pwd)"
printf '  The daemon enables interactive commands from Telegram\n'
printf '  (e.g. /status, /view, /approve). Notifications work without it.\n\n'
