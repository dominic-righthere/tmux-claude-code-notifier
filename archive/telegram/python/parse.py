"""Terminal output parsing — ports lib.sh text processing to Python."""

from __future__ import annotations

import re
import textwrap

from telegram.models import ModeInfo


def strip_ghost_text(text: str) -> str:
    """Strip dim/grey ghost text spans (autocomplete suggestions).

    Must be called BEFORE strip_ansi(). Removes spans using:
    - SGR 2 (dim) — but NOT 38;2;... or 48;2;... (24-bit color)
    - SGR 90 (bright-black)
    - 256-color grey (38;5;240-249)

    Uses two passes: one for grey/bright-black, one for dim.
    Dim matching uses a callback to verify SGR 2 is actually dim,
    not part of a 24-bit color sequence (38;2;... or 48;2;...).
    """
    _GREY_OPEN = r"\x1b\[(?:[0-9;]*;)?(?:90|38;5;24[0-9])(?:;[0-9;]*)?m"
    _RESET = r"\x1b\[(?:0?m|22m|39m)"
    _SPAN = r"[^\x1b]*"
    text = re.sub(_GREY_OPEN + _SPAN + _RESET, "", text)

    # Dim: match any SGR containing param 2, then verify it's not 24-bit color
    _DIM_SEQ = re.compile(r"\x1b\[([0-9;]*)m([^\x1b]*)" + _RESET)

    def _strip_dim(m: re.Match) -> str:  # type: ignore[type-arg]
        params = m.group(1).split(";")
        # Check if 2 is a standalone SGR param (dim), not part of 38;2 or 48;2
        for i, p in enumerate(params):
            if p == "2" and (i == 0 or params[i - 1] not in ("38", "48")):
                return ""
        return m.group(0)  # not dim, keep it

    text = _DIM_SEQ.sub(_strip_dim, text)
    return text


def strip_ansi(text: str) -> str:
    """Strip ANSI escape codes."""
    return re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)


def trim_blank_lines(text: str) -> str:
    """Strip leading and trailing blank lines."""
    lines = text.splitlines()
    # Strip leading
    while lines and not lines[0].strip():
        lines.pop(0)
    # Strip trailing
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines)


def strip_terminal_chrome(text: str) -> str:
    """Remove tmux/terminal UI noise from captured pane output."""
    lines = text.splitlines()
    filtered = []
    for line in lines:
        stripped = line.strip()
        # Skip separator-only lines (───, ═══, ╌╌╌, etc.)
        if re.match(r'^[─═╌━┄┈—\-]{3,}$', stripped):
            continue
        # Skip status bar: -- INSERT --, -- NORMAL --, etc.
        if re.match(r'^--\s+(INSERT|NORMAL|VISUAL)', stripped):
            continue
        # Skip context percentage line
        if re.search(r'Context left until auto-compact:\s*\d+%', stripped):
            continue
        # Skip status lines: "✳ Beaming…", "✻ Working…", "· Germinating…", "✢ Enchanting…", etc.
        # Symbol may be stripped by ghost text, so make it optional
        if re.match(r'^[✳✻·✢✦✧⟡◇◆]?\s*\w+…', stripped):
            continue
        # Skip bare prompt lines (just ❯ with nothing after)
        if re.match(r'^❯\s*$', stripped):
            continue
        # Skip mode indicator lines (⏵⏵ at start)
        if re.match(r'^⏵⏵', stripped):
            continue
        # Skip mode indicator remnants — ghost text can strip ⏵⏵/-- INSERT --,
        # leaving fragments like "on  cycle)", "accept edits on", "to cycle)"
        if re.search(r'shift[\+\-]tab|cycle\)', stripped):
            continue
        # Skip ctrl+key / ctrl-key hint lines (e.g. "ctrl+b ctrl+b", "ctrl-g")
        if re.match(r'^ctrl[\+\-]\w', stripped):
            continue
        # Skip "+N more tool uses" / "ctrl+o to expand" combined lines
        if re.match(r'^\+\d+ more tool uses', stripped):
            continue
        # Skip "Running…" status lines
        if re.match(r'^Running…', stripped):
            continue
        # Skip hint lines: "Esc to cancel", "Tab to amend"
        if re.match(r'^(Esc|Tab) to \w', stripped):
            continue
        # Skip "Enter to select" navigation hints
        if re.match(r'^Enter to \w', stripped):
            continue
        # Skip "↑/↓ to navigate" hints
        if re.match(r'^[↑↓]', stripped):
            continue
        # Skip plan file paths: ~/.claude/...
        if re.match(r'^~/\.claude/', stripped):
            continue
        # Skip satisfaction survey: "● How is Claude doing" (● prefix from UI)
        if re.search(r'How is Claude doing', stripped):
            continue
        # Skip survey scale: "1: Bad  2: Fine  3: Good  Dismiss"
        if re.match(r'^\d+:\s*(Bad|Fine|Good|Dismiss)', stripped):
            continue
        filtered.append(line)
    return '\n'.join(filtered)


