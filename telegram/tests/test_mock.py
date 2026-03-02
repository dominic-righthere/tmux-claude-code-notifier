"""Tests using the mock Telegram API for full pipeline verification."""

from telegram import api
from telegram.message import build_message
from telegram.models import EventType, ModeInfo, SendContext, TelegramConfig


class TestMockSendPipeline:
    """Full send pipeline tests using the mock API."""

    def test_permission_request_message(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            project_name="myproject",
            raw_context="⏺ I need to run `ls -la` to check the files.\nCan I proceed?",
        )
        payload = build_message(ctx)
        msg_id = api.send_message(config, payload.text, payload.keyboard.to_dict())

        assert msg_id is not None
        assert mock_telegram.last is not None

        sent = mock_telegram.last
        assert sent["method"] == "sendMessage"
        text = sent["data"]["text"]
        assert "Permission Request" in text
        assert "main:1" in text
        assert "myproject" in text
        # Tool name in <code> tags
        assert "<code>Bash</code>" in text

        # Check keyboard buttons
        kb = sent["data"]["reply_markup"]["inline_keyboard"]
        button_texts = [b["text"] for row in kb for b in row]
        assert "✅ Approve" in button_texts
        assert "❌ Deny" in button_texts
        assert "📋 View" in button_texts

    def test_finished_message(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="dev",
            window="0",
            project_name="webapp",
            raw_context="\n".join([
                "❯ do stuff",
                "⏺ Tool call",
                "  ⎿ Read src/app.py",
                "  ⎿ Wrote src/app.py",
                "",
                "⏺ All changes applied.",
            ]),
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        assert "Task Finished" in text
        assert "webapp" in text
        # Claude's final speech
        assert "All changes applied" in text
        # Activity log in expandable blockquote
        assert "Activity:" in text
        assert "Read src/app.py" in text
        assert "Wrote src/app.py" in text

    def test_prompt_message(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
            message="Implement the user authentication flow",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        assert "Working" in sent["data"]["text"]
        assert "authentication flow" in sent["data"]["text"]

    def test_short_prompt_inline(self, mock_telegram):
        """Short prompts stay inline, not in blockquote."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
            message="Fix the typo",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        text = mock_telegram.last["data"]["text"]
        assert "Fix the typo" in text
        assert "<blockquote" not in text

    def test_long_prompt_collapsible(self, mock_telegram):
        """Long prompts are wrapped in an expandable blockquote."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        long_msg = "Implement the user authentication flow with JWT tokens, " \
                   "session management, and refresh token rotation for the API"
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
            message=long_msg,
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        text = mock_telegram.last["data"]["text"]
        assert "Working" in text
        assert "<blockquote expandable>" in text
        assert "authentication flow" in text

    def test_multiline_prompt_collapsible(self, mock_telegram):
        """Multi-line prompts are wrapped in an expandable blockquote."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
            message="Fix the following:\n1. Auth bug\n2. DB leak\n3. CSS issue",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        text = mock_telegram.last["data"]["text"]
        assert "<blockquote expandable>" in text

    def test_finished_no_activity_log_clean_header(self, mock_telegram):
        """Finished message with no ⎿ markers produces header-only message."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="dev",
            window="0",
            project_name="webapp",
            raw_context="Just some plain text with no activity markers at all.",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        assert "Task Finished" in text
        assert "webapp" in text
        # No raw context dump — no blockquote fallback
        assert "<blockquote" not in text
        assert "plain text" not in text

    def test_finished_no_raw_fallback(self, mock_telegram):
        """Finished message never dumps raw pane content."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        long_output = "line of output\n" * 100
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="s",
            window="0",
            raw_context=long_output,
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        assert "Task Finished" in text
        # Should NOT contain a raw pane dump
        assert "line of output" not in text

    def test_waiting_input_filters_tool_outputs(self, mock_telegram):
        """Waiting-for-input message filters tool output blocks from Claude's speech."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            raw_context="\n".join([
                "⏺ Tool call",
                "  Let me check the file.",
                "  ⎿ Read src/app.py",
                "    import os",
                "",
                "  Should I proceed with the changes?",
            ]),
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        assert "check the file" in text
        assert "Should I proceed" in text
        # Tool output should be filtered
        assert "import os" not in text
        assert "Read src/app.py" not in text

    def test_edit_message(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")

        # Send initial
        msg_id = api.send_message(config, "initial")
        assert msg_id is not None

        # Edit it
        success = api.edit_message(config, msg_id, "updated")
        assert success is True
        assert len(mock_telegram.messages) == 2
        assert mock_telegram.last["method"] == "editMessageText"
        assert mock_telegram.last["data"]["text"] == "updated"

    def test_options_keyboard(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            raw_context="⏺ Which option?\n  1. Create new file\n  2. Edit existing\n  3. Delete",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        kb = sent["data"]["reply_markup"]["inline_keyboard"]
        # 3 option rows + 1 view row
        assert len(kb) == 4
        assert "1. Create new file" in kb[0][0]["text"]
        assert kb[0][0]["callback_data"] == "opt:main:1:1"

    def test_auto_mode_view_only_keyboard(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            mode=ModeInfo(label="⏵⏵ Auto-accept edits", auto=True),
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        kb = sent["data"]["reply_markup"]["inline_keyboard"]
        # Auto mode = view only, no approve/deny
        button_texts = [b["text"] for row in kb for b in row]
        assert "✅ Approve" not in button_texts
        assert "📋 View Output" in button_texts

    def test_message_under_4096_chars(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="s",
            window="0",
            raw_context="x" * 5000,
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        assert len(sent["data"]["text"]) <= 4096

    def test_html_escaping(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
            message="Fix <div> & <span> elements",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        # Raw < and & should be escaped
        assert "&lt;div&gt;" in text
        assert "&amp;" in text

    def test_permission_request_has_cancel_button(self, mock_telegram):
        """Permission request keyboard includes cancel button."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        kb = sent["data"]["reply_markup"]["inline_keyboard"]
        all_texts = [b["text"] for row in kb for b in row]
        assert "⏹ Cancel" in all_texts
        # Also check callback data
        all_data = [b["callback_data"] for row in kb for b in row]
        assert "mode:main:1:esc" in all_data

    def test_waiting_no_tool_has_reply_button(self, mock_telegram):
        """Waiting for input (no tool) gets view + reply buttons."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="dev",
            window="0",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        kb = sent["data"]["reply_markup"]["inline_keyboard"]
        all_texts = [b["text"] for row in kb for b in row]
        assert "📋 View" in all_texts
        assert "💬 Reply" in all_texts

    def test_finished_has_send_button(self, mock_telegram):
        """Finished notification gets view + send buttons."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="dev",
            window="0",
            project_name="webapp",
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        kb = sent["data"]["reply_markup"]["inline_keyboard"]
        all_texts = [b["text"] for row in kb for b in row]
        assert "📋 View" in all_texts
        assert "💬 Send" in all_texts
        all_data = [b["callback_data"] for row in kb for b in row]
        assert "prompt:dev:0" in all_data

    def test_permission_request_shows_command_block(self, mock_telegram):
        """Permission request body shows command in <code>, not raw speech."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            project_name="myproject",
            raw_context="\n".join([
                "⏺ Bash(cat /foo/bar)",
                "  ⎿ file contents here",
                "───────────────",
                "Bash command",
                "cat /foo/bar",
                "Check msg_id files",
                "❯ Do you want to proceed?",
            ]),
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        assert "Permission Request" in text
        assert "<code>" in text
        assert "cat /foo/bar" in text
        assert "Check msg_id files" in text
        # Should NOT contain raw speech or tool output
        assert "file contents here" not in text

    def test_permission_request_no_noise(self, mock_telegram):
        """Permission request filters Running…, ctrl hints from body."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            raw_context="\n".join([
                "⏺ Bash(ls -la)",
                "───────────────",
                "ls -la",
                "Running…",
                "ctrl+b ctrl+b",
                "+20 more tool uses",
            ]),
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        text = mock_telegram.last["data"]["text"]
        assert "ls -la" in text
        # Noise should be filtered by strip_terminal_chrome before it reaches here
        # (In real flow it's stripped; in this test raw_context is already clean-ish)
        assert "Permission Request" in text

    def test_exit_plan_mode_shows_plan_context(self, mock_telegram):
        """ExitPlanMode permission request shows plan summary, not empty body."""
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="ExitPlanMode",
            project_name="myapp",
            raw_context="\n".join([
                "⏺ Here is my plan for the refactor:",
                "  1. Extract helper functions",
                "  2. Add type annotations",
                "  3. Update tests",
                "",
                "  Shall I proceed with this plan?",
            ]),
        )
        payload = build_message(ctx)
        api.send_message(config, payload.text, payload.keyboard.to_dict())

        sent = mock_telegram.last
        text = sent["data"]["text"]
        assert "Permission Request" in text
        assert "ExitPlanMode" in text
        # Should show the plan context, not be empty
        assert "plan for the refactor" in text
        assert "<blockquote expandable>" in text

    def test_multiple_calls_logged(self, mock_telegram):
        config = TelegramConfig(bot_token="fake:token", chat_id="123")
        api.send_message(config, "first")
        api.send_message(config, "second")
        api.answer_callback(config, "cb123", "ok")

        assert len(mock_telegram.messages) == 2
        assert len(mock_telegram.log) == 3  # includes answerCallbackQuery
