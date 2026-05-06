"""Bot command and callback tests."""

import pytest

import asyncio

from telegram.bot import (
    BotHandler,
    MAX_SEND_TEXT_LEN,
    _clean_pane_for_file,
    _clean_pane_for_view,
    _resolve_target,
    parse_command,
    dispatch_callback_data,
)
from telegram.models import TelegramConfig
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
    """Test capture_wide captures at native width (no resize)."""

    def test_captures_at_native_width(self, monkeypatch):
        """Returns captured content and native pane width."""
        calls = []

        def fake_run_tmux(*args, **kw):
            calls.append(args)
            if args[0] == "display-message":
                return "80\n"
            if args[0] == "capture-pane":
                return "captured content"
            return ""

        monkeypatch.setattr("telegram.tmux.run_tmux", fake_run_tmux)

        text, width = capture_wide("s", "0")
        assert text == "captured content"
        assert width == 80

        # Only display-message (pane_width) and capture-pane — no resize
        ops = [c[0] for c in calls]
        assert ops == ["display-message", "capture-pane"]

    def test_returns_default_width_on_failure(self, monkeypatch):
        """When pane_width fails, returns default 120."""
        def fake_run_tmux(*args, **kw):
            if args[0] == "display-message":
                return None  # pane_width fails
            if args[0] == "capture-pane":
                return "content"
            return ""

        monkeypatch.setattr("telegram.tmux.run_tmux", fake_run_tmux)

        text, width = capture_wide("s", "0")
        assert text == "content"
        assert width == 120  # default fallback

    def test_capture_none_returns_none(self, monkeypatch):
        """Returns None text when capture fails."""
        def fake_run_tmux(*args, **kw):
            if args[0] == "display-message":
                return "200\n"
            if args[0] == "capture-pane":
                return None
            return ""

        monkeypatch.setattr("telegram.tmux.run_tmux", fake_run_tmux)

        text, width = capture_wide("s", "0")
        assert text is None
        assert width == 200


class TestCmdDoctor:
    """Test cmd_doctor handles empty/whitespace output."""

    def test_empty_stdout_shows_all_passed(self, monkeypatch):
        """When doctor.sh --quiet outputs only whitespace, show fallback."""
        sent: list[str] = []
        config = TelegramConfig(bot_token="fake", chat_id="123")
        handler = BotHandler(config, "/tmp")

        async def fake_send(text, reply_markup=None):
            sent.append(text)
            return "1"

        handler.send = fake_send

        async def fake_subprocess(*args, **kwargs):
            class FakeProc:
                async def communicate(self):
                    return (b"\n", None)
            return FakeProc()

        monkeypatch.setattr("asyncio.create_subprocess_exec", fake_subprocess)
        asyncio.run(handler.cmd_doctor())

        assert len(sent) == 1
        assert "All checks passed." in sent[0]
        # Should not contain just <pre>\n</pre>
        assert sent[0] != "<pre>\n</pre>"

    def test_none_stdout_shows_all_passed(self, monkeypatch):
        """When stdout is None, show fallback."""
        sent: list[str] = []
        config = TelegramConfig(bot_token="fake", chat_id="123")
        handler = BotHandler(config, "/tmp")

        async def fake_send(text, reply_markup=None):
            sent.append(text)
            return "1"

        handler.send = fake_send

        async def fake_subprocess(*args, **kwargs):
            class FakeProc:
                async def communicate(self):
                    return (None, None)
            return FakeProc()

        monkeypatch.setattr("asyncio.create_subprocess_exec", fake_subprocess)
        asyncio.run(handler.cmd_doctor())

        assert "All checks passed." in sent[0]


