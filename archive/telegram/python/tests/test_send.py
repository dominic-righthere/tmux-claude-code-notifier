"""Integration tests for send.py with mocked Telegram API."""

from unittest.mock import patch

from telegram.models import EventType, MsgIdEntry
from telegram.send import cli_main, send_notification


class TestSendNotification:
    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_sends_waiting_message(self, mock_db, mock_state, mock_tmux, mock_api):
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = None
        mock_tmux.pane_current_path.return_value = "/home/user/myproject"
        mock_tmux.capture_wide.return_value = ("⏺ Can I run this?\nsome context", 120)
        mock_api.send_message.return_value = "789"

        send_notification(EventType.WAITING, "main", "1", "Waiting", "Bash")

        mock_api.send_message.assert_called_once()
        call_args = mock_api.send_message.call_args
        assert config == call_args[0][0]
        assert "Permission Request" in call_args[0][1]

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_edits_existing_message(self, mock_db, mock_state, mock_tmux, mock_api):
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = MsgIdEntry(msg_id="100", type="prompt")
        mock_tmux.pane_current_path.return_value = "/home/user/project"
        mock_tmux.capture_wide.return_value = ("⏺ Done\nfinished work", 120)
        mock_api.edit_message.return_value = True

        send_notification(EventType.FINISHED, "main", "1", "Finished")

        mock_api.edit_message.assert_called_once()
        mock_api.send_message.assert_not_called()

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_type_guard_prevents_overwrite(self, mock_db, mock_state, mock_tmux, mock_api):
        """finished should not edit over a waiting message."""
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = MsgIdEntry(msg_id="100", type="waiting")
        mock_tmux.pane_current_path.return_value = "/home/user/project"
        mock_tmux.capture_wide.return_value = ("done", 120)
        mock_api.send_message.return_value = "200"

        send_notification(EventType.FINISHED, "main", "1", "Finished")

        # Should NOT edit, should send new
        mock_api.edit_message.assert_not_called()
        mock_api.send_message.assert_called_once()

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_finished_not_overwritten_by_waiting(self, mock_db, mock_state, mock_tmux, mock_api):
        """waiting should not edit over a finished message — strip buttons and send new."""
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = MsgIdEntry(msg_id="100", type="finished")
        mock_tmux.pane_current_path.return_value = "/home/user/project"
        mock_tmux.capture_wide.return_value = ("⏺ Can I run this?", 120)
        mock_api.send_message.return_value = "201"

        send_notification(EventType.WAITING, "main", "1", "Waiting")

        # Should strip buttons from finished message, then send new
        mock_api.strip_buttons.assert_called_once_with(config, "100")
        mock_api.edit_message.assert_not_called()
        mock_api.send_message.assert_called_once()

    @patch("telegram.send.api")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_exits_if_not_configured(self, mock_db, mock_state, mock_api):
        mock_state.load_config.return_value = None

        send_notification(EventType.WAITING, "main", "1")

        mock_api.send_message.assert_not_called()

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_prompt_type_uses_message_text(self, mock_db, mock_state, mock_tmux, mock_api):
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = None
        mock_tmux.pane_current_path.return_value = "/home/user/project"
        mock_api.send_message.return_value = "300"

        send_notification(EventType.PROMPT, "main", "1", "Fix the login bug")

        call_args = mock_api.send_message.call_args
        text = call_args[0][1]
        assert "Working" in text
        assert "Fix the login bug" in text

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_ask_user_question_treated_as_input(self, mock_db, mock_state, mock_tmux, mock_api):
        """AskUserQuestion should be treated as input request, not permission."""
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = None
        mock_tmux.pane_current_path.return_value = "/home/user/project"
        mock_tmux.capture_wide.return_value = ("⏺ Which option?\n  1. Option A\n  2. Option B", 120)
        mock_api.send_message.return_value = "400"

        send_notification(EventType.WAITING, "main", "1", "", "AskUserQuestion")

        call_args = mock_api.send_message.call_args
        text = call_args[0][1]
        assert "Waiting for Input" in text
        assert "Permission Request" not in text

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_muted_logs_not_sent_and_skips_api(self, mock_db, mock_state, mock_tmux, mock_api):
        """When muted, send_notification should log not_sent and not call API."""
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = True

        send_notification(EventType.WAITING, "main", "1", "Waiting", "Bash")

        mock_db.log_event.assert_called_once_with(
            src="send", event="not_sent", type="waiting", session="main", window="1", tool="Bash",
        )
        mock_api.send_message.assert_not_called()
        mock_api.edit_message.assert_not_called()
        mock_tmux.capture_wide.assert_not_called()

    @patch("telegram.send.api")
    @patch("telegram.send.tmux")
    @patch("telegram.send.state")
    @patch("telegram.send.db")
    def test_prompt_unescapes_json_newlines(self, mock_db, mock_state, mock_tmux, mock_api):
        """Literal \\n from bash JSON extraction should become real newlines."""
        from telegram.models import TelegramConfig

        config = TelegramConfig(bot_token="123:ABC", chat_id="456")
        mock_state.load_config.return_value = config
        mock_state.is_muted.return_value = False
        mock_state.make_msg_key.return_value = "main_1"
        mock_state.read_msg_id.return_value = None
        mock_tmux.pane_current_path.return_value = "/home/user/project"
        mock_api.send_message.return_value = "300"

        # Simulate what bash passes: literal \n in the string
        cli_main(["prompt", "main", "1", "line one\\nline two\\nline three"])

        call_args = mock_api.send_message.call_args
        text = call_args[0][1]
        assert "line one" in text
        assert "line two" in text
        # Should NOT contain literal \n
        assert "\\n" not in text
