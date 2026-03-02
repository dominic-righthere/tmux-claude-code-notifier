"""Unit tests for terminal parsing functions."""

from telegram.parse import (
    convert_tables_to_bullets,
    detect_mode,
    extract_activity_log,
    extract_command_block,
    extract_preview,
    extract_prompt_text,
    html_escape,
    reflow_for_telegram,
    strip_ansi,
    strip_ghost_text,
    strip_terminal_chrome,
    trim_blank_lines,
    wrap_long_lines,
)


class TestStripAnsi:
    def test_strips_color_codes(self):
        assert strip_ansi("\x1b[31mred\x1b[0m") == "red"

    def test_strips_multiple_codes(self):
        assert strip_ansi("\x1b[1;32mbold green\x1b[0m normal") == "bold green normal"

    def test_no_codes_unchanged(self):
        assert strip_ansi("plain text") == "plain text"


class TestStripGhostText:
    def test_strips_dim(self):
        text = "real \x1b[2mghost\x1b[0m real"
        assert strip_ghost_text(text) == "real  real"

    def test_strips_bright_black(self):
        text = "real \x1b[90mghost\x1b[0m real"
        assert strip_ghost_text(text) == "real  real"

    def test_strips_256_color_grey(self):
        text = "real \x1b[38;5;245mghost\x1b[0m real"
        assert strip_ghost_text(text) == "real  real"

    def test_strips_compound_sequence(self):
        """Compound sequences like \\e[1;2m (bold+dim) are stripped."""
        text = "real \x1b[1;2mghost\x1b[0m real"
        assert strip_ghost_text(text) == "real  real"

    def test_preserves_non_dim_ansi(self):
        text = "\x1b[31mred text\x1b[0m normal"
        assert strip_ghost_text(text) == "\x1b[31mred text\x1b[0m normal"

    def test_prompt_line_with_ghost(self):
        """Prompt line where ghost suggestion follows real input."""
        text = "❯ \x1b[90mcommit this\x1b[0m"
        result = strip_ghost_text(text)
        assert "commit this" not in result
        assert "❯" in result

    def test_empty_string(self):
        assert strip_ghost_text("") == ""

    def test_reset_22m(self):
        """SGR 22m (normal intensity) also serves as reset for dim."""
        text = "real \x1b[2mghost\x1b[22m real"
        assert strip_ghost_text(text) == "real  real"

    def test_reset_39m(self):
        """SGR 39m (default foreground) also serves as reset for color."""
        text = "real \x1b[90mghost\x1b[39m real"
        assert strip_ghost_text(text) == "real  real"


class TestTrimBlankLines:
    def test_trims_leading(self):
        assert trim_blank_lines("\n\n  \nhello\nworld") == "hello\nworld"

    def test_trims_trailing(self):
        assert trim_blank_lines("hello\nworld\n\n  \n") == "hello\nworld"

    def test_trims_both(self):
        assert trim_blank_lines("\n\nhello\n\n") == "hello"

    def test_preserves_middle(self):
        assert trim_blank_lines("hello\n\nworld") == "hello\n\nworld"

    def test_empty_string(self):
        assert trim_blank_lines("") == ""


