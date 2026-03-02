"""Unit tests for message construction."""

from telegram.message import _extract_options, build_header, build_keyboard, build_message
from telegram.models import EventType, KeyboardStyle, ModeInfo, SendContext


class TestBuildHeader:
    def test_waiting_with_tool(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            project_name="myproject",
        )
        header = build_header(ctx)
        assert "Permission Request" in header
        assert "main:1" in header
        assert "myproject" in header
        assert "Bash" in header

    def test_waiting_without_tool(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
        )
        header = build_header(ctx)
        assert "Waiting for Input" in header

    def test_finished(self):
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="dev",
            window="0",
            project_name="webapp",
        )
        header = build_header(ctx)
        assert "Task Finished" in header
        assert "dev:0" in header
        assert "webapp" in header

    def test_prompt(self):
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
        )
        header = build_header(ctx)
        assert "Working" in header

    def test_mode_shown(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="s",
            window="0",
            mode=ModeInfo(label="⏸ plan mode"),
        )
        header = build_header(ctx)
        assert "⏸ plan mode" in header


class TestBuildKeyboard:
    def test_waiting_with_tool_gets_approve_deny(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
        )
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.APPROVE_DENY
        buttons = [b.text for row in kb.inline_keyboard for b in row]
        assert "✅ Approve" in buttons
        assert "❌ Deny" in buttons
        assert "📋 View" in buttons

    def test_waiting_without_tool_gets_view_reply(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
        )
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.VIEW_REPLY
        buttons = [b.text for row in kb.inline_keyboard for b in row]
        assert "💬 Reply" in buttons

    def test_finished_gets_view_reply(self):
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="main",
            window="1",
        )
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.VIEW_REPLY
        buttons = [b.text for row in kb.inline_keyboard for b in row]
        assert "💬 Send" in buttons

    def test_auto_mode_skips_buttons(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            mode=ModeInfo(label="⏵⏵ Auto-accept", auto=True),
        )
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.VIEW_ONLY

    def test_options_detected(self):
        raw = "⏺ Choose one:\n  1. Option A\n  2. Option B\n  3. Option C"
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            raw_context=raw,
        )
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS
        # Should have 3 option rows + 1 view row
        assert len(kb.inline_keyboard) == 4

    def test_callback_data_format(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="my-session",
            window="3",
            tool_name="Read",
        )
        kb, _ = build_keyboard(ctx)
        approve_btn = kb.inline_keyboard[0][0]
        assert approve_btn.callback_data == "approve:my-session:3"


class TestBuildMessage:
    def test_full_pipeline(self):
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            project_name="myapp",
            raw_context="⏺ I need to run a command\nCan I execute `ls -la`?",
        )
        payload = build_message(ctx)
        assert "Permission Request" in payload.text
        assert "main:1" in payload.text
        assert len(payload.text) <= 4096

    def test_prompt_type(self):
        ctx = SendContext(
            event_type=EventType.PROMPT,
            session="main",
            window="1",
            message="Implement the login page",
        )
        payload = build_message(ctx)
        assert "Working" in payload.text
        assert "Implement the login page" in payload.text

    def test_truncation(self):
        ctx = SendContext(
            event_type=EventType.FINISHED,
            session="s",
            window="0",
            raw_context="x" * 5000,
        )
        payload = build_message(ctx)
        assert len(payload.text) <= 4096


class TestBuildBodyPermissionFallback:
    def test_permission_no_separator_falls_back_to_speech(self):
        """ExitPlanMode with ⏺ speech shows plan context in blockquote."""
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="ExitPlanMode",
            project_name="myapp",
            raw_context="\n".join([
                "⏺ Here is my implementation plan:",
                "  1. Update the config parser",
                "  2. Add validation logic",
                "  3. Write tests",
                "",
                "  Ready to proceed?",
            ]),
        )
        payload = build_message(ctx)
        assert "Permission Request" in payload.text
        assert "<blockquote expandable>" in payload.text
        assert "implementation plan" in payload.text

    def test_permission_with_separator_unchanged(self):
        """Bash with separator still uses <code> block."""
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            raw_context="\n".join([
                "⏺ Bash(ls -la)",
                "───────────────",
                "ls -la /tmp",
                "❯ proceed?",
            ]),
        )
        payload = build_message(ctx)
        assert "<code>" in payload.text
        assert "ls -la /tmp" in payload.text
        assert "<blockquote" not in payload.text


