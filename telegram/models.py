"""Pydantic models for state, messages, and Telegram API types."""

from __future__ import annotations

from enum import Enum
from typing import Optional

from pydantic import BaseModel


class EventType(str, Enum):
    WAITING = "waiting"
    FINISHED = "finished"
    PROMPT = "prompt"


class KeyboardStyle(str, Enum):
    APPROVE_DENY = "approve_deny"
    OPTIONS = "options"
    VIEW_ONLY = "view_only"
    VIEW_REPLY = "view_reply"
    DEFAULT = "default"


class ModeInfo(BaseModel):
    label: str = ""
    auto: bool = False


class StateFile(BaseModel):
    """Represents a KEY=VALUE state file from active/ or notifications/."""

    session: str
    window: str
    window_name: str = ""
    message: str = ""
    type: str = ""
    timestamp: str = ""


class SendContext(BaseModel):
    """All context needed to build and send a Telegram message."""

    event_type: EventType
    session: str
    window: str
    message: str = ""
    tool_name: str = ""
    project_name: str = ""
    raw_context: str = ""
    raw_pre_chrome: str = ""  # text before strip_terminal_chrome, for option extraction
    pane_width: int = 120
    mode: ModeInfo = ModeInfo()


class InlineButton(BaseModel):
    text: str
    callback_data: str


class InlineKeyboard(BaseModel):
    inline_keyboard: list[list[InlineButton]]

    def to_dict(self) -> dict:
        return {
            "inline_keyboard": [
                [{"text": b.text, "callback_data": b.callback_data} for b in row]
                for row in self.inline_keyboard
            ]
        }


class MessagePayload(BaseModel):
    """Final message ready to send via Telegram API."""

    text: str
    keyboard: InlineKeyboard
    kb_style: KeyboardStyle = KeyboardStyle.DEFAULT


class TelegramConfig(BaseModel):
    bot_token: str
    chat_id: str

    @property
    def api_base(self) -> str:
        return f"https://api.telegram.org/bot{self.bot_token}"


class MsgIdEntry(BaseModel):
    """Stored as msg_id:type in telegram_msg_ids/ files."""

    msg_id: str
    type: str

    @classmethod
    def parse(cls, raw: str) -> Optional[MsgIdEntry]:
        """Parse 'msg_id:type' format. Returns None for empty/invalid."""
        raw = raw.strip()
        if not raw:
            return None
        if ":" in raw:
            msg_id, type_ = raw.split(":", 1)
            return cls(msg_id=msg_id, type=type_)
        # Legacy format: just msg_id, no type
        return cls(msg_id=raw, type="")

    def serialize(self) -> str:
        return f"{self.msg_id}:{self.type}"
