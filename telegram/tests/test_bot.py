"""Bot command and callback tests."""

import pytest

from telegram.bot import (
    MAX_SEND_TEXT_LEN,
    _clean_pane_for_view,
    _resolve_target,
    parse_command,
    dispatch_callback_data,
)
from telegram.tmux import capture_wide, send_text


class TestParseCommand:
    def test_simple_command(self):
        cmd, args = parse_command("/help")
        assert cmd == "/help"
        assert args == ""

    def test_command_with_args(self):
        cmd, args = parse_command("/v 3")
        assert cmd == "/v"
        assert args == "3"

    def test_command_with_bot_suffix(self):
        cmd, args = parse_command("/help@mybot")
        assert cmd == "/help"
        assert args == ""

    def test_command_with_multiple_args(self):
        cmd, args = parse_command("/send 1 hello world")
        assert cmd == "/send"
        assert args == "1 hello world"


class TestDispatchCallbackData:
    def test_approve(self):
        action, session, window, extra = dispatch_callback_data("approve:main:1")
        assert action == "approve"
        assert session == "main"
        assert window == "1"
        assert extra == ""

    def test_option(self):
        action, session, window, extra = dispatch_callback_data("opt:dev:2:3")
        assert action == "opt"
        assert session == "dev"
        assert window == "2"
        assert extra == "3"

    def test_view(self):
        action, session, window, extra = dispatch_callback_data("view:main:0")
        assert action == "view"
        assert session == "main"
        assert window == "0"

    def test_sessions_refresh(self):
        action, session, window, extra = dispatch_callback_data("sessions:refresh")
        assert action == "sessions"
        assert session == "refresh"

    def test_mode_callback(self):
        action, session, window, extra = dispatch_callback_data("mode:dev:1:esc")
        assert action == "mode"
        assert session == "dev"
        assert window == "1"
        assert extra == "esc"

    def test_prompt_callback(self):
        action, session, window, extra = dispatch_callback_data("prompt:main:0")
        assert action == "prompt"
        assert session == "main"
        assert window == "0"


class TestResolveTarget:
    """Test _resolve_target with various identifier types."""

    SESSIONS = [
        {"idx": 1, "session": "tmux-cc", "window": "1", "category": "working", "message": "Working..."},
        {"idx": 2, "session": "sf-dev", "window": "0", "category": "waiting", "message": "Bash: ls"},
        {"idx": 3, "session": "baby-app", "window": "2", "category": "finished", "message": "Done"},
    ]

    def test_resolve_by_number(self):
        entry = _resolve_target("1", self.SESSIONS)
        assert entry is not None
        assert entry["session"] == "tmux-cc"

    def test_resolve_by_number_not_found(self):
        assert _resolve_target("99", self.SESSIONS) is None

    def test_resolve_by_session_window(self):
        entry = _resolve_target("sf-dev:0", self.SESSIONS)
        assert entry is not None
        assert entry["session"] == "sf-dev"
        assert entry["window"] == "0"

    def test_resolve_by_session_name(self):
        entry = _resolve_target("baby-app", self.SESSIONS)
        assert entry is not None
        assert entry["session"] == "baby-app"

    def test_resolve_by_project_name(self, monkeypatch):
        """Project name lookup uses _get_session_info which calls tmux."""
        monkeypatch.setattr(
            "telegram.bot._get_session_info",
            lambda s, w: {"project": "notifier" if s == "tmux-cc" else "", "mode": "", "mode_icon": "", "task": ""},
        )
        entry = _resolve_target("notifier", self.SESSIONS)
        assert entry is not None
        assert entry["session"] == "tmux-cc"

    def test_resolve_by_project_case_insensitive(self, monkeypatch):
        monkeypatch.setattr(
            "telegram.bot._get_session_info",
            lambda s, w: {"project": "MyProject" if s == "sf-dev" else "", "mode": "", "mode_icon": "", "task": ""},
        )
        entry = _resolve_target("myproject", self.SESSIONS)
        assert entry is not None
        assert entry["session"] == "sf-dev"

    def test_resolve_empty_list(self):
        assert _resolve_target("1", []) is None

    def test_resolve_none_list(self, monkeypatch):
        """When sessions=None, builds list from state files."""
        monkeypatch.setattr("telegram.bot._build_session_list", lambda: [])
        assert _resolve_target("1") is None

    def test_resolve_strips_whitespace(self):
        entry = _resolve_target("  2  ", self.SESSIONS)
        assert entry is not None
        assert entry["session"] == "sf-dev"


