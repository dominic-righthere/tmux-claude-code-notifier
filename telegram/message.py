"""Message pipeline — build header, body, and keyboard for Telegram messages."""

from __future__ import annotations

import re

from telegram.models import (
    EventType,
    InlineButton,
    InlineKeyboard,
    KeyboardStyle,
    MessagePayload,
    SendContext,
)
from telegram.parse import (
    convert_tables_to_bullets,
    extract_activity_log,
    extract_command_block,
    extract_prompt_text,
    html_escape,
    reflow_for_telegram,
    wrap_long_lines,
)


def build_header(ctx: SendContext) -> str:
    """Build message header: type badge, session, project, tool, mode."""
    if ctx.event_type == EventType.PROMPT:
        header = "▶ <b>Working</b>"
    elif ctx.event_type == EventType.WAITING:
        if ctx.tool_name:
            header = "⏳ <b>Permission Request</b>"
        else:
            header = "⏳ <b>Waiting for Input</b>"
    else:
        header = "● <b>Task Finished</b>"

    # Compact session line
    session_line = f"\n{ctx.session}:{ctx.window}"
    if ctx.project_name:
        session_line += f" · {ctx.project_name}"
    header += session_line

    # Tool on its own line (in code tags)
    if ctx.event_type == EventType.WAITING and ctx.tool_name:
        header += f"\n<b>Tool:</b> <code>{html_escape(ctx.tool_name)}</code>"

    # Mode (skip for finished — not actionable)
    if ctx.mode.label and ctx.event_type != EventType.FINISHED:
        header += f"\n{ctx.mode.label}"

    return header


def build_body(ctx: SendContext, header: str) -> str:
    """Build message body — clean, minimal, no raw pane dumps."""
    if ctx.event_type == EventType.PROMPT:
        if ctx.message:
            wrapped = wrap_long_lines(ctx.message, 50)
            escaped = html_escape(wrapped)
            # Long prompts go in expandable blockquote
            if len(ctx.message) > 100 or ctx.message.count("\n") > 2:
                return f"\n\n<blockquote expandable>{escaped}</blockquote>"
            return f"\n\n{escaped}"
        return ""

    if not ctx.raw_context:
        return ""

    # Reflow and convert tables
    reflowed = convert_tables_to_bullets(reflow_for_telegram(ctx.raw_context, ctx.pane_width))

    body = ""

    # WAITING: show command block for permission requests, speech for input requests
    if ctx.event_type == EventType.WAITING:
        if ctx.tool_name:
            # Permission request: show the command/action block in <code>
            cmd_block = extract_command_block(reflowed)
            if cmd_block:
                cmd_block = wrap_long_lines(cmd_block, 50)
                body = f"\n\n<code>{html_escape(cmd_block)}</code>"
            else:
                # No separator (e.g. ExitPlanMode) — show Claude's speech
                fallback_budget = max(200, min(1500, 4096 - len(header) - 600))
                fallback = extract_prompt_text(reflowed, fallback_budget)
                if fallback:
                    fallback = wrap_long_lines(fallback, 50)
                    body = f"\n\n<blockquote expandable>{html_escape(fallback)}</blockquote>"
        else:
            # Input needed: show Claude's speech/question
            header_len = len(header)
            prompt_budget = 4096 - header_len - 600
            prompt_budget = max(200, min(3000, prompt_budget))

            prompt_text = extract_prompt_text(reflowed, prompt_budget)
            if prompt_text:
                prompt_text = wrap_long_lines(prompt_text, 50)
                body = f"\n\n{html_escape(prompt_text)}"

    # FINISHED: show Claude's final speech
    if ctx.event_type == EventType.FINISHED:
        header_len = len(header)
        speech_budget = 4096 - header_len - 200
        speech_budget = max(200, min(1500, speech_budget))

        speech = extract_prompt_text(reflowed, speech_budget)
        if speech:
            speech = wrap_long_lines(speech, 50)
            escaped_speech = html_escape(speech)
            if len(speech) > 100 or speech.count("\n") > 2:
                body += f"\n\n<blockquote expandable>{escaped_speech}</blockquote>"
            else:
                body += f"\n\n{escaped_speech}"

        activity = extract_activity_log(reflowed, 15)
        if activity:
            activity_escaped = html_escape(activity)
            cur_len = len(header) + len(body)
            max_activity = 4096 - cur_len - 200
            if max_activity > 100 and len(activity_escaped) <= max_activity:
                body += f"\n\n<blockquote expandable>Activity:\n{activity_escaped}</blockquote>"

    return body


