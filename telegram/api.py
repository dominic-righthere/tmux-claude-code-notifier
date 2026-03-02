"""Telegram Bot API client using httpx."""

from __future__ import annotations

import logging
from typing import Any

import httpx

from telegram.models import TelegramConfig

logger = logging.getLogger(__name__)

# Shared client for connection pooling
_client: httpx.Client | None = None
_async_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.Client:
    global _client
    if _client is None:
        _client = httpx.Client(timeout=15.0)
    return _client


def _get_async_client() -> httpx.AsyncClient:
    global _async_client
    if _async_client is None:
        _async_client = httpx.AsyncClient(timeout=15.0)
    return _async_client


def close() -> None:
    """Close the shared HTTP client."""
    global _client, _async_client
    if _client:
        _client.close()
        _client = None
    if _async_client:
        # Can't close async from sync context, but we'll handle it
        _async_client = None


def _api_call(config: TelegramConfig, method: str, data: dict[str, Any]) -> dict[str, Any] | None:
    """Make a synchronous Telegram API call. Returns response dict or None.

    When TELEGRAM_MOCK=1, intercepts all calls and writes to a JSONL log file.
    """
    from telegram.mock import is_mock_enabled, mock_api_call
    if is_mock_enabled():
        return mock_api_call(method, data)

    url = f"{config.api_base}/{method}"
    try:
        resp = _get_client().post(url, json=data)
        result = resp.json()
        if result.get("ok"):
            return result
        logger.warning("API %s failed: %s", method, result.get("description", "unknown"))
        return result
    except Exception:
        logger.exception("API call %s failed", method)
        return None


async def _async_api_call(config: TelegramConfig, method: str, data: dict[str, Any]) -> dict[str, Any] | None:
    """Make an async Telegram API call.

    When TELEGRAM_MOCK=1, intercepts all calls and writes to a JSONL log file.
    """
    from telegram.mock import is_mock_enabled, mock_api_call
    if is_mock_enabled():
        return mock_api_call(method, data)

    url = f"{config.api_base}/{method}"
    try:
        resp = await _get_async_client().post(url, json=data)
        result = resp.json()
        if result.get("ok"):
            return result
        logger.warning("API %s failed: %s", method, result.get("description", "unknown"))
        return result
    except Exception:
        logger.exception("API call %s failed", method)
        return None


# ─── Sync API methods (used by send.py) ─────────────────────────────────────


def send_message(
    config: TelegramConfig,
    text: str,
    reply_markup: dict | None = None,
) -> str | None:
    """Send a message. Returns message_id or None."""
    data: dict[str, Any] = {
        "chat_id": int(config.chat_id),
        "text": text,
        "parse_mode": "HTML",
    }
    if reply_markup:
        data["reply_markup"] = reply_markup

    result = _api_call(config, "sendMessage", data)
    if result and result.get("ok"):
        return str(result["result"]["message_id"])
    return None


def edit_message(
    config: TelegramConfig,
    message_id: str,
    text: str,
    reply_markup: dict | None = None,
) -> bool:
    """Edit an existing message. Returns True on success."""
    data: dict[str, Any] = {
        "chat_id": int(config.chat_id),
        "message_id": int(message_id),
        "text": text,
        "parse_mode": "HTML",
    }
    if reply_markup:
        data["reply_markup"] = reply_markup

    result = _api_call(config, "editMessageText", data)
    return bool(result and result.get("ok"))


def strip_buttons(config: TelegramConfig, message_id: str) -> None:
    """Remove inline keyboard from a message."""
    _api_call(config, "editMessageReplyMarkup", {
        "chat_id": int(config.chat_id),
        "message_id": int(message_id),
        "reply_markup": {"inline_keyboard": []},
    })


def answer_callback(config: TelegramConfig, callback_id: str, text: str = "") -> None:
    """Answer a callback query (acknowledge button press)."""
    _api_call(config, "answerCallbackQuery", {
        "callback_query_id": callback_id,
        "text": text,
    })


def get_me(config: TelegramConfig) -> dict | None:
    """Get bot info. Returns result dict or None."""
    result = _api_call(config, "getMe", {})
    if result and result.get("ok"):
        return result["result"]
    return None


def set_my_commands(config: TelegramConfig, commands: list[dict[str, str]]) -> bool:
    """Set bot command menu."""
    result = _api_call(config, "setMyCommands", {"commands": commands})
    return bool(result and result.get("ok"))


# ─── Async API methods (used by bot.py) ──────────────────────────────────────


async def async_send_message(
    config: TelegramConfig,
    text: str,
    reply_markup: dict | None = None,
) -> str | None:
    """Async send a message. Returns message_id or None."""
    data: dict[str, Any] = {
        "chat_id": int(config.chat_id),
        "text": text,
        "parse_mode": "HTML",
    }
    if reply_markup:
        data["reply_markup"] = reply_markup

    result = await _async_api_call(config, "sendMessage", data)
    if result and result.get("ok"):
        return str(result["result"]["message_id"])
    return None


async def async_edit_message(
    config: TelegramConfig,
    message_id: str,
    text: str,
    reply_markup: dict | None = None,
) -> bool:
    """Async edit message. Returns True on success."""
    data: dict[str, Any] = {
        "chat_id": int(config.chat_id),
        "message_id": int(message_id),
        "text": text,
        "parse_mode": "HTML",
    }
    if reply_markup:
        data["reply_markup"] = reply_markup

    result = await _async_api_call(config, "editMessageText", data)
    return bool(result and result.get("ok"))


async def async_strip_buttons(config: TelegramConfig, message_id: str) -> None:
    """Async remove inline keyboard."""
    await _async_api_call(config, "editMessageReplyMarkup", {
        "chat_id": int(config.chat_id),
        "message_id": int(message_id),
        "reply_markup": {"inline_keyboard": []},
    })


async def async_answer_callback(config: TelegramConfig, callback_id: str, text: str = "") -> None:
    """Async answer callback query."""
    await _async_api_call(config, "answerCallbackQuery", {
        "callback_query_id": callback_id,
        "text": text,
    })


async def async_get_updates(config: TelegramConfig, offset: int = 0, timeout: int = 30) -> list[dict] | None:
    """Long-poll for updates. Returns list of update dicts or None."""
    try:
        client = _get_async_client()
        resp = await client.get(
            f"{config.api_base}/getUpdates",
            params={"offset": offset, "timeout": timeout},
            timeout=timeout + 5,
        )
        result = resp.json()
        if result.get("ok"):
            return result.get("result", [])
        return None
    except Exception:
        logger.exception("getUpdates failed")
        return None
