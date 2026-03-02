"""Unit tests for state file I/O."""

from pathlib import Path

from telegram.models import MsgIdEntry, StateFile
from telegram.state import (
    find_session_by_msg_id,
    load_config,
    make_msg_key,
    read_state_file,
    sanitize_key,
    write_state_file,
)


class TestSanitizeKey:
    def test_replaces_slash(self):
        assert sanitize_key("a/b") == "a_b"

    def test_replaces_space(self):
        assert sanitize_key("a b") == "a_b"

    def test_both(self):
        assert sanitize_key("my session/name") == "my_session_name"

    def test_plain(self):
        assert sanitize_key("main") == "main"


class TestMsgKey:
    def test_format(self):
        assert make_msg_key("main", "1") == "main_1"

    def test_sanitizes_session(self):
        assert make_msg_key("my session", "2") == "my_session_2"


class TestMsgIdEntry:
    def test_parse_with_type(self):
        entry = MsgIdEntry.parse("12345:waiting")
        assert entry is not None
        assert entry.msg_id == "12345"
        assert entry.type == "waiting"

    def test_parse_legacy(self):
        entry = MsgIdEntry.parse("12345")
        assert entry is not None
        assert entry.msg_id == "12345"
        assert entry.type == ""

    def test_parse_empty(self):
        assert MsgIdEntry.parse("") is None
        assert MsgIdEntry.parse("   ") is None

    def test_serialize(self):
        entry = MsgIdEntry(msg_id="123", type="finished")
        assert entry.serialize() == "123:finished"


class TestStateFile:
    def test_write_and_read(self, tmp_path: Path):
        write_state_file(
            tmp_path, "main_1",
            session="main", window="1", window_name="claude",
            type_="working", message="Working...", timestamp="1234567890",
        )
        sf = read_state_file(tmp_path / "main_1")
        assert sf is not None
        assert sf.session == "main"
        assert sf.window == "1"
        assert sf.window_name == "claude"
        assert sf.type == "working"
        assert sf.message == "Working..."
        assert sf.timestamp == "1234567890"

    def test_read_missing(self, tmp_path: Path):
        assert read_state_file(tmp_path / "nonexistent") is None

    def test_bash_compatible_format(self, tmp_path: Path):
        """Verify the output format matches lib.sh write_state_file."""
        write_state_file(
            tmp_path, "test_0",
            session="test", window="0", window_name="main",
            type_="idle", message="Idle", timestamp="9999",
        )
        content = (tmp_path / "test_0").read_text()
        assert "SESSION=test\n" in content
        assert "WINDOW=0\n" in content
        assert "TYPE=idle\n" in content


class TestFindSessionByMsgId:
    def test_finds_matching_session(self, tmp_path, monkeypatch):
        monkeypatch.setattr("telegram.state.msg_id_dir", lambda: tmp_path)
        # Write a msg_id file: tmux-cc_1 with msg_id 12345
        (tmp_path / "tmux-cc_1").write_text("12345:waiting")
        (tmp_path / "sf-dev_0").write_text("67890:finished")

        result = find_session_by_msg_id("12345")
        assert result is not None
        assert result == ("tmux-cc", "1")

    def test_finds_second_session(self, tmp_path, monkeypatch):
        monkeypatch.setattr("telegram.state.msg_id_dir", lambda: tmp_path)
        (tmp_path / "tmux-cc_1").write_text("12345:waiting")
        (tmp_path / "sf-dev_0").write_text("67890:finished")

        result = find_session_by_msg_id("67890")
        assert result is not None
        assert result == ("sf-dev", "0")

    def test_returns_none_for_unknown_msg_id(self, tmp_path, monkeypatch):
        monkeypatch.setattr("telegram.state.msg_id_dir", lambda: tmp_path)
        (tmp_path / "tmux-cc_1").write_text("12345:waiting")

        assert find_session_by_msg_id("99999") is None

    def test_returns_none_for_empty_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr("telegram.state.msg_id_dir", lambda: tmp_path)
        assert find_session_by_msg_id("12345") is None

    def test_handles_hyphenated_session_name(self, tmp_path, monkeypatch):
        monkeypatch.setattr("telegram.state.msg_id_dir", lambda: tmp_path)
        (tmp_path / "my-long-session_3").write_text("55555:waiting")

        result = find_session_by_msg_id("55555")
        assert result is not None
        assert result == ("my-long-session", "3")


class TestLoadConfig:
    def test_loads_valid_config(self, tmp_path: Path, monkeypatch):
        conf = tmp_path / "telegram.conf"
        conf.write_text("BOT_TOKEN=123:ABC\nCHAT_ID=456\n")
        monkeypatch.setattr("telegram.state.config_path", lambda: conf)

        config = load_config()
        assert config is not None
        assert config.bot_token == "123:ABC"
        assert config.chat_id == "456"

    def test_returns_none_if_missing(self, tmp_path: Path, monkeypatch):
        monkeypatch.setattr("telegram.state.config_path", lambda: tmp_path / "nope")
        assert load_config() is None

    def test_returns_none_if_incomplete(self, tmp_path: Path, monkeypatch):
        conf = tmp_path / "telegram.conf"
        conf.write_text("BOT_TOKEN=123:ABC\n")  # missing CHAT_ID
        monkeypatch.setattr("telegram.state.config_path", lambda: conf)
        assert load_config() is None