class TestStripTerminalChrome:
    def test_removes_separator_lines(self):
        text = "hello\n───────────────\nworld"
        result = strip_terminal_chrome(text)
        assert "───" not in result
        assert "hello" in result
        assert "world" in result

    def test_removes_double_dash_separators(self):
        text = "hello\n----------\nworld"
        result = strip_terminal_chrome(text)
        assert "----------" not in result

    def test_removes_status_bar(self):
        text = "some output\n-- INSERT --\nmore output"
        result = strip_terminal_chrome(text)
        assert "INSERT" not in result
        assert "some output" in result

    def test_removes_context_percentage(self):
        text = "output\nContext left until auto-compact: 12%\nmore"
        result = strip_terminal_chrome(text)
        assert "auto-compact" not in result

    def test_removes_beaming_line(self):
        text = "output\n✳ Beaming…\nmore"
        result = strip_terminal_chrome(text)
        assert "Beaming" not in result

    def test_removes_working_line(self):
        text = "output\n✻ Working…\nmore"
        result = strip_terminal_chrome(text)
        assert "Working" not in result

    def test_removes_bare_prompt(self):
        text = "output\n❯\n❯  \nmore"
        result = strip_terminal_chrome(text)
        assert result == "output\nmore"

    def test_removes_mode_indicator(self):
        text = "output\n⏵⏵ Auto-accept edits (3 remaining)\nmore"
        result = strip_terminal_chrome(text)
        assert "⏵⏵" not in result

    def test_removes_germinating_line(self):
        text = "output\n· Germinating… (running stop hook)\nmore"
        result = strip_terminal_chrome(text)
        assert "Germinating" not in result

    def test_preserves_normal_content(self):
        text = "⏺ I need to read the file.\n  Can I proceed?\n  ⎿ Read file.py"
        result = strip_terminal_chrome(text)
        assert result == text

    def test_preserves_prompt_with_content(self):
        """❯ with content after it should be preserved."""
        text = "❯ run the tests\noutput here"
        result = strip_terminal_chrome(text)
        assert "❯ run the tests" in result

    def test_removes_ctrl_hint_lines(self):
        text = "output\nctrl+b ctrl+b to switch\nmore output"
        result = strip_terminal_chrome(text)
        assert "ctrl+b" not in result
        assert "output" in result

    def test_removes_more_tool_uses(self):
        text = "output\n+20 more tool uses\nmore output"
        result = strip_terminal_chrome(text)
        assert "+20 more tool uses" not in result

    def test_removes_running_status(self):
        text = "output\nRunning…\nmore output"
        result = strip_terminal_chrome(text)
        assert "Running…" not in result

    def test_removes_esc_to_cancel(self):
        text = "output\nEsc to cancel\nmore output"
        result = strip_terminal_chrome(text)
        assert "Esc to cancel" not in result

    def test_removes_tab_to_amend(self):
        text = "output\nTab to amend\nmore output"
        result = strip_terminal_chrome(text)
        assert "Tab to amend" not in result

    def test_real_terminal_noise(self):
        """Simulate a real noisy pane capture."""
        text = "\n".join([
            "⏺ I need to run a command.",
            "  Can I proceed?",
            "─────────────────────────────",
            "-- INSERT --",
            "Context left until auto-compact: 45%",
            "✳ Beaming…",
            "⏵⏵ accept edits",
            "❯",
            "❯  ",
        ])
        result = strip_terminal_chrome(text)
        assert "I need to run a command" in result
        assert "Can I proceed" in result
        assert "───" not in result
        assert "INSERT" not in result
        assert "auto-compact" not in result
        assert "Beaming" not in result
        assert "⏵⏵" not in result

    def test_removes_ctrl_dash_hint(self):
        text = "output\nctrl-g to interrupt\nmore output"
        result = strip_terminal_chrome(text)
        assert "ctrl-g" not in result
        assert "output" in result

    def test_removes_plan_file_path(self):
        text = "output\n~/.claude/projects/foo/plan.md\nmore output"
        result = strip_terminal_chrome(text)
        assert "~/.claude/" not in result
        assert "output" in result

    def test_removes_satisfaction_survey(self):
        text = "output\nHow is Claude doing today?\nmore output"
        result = strip_terminal_chrome(text)
        assert "How is Claude doing" not in result
        assert "output" in result

    def test_removes_survey_scale(self):
        text = "output\n1: Bad  2: Fine  3: Good  Dismiss\nmore output"
        result = strip_terminal_chrome(text)
        assert "Bad" not in result
        assert "Fine" not in result
        assert "output" in result

    def test_removes_survey_with_bullet(self):
        """● prefix on survey question should still be stripped."""
        text = "output\n● How is Claude doing this session? (optional)\nmore output"
        result = strip_terminal_chrome(text)
        assert "How is Claude doing" not in result
        assert "output" in result

    def test_removes_spinner_without_symbol(self):
        """Ghost text may strip the spinner symbol, leaving bare word…"""
        text = "output\nPrecipitating…\nmore output"
        result = strip_terminal_chrome(text)
        assert "Precipitating" not in result
        assert "output" in result

    def test_removes_mode_remnant_cycle(self):
        """Ghost text strips ⏵⏵/INSERT from status line, leaving 'on  cycle)' fragment."""
        text = "output\non  cycle)\nmore output"
        result = strip_terminal_chrome(text)
        assert "cycle)" not in result
        assert "output" in result

    def test_removes_mode_remnant_shift_tab(self):
        text = "output\naccept edits on (shift+tab to cycle)\nmore output"
        result = strip_terminal_chrome(text)
        assert "shift+tab" not in result
        assert "output" in result

    def test_removes_enter_to_select(self):
        text = "output\nEnter to select · ↑/↓ to navigate\nmore output"
        result = strip_terminal_chrome(text)
        assert "Enter to select" not in result
        assert "output" in result

    def test_removes_arrow_navigation(self):
        text = "output\n↑/↓ to navigate\nmore output"
        result = strip_terminal_chrome(text)
        assert "↑/↓" not in result
        assert "output" in result

    def test_real_permission_noise(self):
        """Permission request with Running…, ctrl hints, +N more."""
        text = "\n".join([
            "⏺ Bash(cat /foo/bar)",
            "  Check msg_id files",
            "Running…",
            "ctrl+b ctrl+b",
            "+20 more tool uses",
            "Esc to cancel",
        ])
        result = strip_terminal_chrome(text)
        assert "Check msg_id files" in result
        assert "Running" not in result
        assert "ctrl+b" not in result
        assert "+20 more" not in result
        assert "Esc to cancel" not in result