def detect_mode(context: str) -> ModeInfo:
    """Detect Claude Code mode from pane content.

    Must match telegram-send.sh detect_mode exactly:
    - ⏵⏵ signals auto-accept — extract the actual label
    - 'plan mode' → ⏸ plan mode
    """
    if not context:
        return ModeInfo()

    # Scope to last 15 lines — mode indicators are near pane bottom
    tail = "\n".join(context.splitlines()[-15:])

    # ⏵⏵ signals auto-accept
    matches = re.findall(r"⏵⏵[^(]*", tail)
    if matches:
        label = matches[-1].rstrip()
        return ModeInfo(label=label, auto=True)

    # Plan mode
    if re.search(r"plan mode", tail, re.IGNORECASE):
        return ModeInfo(label="⏸ plan mode", auto=False)

    return ModeInfo()


def _is_structural(line: str) -> bool:
    """Check if a line is structural (should not be reflowed)."""
    if re.match(r"^\s*[⏺⎿❯✻]", line):
        return True
    if "…" in line:
        return True
    if re.match(r"^\s+\d+\s+[-+|]", line):
        return True
    if re.match(r"^\s+[-*] ", line):
        return True
    if re.match(r"^\s+\d+\. ", line):
        return True
    if re.match(r"^\s*[$>] ", line):
        return True
    if re.match(r"^(===|---)", line):
        return True
    return False


def reflow_for_telegram(text: str, pane_width: int = 120) -> str:
    """Rejoin hard-wrapped prose while preserving structural lines.

    Must match lib.sh reflow_for_telegram.
    """
    threshold = pane_width - 5
    lines = text.splitlines()
    result: list[str] = []
    buf = ""
    prev_len = 0

    for line in lines:
        rlen = len(line)
        if not line.strip():
            # Blank line: flush buffer, emit blank
            if buf:
                result.append(buf)
                buf = ""
            result.append("")
            prev_len = 0
        elif _is_structural(line):
            if buf:
                result.append(buf)
            buf = line
            prev_len = rlen
        elif prev_len >= threshold and buf:
            # Continuation of wrapped line
            buf = buf + " " + line.lstrip()
            prev_len = rlen
        else:
            if buf:
                result.append(buf)
            buf = line
            prev_len = rlen

    if buf:
        result.append(buf)

    return "\n".join(result)


def extract_activity_log(text: str, max_items: int = 20) -> str:
    """Extract ⎿ marker lines from the current work block.

    Must match lib.sh extract_activity_log.
    """
    # Get current work block: everything after the last ❯ line
    lines = text.splitlines()
    work_block_lines: list[str] = []
    buf: list[str] = []
    for line in lines:
        if "❯ " in line:
            buf = []
        buf.append(line)
    work_block_lines = buf if buf else lines

    # Extract ⎿ lines, deduplicate
    seen: set[str] = set()
    items: list[str] = []
    for line in work_block_lines:
        stripped = line.lstrip()
        if stripped.startswith("⎿"):
            content = re.sub(r"^⎿\s*", "", stripped).strip()
            if content and content not in seen:
                seen.add(content)
                items.append(f"• {content}")
                if len(items) >= max_items:
                    break

    return "\n".join(items)