class TestCallbackDataValidation:
    """Callback data validation — rejects malformed/injected data."""

    def test_valid_approve(self):
        action, sess, win, _ = dispatch_callback_data("approve:main:0")
        assert action == "approve"
        assert sess == "main"

    def test_valid_mode_with_extra(self):
        action, sess, win, extra = dispatch_callback_data("mode:dev:1:esc")
        assert action == "mode"
        assert extra == "esc"

    def test_missing_window_for_targeted_action(self):
        with pytest.raises(ValueError, match="Missing session/window"):
            dispatch_callback_data("approve:main")

    def test_missing_session_and_window(self):
        with pytest.raises(ValueError, match="Missing session/window"):
            dispatch_callback_data("view")

    def test_shell_injection_in_session(self):
        with pytest.raises(ValueError, match="Invalid session"):
            dispatch_callback_data("approve:; rm -rf /:0")

    def test_command_substitution_in_session(self):
        with pytest.raises(ValueError, match="Invalid session"):
            dispatch_callback_data("approve:$(whoami):0")

    def test_invalid_window_non_numeric(self):
        with pytest.raises(ValueError, match="Invalid window"):
            dispatch_callback_data("deny:main:abc")

    def test_non_targeted_action_no_validation(self):
        """Non-targeted actions like 'sessions' skip target validation."""
        action, sess, _, _ = dispatch_callback_data("sessions:refresh")
        assert action == "sessions"
        assert sess == "refresh"

    def test_empty_callback_data(self):
        action, sess, win, extra = dispatch_callback_data("")
        assert action == ""


class TestCleanPaneForView:
    """Test _clean_pane_for_view scoping logic."""

    def test_scopes_to_last_prompt(self):
        raw = "\n".join([
            "❯ first task",
            "⏺ old work",
            "  ⎿ old result",
            "❯ second task",
            "⏺ new work",
            "  ⎿ new result",
            "  More output here",
            "  Line four",
            "  Line five",
            "  Line six",
        ])
        result = _clean_pane_for_view(raw, 120)
        assert "new work" in result
        assert "old work" not in result

    def test_falls_back_to_previous_prompt_when_last_block_empty(self):
        """When last work block has < 5 non-blank lines, use second-to-last prompt."""
        raw = "\n".join([
            "❯ do the real work",
            "⏺ I made all the changes.",
            "  ⎿ Read file.py",
            "  ⎿ Wrote file.py",
            "  ⎿ Ran tests",
            "",
            "⏺ All done. The changes are applied.",
            "",
            "❯ next task",
            "⏺ Short response",
        ])
        result = _clean_pane_for_view(raw, 120)
        # Should fall back to "do the real work" block
        assert "made all the changes" in result
        assert "Read file.py" in result

    def test_keeps_last_block_when_substantial(self):
        """When last work block has >= 5 non-blank lines, keep it."""
        lines = ["❯ old task", "⏺ old stuff", "❯ current task"]
        lines.extend([f"  Line {i}" for i in range(10)])
        raw = "\n".join(lines)
        result = _clean_pane_for_view(raw, 120)
        assert "current task" in result
        assert "old stuff" not in result

    def test_no_prompts_returns_all(self):
        raw = "⏺ Some output\n  ⎿ result\n  More text"
        result = _clean_pane_for_view(raw, 120)
        assert "Some output" in result

    def test_limits_to_80_lines(self):
        lines = ["❯ task"] + [f"line {i}" for i in range(100)]
        raw = "\n".join(lines)
        result = _clean_pane_for_view(raw, 120)
        result_lines = result.splitlines()
        assert len(result_lines) <= 80


class TestSendText:
    """Test send_text uses paste buffer for long/multiline text."""

    def test_short_text_uses_send_keys(self, monkeypatch):
        calls = []
        monkeypatch.setattr("telegram.tmux.run_tmux", lambda *args, **kw: (calls.append(args), "")[1])
        send_text("s", "0", "hello")
        # Should use send-keys -l, not load-buffer
        assert any("send-keys" in c and "-l" in c for c in calls)
        assert not any("load-buffer" in c for c in calls)

    def test_long_text_uses_paste_buffer(self, monkeypatch):
        calls = []
        monkeypatch.setattr("telegram.tmux.run_tmux", lambda *args, **kw: (calls.append(args), "")[1])
        monkeypatch.setattr("telegram.tmux._run_tmux_stdin", lambda data, *args, **kw: (calls.append(("stdin", *args)), True)[1])
        monkeypatch.setattr("telegram.tmux.time.sleep", lambda _: None)
        send_text("s", "0", "x" * 600)
        assert any("load-buffer" in c for c in calls)
        assert any("paste-buffer" in c for c in calls)

    def test_multiline_uses_paste_buffer(self, monkeypatch):
        calls = []
        monkeypatch.setattr("telegram.tmux.run_tmux", lambda *args, **kw: (calls.append(args), "")[1])
        monkeypatch.setattr("telegram.tmux._run_tmux_stdin", lambda data, *args, **kw: (calls.append(("stdin", *args)), True)[1])
        monkeypatch.setattr("telegram.tmux.time.sleep", lambda _: None)
        send_text("s", "0", "line1\nline2")
        assert any("load-buffer" in c for c in calls)

    def test_paste_failure_returns_false(self, monkeypatch):
        monkeypatch.setattr("telegram.tmux._run_tmux_stdin", lambda data, *args, **kw: False)
        result = send_text("s", "0", "x" * 600)
        assert result is False


