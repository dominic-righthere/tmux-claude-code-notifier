"""Tests for tmux.py — validate_target and helpers."""

import pytest

from telegram.tmux import validate_target


class TestValidateTarget:
    """Validate session/window names against injection."""

    def test_valid_simple(self):
        assert validate_target("main", "0") is None

    def test_valid_with_dots_dashes(self):
        assert validate_target("my-app.dev", "12") is None

    def test_valid_with_underscores(self):
        assert validate_target("claude_session_1", "0") is None

    def test_valid_max_length_session(self):
        assert validate_target("a" * 50, "0") is None

    def test_valid_three_digit_window(self):
        assert validate_target("main", "999") is None

    def test_invalid_session_empty(self):
        err = validate_target("", "0")
        assert err is not None
        assert "Invalid session" in err

    def test_invalid_session_too_long(self):
        err = validate_target("a" * 51, "0")
        assert err is not None
        assert "Invalid session" in err

    def test_invalid_session_shell_injection(self):
        err = validate_target("; rm -rf /", "0")
        assert err is not None

    def test_invalid_session_command_substitution(self):
        err = validate_target("$(whoami)", "0")
        assert err is not None

    def test_invalid_session_backtick(self):
        err = validate_target("`id`", "0")
        assert err is not None

    def test_invalid_session_slash(self):
        err = validate_target("foo/bar", "0")
        assert err is not None

    def test_invalid_session_space(self):
        err = validate_target("foo bar", "0")
        assert err is not None

    def test_invalid_window_empty(self):
        err = validate_target("main", "")
        assert err is not None
        assert "Invalid window" in err

    def test_invalid_window_non_numeric(self):
        err = validate_target("main", "abc")
        assert err is not None

    def test_invalid_window_negative(self):
        err = validate_target("main", "-1")
        assert err is not None

    def test_invalid_window_too_long(self):
        err = validate_target("main", "1234")
        assert err is not None

    def test_invalid_window_injection(self):
        err = validate_target("main", "0;rm -rf /")
        assert err is not None

    def test_crafted_callback_attack(self):
        """Simulates approve:; rm -rf /:0 callback."""
        err = validate_target("; rm -rf /", "0")
        assert err is not None
