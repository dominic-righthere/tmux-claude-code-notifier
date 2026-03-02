"""Tmux subprocess wrapper — capture-pane, send-keys, display-message."""

from __future__ import annotations

import re
import subprocess
import time

# Tmux target validation patterns
_SESSION_RE = re.compile(r"^[a-zA-Z0-9_.-]{1,50}$")
_WINDOW_RE = re.compile(r"^[0-9]{1,3}$")


def validate_target(session: str, window: str) -> str | None:
    """Validate tmux session and window names.

    Returns an error string if invalid, None if valid.
    Prevents shell injection via crafted callback data.
    """
    if not _SESSION_RE.match(session):
        return f"Invalid session name: {session!r}"
    if not _WINDOW_RE.match(window):
        return f"Invalid window index: {window!r}"
    return None


_PASTE_BUFFER_NAME = "_notifier"


def run_tmux(*args: str, timeout: float = 5.0) -> str | None:
    """Run a tmux command, return stdout or None on failure."""
    try:
        result = subprocess.run(
            ["tmux", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode == 0:
            return result.stdout
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def _run_tmux_stdin(data: str, *args: str, timeout: float = 5.0) -> bool:
    """Run a tmux command with stdin data. Returns True on success."""
    try:
        result = subprocess.run(
            ["tmux", *args],
            input=data,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def capture_pane(session: str, window: str, lines: int = 200) -> str | None:
    """Capture pane content, returns raw text or None."""
    return run_tmux("capture-pane", "-t", f"{session}:{window}", "-J", "-p", "-S", f"-{lines}")


def capture_pane_escaped(session: str, window: str, lines: int = 200) -> str | None:
    """Capture pane with ANSI codes preserved (for ghost text detection)."""
    return run_tmux("capture-pane", "-e", "-t", f"{session}:{window}", "-J", "-p", "-S", f"-{lines}")


def capture_wide(session: str, window: str, lines: int = 200, width: int = 250) -> tuple[str | None, int]:
    """Resize pane wide, capture with ANSI, restore. Returns (text, capture_width)."""
    target = f"{session}:{window}"
    orig = pane_width(session, window)
    resized = run_tmux("resize-pane", "-t", target, "-x", str(width)) is not None
    if resized:
        time.sleep(0.15)
    captured = capture_pane_escaped(session, window, lines)
    if resized:
        run_tmux("resize-pane", "-t", target, "-x", str(orig))
    return captured, width if resized else orig


def pane_width(session: str, window: str) -> int:
    """Get pane width, defaults to 120."""
    result = run_tmux("display-message", "-t", f"{session}:{window}", "-p", "#{pane_width}")
    if result:
        try:
            return int(result.strip())
        except ValueError:
            pass
    return 120


def pane_current_path(session: str, window: str) -> str | None:
    """Get the current working directory of the pane."""
    result = run_tmux("display-message", "-t", f"{session}:{window}", "-p", "#{pane_current_path}")
    return result.strip() if result else None


def send_keys(session: str, window: str, *keys: str) -> bool:
    """Send keys to a pane. Returns True on success."""
    result = run_tmux("send-keys", "-t", f"{session}:{window}", *keys)
    return result is not None


def send_text(session: str, window: str, text: str) -> bool:
    """Send literal text followed by Enter. Use for user-typed input."""
    target = f"{session}:{window}"
    clean = text.strip()

    if len(clean) > 500 or "\n" in clean:
        # Paste buffer approach — reliable for bulk text
        if not _run_tmux_stdin(clean, "load-buffer", "-b", _PASTE_BUFFER_NAME, "-"):
            return False
        if run_tmux("paste-buffer", "-b", _PASTE_BUFFER_NAME, "-t", target, "-d", "-p") is None:
            return False
        time.sleep(0.1)  # let paste settle
    else:
        # Short single-line: send-keys -l (fast)
        if run_tmux("send-keys", "-t", target, "-l", clean) is None:
            return False

    return run_tmux("send-keys", "-t", target, "Enter") is not None


def has_session(session: str) -> bool:
    """Check if a tmux session exists."""
    return run_tmux("has-session", "-t", session) is not None


def has_window(session: str, window: str) -> bool:
    """Check if a tmux window exists."""
    return run_tmux("display-message", "-t", f"{session}:{window}", "-p", "") is not None


def new_window(session: str) -> str | None:
    """Create a new window adjacent to current, return window index."""
    result = run_tmux("new-window", "-t", session, "-a", "-P", "-F", "#{window_index}")
    return result.strip() if result else None