class TestDetectMode:
    def test_empty_returns_default(self):
        mode = detect_mode("")
        assert mode.label == ""
        assert mode.auto is False

    def test_auto_accept(self):
        mode = detect_mode("some text ⏵⏵ Auto-accept edits more text")
        assert "⏵⏵" in mode.label
        assert mode.auto is True

    def test_plan_mode(self):
        mode = detect_mode("currently in Plan Mode for this task")
        assert mode.label == "⏸ plan mode"
        assert mode.auto is False

    def test_normal_mode(self):
        mode = detect_mode("just normal output with no mode indicators")
        assert mode.label == ""
        assert mode.auto is False

    def test_auto_accept_takes_label(self):
        mode = detect_mode("⏵⏵ Auto-accept edits (4 remaining)")
        assert mode.label == "⏵⏵ Auto-accept edits"
        assert mode.auto is True

    def test_ignores_auto_accept_in_scrollback(self):
        """⏵⏵ in scrollback above last 15 lines should NOT trigger auto mode."""
        scrollback = "\n".join([
            '  "⏵⏵ Auto-accept edits',
            '  87 +  "⏺ Claude Code"',
        ])
        padding = "\n".join([f"line {i}" for i in range(20)])
        bottom = "\n".join([
            "⏺ I need to run a command.",
            "  Can I proceed?",
        ])
        context = scrollback + "\n" + padding + "\n" + bottom
        mode = detect_mode(context)
        assert mode.auto is False
        assert mode.label == ""

    def test_finds_auto_accept_in_last_15_lines(self):
        """⏵⏵ within the last 15 lines is correctly detected."""
        padding = "\n".join([f"line {i}" for i in range(20)])
        bottom = "\n".join([
            "⏺ Working on the task",
            "⏵⏵ Auto-accept edits (3 remaining)",
        ])
        context = padding + "\n" + bottom
        mode = detect_mode(context)
        assert mode.auto is True
        assert "⏵⏵" in mode.label

    def test_ignores_plan_mode_in_scrollback(self):
        """'plan mode' in scrollback body should NOT trigger plan mode."""
        scrollback = "\n".join([
            "⏺ I've written the plan. Use plan mode for non-trivial changes.",
            "  The plan file is at ~/.claude/plan.md",
        ])
        padding = "\n".join([f"line {i}" for i in range(20)])
        bottom = "\n".join([
            "⏺ Done implementing the fix.",
            "  All tests pass.",
        ])
        context = scrollback + "\n" + padding + "\n" + bottom
        mode = detect_mode(context)
        assert mode.label == ""
        assert mode.auto is False


class TestReflow:
    def test_joins_wrapped_lines(self):
        # Line at threshold width should cause next line to be joined
        long_line = "x" * 116  # >= 120 - 5 = 115
        result = reflow_for_telegram(f"{long_line}\ncontinued", 120)
        assert "continued" in result
        assert result.count("\n") == 0  # joined into one line

    def test_preserves_structural_lines(self):
        text = "⏺ Tool call\n  normal line"
        result = reflow_for_telegram(text, 120)
        assert "⏺ Tool call" in result

    def test_preserves_blank_lines(self):
        text = "first\n\nsecond"
        result = reflow_for_telegram(text, 120)
        assert "\n\n" in result

    def test_preserves_bullet_lists(self):
        text = "intro text\n  - item one\n  - item two"
        result = reflow_for_telegram(text, 120)
        assert "- item one" in result
        assert "- item two" in result


