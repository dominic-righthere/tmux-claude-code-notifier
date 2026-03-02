"""Telegram bot setup wizard — replaces telegram-setup.sh."""

from __future__ import annotations

import sys
import time

from telegram import api
from telegram.models import TelegramConfig
from telegram.state import save_config


def cli_main(args: list[str]) -> None:
    """Interactive setup wizard."""
    print("Claude Code Notifier — Telegram Setup\n")

    # Step 1: Get bot token
    print("  Step 1: Create a Telegram bot\n")
    print("  1. Open Telegram and search for @BotFather")
    print("  2. Send /newbot and follow the prompts")
    print("  3. Copy the HTTP API token (looks like 123456:ABC-DEF...)\n")

    token = input("  Bot token: ").strip()
    if not token:
        print("\n  Error: No token provided.")
        sys.exit(1)

    # Validate token
    print("\n  Validating token...", end="", flush=True)
    temp_config = TelegramConfig(bot_token=token, chat_id="0")
    bot_info = api.get_me(temp_config)
    if not bot_info:
        print(" invalid.\n  Error: Token rejected by Telegram API.")
        sys.exit(1)

    bot_name = bot_info.get("username", "unknown")
    print(f" OK! Bot: @{bot_name}")

    # Step 2: Get chat_id
    print(f"\n  Step 2: Link your Telegram account\n")
    print(f"  Send any message to @{bot_name} in Telegram, then press Enter here.")
    print("  (Waiting up to 60 seconds...)\n")
    input()

    # Clear old updates
    import httpx
    try:
        httpx.get(f"{temp_config.api_base}/getUpdates?offset=-1", timeout=10)
    except Exception:
        pass
    time.sleep(1)

    # Poll for messages
    chat_id = ""
    for attempt in range(12):
        try:
            resp = httpx.get(f"{temp_config.api_base}/getUpdates?timeout=5", timeout=10)
            data = resp.json()
            if data.get("ok") and data.get("result"):
                last = data["result"][-1]
                chat_id = str(last.get("message", {}).get("chat", {}).get("id", ""))
                if chat_id:
                    from_name = last.get("message", {}).get("from", {}).get("first_name", "Unknown")
                    print(f"  Detected chat from: {from_name} (ID: {chat_id})")
                    # Acknowledge
                    update_id = last.get("update_id")
                    if update_id:
                        httpx.get(f"{temp_config.api_base}/getUpdates?offset={update_id + 1}", timeout=10)
                    break
        except Exception:
            pass
        print(f"  Polling... ({attempt + 1}/12)")

    if not chat_id:
        print(f"\n  Error: No message received. Make sure you sent a message to @{bot_name}.")
        sys.exit(1)

    # Step 3: Save config
    config = TelegramConfig(bot_token=token, chat_id=chat_id)
    print(f"\n  Writing config...")
    save_config(config)

    # Step 4: Test message
    print("  Sending test message...", end="", flush=True)
    msg_id = api.send_message(
        config,
        "✅ Claude Code Notifier connected!\n\nYou will receive notifications when Claude needs attention.",
    )
    if msg_id:
        print(" sent!")
    else:
        print(" failed.\n  Warning: Could not send test message, but config was saved.")

    # Step 5: Set bot menu
    print("  Setting bot menu...", end="", flush=True)
    from telegram.bot import BOT_COMMANDS
    if api.set_my_commands(config, BOT_COMMANDS):
        print(" done!")
    else:
        print(" skipped (non-critical).")

    print("\n  Setup complete!\n")
    print(f"  To start the bot daemon:")
    print(f"    telegram-bot.sh start\n")
    print("  The daemon enables interactive commands from Telegram")
    print("  (e.g. /s, /v, /a). Notifications work without it.\n")

    api.close()
