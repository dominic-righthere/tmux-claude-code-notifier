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
            cmd_block = extract_command_block(ctx.raw_pre_chrome or reflowed)
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
            # Input needed: show Claude's speech/question in expandable blockquote
            header_len = len(header)
            prompt_budget = 4096 - header_len - 600
            prompt_budget = max(200, min(3000, prompt_budget))

            prompt_text = extract_prompt_text(reflowed, prompt_budget)
            if prompt_text:
                prompt_text = wrap_long_lines(prompt_text, 50)
                body = f"\n\n<blockquote expandable>{html_escape(prompt_text)}</blockquote>"

    # FINISHED: show Claude's final speech in expandable blockquote
    if ctx.event_type == EventType.FINISHED:
        header_len = len(header)
        speech_budget = 4096 - header_len - 200
        speech_budget = max(200, min(1500, speech_budget))

        speech = extract_prompt_text(reflowed, speech_budget)
        if speech:
            speech = wrap_long_lines(speech, 50)
            escaped_speech = html_escape(speech)
            body += f"\n\n<blockquote expandable>{escaped_speech}</blockquote>"

        activity = extract_activity_log(reflowed, 15)
        if activity:
            activity_escaped = html_escape(activity)
            cur_len = len(header) + len(body)
            max_activity = 4096 - cur_len - 200
            if max_activity > 100 and len(activity_escaped) <= max_activity:
                body += f"\n\n<blockquote expandable>Activity:\n{activity_escaped}</blockquote>"

    return body


# Hint/chrome lines stripped from bottom of option blocks
_HINT_RE = re.compile(
    r'^\s*$|^(Esc|Tab|Enter) to \w|^ctrl[\+\-]|^~/\.claude/|^↑|^How is Claude doing|^\d+:\s*(Bad|Fine|Good|Dismiss)',
)

# Numbered option: "  1. Option text" or "❯ 1. Option text"
_OPTION_RE = re.compile(r"^(?:\s+(?:❯\s+)?|❯\s*)(\d)\.\s+(.+)$")


def _scan_options_crossing_sep(buf: list[str]) -> list[tuple[str, str]]:
    """Reverse-scan for numbered options, crossing separator lines.

    Used when options below a separator don't start from "1" — they're
    continuation meta-options (e.g. AskUserQuestion's "5. Chat about this").
    This scans the full buffer to find options 1-N above the separator.
    """
    # Strip hint/chrome from bottom
    tail = list(buf)
    while tail and _HINT_RE.match(tail[-1].strip()):
        tail.pop()

    options: list[tuple[str, str]] = []
    for line in reversed(tail):
        m = _OPTION_RE.match(line)
        if m:
            options.append((m.group(1), m.group(2).rstrip()))
        elif options:
            # Allow description lines, blank lines, AND separator lines
            if line.startswith("     ") or not line.strip() or re.search(r'[─╌]{5}', line):
                continue
            break
    options.reverse()
    return options


