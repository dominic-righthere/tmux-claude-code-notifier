"""Shared pytest fixtures for telegram tests."""

import os
from pathlib import Path

import pytest

from telegram.mock import clear_mock_log, mock_log_path, read_mock_log


@pytest.fixture
def mock_telegram(tmp_path, monkeypatch):
    """Enable mock Telegram API for a test.

    Returns a helper object with:
        .messages — list of all send/edit message calls
        .last — the last message dict
        .log — all log entries
        .log_path — path to the mock log file
    """
    log_file = tmp_path / "mock.jsonl"
    monkeypatch.setenv("TELEGRAM_MOCK", "1")
    monkeypatch.setenv("TELEGRAM_MOCK_LOG", str(log_file))

    class MockHelper:
        @property
        def log_path(self) -> Path:
            return log_file

        @property
        def log(self) -> list[dict]:
            return read_mock_log(log_file)

        @property
        def messages(self) -> list[dict]:
            return [
                e for e in self.log
                if e["method"] in ("sendMessage", "editMessageText")
            ]

        @property
        def last(self) -> dict | None:
            msgs = self.messages
            return msgs[-1] if msgs else None

        def clear(self) -> None:
            clear_mock_log(log_file)

    return MockHelper()
