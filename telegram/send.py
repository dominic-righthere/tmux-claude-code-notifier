"""Telegram notification sender — replaces telegram-send.sh.

CLI: python -m telegram send <type> <session> <window> <message> [tool_name]
"""

from __future__ import annotations

import logging
import re
import sys
import time
from pathlib import Path

from telegram import api, db, state, tmux
from telegram.message import build_message
from telegram.models import EventType, ModeInfo, MsgIdEntry, SendContext
from telegram.parse import detect_mode, strip_ansi, strip_ghost_text, strip_terminal_chrome, trim_blank_lines

logger = logging.getLogger(__name__)


def send_notification(
    event_type: EventType,
    session: str,
    window: str,
    message: str = "",
    tool_name: str = "",
) -> None:
    """Main entry point: build and send a Telegram notification."""
    config = state.load_config()
    if not config:
        return

    msg_key = state.make_msg_key(session, window)

    # AskUserQuestion is an options prompt, not a command permission
    if tool_name == "AskUserQuestion":
        tool_name = ""

    # Early trace
    db.log_event(src="send", event="enter", type=event_type.value, session=session, window=window, tool=tool_name)

    # Get project name
    project_name = ""
    pane_path = tmux.pane_current_path(session, window)
    if pane_path:
        project_name = Path(pane_path).name

    # Mode detection + pane capture (skip for prompt type)
    raw_context = ""
    raw_pre_chrome = ""
    pw = 120
    mode = detect_mode("")

    if event_type != EventType.PROMPT:
        # Finished needs more time — final speech renders after Stop hook fires
        delay = 1.0 if event_type == EventType.FINISHED else 0.3
        time.sleep(delay)
        captured, pw = tmux.capture_wide(session, window)
        if captured:
            captured = strip_ghost_text(captured)
            raw_context = strip_ansi(captured)
            mode = detect_mode(raw_context)  # before chrome strip (needs ⏵⏵)
            raw_pre_chrome = raw_context  # save for option extraction (separators intact)
            raw_context = strip_terminal_chrome(raw_context)
            raw_context = trim_blank_lines(raw_context)

    # Override auto mode if pane shows a manual-approval prompt
    # (dangerous commands require approval even in auto-accept mode)
    if mode.auto and raw_pre_chrome:
        tail = raw_pre_chrome.splitlines()[-30:]
        if any(re.search(r'❯\s+[1-4]\.\s+\w', line) for line in tail):
            mode = ModeInfo(label=mode.label, auto=False)

    # Skip waiting in auto-accept mode
    if event_type == EventType.WAITING and mode.auto:
        db.log_event(
            src="send", event="skip_auto", type=event_type.value,
            session=session, window=window, extra=f"mode={mode.label}",
        )
        return

    # Log context
    if raw_context:
        db.log_event(
            src="send", event="context", type=event_type.value,
            session=session, window=window, text=raw_context[-500:],
        )

    db.log_event(
        src="send", event="dispatch", type=event_type.value,
        session=session, window=window, tool=tool_name,
        extra=f"mode={mode.label or 'normal'}",
    )

    # Build message
    ctx = SendContext(
        event_type=event_type,
        session=session,
        window=window,
        message=message,
        tool_name=tool_name,
        project_name=project_name,
        raw_context=raw_context,
        raw_pre_chrome=raw_pre_chrome,
        pane_width=pw,
        mode=mode,
    )

    payload = build_message(ctx)
    keyboard_dict = payload.keyboard.to_dict()

    db.log_event(
        src="send", event="keyboard", type=event_type.value,
        session=session, window=window, action=payload.kb_style.value,
        extra=f"tool={tool_name} options={len(payload.keyboard.inline_keyboard) - 1 if payload.kb_style.value == 'options' else 0}",
    )

    # Send or edit
    _send_or_edit(config, session, window, event_type, payload.text, keyboard_dict, tool_name=tool_name)


def _send_or_edit(
    config: state.TelegramConfig,
    session: str,
    window: str,
    event_type: EventType,
    text: str,
    keyboard: dict,
    tool_name: str = "",
) -> None:
    """Send new message or edit previous, with type guard for race conditions."""
    prev = state.read_msg_id(session, window)

    if prev and prev.msg_id:
        # Permission requests always get their own message — strip buttons
        # from the old message and fall through to send new
        if tool_name:
            api.strip_buttons(config, prev.msg_id)
            db.log_event(
                src="send", event="strip_for_perm", type=event_type.value,
                session=session, window=window, msg_id=prev.msg_id,
            )
        # Type guard: don't edit a waiting message with a finished message
        elif prev.type == "waiting" and event_type == EventType.FINISHED:
            db.log_event(
                src="send", event="skip_edit", type=event_type.value,
                session=session, window=window, msg_id=prev.msg_id,
                extra="prev_type=waiting",
            )
        else:
            # Try to edit in-place
            if api.edit_message(config, prev.msg_id, text, keyboard):
                state.write_msg_id(session, window, MsgIdEntry(msg_id=prev.msg_id, type=event_type.value))
                db.log_event(
                    src="send", event="edit", type=event_type.value,
                    session=session, window=window, msg_id=prev.msg_id,
                )
                return

            db.log_event(
                src="send", event="edit_fail", type=event_type.value,
                session=session, window=window, msg_id=prev.msg_id,
            )

    # Send new message
    new_msg_id = api.send_message(config, text, keyboard)
    if new_msg_id and event_type != EventType.PROMPT:
        state.write_msg_id(session, window, MsgIdEntry(msg_id=new_msg_id, type=event_type.value))
        db.log_event(
            src="send", event="new", type=event_type.value,
            session=session, window=window, msg_id=new_msg_id,
        )
    else:
        db.log_event(
            src="send", event="send_fail", type=event_type.value,
            session=session, window=window,
        )


def cli_main(args: list[str]) -> None:
    """CLI entry point matching telegram-send.sh interface:

    <type> <session> <window> <message> [tool_name]
    """
    logging.basicConfig(
        level=logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if len(args) < 2:
        return

    type_str = args[0]
    session = args[1]
    window = args[2] if len(args) > 2 else ""
    message = args[3] if len(args) > 3 else ""
    tool_name = args[4] if len(args) > 4 else ""

    # Unescape JSON string sequences from bash extract_json_value
    if message:
        message = message.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"')

    # Only handle known types
    try:
        event_type = EventType(type_str)
    except ValueError:
        return

    try:
        send_notification(event_type, session, window, message, tool_name)
    except Exception:
        logger.exception("send_notification failed")
        sys.exit(1)
    finally:
        api.close()