def _extract_options(raw_context: str, raw_pre_chrome: str = "") -> list[tuple[str, str]]:
    """Extract options from the prompt block in raw terminal output.

    Handles two formats:
    1. Numbered options (AskUserQuestion): "  1. Option text"
    2. Permission choices: indented lines after "Do you want to...?"

    Uses raw_pre_chrome (before chrome/ghost stripping) when available so
    dim options (unselected permission choices) are still present.
    Falls back to raw_context if pre-chrome text isn't provided.

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
    full_buf = list(buf)
    last_sep = -1
    for i, line in enumerate(buf):
        if re.search(r'[─╌]{5}', line):
            last_sep = i
    if last_sep >= 0:
        buf = buf[last_sep + 1:]

    # Take last 15 lines
    tail = buf[-15:] if len(buf) > 15 else buf

    # Strip hint/chrome lines from bottom
    while tail and _HINT_RE.match(tail[-1].strip()):
        tail.pop()

    # Try numbered options first (AskUserQuestion format: "  1. Option")
    # Match options 1-9; ❯ marks the currently-selected option and may appear
    # at the start of the line (no leading whitespace) or indented.
    # Require either leading whitespace or ❯ — bare "1. text" at column 0
    # is Claude's prose, not an option.
    options: list[tuple[str, str]] = []
    for line in reversed(tail):
        m = _OPTION_RE.match(line)
        if m:
            options.append((m.group(1), m.group(2).rstrip()))
        elif options:
            # Allow description lines (more indented) between options
            if line.startswith("     ") or not line.strip():
                continue
            break  # non-description, non-blank = end of options block

    options.reverse()

    # Options below separator don't start from "1" — they're continuation
    # of a group above (e.g. AskUserQuestion meta-options 5,6).
    # Re-extract from full buffer, crossing the separator.
    if len(options) >= 1 and options[0][0] != "1" and last_sep >= 0:
        cross_options = _scan_options_crossing_sep(full_buf)
        if len(cross_options) >= 2:
            return cross_options[:4]

    # Require at least 2 options — a single match is almost always a false
    # positive (e.g. numbered list item in Claude's output text)
    if len(options) >= 2:
        return options[:4]

    # Try permission prompt choices (unnumbered indented lines after question)
    return _extract_permission_choices(tail)


# Permission choices: known labels Claude Code uses for Yes/No prompts
_PERM_LABELS = re.compile(
    r"^\s{2,}(?:❯\s+)?"
    r"(Yes(?:\s*\(Recommended\))?|Yes,\s+.+|No|Always allow|Allow once)\s*$",
    re.IGNORECASE,
)
# Lines to skip between permission choices (hints, blanks)
_PERM_SKIP = re.compile(
    r"^\s*$|^\s*\(shift\+tab|^\s*\(tab\b",
    re.IGNORECASE,
)


def _extract_permission_choices(tail: list[str]) -> list[tuple[str, str]]:
    """Extract unnumbered permission choices from tail lines.

    Claude Code permission prompts show indented choices like:
        Do you want to run this command?
            Yes (Recommended)
            Yes, and don't ask again for this session
            No

    Returns list of (number, label) tuples with synthetic numbering.
    """
    choices: list[str] = []
    for line in tail:
        if _PERM_LABELS.match(line):
            choices.append(line.strip().removeprefix("❯").strip())
        elif _PERM_SKIP.match(line):
            continue  # skip blanks and hint lines between choices
        elif choices:
            break  # non-choice, non-skip line after finding choices = done

    if len(choices) < 2:
        return []

    return [(str(i + 1), label) for i, label in enumerate(choices[:4])]


def build_keyboard(ctx: SendContext) -> tuple[InlineKeyboard, KeyboardStyle]:
    """Build inline keyboard JSON."""
    s, w = ctx.session, ctx.window

    if ctx.event_type == EventType.WAITING:
        # Auto-accept mode: skip permission buttons but still show input buttons
        if ctx.mode.auto and ctx.tool_name:
            return InlineKeyboard(inline_keyboard=[
                [
                    InlineButton(text="📋 View Output", callback_data=f"view:{s}:{w}"),
                    InlineButton(text="🔄", callback_data=f"refresh:{s}:{w}"),
                ],
            ]), KeyboardStyle.VIEW_ONLY

        # Try to detect numbered options
        options = _extract_options(ctx.raw_context, ctx.raw_pre_chrome) if (ctx.raw_context or ctx.raw_pre_chrome) else []

        if options:
            rows: list[list[InlineButton]] = []
            for num, label in options:
                btn_label = f"{num}. {label}"
                if len(btn_label) > 30:
                    btn_label = btn_label[:29] + "…"
                rows.append([InlineButton(
                    text=btn_label,
                    callback_data=f"opt:{s}:{w}:{num}",
                )])
            rows.append([
                InlineButton(text="📋 View", callback_data=f"view:{s}:{w}"),
                InlineButton(text="🔄", callback_data=f"refresh:{s}:{w}"),
            ])
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
                    InlineButton(text="🔄", callback_data=f"refresh:{s}:{w}"),
                    InlineButton(text="⏹ Cancel", callback_data=f"mode:{s}:{w}:esc"),
                ],
            ]), KeyboardStyle.APPROVE_DENY

        # Waiting for input (no tool): view + reply
        return InlineKeyboard(inline_keyboard=[
            [
                InlineButton(text="📋 View", callback_data=f"view:{s}:{w}"),
                InlineButton(text="🔄", callback_data=f"refresh:{s}:{w}"),
                InlineButton(text="💬 Reply", callback_data=f"prompt:{s}:{w}"),
            ],
        ]), KeyboardStyle.VIEW_REPLY

    # Finished: view + send
    if ctx.event_type == EventType.FINISHED:
        return InlineKeyboard(inline_keyboard=[
            [
                InlineButton(text="📋 View", callback_data=f"view:{s}:{w}"),
                InlineButton(text="🔄", callback_data=f"refresh:{s}:{w}"),
                InlineButton(text="💬 Send", callback_data=f"prompt:{s}:{w}"),
            ],
        ]), KeyboardStyle.VIEW_REPLY

    # Default: view only (prompt/working)
    return InlineKeyboard(inline_keyboard=[
        [
            InlineButton(text="📋 View Output", callback_data=f"view:{s}:{w}"),
            InlineButton(text="🔄", callback_data=f"refresh:{s}:{w}"),
        ],
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
