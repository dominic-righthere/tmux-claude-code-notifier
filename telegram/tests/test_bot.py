"""Bot command and callback tests."""

import pytest

from telegram.bot import (
    MAX_SEND_TEXT_LEN,
    _resolve_target,
    parse_command,
    dispatch_callback_data,
)


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


class TestMaxSendTextLen:
    def test_constant_value(self):
        assert MAX_SEND_TEXT_LEN == 4000
