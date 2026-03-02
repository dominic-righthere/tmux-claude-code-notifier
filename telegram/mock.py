"""Mock Telegram API — intercepts all API calls and logs them to a file.

Enable via environment variable:
    TELEGRAM_MOCK=1  — intercept all API calls, write to mock log
    TELEGRAM_MOCK_LOG — path to mock log file (default: ~/.local/share/claude-notifier/telegram-mock.jsonl)

The mock log is a JSONL file (one JSON object per line) with:
    {"ts": "...", "method": "sendMessage", "data": {...}, "response": {...}}

Usage:
    TELEGRAM_MOCK=1 ./telegram-send-py.sh waiting main 1 "Test" "Bash"
    cat ~/.local/share/claude-notifier/telegram-mock.jsonl | python -m json.tool
"""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime
from pathlib import Path
from typing import Any

_mock_msg_counter = 0
_mock_lock = threading.Lock()

DEFAULT_MOCK_LOG = Path.home() / ".local" / "share" / "claude-notifier" / "telegram-mock.jsonl"


def is_mock_enabled() -> bool:
    return os.environ.get("TELEGRAM_MOCK", "") == "1"


def mock_log_path() -> Path:
    return Path(os.environ.get("TELEGRAM_MOCK_LOG", str(DEFAULT_MOCK_LOG)))


def _next_msg_id() -> int:
    global _mock_msg_counter
    with _mock_lock:
        _mock_msg_counter += 1
        return 90000 + _mock_msg_counter


def _write_log(method: str, data: dict[str, Any], response: dict[str, Any]) -> None:
    """Append a mock API call to the JSONL log."""
    path = mock_log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now().isoformat(timespec="seconds"),
        "method": method,
        "data": data,
        "response": response,
    }
    with open(path, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def mock_api_call(method: str, data: dict[str, Any]) -> dict[str, Any]:
    """Simulate a Telegram API call. Returns a fake success response."""
    if method == "sendMessage":
        msg_id = _next_msg_id()
        response = {
            "ok": True,
            "result": {
                "message_id": msg_id,
                "chat": {"id": data.get("chat_id", 0)},
                "text": data.get("text", ""),
                "date": int(datetime.now().timestamp()),
            },
        }
    elif method in ("editMessageText", "editMessageReplyMarkup"):
        response = {
            "ok": True,
            "result": {
                "message_id": data.get("message_id", 0),
                "chat": {"id": data.get("chat_id", 0)},
                "text": data.get("text", ""),
                "date": int(datetime.now().timestamp()),
            },
        }
    elif method == "answerCallbackQuery":
        response = {"ok": True, "result": True}
    elif method == "getMe":
        response = {
            "ok": True,
            "result": {
                "id": 123456789,
                "is_bot": True,
                "first_name": "MockBot",
                "username": "mock_notifier_bot",
            },
        }
    elif method == "setMyCommands":
        response = {"ok": True, "result": True}
    elif method == "getUpdates":
        response = {"ok": True, "result": []}
    else:
        response = {"ok": True, "result": {}}

    _write_log(method, data, response)
    return response


def read_mock_log(path: Path | None = None) -> list[dict]:
    """Read all entries from the mock log."""
    p = path or mock_log_path()
    if not p.exists():
        return []
    entries = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if line:
            entries.append(json.loads(line))
    return entries


def clear_mock_log(path: Path | None = None) -> None:
    """Clear the mock log file."""
    p = path or mock_log_path()
    p.unlink(missing_ok=True)


def last_message(path: Path | None = None) -> dict | None:
    """Get the last sendMessage/editMessageText call from the mock log."""
    entries = read_mock_log(path)
    for entry in reversed(entries):
        if entry["method"] in ("sendMessage", "editMessageText"):
            return entry
    return None


def all_messages(path: Path | None = None) -> list[dict]:
    """Get all send/edit message calls from the mock log."""
    return [
        e for e in read_mock_log(path)
        if e["method"] in ("sendMessage", "editMessageText")
    ]