class TestExtractOptions:
    def test_basic_options(self):
        raw = "⏺ Choose:\n  1. Option A\n  2. Option B"
        options = _extract_options(raw)
        assert options == [("1", "Option A"), ("2", "Option B")]

    def test_ignores_plan_section_numbers(self):
        """Plan content with numbered items should NOT be picked up as options."""
        raw = "\n".join([
            "⏺ Here is my plan:",
            "  1. Permission request handling",
            "  2. View output improvements",
            "  3. Plan mode approval",
            "",
            "  Do you approve this plan?",
            "  1. Yes, clear context and start",
            "  2. Yes, keep context and start",
            "  3. No, let me adjust",
        ])
        options = _extract_options(raw)
        # Should pick up the actual prompt options at the bottom, not plan items
        assert len(options) == 3
        assert options[0][1] == "Yes, clear context and start"
        assert options[2][1] == "No, let me adjust"

    def test_options_with_cursor(self):
        raw = "⏺ Pick one:\n  ❯ 1. First\n  2. Second"
        options = _extract_options(raw)
        assert options == [("1", "First"), ("2", "Second")]

    def test_no_options(self):
        raw = "⏺ Just a question with no numbered options."
        options = _extract_options(raw)
        assert options == []

    def test_strips_hint_lines(self):
        raw = "⏺ Choose:\n  1. Yes\n  2. No\nEsc to cancel"
        options = _extract_options(raw)
        assert len(options) == 2
        assert options[0] == ("1", "Yes")

    def test_max_4_options(self):
        raw = "⏺ Pick:\n  1. A\n  2. B\n  3. C\n  4. D"
        options = _extract_options(raw)
        assert len(options) == 4

    def test_non_indented_numbers_ignored(self):
        """Non-indented numbered items should not be captured."""
        raw = "⏺ Summary:\n1. Not an option\n2. Also not\n  1. Real option\n  2. Real option 2"
        options = _extract_options(raw)
        assert len(options) == 2
        assert options[0][1] == "Real option"

    def test_separator_scoping(self):
        """Options after separator found, plan items above ignored."""
        pre_chrome = "\n".join([
            "⏺ Here is my plan:",
            "  1. Fix the parser",
            "  2. Add validation",
            "  3. Manual: trigger the flow",
            "  4. Visual: pane looks correct",
            "───────────────────────────────",
            "  1. Yes, clear context and start",
            "  2. Yes, auto-accept and start",
            "  3. No, let me adjust",
        ])
        # raw_context has separators stripped (simulating strip_terminal_chrome)
        raw = "\n".join([
            "⏺ Here is my plan:",
            "  1. Fix the parser",
            "  2. Add validation",
            "  3. Manual: trigger the flow",
            "  4. Visual: pane looks correct",
            "  1. Yes, clear context and start",
            "  2. Yes, auto-accept and start",
            "  3. No, let me adjust",
        ])
        options = _extract_options(raw, pre_chrome)
        assert len(options) == 3
        assert options[0][1] == "Yes, clear context and start"
        assert options[1][1] == "Yes, auto-accept and start"
        assert options[2][1] == "No, let me adjust"

    def test_separator_scoping_real_exitplanmode(self):
        """Reproduce the ExitPlanMode case: plan verification items vs actual options."""
        pre_chrome = "\n".join([
            "⏺ I've written a plan. Here's the verification checklist:",
            "  1. Permission request handling fixes",
            "  2. View output improvements",
            "  3. Manual: trigger ExitPlanMode notification",
            "  4. Visual: pane shows correct buttons",
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            "  1. Yes, clear context and start (Recommended)",
            "  2. Yes, keep context and start",
            "  3. No, let me adjust the plan",
            "Enter to select · ↑/↓ to navigate",
        ])
        raw = "\n".join([
            "⏺ I've written a plan. Here's the verification checklist:",
            "  1. Permission request handling fixes",
            "  2. View output improvements",
            "  3. Manual: trigger ExitPlanMode notification",
            "  4. Visual: pane shows correct buttons",
            "  1. Yes, clear context and start (Recommended)",
            "  2. Yes, keep context and start",
            "  3. No, let me adjust the plan",
        ])
        options = _extract_options(raw, pre_chrome)
        assert len(options) == 3
        assert options[0][1] == "Yes, clear context and start (Recommended)"
        assert "Manual" not in str(options)
        assert "Visual" not in str(options)

    def test_ask_user_question_cleared(self):
        """AskUserQuestion tool_name is cleared — shows as input request, not permission."""
        # When AskUserQuestion tool_name is cleared in send.py, ctx.tool_name=""
        raw = "⏺ Which approach?\n  1. Option A\n  2. Option B"
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="",  # cleared by send.py
            raw_context=raw,
        )
        header = build_header(ctx)
        assert "Waiting for Input" in header
        assert "Permission Request" not in header
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS
