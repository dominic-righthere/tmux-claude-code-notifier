"""Telegram bot daemon — replaces telegram.sh.

Async long-polling bot that receives commands and dispatches to tmux.
Usage: python -m telegram bot start|stop|status|run
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import signal
import sys
from pathlib import Path

from telegram import api, db, state, tmux
from telegram.models import TelegramConfig
from telegram.tmux import validate_target
from telegram.parse import (
    convert_tables_to_bullets,
    extract_preview,
    html_escape,
    reflow_for_telegram,
    strip_ansi,
    strip_ghost_text,
    strip_terminal_chrome,
    trim_blank_lines,
    wrap_long_lines,
)

logger = logging.getLogger(__name__)

DATA_DIR = Path.home() / ".local" / "share" / "claude-notifier"
PID_FILE = DATA_DIR / "telegram.pid"
LOG_FILE = DATA_DIR / "telegram.log"

MAX_SEND_TEXT_LEN = 4000

# Actions that require session:window target
_TARGETED_ACTIONS = {"approve", "deny", "opt", "view", "prompt", "mode"}


# ─── Helpers ─────────────────────────────────────────────────────────────────


def parse_command(text: str) -> tuple[str, str]:
    """Parse '/command args' into (command, args). Strips @botname suffix."""
    parts = text.split(" ", 1)
    cmd = parts[0].split("@")[0]  # strip @botname
    args = parts[1] if len(parts) > 1 else ""
    return cmd, args


def dispatch_callback_data(data: str) -> tuple[str, str, str, str]:
    """Parse 'action:session:window[:extra]' callback data.

    Returns (action, session, window, extra). Validates that targeted actions
    have enough parts and that session/window pass format checks.
    Raises ValueError on invalid data.
    """
    parts = data.split(":", 3)
    action = parts[0] if len(parts) > 0 else ""
    session = parts[1] if len(parts) > 1 else ""
    window = parts[2] if len(parts) > 2 else ""
    extra = parts[3] if len(parts) > 3 else ""

    if action in _TARGETED_ACTIONS:
        if len(parts) < 3:
            raise ValueError(f"Missing session/window for '{action}'")
        err = validate_target(session, window)
        if err:
            raise ValueError(err)

    return action, session, window, extra


# ─── Session helpers ──────────────────────────────────────────────────────────


def _build_session_list() -> list[dict]:
    """Build sorted session list: working → waiting → finished → idle."""
    sessions: list[dict] = []
    idx = 0

    for cat in ("working", "waiting", "finished", "idle"):
        if cat in ("working", "idle"):
            dir_path = state.active_dir()
        else:
            dir_path = state.notif_dir()

        if not dir_path.exists():
            continue

        for f in sorted(dir_path.iterdir()):
            if not f.is_file():
                continue

            sf = state.read_state_file(f)
            if not sf or not sf.session:
                continue

            # Map type to category
            type_to_cat = {"working": "working", "idle": "idle", "waiting": "waiting"}
            file_cat = type_to_cat.get(sf.type, "finished")
            if file_cat != cat:
                continue

            idx += 1
            sessions.append({
                "idx": idx,
                "session": sf.session,
                "window": sf.window,
                "category": cat,
                "message": sf.message,
            })

    return sessions


def _get_session_info(session: str, window: str) -> dict:
    """Get enriched session info: project, mode, task hint."""
    info: dict = {"project": "", "mode": "", "mode_icon": "", "task": ""}

    pane_path = tmux.pane_current_path(session, window)
    if pane_path:
        info["project"] = Path(pane_path).name

    # Capture bottom lines for mode/task detection
    bottom = tmux.run_tmux("capture-pane", "-e", "-t", f"{session}:{window}", "-J", "-p", "-S", "-8")
    if bottom:
        bottom_clean = strip_ghost_text(bottom)
        bottom_clean = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", bottom_clean)
        if re.search(r"plan mode", bottom_clean, re.IGNORECASE):
            info["mode"] = "plan mode"
            info["mode_icon"] = "⏸"
        elif re.search(r"auto-accept|accept edits", bottom_clean, re.IGNORECASE):
            info["mode"] = "auto-accept"
            info["mode_icon"] = "⏵⏵"

        # Task hint: last ❯ line
        task_lines = [l for l in bottom_clean.splitlines() if "❯" in l]
        if task_lines:
            task = task_lines[-1].split("❯", 1)[-1].strip()
            if len(task) > 60:
                task = task[:57] + "..."
            info["task"] = task

    return info


def _icon_for(cat: str) -> str:
    return {"working": "⟳", "waiting": "⏳", "finished": "●", "idle": "○"}.get(cat, "?")


def _check_target(session: str, window: str) -> str | None:
    """Check if session:window exists. Returns error string or None."""
    if not tmux.has_session(session):
        return f"Session '{session}' closed"
    if not tmux.has_window(session, window):
        return f"Window {window} not found in '{session}'"
    return None


def _clean_pane_for_view(raw: str, pw: int) -> str:
    """Clean captured pane output for the View handler.

    Strips ANSI, terminal chrome, scopes to the current work block
    (after last ❯ prompt), then reflows/wraps for mobile.
    """
    text = strip_ghost_text(raw)
    text = strip_ansi(text)
    text = strip_terminal_chrome(text)

    # Scope to current work block: everything after last ❯ line.
    # If the last work block has < 5 non-blank lines (e.g. empty new prompt
    # after task completion), fall back to the second-to-last prompt.
    lines = text.splitlines()
    prompt_indices: list[int] = []
    for i, line in enumerate(lines):
        if re.match(r"^\s*❯\s+", line):
            prompt_indices.append(i)
    if prompt_indices:
        last = prompt_indices[-1]
        work_block = lines[last:]
        non_blank = [l for l in work_block if l.strip()]
        if len(non_blank) < 5 and len(prompt_indices) >= 2:
            lines = lines[prompt_indices[-2]:]
        else:
            lines = work_block

    # Keep last 80 lines to avoid walls of text
    if len(lines) > 80:
        lines = lines[-80:]

    text = "\n".join(lines)
    text = reflow_for_telegram(text, pw)
    text = convert_tables_to_bullets(text)
    text = wrap_long_lines(text, 50)
    return trim_blank_lines(text)


def _resolve_target(identifier: str, sessions: list[dict] | None = None) -> dict | None:
    """Resolve a session identifier to a session entry.

    Tries (in order):
    1. Numeric index
    2. Exact session:window match
    3. Session name match (any window)
    4. Project name match (case-insensitive)
    """
    if sessions is None:
        sessions = _build_session_list()
    if not sessions:
        return None

    identifier = identifier.strip()

    # 1. Numeric index
    if identifier.isdigit():
        return next((s for s in sessions if str(s["idx"]) == identifier), None)

    # 2. Exact session:window
    if ":" in identifier:
        sess_name, win = identifier.split(":", 1)
        return next(
            (s for s in sessions if s["session"] == sess_name and s["window"] == win),
            None,
        )

    # 3. Session name (first match)
    match = next((s for s in sessions if s["session"] == identifier), None)
    if match:
        return match

    # 4. Project name (case-insensitive)
    ident_lower = identifier.lower()
    for entry in sessions:
        info = _get_session_info(entry["session"], entry["window"])
        if info["project"] and info["project"].lower() == ident_lower:
            return entry

    return None


def _active_session_names(sessions: list[dict] | None = None) -> str:
    """Return comma-separated list of active session names for error messages."""
    if sessions is None:
        sessions = _build_session_list()
    names: list[str] = []
    for s in sessions:
        info = _get_session_info(s["session"], s["window"])
        name = info["project"] or s["session"]
        if name not in names:
            names.append(name)
    return ", ".join(names) if names else "none"


# ─── Command handlers ────────────────────────────────────────────────────────


BOT_COMMANDS = [
    {"command": "s", "description": "Session dashboard"},
    {"command": "v", "description": "View session output"},
    {"command": "a", "description": "Approve (send y)"},
    {"command": "d", "description": "Deny (send n)"},
    {"command": "send", "description": "Send text to session"},
    {"command": "mode", "description": "Switch mode (plan/compact/cancel)"},
    {"command": "run", "description": "Run command in session"},
    {"command": "restart", "description": "Restart all Claude sessions"},
    {"command": "doctor", "description": "Run diagnostics"},
    {"command": "help", "description": "Show all commands"},
]

HELP_TEXT = """\
<b>Claude Code Notifier</b>