class TestCleanPaneForFile:
    """Test _clean_pane_for_file preserves formatting and uses 200-line limit."""

    def test_no_reflow_preserves_long_lines(self):
        """Long lines should not be reflowed or wrapped."""
        long_line = "x" * 200
        raw = f"❯ task\n{long_line}\nmore\nline3\nline4\nline5"
        result = _clean_pane_for_file(raw, 120)
        assert long_line in result

    def test_no_table_conversion(self):
        """Tables should be preserved as-is."""
        raw = "\n".join([
            "❯ task",
            "| Col1 | Col2 |",
            "|------|------|",
            "| a    | b    |",
            "line4",
            "line5",
            "line6",
        ])
        result = _clean_pane_for_file(raw, 120)
        assert "| Col1 | Col2 |" in result

    def test_limits_to_200_lines(self):
        lines = ["❯ task"] + [f"line {i}" for i in range(250)]
        raw = "\n".join(lines)
        result = _clean_pane_for_file(raw, 120)
        result_lines = result.splitlines()
        assert len(result_lines) <= 200

    def test_scopes_to_last_prompt(self):
        raw = "\n".join([
            "❯ first task",
            "old output",
            "❯ second task",
            "new output",
            "line2",
            "line3",
            "line4",
            "line5",
        ])
        result = _clean_pane_for_file(raw, 120)
        assert "new output" in result
        assert "old output" not in result

    def test_returns_plain_text(self):
        """Output should not be HTML-escaped."""
        raw = "❯ task\n<b>bold</b> & stuff\nline2\nline3\nline4\nline5"
        result = _clean_pane_for_file(raw, 120)
        assert "<b>bold</b>" in result
        assert "&amp;" not in result


class TestSendViewDocument:
    """Test _send_view sends HTML document instead of inline message."""

    def test_sends_document_with_content(self, monkeypatch):
        """_send_view should call async_send_document with .html file."""
        doc_calls: list[dict] = []
        config = TelegramConfig(bot_token="fake", chat_id="123")
        handler = BotHandler(config, "/tmp")

        async def fake_send_document(cfg, filename, content, caption="", reply_markup=None):
            doc_calls.append({"filename": filename, "content": content, "caption": caption})
            return "1"

        monkeypatch.setattr("telegram.api.async_send_document", fake_send_document)
        monkeypatch.setattr(
            "telegram.bot._get_session_info",
            lambda s, w: {"project": "myapp", "mode": "", "mode_icon": "", "task": ""},
        )

        raw = "\n".join(["❯ do work", "output line 1", "output line 2", "line 3", "line 4", "line 5"])
        asyncio.run(handler._send_view("main", "0", raw, 120))

        assert len(doc_calls) == 1
        assert doc_calls[0]["filename"] == "myapp.html"
        assert b"output line 1" in doc_calls[0]["content"]
        assert b"<!DOCTYPE html>" in doc_calls[0]["content"]
        assert "myapp" in doc_calls[0]["caption"]

    def test_empty_output_sends_text_message(self, monkeypatch):
        """Empty pane sends a regular text message, not a document."""
        sent: list[str] = []
        config = TelegramConfig(bot_token="fake", chat_id="123")
        handler = BotHandler(config, "/tmp")

        async def fake_send(text, reply_markup=None):
            sent.append(text)
            return "1"

        handler.send = fake_send

        asyncio.run(handler._send_view("main", "0", "", 120))
        assert len(sent) == 1
        assert "(empty)" in sent[0]

    def test_uses_session_name_when_no_project(self, monkeypatch):
        """Filename falls back to session name when project is empty."""
        doc_calls: list[dict] = []
        config = TelegramConfig(bot_token="fake", chat_id="123")
        handler = BotHandler(config, "/tmp")

        async def fake_send_document(cfg, filename, content, caption="", reply_markup=None):
            doc_calls.append({"filename": filename})
            return "1"

        monkeypatch.setattr("telegram.api.async_send_document", fake_send_document)
        monkeypatch.setattr(
            "telegram.bot._get_session_info",
            lambda s, w: {"project": "", "mode": "", "mode_icon": "", "task": ""},
        )

        raw = "\n".join(["❯ task", "output", "line2", "line3", "line4", "line5"])
        asyncio.run(handler._send_view("dev-session", "0", raw, 120))

        assert doc_calls[0]["filename"] == "dev-session.html"