class TestExtractActivityLog:
    def test_extracts_markers(self):
        text = "❯ do stuff\n⏺ Tool\n  ⎿ Read file.py\n  ⎿ Wrote output.py"
        result = extract_activity_log(text)
        assert "• Read file.py" in result
        assert "• Wrote output.py" in result

    def test_deduplicates(self):
        text = "❯ go\n  ⎿ Read file.py\n  ⎿ Read file.py\n  ⎿ Read file.py"
        result = extract_activity_log(text)
        assert result.count("• Read file.py") == 1

    def test_max_items(self):
        lines = "❯ go\n" + "\n".join(f"  ⎿ item{i}" for i in range(30))
        result = extract_activity_log(lines, max_items=5)
        assert result.count("•") == 5

    def test_empty_input(self):
        assert extract_activity_log("") == ""

    def test_uses_last_user_block(self):
        text = "❯ first task\n  ⎿ old item\n❯ second task\n  ⎿ new item"
        result = extract_activity_log(text)
        assert "• new item" in result
        assert "old item" not in result


class TestExtractPromptText:
    def test_extracts_between_markers(self):
        text = "some stuff\n⏺ Claude says\n  Hello world\n  How are you?\n❯ user input"
        result = extract_prompt_text(text)
        assert "Claude says" in result
        assert "Hello world" in result
        assert "How are you?" in result

    def test_captures_speech_on_marker_line(self):
        text = "⏺ All tests pass. The fix is deployed."
        result = extract_prompt_text(text)
        assert "All tests pass" in result

    def test_skips_tool_calls_on_marker_line(self):
        text = "⏺ Bash(ls -la)\n  ⎿ output\n\n⏺ Done, all files listed."
        result = extract_prompt_text(text)
        assert "Bash(ls" not in result
        assert "Done, all files listed" in result

    def test_speech_on_marker_plus_continuation(self):
        """Speech starts on ⏺ line and continues on next lines."""
        text = "⏺ Bot restarted successfully.\n  Everything looks good."
        result = extract_prompt_text(text)
        assert "Bot restarted" in result
        assert "Everything looks good" in result

    def test_truncates_long_text(self):
        text = "⏺ Start\n" + "x" * 2000
        result = extract_prompt_text(text, max_chars=100)
        assert len(result) <= 110  # with "..." suffix
        assert result.endswith("...")

    def test_empty_input(self):
        assert extract_prompt_text("") == ""

    def test_stops_at_numbered_option(self):
        text = "⏺ Choose\n  Pick one:\n1. Option A\n2. Option B"
        result = extract_prompt_text(text)
        assert "Pick one:" in result
        assert "Option A" not in result

    def test_filters_tool_output_blocks(self):
        text = "\n".join([
            "⏺ Tool call",
            "  Let me check the file first.",
            "  ⎿ Read src/app.py",
            "    import os",
            "    import sys",
            "",
            "  The file looks good. Should I proceed?",
        ])
        result = extract_prompt_text(text)
        assert "check the file first" in result
        assert "Should I proceed" in result
        assert "Read src/app.py" not in result
        assert "import os" not in result

    def test_filters_multiple_tool_outputs(self):
        text = "\n".join([
            "⏺ Tool call",
            "  I'll read both files.",
            "  ⎿ Read file1.py",
            "    content1",
            "",
            "  ⎿ Read file2.py",
            "    content2",
            "",
            "  Both files look correct.",
        ])
        result = extract_prompt_text(text)
        assert "read both files" in result
        assert "Both files look correct" in result
        assert "content1" not in result
        assert "content2" not in result

    def test_only_speech_when_mixed_with_tools(self):
        text = "\n".join([
            "⏺ Tool call",
            "  Running the tests now.",
            "  ⎿ Bash: pytest -v",
            "    PASSED test_one",
            "    PASSED test_two",
            "",
            "  All 2 tests passed. Ready to commit?",
            "❯ yes",
        ])
        result = extract_prompt_text(text)
        assert "Running the tests now" in result
        assert "Ready to commit" in result
        assert "PASSED" not in result
        assert "pytest" not in result


