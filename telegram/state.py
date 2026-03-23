"""State file I/O — compatible with bash KEY=VALUE format."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

from telegram.models import MsgIdEntry, StateFile, TelegramConfig


def _ensure_dir(d: Path) -> Path:
    """Create directory with restricted permissions (700)."""
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Tighten permissions on existing dirs (mkdir won't change them)
    os.chmod(d, 0o700)
    return d


def data_dir() -> Path:
    return _ensure_dir(Path.home() / ".local" / "share" / "claude-notifier")


def config_path() -> Path:
    return data_dir() / "telegram.conf"


def msg_id_dir() -> Path:
    d = data_dir() / "telegram_msg_ids"
    d.mkdir(parents=True, exist_ok=True)
    return d


def active_dir() -> Path:
    d = data_dir() / "active"
    d.mkdir(parents=True, exist_ok=True)
    return d


def notif_dir() -> Path:
    d = data_dir() / "notifications"
    d.mkdir(parents=True, exist_ok=True)
    return d


def sanitize_key(session: str) -> str:
    """Sanitize a tmux session name for use as a filename.

    Must match lib.sh sanitize_key exactly.
    """
    return session.replace("/", "_").replace(" ", "_")


def make_msg_key(session: str, window: str) -> str:
    return f"{sanitize_key(session)}_{window}"


def load_config() -> Optional[TelegramConfig]:
    """Load telegram.conf. Returns None if not configured."""
    path = config_path()
    if not path.exists():
        return None

    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            key, val = line.split("=", 1)
            values[key.strip()] = val.strip()

    token = values.get("BOT_TOKEN", "")
    chat_id = values.get("CHAT_ID", "")
    if not token or not chat_id:
        return None

    return TelegramConfig(bot_token=token, chat_id=chat_id)


def save_config(config: TelegramConfig) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = f"BOT_TOKEN={config.bot_token}\nCHAT_ID={config.chat_id}\n"
    path.write_text(lines)
    path.chmod(0o600)


def read_state_file(path: Path) -> Optional[StateFile]:
    """Read a KEY=VALUE state file."""
    if not path.exists():
        return None

    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            values[key] = val

    session = values.get("SESSION", "")
    if not session:
        return None

    return StateFile(
        session=session,
        window=values.get("WINDOW", ""),
        window_name=values.get("WINDOW_NAME", ""),
        message=values.get("MESSAGE", ""),
        type=values.get("TYPE", ""),
        timestamp=values.get("TIMESTAMP", ""),
    )


def write_state_file(
    dir_path: Path,
    key: str,
    session: str,
    window: str,
    window_name: str,
    type_: str,
    message: str,
    timestamp: str,
) -> None:
    """Write a state file in bash-compatible KEY=VALUE format."""
    dir_path.mkdir(parents=True, exist_ok=True)
    content = (
        f"SESSION={session}\n"
        f"WINDOW={window}\n"
        f"WINDOW_NAME={window_name}\n"
        f"MESSAGE={message}\n"
        f"TYPE={type_}\n"
        f"TIMESTAMP={timestamp}\n"
    )
    (dir_path / key).write_text(content)


def read_msg_id(session: str, window: str) -> Optional[MsgIdEntry]:
    """Read msg_id:type from the msg_id file."""
    key = make_msg_key(session, window)
    path = msg_id_dir() / key
    if not path.exists():
        return None
    return MsgIdEntry.parse(path.read_text())


def write_msg_id(session: str, window: str, entry: MsgIdEntry) -> None:
    key = make_msg_key(session, window)
    (msg_id_dir() / key).write_text(entry.serialize())


def clear_msg_id(session: str, window: str) -> None:
    key = make_msg_key(session, window)
    path = msg_id_dir() / key
    path.unlink(missing_ok=True)


def clear_session_state(session: str, window: str) -> None:
    """Clear notification + msg_id for a session (matches bash clear_session_state)."""
    key = make_msg_key(session, window)
    (notif_dir() / key).unlink(missing_ok=True)
    (msg_id_dir() / key).unlink(missing_ok=True)


def is_muted() -> bool:
    """Check if notifications are muted (telegram.disabled flag file exists)."""
    return (data_dir() / "telegram.disabled").exists()


def set_muted(muted: bool) -> None:
    """Touch or remove the telegram.disabled flag file."""
    flag = data_dir() / "telegram.disabled"
    if muted:
        flag.touch()
    else:
        flag.unlink(missing_ok=True)


def find_session_by_msg_id(target_msg_id: str) -> tuple[str, str] | None:
    """Reverse lookup: find (session, window) for a Telegram message_id."""
    for f in msg_id_dir().iterdir():
        if not f.is_file():
            continue
        entry = MsgIdEntry.parse(f.read_text())
        if entry and entry.msg_id == target_msg_id:
            # Filename is {sanitized_session}_{window}; window is always a digit
            name = f.name
            last_us = name.rfind("_")
            if last_us > 0:
                return name[:last_us], name[last_us + 1:]
    return None
