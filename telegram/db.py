"""SQLite event logging — compatible with existing events.db schema."""

from __future__ import annotations

import sqlite3
from pathlib import Path

_DB_PATH = Path.home() / ".local" / "share" / "claude-notifier" / "events.db"

_SCHEMA = """\
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime')),
    src TEXT NOT NULL,
    event TEXT NOT NULL,
    session TEXT,
    window TEXT,
    type TEXT,
    tool TEXT,
    action TEXT,
    msg_id TEXT,
    message TEXT,
    text TEXT,
    extra TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session, window);
"""

# Valid column names for INSERT
_VALID_COLS = {"src", "event", "session", "window", "type", "tool", "action", "msg_id", "message", "text", "extra"}


def init_db(path: Path | None = None) -> None:
    """Initialize the events database if it doesn't exist."""
    db = path or _DB_PATH
    db.parent.mkdir(parents=True, exist_ok=True)
    if db.exists():
        return
    conn = sqlite3.connect(str(db))
    conn.executescript(_SCHEMA)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.close()


def log_event(path: Path | None = None, **kwargs: str) -> None:
    """Log an event with key-value pairs.

    Usage: log_event(src="send", event="dispatch", type="waiting", session="main")
    Silently no-ops if DB missing or sqlite3 fails.
    """
    db = path or _DB_PATH
    if not db.exists():
        return

    # Filter to valid columns only
    cols = {k: v for k, v in kwargs.items() if k in _VALID_COLS and v}
    if not cols:
        return

    col_names = ", ".join(["ts"] + list(cols.keys()))
    placeholders = ", ".join(["strftime('%Y-%m-%dT%H:%M:%S','now','localtime')"] + ["?"] * len(cols))
    values = list(cols.values())

    try:
        conn = sqlite3.connect(str(db))
        conn.execute(f"INSERT INTO events({col_names}) VALUES({placeholders});", values)
        conn.commit()
        conn.close()
    except Exception:
        pass


def prune_old_events(days: int = 7, path: Path | None = None) -> None:
    """Delete events older than N days."""
    db = path or _DB_PATH
    if not db.exists():
        return
    try:
        conn = sqlite3.connect(str(db))
        conn.execute(f"DELETE FROM events WHERE ts < datetime('now', '-{days} days', 'localtime');")
        conn.commit()
        conn.close()
    except Exception:
        pass