class TestConvertTablesToBullets:
    def test_simple_table(self):
        table = "| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |"
        result = convert_tables_to_bullets(table)
        assert "- Name: Alice, Age: 30" in result
        assert "- Name: Bob, Age: 25" in result

    def test_non_table_passthrough(self):
        text = "just normal text\nno tables here"
        assert convert_tables_to_bullets(text) == text

    def test_mixed_content(self):
        text = "header\n| A | B |\n|---|---|\n| 1 | 2 |\nnormal"
        result = convert_tables_to_bullets(text)
        assert "header" in result
        assert "- A: 1, B: 2" in result
        assert "normal" in result


class TestWrapLongLines:
    def test_wraps_at_width(self):
        line = "word " * 20  # 100 chars
        result = wrap_long_lines(line.strip(), 50)
        for out_line in result.splitlines():
            assert len(out_line) <= 55  # some slack for word boundaries

    def test_short_lines_unchanged(self):
        assert wrap_long_lines("short", 50) == "short"


class TestHtmlEscape:
    def test_escapes_ampersand(self):
        assert html_escape("a & b") == "a &amp; b"

    def test_escapes_angle_brackets(self):
        assert html_escape("<b>bold</b>") == "&lt;b&gt;bold&lt;/b&gt;"

    def test_plain_text(self):
        assert html_escape("hello") == "hello"


class TestExtractPreview:
    def test_last_n_nonblank(self):
        text = "a\n\nb\n\nc\n"
        assert extract_preview(text, 2) == "b\nc"

    def test_fewer_than_n(self):
        assert extract_preview("only one", 5) == "only one"


class TestExtractCommandBlock:
    def test_extracts_command_after_separator(self):
        text = "\n".join([
            "⏺ Bash command",
            "───────────────",
            "cat /foo/bar",
            "Check msg_id files",
            "❯ user input",
        ])
        result = extract_command_block(text)
        assert "cat /foo/bar" in result
        assert "Check msg_id files" in result
        assert "❯" not in result

    def test_stops_at_do_you_want(self):
        text = "\n".join([
            "───────────────",
            "ls -la /tmp",
            "Do you want to proceed?",
            "more stuff",
        ])
        result = extract_command_block(text)
        assert "ls -la /tmp" in result
        assert "Do you want to proceed" not in result

    def test_no_separator_returns_empty(self):
        text = "just some text\nno separator here"
        result = extract_command_block(text)
        assert result == ""

    def test_uses_last_separator(self):
        text = "\n".join([
            "───────────────",
            "old command",
            "───────────────",
            "new command",
            "❯ prompt",
        ])
        result = extract_command_block(text)
        assert "new command" in result
        assert "old command" not in result

    def test_truncates_long_block(self):
        text = "───────────────\n" + "x" * 600
        result = extract_command_block(text, max_chars=100)
        assert len(result) <= 110
        assert result.endswith("...")

    def test_skips_blank_lines(self):
        text = "\n".join([
            "───────────────",
            "",
            "actual command",
            "",
            "❯ prompt",
        ])
        result = extract_command_block(text)
        assert "actual command" in result

    def test_pre_chrome_text_has_separators(self):
        """Pre-chrome text (before strip_terminal_chrome) preserves separators."""
        pre_chrome = "\n".join([
            "⏺ mcp__traefik__doctor (MCP)",
            "  ⎿  Running…",
            "───────────────────────────────────────────────",
            "",
            "  Tool use: mcp__traefik__doctor",
            "  MCP Server: traefik",
            "",
            "  Do you want to proceed?",
            "  ❯ 1. Yes",
        ])
        result = extract_command_block(pre_chrome)
        assert "Tool use: mcp__traefik__doctor" in result
        assert "MCP Server: traefik" in result
        assert "Do you want to proceed" not in result

    def test_chrome_stripped_text_missing_separators(self):
        """After strip_terminal_chrome, separators are gone → returns empty."""
        chrome_stripped = "\n".join([
            "⏺ mcp__traefik__doctor (MCP)",
            "",
            "  Tool use: mcp__traefik__doctor",
            "  MCP Server: traefik",
            "",
            "  Do you want to proceed?",
            "  ❯ 1. Yes",
        ])
        result = extract_command_block(chrome_stripped)
        assert result == ""