<b>Quick actions:</b>
Reply to any notification to send text.
Tap buttons for approve/deny/view/send.

<b>Commands:</b>
/s — Session dashboard (names + #)
/v — View output
/a — Approve (send y)
/d — Deny (send n)
/send — Send text to session
/mode — Switch mode
/run — Run shell command
/restart — Restart all sessions
/doctor — Diagnostics

<b>Examples:</b>
<code>/v myapp</code>  or  <code>/v 1</code>
<code>/a 1</code>
<code>/send myapp fix the bug</code>
<code>/mode myapp plan</code>
<code>/run 1 git status</code>
<code>/restart</code>  or  <code>/restart 1.0.20</code>

Use /s to see project names and numbers."""


class BotHandler:
    """Stateful handler for bot commands and callbacks."""

    def __init__(self, config: TelegramConfig, script_dir: str):
        self.config = config
        self.script_dir = script_dir
        self.last_sessions_msg_id: str | None = None
        self.pending_reply_target: tuple[str, str] | None = None

    async def send(self, text: str, reply_markup: dict | None = None) -> str | None:
        msg_id = await api.async_send_message(self.config, text, reply_markup)
        plain = re.sub(r"<[^>]+>", "", text)[:200]
        db.log_event(src="bot", event="sent", message=plain, msg_id=msg_id or "")
        return msg_id

    async def edit(self, msg_id: str, text: str, reply_markup: dict | None = None) -> bool:
        return await api.async_edit_message(self.config, msg_id, text, reply_markup)

    async def cmd_reply_send(self, sess: str, win: str, text: str) -> None:
        """Send text to a session (used by reply-to-send and ForceReply)."""
        if len(text) > MAX_SEND_TEXT_LEN:
            await self.send(f"Message too long ({len(text)} chars, max {MAX_SEND_TEXT_LEN})")
            return
        err = _check_target(sess, win)
        if err:
            await self.send(err)
            return
        if tmux.send_text(sess, win, text):
            info = _get_session_info(sess, win)
            label = info["project"] or sess
            await self.send(f"Sent to <b>{html_escape(label)}</b>")
            db.log_event(src="bot", event="reply_send", session=sess, window=win)
        else:
            await self.send(f"Failed to send to {sess}:{win}")

    # ─── Commands ─────────────────────────────────────────────────────

    async def cmd_help(self) -> None:
        await self.send(HELP_TEXT)

    async def cmd_sessions(self) -> None:
        sessions = _build_session_list()
        if not sessions:
            await self.send("No active Claude Code sessions.")
            return

        text = "<b>Sessions</b>\n"
        keyboard_rows: list[list[dict]] = []

        for entry in sessions:
            cat = entry["category"]
            sess = entry["session"]
            win = entry["window"]
            msg = entry["message"]

            info = _get_session_info(sess, win)
            icon = _icon_for(cat)

            # Compact line: icon session · project
            line = f"\n{icon}"
            if info["mode_icon"]:
                line += f" {info['mode_icon']}"
            line += f" {sess}"
            if win != "0":
                line += f":{win}"
            if info["project"]:
                line += f" · {info['project']}"
            text += line

            if info["task"]:
                text += f"\n  {html_escape(info['task'])}"
            elif msg and msg not in ("Idle", "Working..."):
                text += f"\n  {html_escape(msg)}"

            # Button label
            btn_label = info["project"][:12] if info["project"] else sess[:12]

            if cat == "waiting":
                keyboard_rows.append([
                    {"text": f"✅ {btn_label}", "callback_data": f"approve:{sess}:{win}"},
                    {"text": f"❌ {btn_label}", "callback_data": f"deny:{sess}:{win}"},
                    {"text": f"📋 {btn_label}", "callback_data": f"view:{sess}:{win}"},
                ])
                keyboard_rows.append([
                    {"text": f"⏹ Cancel", "callback_data": f"mode:{sess}:{win}:esc"},
                ])
            elif cat == "working":
                keyboard_rows.append([
                    {"text": f"📋 {btn_label}", "callback_data": f"view:{sess}:{win}"},
                    {"text": f"💬 {btn_label}", "callback_data": f"prompt:{sess}:{win}"},
                    {"text": "⏹", "callback_data": f"mode:{sess}:{win}:esc"},
                ])
            else:
                keyboard_rows.append([
                    {"text": f"📋 {btn_label}", "callback_data": f"view:{sess}:{win}"},
                    {"text": f"💬 {btn_label}", "callback_data": f"prompt:{sess}:{win}"},
                ])

        keyboard_rows.append([{"text": "🔄 Refresh", "callback_data": "sessions:refresh"}])
        keyboard = {"inline_keyboard": keyboard_rows}

        if self.last_sessions_msg_id:
            if await self.edit(self.last_sessions_msg_id, text, keyboard):
                return

        self.last_sessions_msg_id = await self.send(text, keyboard)

    async def cmd_view(self, identifier: str) -> None:
        sessions = _build_session_list()
        entry = _resolve_target(identifier, sessions)
        if not entry:
            await self.send(f"Session '{identifier}' not found. Active: {_active_session_names(sessions)}")
            return

        sess, win = entry["session"], entry["window"]
        err = _check_target(sess, win)
        if err:
            await self.send(err)
            return

        raw, pw = tmux.capture_wide(sess, win)
        output = _clean_pane_for_view(raw or "", pw)

        if not output:
            await self.send(f"<b>{sess}:{win}</b>\n\n(empty)")
            return

        info = _get_session_info(sess, win)
        header = f"📋 <b>View</b>\n{sess}:{win}"
        if info["project"]:
            header += f" · {info['project']}"

        preview = html_escape(extract_preview(output, 3))

        if len(output) > 3800:
            output = "..." + output[len(output) - 3800:]
        output_escaped = html_escape(output)

        await self.send(
            f"{header}\n\n{preview}\n\n<blockquote expandable>{output_escaped}</blockquote>"
        )

    async def _action(self, sess: str, win: str, keys: list[str], label: str, cb_msg_id: str = "") -> str:
        """Execute an action (approve/deny/opt). Returns status message."""
        err = _check_target(sess, win)
        if err:
            state.clear_session_state(sess, win)
            if cb_msg_id:
                await api.async_strip_buttons(self.config, cb_msg_id)
            return err

        if tmux.send_keys(sess, win, *keys):
            state.clear_session_state(sess, win)
            if cb_msg_id:
                await api.async_strip_buttons(self.config, cb_msg_id)
            db.log_event(src="bot", event="callback_ok", action=label, session=sess, window=win)
            return label
        else:
            db.log_event(src="bot", event="callback_err", action=label, session=sess, window=win)
            return "Failed to send keys"

    async def cmd_approve(self, identifier: str) -> None:
        sessions = _build_session_list()
        entry = _resolve_target(identifier, sessions)
        if not entry:
            await self.send(f"Session '{identifier}' not found. Active: {_active_session_names(sessions)}")
            return
        result = await self._action(entry["session"], entry["window"], ["y", "Enter"], "Approved")
        await self.send(f"✅ {result} {entry['session']}:{entry['window']}")

    async def cmd_deny(self, identifier: str) -> None:
        sessions = _build_session_list()
        entry = _resolve_target(identifier, sessions)
        if not entry:
            await self.send(f"Session '{identifier}' not found. Active: {_active_session_names(sessions)}")
            return
        result = await self._action(entry["session"], entry["window"], ["n", "Enter"], "Denied")
        await self.send(f"❌ {result} {entry['session']}:{entry['window']}")

    async def cmd_send(self, identifier: str, msg: str) -> None:
        sessions = _build_session_list()
        entry = _resolve_target(identifier, sessions)
        if not entry:
            await self.send(f"Session '{identifier}' not found. Active: {_active_session_names(sessions)}")
            return
        if not msg:
            await self.send("Usage: /send &lt;target&gt; &lt;message&gt;\nExample: <code>/send myapp fix the bug</code>")
            return
        if len(msg) > MAX_SEND_TEXT_LEN:
            await self.send(f"Message too long ({len(msg)} chars, max {MAX_SEND_TEXT_LEN})")
            return
        sess, win = entry["session"], entry["window"]
        err = _check_target(sess, win)
        if err:
            await self.send(err)
            return
        if tmux.send_text(sess, win, msg):
            await self.send(f"Sent to {sess}:{win}")
        else:
            await self.send(f"Failed to send to {sess}:{win}")

    async def cmd_run(self, identifier: str, run_cmd: str) -> None:
        sessions = _build_session_list()
        entry = _resolve_target(identifier, sessions)
        if not entry:
            await self.send(f"Session '{identifier}' not found. Active: {_active_session_names(sessions)}")
            return
        if not run_cmd:
            await self.send("Usage: /run &lt;target&gt; &lt;command&gt;\nExample: <code>/run myapp git status</code>")
            return
        sess = entry["session"]
        err = _check_target(sess, entry["window"])
        if err:
            await self.send(err)
            return

        new_win = tmux.new_window(sess)
        if not new_win:
            await self.send(f"Failed to create window in {sess}")
            return

        tmux.send_keys(sess, new_win, run_cmd, "Enter")
        await self.send(f"Running in {sess}:{new_win}...\n{html_escape(run_cmd)}")

        await asyncio.sleep(2)
        pw = tmux.pane_width(sess, new_win)
        raw = tmux.capture_pane(sess, new_win, lines=50) or ""
        output = trim_blank_lines(reflow_for_telegram(raw, pw))
        if output:
            if len(output) > 3800:
                output = "..." + output[len(output) - 3800:]
            await self.send(f"<b>Output from {sess}:{new_win}</b>\n\n{html_escape(output)}")

    async def cmd_doctor(self) -> None:
        try:
            proc = await asyncio.create_subprocess_exec(
                f"{self.script_dir}/doctor.sh", "--quiet",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
            output = stdout.decode() if stdout else "All checks passed."
        except asyncio.TimeoutError:
            output = "Doctor timed out after 30s."
        except Exception as e:
            output = f"Error running doctor: {e}"

        if len(output) > 3800:
            output = "..." + output[len(output) - 3800:]
        await self.send(f"<pre>{html_escape(output)}</pre>")

    async def cmd_restart(self, version: str = "") -> None:
        script = f"{self.script_dir}/restart.sh"
        args = [script, "--yes"]
        if version:
            args.extend(["--version", version])
            await self.send(f"Restarting all Claude Code sessions (installing v{version})...")
        else:
            await self.send("Restarting all Claude Code sessions...")

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=120)
            output = stdout.decode() if stdout else "No output from restart script."
        except asyncio.TimeoutError:
            output = "Restart timed out after 120s."
        except Exception as e:
            output = f"Error: {e}"

        if len(output) > 3800:
            output = "..." + output[len(output) - 3800:]
        await self.send(f"<pre>{html_escape(output)}</pre>")

    async def cmd_mode(self, args: str) -> None:
        parts = args.split(None, 1)
        if len(parts) < 2:
            await self.send("Usage: /mode &lt;target&gt; &lt;plan|compact|cancel&gt;\nExample: <code>/mode myapp plan</code>")
            return

        identifier, mode_cmd = parts[0], parts[1].lower()
        sessions = _build_session_list()
        entry = _resolve_target(identifier, sessions)
        if not entry:
            await self.send(f"Session '{identifier}' not found. Active: {_active_session_names(sessions)}")
            return

        sess, win = entry["session"], entry["window"]
        err = _check_target(sess, win)
        if err:
            await self.send(err)
            return

        match mode_cmd:
            case "cancel" | "esc":
                keys = ["Escape"]
                label = "Cancelled"
            case "plan":
                keys = ["/plan", "Enter"]
                label = "Plan mode"
            case "compact":
                keys = ["/compact", "Enter"]
                label = "Compact"
            case _:
                await self.send(f"Unknown mode '{mode_cmd}'. Use: plan, compact, cancel")
                return

        if tmux.send_keys(sess, win, *keys):
            await self.send(f"{label} → {sess}:{win}")
            db.log_event(src="bot", event="mode", action=mode_cmd, session=sess, window=win)
        else:
            await self.send(f"Failed to send to {sess}:{win}")

    # ─── Dispatch ─────────────────────────────────────────────────────

    async def dispatch_message(self, text: str) -> None:
        cmd, args = parse_command(text)

        match cmd:
            case "/help" | "/start":
                await self.cmd_help()
            case "/s":
                await self.cmd_sessions()
            case "/v":
                if not args:
                    await self.send("Usage: /v &lt;target&gt;\nExample: <code>/v myapp</code> or <code>/v 1</code>")
                else:
                    await self.cmd_view(args.split()[0])
            case "/a":
                if not args:
                    await self.send("Usage: /a &lt;target&gt;\nExample: <code>/a myapp</code> or <code>/a 1</code>")
                else:
                    await self.cmd_approve(args.split()[0])
            case "/d":
                if not args:
                    await self.send("Usage: /d &lt;target&gt;\nExample: <code>/d myapp</code> or <code>/d 1</code>")
                else:
                    await self.cmd_deny(args.split()[0])
            case "/send":
                if not args:
                    await self.send("Usage: /send &lt;target&gt; &lt;message&gt;\nExample: <code>/send myapp fix the bug</code>")
                else:
                    parts = args.split(" ", 1)
                    num = parts[0]
                    msg = parts[1] if len(parts) > 1 else ""
                    await self.cmd_send(num, msg)
            case "/run":
                if not args:
                    await self.send("Usage: /run &lt;target&gt; &lt;command&gt;\nExample: <code>/run 1 git status</code>")
                else:
                    parts = args.split(" ", 1)
                    num = parts[0]
                    run_cmd = parts[1] if len(parts) > 1 else ""
                    await self.cmd_run(num, run_cmd)
            case "/mode":
                if not args:
                    await self.send("Usage: /mode &lt;target&gt; &lt;plan|compact|cancel&gt;\nExample: <code>/mode myapp plan</code>")
                else:
                    await self.cmd_mode(args)
            case "/restart":
                await self.cmd_restart(args.strip())
            case "/doctor":
                await self.cmd_doctor()
            case _:
                await self.send("Unknown command. Type /help for available commands.")

    async def handle_callback(self, callback_id: str, data: str, cb_msg_id: str = "") -> None:
        try:
            action, sess, win, extra = dispatch_callback_data(data)
        except ValueError as e:
            logger.warning("Invalid callback data %r: %s", data, e)
            await api.async_answer_callback(self.config, callback_id, "Invalid request")
            return
        db.log_event(src="bot", event="callback", action=action, session=sess, window=win, msg_id=cb_msg_id)

        match action:
            case "approve":
                result = await self._action(sess, win, ["y", "Enter"], "Approved", cb_msg_id)
                await api.async_answer_callback(self.config, callback_id, result)
            case "deny":
                result = await self._action(sess, win, ["n", "Enter"], "Denied", cb_msg_id)
                await api.async_answer_callback(self.config, callback_id, result)
            case "opt":
                result = await self._action(sess, win, [extra], f"Sent option {extra}", cb_msg_id)
                await api.async_answer_callback(self.config, callback_id, result)
            case "view":
                await api.async_answer_callback(self.config, callback_id, "")
                err = _check_target(sess, win)
                if err:
                    await self.send(f"<b>{sess}:{win}</b>\n\n{err}")
                    return

                raw, pw = tmux.capture_wide(sess, win)
                output = _clean_pane_for_view(raw or "", pw)

                if not output:
                    await self.send(f"<b>{sess}:{win}</b>\n\n(empty)")
                    return

                info = _get_session_info(sess, win)
                header = f"📋 <b>View</b>\n{sess}:{win}"
                if info["project"]:
                    header += f" · {info['project']}"

                preview = html_escape(extract_preview(output, 3))
                if len(output) > 3800:
                    output = "..." + output[len(output) - 3800:]

                await self.send(
                    f"{header}\n\n{preview}\n\n"
                    f"<blockquote expandable>{html_escape(output)}</blockquote>"
                )
            case "prompt":
                # ForceReply flow: set pending target, send ForceReply message
                await api.async_answer_callback(self.config, callback_id, "")
                self.pending_reply_target = (sess, win)
                info = _get_session_info(sess, win)
                label = info["project"] or sess
                await api.async_send_message(
                    self.config,
                    f"Type your message for <b>{html_escape(label)}</b>:",
                    {"force_reply": True, "selective": True},
                )
                db.log_event(src="bot", event="prompt_reply", session=sess, window=win)
            case "mode":
                # Mode switching: extra is the command (esc, plan, compact)
                match extra:
                    case "esc":
                        keys = ["Escape"]
                        label = "Cancelled"
                    case "plan":
                        keys = ["/plan", "Enter"]
                        label = "Plan mode"
                    case "compact":
                        keys = ["/compact", "Enter"]
                        label = "Compact"
                    case _:
                        await api.async_answer_callback(self.config, callback_id, f"Unknown mode: {extra}")
                        return
                err = _check_target(sess, win)
                if err:
                    await api.async_answer_callback(self.config, callback_id, err)
                    return
                if tmux.send_keys(sess, win, *keys):
                    await api.async_answer_callback(self.config, callback_id, label)
                    db.log_event(src="bot", event="mode", action=extra, session=sess, window=win)
                else:
                    await api.async_answer_callback(self.config, callback_id, "Failed")
            case "sessions":
                await api.async_answer_callback(self.config, callback_id, "Refreshing...")
                await self.cmd_sessions()
            case _:
                await api.async_answer_callback(self.config, callback_id, "Unknown action")


# ─── Daemon management ───────────────────────────────────────────────────────


async def run_bot(config: TelegramConfig, script_dir: str) -> None:
    """Main async polling loop."""
    handler = BotHandler(config, script_dir)

    # Initialize DB and prune
    db.init_db()
    db.prune_old_events()

    # Truncate log
    if LOG_FILE.exists():
        lines = LOG_FILE.read_text().splitlines()
        LOG_FILE.write_text("\n".join(lines[-200:]) + "\n")

    logger.info("Telegram bot started (PID %d)", os.getpid())
    db.log_event(src="bot", event="start", message=f"PID {os.getpid()}")

    # Register commands
    api.set_my_commands(config, BOT_COMMANDS)

    # Startup message
    version = ""
    version_file = Path(script_dir) / "VERSION"
    if version_file.exists():
        version = f" v{version_file.read_text().strip()}"
    await handler.send(f"Bot started{version}")
    await handler.cmd_doctor()

    offset = 0
    running = True

    def handle_signal(sig: int, frame: object) -> None:
        nonlocal running
        running = False
        db.log_event(src="bot", event="stop")
        logger.info("Bot stopping")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    while running:
        try:
            updates = await api.async_get_updates(config, offset=offset)
        except Exception:
            logger.exception("Polling error")
            await asyncio.sleep(5)
            continue

        if updates is None:
            await asyncio.sleep(5)
            continue

        for update in updates:
            update_id = update.get("update_id")
            if update_id is not None:
                offset = update_id + 1

            # Callback query (inline keyboard)
            cb = update.get("callback_query")
            if cb:
                cb_id = cb.get("id", "")
                from_id = str(cb.get("from", {}).get("id", ""))
                if from_id == config.chat_id:
                    cb_data = cb.get("data", "")
                    cb_msg_id = str(cb.get("message", {}).get("message_id", ""))
                    if cb_data:
                        try:
                            await handler.handle_callback(cb_id, cb_data, cb_msg_id)
                        except Exception:
                            logger.exception("Callback error")
                continue

            # Regular message
            msg = update.get("message", {})
            from_id = str(msg.get("from", {}).get("id", ""))
            if not from_id:
                continue

            if from_id != config.chat_id:
                logger.warning("Rejected message from unauthorized user: %s", from_id)
                db.log_event(src="bot", event="rejected", message=from_id)
                continue

            msg_text = msg.get("text", "")
            if not msg_text:
                continue

            # Reply-to-send: if replying to a notification and not a command
            reply_to = msg.get("reply_to_message")
            if reply_to and not msg_text.startswith("/"):
                reply_msg_id = str(reply_to.get("message_id", ""))
                if reply_msg_id:
                    target = state.find_session_by_msg_id(reply_msg_id)
                    if target:
                        sess, win = target
                        logger.info("Reply-send to %s:%s: %s", sess, win, msg_text)
                        db.log_event(src="bot", event="recv", action="reply", session=sess, window=win, message=msg_text)
                        try:
                            await handler.cmd_reply_send(sess, win, msg_text)
                        except Exception:
                            logger.exception("Reply-send error")
                        continue

            # Handle pending ForceReply target
            if handler.pending_reply_target and not msg_text.startswith("/"):
                sess, win = handler.pending_reply_target
                handler.pending_reply_target = None
                logger.info("ForceReply to %s:%s: %s", sess, win, msg_text)
                db.log_event(src="bot", event="recv", action="force_reply", session=sess, window=win, message=msg_text)
                try:
                    await handler.cmd_reply_send(sess, win, msg_text)
                except Exception:
                    logger.exception("ForceReply send error")
                continue

            logger.info("Command: %s", msg_text)
            db.log_event(src="bot", event="recv", action="command", message=msg_text)
            try:
                await handler.dispatch_message(msg_text)
            except Exception:
                logger.exception("Command error")


def _cmd_start(script_dir: str) -> None:
    config = state.load_config()
    if not config:
        print(f"Error: Telegram not configured. Run: {script_dir}/telegram-setup.sh")
        sys.exit(1)

    if PID_FILE.exists():
        old_pid = int(PID_FILE.read_text().strip())
        try:
            os.kill(old_pid, 0)
            print(f"Bot already running (PID {old_pid})")
            return
        except ProcessLookupError:
            PID_FILE.unlink()

    print("Starting Telegram bot daemon...")
    # Fork into background
    pid = os.fork()
    if pid > 0:
        # Parent
        PID_FILE.write_text(str(pid))
        print(f"Started (PID {pid}). Log: {LOG_FILE}")
        return

    # Child: redirect stdio to log
    os.setsid()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    log_fd = open(LOG_FILE, "a")
    os.dup2(log_fd.fileno(), sys.stdout.fileno())
    os.dup2(log_fd.fileno(), sys.stderr.fileno())

    asyncio.run(run_bot(config, script_dir))


def _cmd_stop() -> None:
    if not PID_FILE.exists():
        print("Bot is not running.")
        return

    pid = int(PID_FILE.read_text().strip())
    try:
        os.kill(pid, signal.SIGTERM)
        # Wait for clean exit
        import time
        for _ in range(10):
            time.sleep(0.5)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
        else:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        print(f"Bot stopped (PID {pid}).")
    except ProcessLookupError:
        print("Bot was not running (stale PID file).")

    PID_FILE.unlink(missing_ok=True)


def _cmd_status() -> None:
    if PID_FILE.exists():
        pid = int(PID_FILE.read_text().strip())
        try:
            os.kill(pid, 0)
            print(f"Bot is running (PID {pid})")
            return
        except ProcessLookupError:
            print("Bot is not running (stale PID file)")
            PID_FILE.unlink()
            sys.exit(1)
    print("Bot is not running.")
    sys.exit(1)


def cli_main(args: list[str]) -> None:
    """CLI entry point matching telegram.sh interface: start|stop|status|run"""
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Determine script_dir (parent of telegram/ package)
    script_dir = str(Path(__file__).resolve().parent.parent)

    if not args:
        print("Usage: python -m telegram bot start|stop|status|run", file=sys.stderr)
        sys.exit(1)

    cmd = args[0]

    if cmd == "start":
        _cmd_start(script_dir)
    elif cmd == "stop":
        _cmd_stop()
    elif cmd == "status":
        _cmd_status()
    elif cmd == "run":
        config = state.load_config()
        if not config:
            print(f"Error: Telegram not configured. Run: {script_dir}/telegram-setup.sh")
            sys.exit(1)
        asyncio.run(run_bot(config, script_dir))
    else:
        print(f"Usage: python -m telegram bot start|stop|status|run", file=sys.stderr)
        sys.exit(1)