def _extract_options(raw_context: str, raw_pre_chrome: str = "") -> list[tuple[str, str]]:
    """Extract numbered options from the prompt block in raw terminal output.

    Uses raw_pre_chrome (before chrome stripping) when available so separators
    (───/╌╌╌) are still present for scoping — options are always below the last
    separator. Falls back to raw_context if pre-chrome text isn't provided.

    Returns list of (number, label) tuples, max 4.
    """
    source = raw_pre_chrome or raw_context

    # Extract prompt block: lines after last ⏺ marker
    lines = source.splitlines()
    buf: list[str] = []
    for line in lines:
        if "⏺" in line:
            buf = []
        else:
            buf.append(line)

    # Scope to after last separator (───/╌╌╌) — options are always below it
    last_sep = -1
    for i, line in enumerate(buf):
        if re.search(r'[─╌]{5}', line):
            last_sep = i
    if last_sep >= 0:
        buf = buf[last_sep + 1:]

    # Take last 15 lines
    tail = buf[-15:] if len(buf) > 15 else buf

    # Strip hint/chrome lines from bottom
    while tail and re.match(
        r'^\s*$|^(Esc|Tab|Enter) to \w|^ctrl[\+\-]|^~/\.claude/|^↑|^How is Claude doing|^\d+:\s*(Bad|Fine|Good|Dismiss)',
        tail[-1].strip(),
    ):
        tail.pop()

    # Scan upward collecting contiguous numbered option lines
    option_re = re.compile(r"^\s+(?:❯\s+)?([1-4])\.\s+(.+)$")
    options: list[tuple[str, str]] = []
    for line in reversed(tail):
        m = option_re.match(line)
        if m:
            options.append((m.group(1), m.group(2).rstrip()))
        else:
            if options:
                break  # non-match after finding options = end of contiguous block

    options.reverse()
    return options[:4]


def build_keyboard(ctx: SendContext) -> tuple[InlineKeyboard, KeyboardStyle]:
    """Build inline keyboard JSON."""
    s, w = ctx.session, ctx.window

    if ctx.event_type == EventType.WAITING and not ctx.mode.auto:
        # Try to detect numbered options
        options = _extract_options(ctx.raw_context, ctx.raw_pre_chrome) if ctx.raw_context else []

        if options:
            rows: list[list[InlineButton]] = []
            for num, label in options:
                rows.append([InlineButton(
                    text=f"{num}. {label}",
                    callback_data=f"opt:{s}:{w}:{num}",
                )])
            rows.append([InlineButton(
                text="📋 View",
                callback_data=f"view:{s}:{w}",
            )])
            return InlineKeyboard(inline_keyboard=rows), KeyboardStyle.OPTIONS

        if ctx.tool_name:
            # Permission request: approve/deny + view + cancel
            return InlineKeyboard(inline_keyboard=[
                [
                    InlineButton(text="✅ Approve", callback_data=f"approve:{s}:{w}"),
                    InlineButton(text="❌ Deny", callback_data=f"deny:{s}:{w}"),
                ],
                [
                    InlineButton(text="📋 View", callback_data=f"view:{s}:{w}"),
                    InlineButton(text="⏹ Cancel", callback_data=f"mode:{s}:{w}:esc"),
                ],
            ]), KeyboardStyle.APPROVE_DENY

        # Waiting for input (no tool): view + reply
        return InlineKeyboard(inline_keyboard=[
            [
                InlineButton(text="📋 View", callback_data=f"view:{s}:{w}"),
                InlineButton(text="💬 Reply", callback_data=f"prompt:{s}:{w}"),
            ],
        ]), KeyboardStyle.VIEW_REPLY

    # Finished: view + send
    if ctx.event_type == EventType.FINISHED:
        return InlineKeyboard(inline_keyboard=[
            [
                InlineButton(text="📋 View", callback_data=f"view:{s}:{w}"),
                InlineButton(text="💬 Send", callback_data=f"prompt:{s}:{w}"),
            ],
        ]), KeyboardStyle.VIEW_REPLY

    # Default: view only (prompt/working)
    return InlineKeyboard(inline_keyboard=[
        [InlineButton(text="📋 View Output", callback_data=f"view:{s}:{w}")],
    ]), KeyboardStyle.VIEW_ONLY


def build_message(ctx: SendContext) -> MessagePayload:
    """Full message pipeline: header + body + keyboard."""
    header = build_header(ctx)
    body = build_body(ctx, header)

    text = header + body
    # Enforce Telegram 4096 char limit
    if len(text) > 4096:
        text = text[:4093] + "..."

    keyboard, kb_style = build_keyboard(ctx)

    return MessagePayload(text=text, keyboard=keyboard, kb_style=kb_style)