class TestCmdSessions:
    """Test /s command behavior."""

    def _make_handler(self, monkeypatch):
        """Create a BotHandler with mocked send/edit/delete."""
        sent: list[dict] = []
        edited: list[dict] = []
        deleted: list[str] = []
        config = TelegramConfig(bot_token="fake", chat_id="123")
        handler = BotHandler(config, "/tmp")

        async def fake_send(text, reply_markup=None):
            msg_id = str(90000 + len(sent))
            sent.append({"text": text, "reply_markup": reply_markup, "msg_id": msg_id})
            return msg_id

        async def fake_edit(msg_id, text, reply_markup=None):
            edited.append({"msg_id": msg_id, "text": text, "reply_markup": reply_markup})
            return True

        async def fake_delete(cfg, msg_id):
            deleted.append(msg_id)
            return True

        handler.send = fake_send
        handler.edit = fake_edit
        monkeypatch.setattr("telegram.api.async_delete_message", fake_delete)

        sessions = [
            {"idx": 1, "session": "traefik-hub", "window": "0", "category": "working", "message": "Working..."},
            {"idx": 2, "session": "career", "window": "1", "category": "waiting", "message": "Bash: ls"},
            {"idx": 3, "session": "ai-browser", "window": "0", "category": "idle", "message": "Idle"},
        ]
        monkeypatch.setattr("telegram.bot._build_session_list", lambda: sessions)
        monkeypatch.setattr("telegram.bot._get_session_info", lambda s, w: {
            "project": s, "mode": "", "mode_icon": "", "task": "",
        })
        monkeypatch.setattr("telegram.bot.state.is_muted", lambda: False)

        return handler, sent, edited, deleted

    def test_sessions_deletes_old_sends_new(self, monkeypatch):
        """Default /s deletes old message, sends new one."""
        handler, sent, edited, deleted = self._make_handler(monkeypatch)

        handler.last_sessions_msg_id = "old_123"
        asyncio.run(handler.cmd_sessions())

        assert deleted == ["old_123"]
        assert len(sent) == 1
        assert handler.last_sessions_msg_id == sent[0]["msg_id"]

    def test_sessions_refresh_edits_in_place(self, monkeypatch):
        """Refresh callback passes edit_msg_id, edits in-place."""
        handler, sent, edited, deleted = self._make_handler(monkeypatch)

        asyncio.run(handler.cmd_sessions(edit_msg_id="cb_456"))

        assert len(edited) == 1
        assert edited[0]["msg_id"] == "cb_456"
        assert len(sent) == 0
        assert len(deleted) == 0
        assert handler.last_sessions_msg_id == "cb_456"

    def test_sessions_index_in_text(self, monkeypatch):
        """Session text includes numeric index prefixes."""
        handler, sent, edited, deleted = self._make_handler(monkeypatch)

        asyncio.run(handler.cmd_sessions())

        text = sent[0]["text"]
        assert "\n1 ⟳" in text
        assert "\n2 ⏳" in text
        assert "\n3 ○" in text

    def test_sessions_compact_buttons(self, monkeypatch):
        """Waiting sessions get compact numbered buttons, idle sessions get none."""
        handler, sent, edited, deleted = self._make_handler(monkeypatch)

        asyncio.run(handler.cmd_sessions())

        kb = sent[0]["reply_markup"]
        rows = kb["inline_keyboard"]
        # waiting session (idx=2) should have [✅ 2] [❌ 2] [📋 2] [💬 2]
        waiting_row = [r for r in rows if any("approve:" in b.get("callback_data", "") for b in r)]
        assert len(waiting_row) == 1
        assert waiting_row[0][0]["text"] == "✅ 2"
        assert waiting_row[0][1]["text"] == "❌ 2"

        # working session (idx=1) should have [📋 1] [💬 1]
        working_row = [r for r in rows if any("view:traefik-hub:" in b.get("callback_data", "") for b in r)]
        assert len(working_row) == 1
        assert working_row[0][0]["text"] == "📋 1"
        assert working_row[0][1]["text"] == "💬 1"

        # idle session (idx=3) should have no buttons
        idle_row = [r for r in rows if any("ai-browser" in b.get("callback_data", "") for b in r)]
        assert len(idle_row) == 0

        # Last row should be Refresh
        assert rows[-1][0]["text"] == "🔄 Refresh"


class TestMaxSendTextLen:
    def test_constant_value(self):
        assert MAX_SEND_TEXT_LEN == 4000