def extract_prompt_text(text: str, max_chars: int = 1500) -> str:
    """Extract Claude's speech from the last ⏺ block.

    Filters out tool outputs (⎿ blocks) and keeps only the assistant's
    direct speech/questions.
    """
    lines = text.splitlines()

    # Find last ⏺ block
    buf: list[str] = []
    capturing = False
    in_tool_output = False

    for line in lines:
        if "⏺" in line:
            buf = []
            capturing = True
            in_tool_output = False
            # Capture text after ⏺ on the same line (skip tool calls like "Bash(...)")
            after = line.split("⏺", 1)[1].strip()
            if after and not re.match(r"^\w+\(", after):
                buf.append(after)
            continue
        if capturing and re.match(r"^\s*(❯|[0-9]+\.)", line):
            capturing = False
            continue
        if capturing:
            stripped = line.lstrip()
            # ⎿ marks tool output — skip it and subsequent indented lines
            if stripped.startswith("⎿"):
                in_tool_output = True
                continue
            # If we were in a tool output block, blank line exits it
            if in_tool_output:
                if not stripped:
                    in_tool_output = False
                continue
            buf.append(line)

    # Clean up: remove blank lines, strip leading whitespace
    extracted = "\n".join(
        line.lstrip() for line in buf if line.strip()
    )

    if len(extracted) > max_chars:
        extracted = extracted[:max_chars]
        # Find last newline for clean boundary
        last_nl = extracted.rfind("\n")
        if last_nl > 0:
            extracted = extracted[:last_nl]
        extracted += "..."

    return extracted


def extract_command_block(text: str, max_chars: int = 500) -> str:
    """Extract the command/action block from a permission request pane.

    Finds the last heavy separator (───), takes lines between it and the
    first ❯ or "Do you want to proceed?" line. This captures the actual
    command text shown in the permission prompt.
    """
    lines = text.splitlines()

    # Find last heavy separator
    last_sep = -1
    for i, line in enumerate(lines):
        if re.search(r"[─╌]{5}", line.strip()):
            last_sep = i

    if last_sep < 0:
        return ""

    # Take lines after separator until ❯ or "Do you want to proceed?"
    block: list[str] = []
    for line in lines[last_sep + 1:]:
        stripped = line.strip()
        if stripped.startswith("❯") or "Do you want to proceed?" in stripped:
            break
        if stripped:
            block.append(stripped)

    result = "\n".join(block)
    if len(result) > max_chars:
        result = result[:max_chars]
        last_nl = result.rfind("\n")
        if last_nl > 0:
            result = result[:last_nl]
        result += "..."

    return result


def convert_tables_to_bullets(text: str) -> str:
    """Convert markdown pipe-delimited tables to bullet format.

    Must match lib.sh convert_tables_to_bullets.
    """
    lines = text.splitlines()
    result: list[str] = []
    headers: list[str] = []

    for line in lines:
        # Skip separator rows
        if re.match(r"^\|[-:\s]+\|", line):
            continue

        # Table rows
        if re.match(r"^\|.*\|$", line):
            # Strip outer pipes and split
            inner = line.strip("|").strip()
            cols = [c.strip() for c in inner.split("|")]

            if not headers:
                headers = cols
            else:
                parts = []
                for i, col in enumerate(cols):
                    if i < len(headers) and headers[i]:
                        parts.append(f"{headers[i]}: {col}")
                    else:
                        parts.append(col)
                result.append("- " + ", ".join(parts))
            continue

        # Non-table line: reset headers
        headers = []
        result.append(line)

    return "\n".join(result)


def wrap_long_lines(text: str, width: int = 50) -> str:
    """Wrap long lines for mobile display. Matches lib.sh wrap_long_lines (fold -s)."""
    lines = text.splitlines()
    result: list[str] = []
    for line in lines:
        if len(line) <= width:
            result.append(line)
        else:
            wrapped = textwrap.fill(line, width=width, break_long_words=True, break_on_hyphens=False)
            result.append(wrapped)
    return "\n".join(result)


def html_escape(text: str) -> str:
    """Escape &<> for Telegram HTML. Must match lib.sh html_escape."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def extract_preview(text: str, count: int = 3) -> str:
    """Extract last N non-blank lines. Must match lib.sh extract_preview."""
    non_blank = [line for line in text.splitlines() if line.strip()]
    return "\n".join(non_blank[-count:])