class TestCleanPaneForViewGhostText:
    """Test that ghost text is stripped from View output."""

    def test_ghost_text_stripped_from_prompt(self):
        """Ghost autocomplete suggestion on prompt line is removed."""
        raw = "\n".join([
            "❯ fix the tests",
            "⏺ Running tests now.",
            "  ⎿ Bash: pytest -v",
            "    PASSED test_one",
            "    PASSED test_two",
            "    PASSED test_three",
            "",
            "⏺ All tests pass.",
            "",
            "❯ \x1b[90mcommit this\x1b[0m",
        ])
        result = _clean_pane_for_view(raw, 120)
        # Ghost text "commit this" should be gone
        assert "commit this" not in result
        # Real output should remain
        assert "All tests pass" in result

    def test_ghost_only_prompt_treated_as_empty(self):
        """A prompt line that only had ghost text becomes bare ❯ and is stripped."""
        raw = "\n".join([
            "❯ real task",
            "⏺ Some substantial work output.",
            "  ⎿ Read file.py",
            "  ⎿ Wrote file.py",
            "  ⎿ Ran tests OK",
            "",
            "⏺ All done.",
            "",
            "❯ \x1b[2msome suggestion\x1b[0m",
        ])
        result = _clean_pane_for_view(raw, 120)
        assert "some suggestion" not in result
        # Should fall back to the real work block
        assert "Some substantial work output" in result


class TestCaptureWide:
    """Test capture_wide resizes pane, captures, and restores."""

    def test_resize_capture_restore(self, monkeypatch):
        """Calls resize → capture → restore in order."""
        calls = []

        def fake_run_tmux(*args, **kw):
            calls.append(args)
            if args[0] == "display-message":
                return "80\n"
            if args[0] == "capture-pane":
                return "captured content"
            return ""

        monkeypatch.setattr("telegram.tmux.run_tmux", fake_run_tmux)
        monkeypatch.setattr("telegram.tmux.time.sleep", lambda _: None)

        text, width = capture_wide("s", "0")
        assert text == "captured content"
        assert width == 250

        # Verify order: display-message (pane_width), resize wide, capture, resize restore
        ops = [c[0] for c in calls]
        assert ops == ["display-message", "resize-pane", "capture-pane", "resize-pane"]

        # First resize sets width=250, second restores to 80
        resize_calls = [c for c in calls if c[0] == "resize-pane"]
        assert resize_calls[0][-1] == "250"
        assert resize_calls[1][-1] == "80"

    def test_resize_failure_returns_original_width(self, monkeypatch):
        """When resize fails, returns original pane width."""
        def fake_run_tmux(*args, **kw):
            if args[0] == "display-message":
                return "100\n"
            if args[0] == "resize-pane":
                return None  # resize fails
            if args[0] == "capture-pane":
                return "content"
            return ""

        monkeypatch.setattr("telegram.tmux.run_tmux", fake_run_tmux)
        monkeypatch.setattr("telegram.tmux.time.sleep", lambda _: None)

        text, width = capture_wide("s", "0")
        assert text == "content"
        assert width == 100

    def test_capture_works_when_resize_fails(self, monkeypatch):
        """Graceful degradation: capture still works if resize fails."""
        calls = []

        def fake_run_tmux(*args, **kw):
            calls.append(args)
            if args[0] == "display-message":
                return "120\n"
            if args[0] == "resize-pane":
                return None
            if args[0] == "capture-pane":
                return "still captured"
            return ""

        monkeypatch.setattr("telegram.tmux.run_tmux", fake_run_tmux)
        monkeypatch.setattr("telegram.tmux.time.sleep", lambda _: None)

        text, width = capture_wide("s", "0")
        assert text == "still captured"
        assert width == 120

        # No restore resize should be attempted
        resize_calls = [c for c in calls if c[0] == "resize-pane"]
        assert len(resize_calls) == 1  # only the failed attempt


class TestMaxSendTextLen:
    def test_constant_value(self):
        assert MAX_SEND_TEXT_LEN == 4000
