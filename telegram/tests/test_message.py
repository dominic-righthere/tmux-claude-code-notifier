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
        """Bash with separator still uses <code> block.

        raw_context has separators stripped (by strip_terminal_chrome),
        raw_pre_chrome preserves them — extract_command_block uses raw_pre_chrome.
        """
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            raw_context="\n".join([
                "⏺ Bash(ls -la)",
                "ls -la /tmp",
                "❯ proceed?",
            ]),
            raw_pre_chrome="\n".join([
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

    def test_single_option_returns_empty(self):
        """A single numbered match is a false positive — require >= 2."""
        raw = "⏺ Here's the summary:\n  3.  — 2 new tests\n  Done."
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
        _, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS


class TestMCPToolPermissionPrompt:
    """Reproduce the exact MCP tool permission prompt format."""

    # Pre-chrome text (before strip_terminal_chrome) — separators intact
    RAW_PRE_CHROME = "\n".join([
        "⏺ mcp__traefik__doctor (MCP)",
        "  ⎿  Running…",
        "───────────────────────────────────────────────",
        "",
        "  Tool use: mcp__traefik__doctor",
        "  MCP Server: traefik",
        "",
        "  Do you want to proceed?",
        "  ❯ 1. Yes",
        "    2. Yes, and don't ask again for mcp__traefik__doctor",
        "    3. No",
        "Esc to cancel · Tab to amend",
    ])

    # raw_context (after strip_terminal_chrome) — separator + hints removed
    RAW_CONTEXT = "\n".join([
        "⏺ mcp__traefik__doctor (MCP)",
        "",
        "  Tool use: mcp__traefik__doctor",
        "  MCP Server: traefik",
        "",
        "  Do you want to proceed?",
        "  ❯ 1. Yes",
        "    2. Yes, and don't ask again for mcp__traefik__doctor",
        "    3. No",
    ])

    def _make_ctx(self) -> SendContext:
        return SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="mcp__traefik__doctor",
            project_name="infra",
            raw_context=self.RAW_CONTEXT,
            raw_pre_chrome=self.RAW_PRE_CHROME,
        )

    def test_options_extracted(self):
        """Should detect the 3 numbered options from pre-chrome text."""
        options = _extract_options(self.RAW_CONTEXT, self.RAW_PRE_CHROME)
        assert len(options) == 3
        assert options[0] == ("1", "Yes")
        assert "don't ask again" in options[1][1]
        assert options[2] == ("3", "No")

    def test_keyboard_is_options_style(self):
        """Should produce OPTIONS keyboard, not APPROVE_DENY."""
        ctx = self._make_ctx()
        _, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS

    def test_body_shows_command_block(self):
        """Body should contain tool description in <code>, not scrollback."""
        ctx = self._make_ctx()
        payload = build_message(ctx)
        assert "<code>" in payload.text
        assert "mcp__traefik__doctor" in payload.text
        assert "MCP Server: traefik" in payload.text
        # Should NOT fall back to blockquote
        assert "<blockquote" not in payload.text

    def test_bash_permission_with_yes_no_options(self):
        """Bash permission with real Yes/No options should get OPTIONS, not APPROVE_DENY."""
        raw = "\n".join([
            "⏺ Bash(rm -f /tmp/test.jsonl)",
            "  ⎿  Running…",
            "───────────────────────────────────────────────",
            "",
            "  Bash command",
            "  rm -f /tmp/test.jsonl",
            "",
            "  Do you want to proceed?",
            "  ❯ 1. Yes",
            "    2. Yes, and always allow access to tmp/ from this project",
            "    3. No",
            "Esc to cancel · Tab to amend",
        ])
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Bash",
            raw_context=raw,
            raw_pre_chrome=raw,
        )
        _, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS

    def test_exit_plan_mode_picks_up_options(self):
        """ExitPlanMode with numbered options should get OPTIONS keyboard."""
        raw = "\n".join([
            "⏺ Here is my plan:",
            "  Verification",
            "  1. Should print 10 pass results",
            "  2. Check has no leftover test files",
            "  3. Run test.sh to confirm existing tests still pass",
            "  4. Run pytest to confirm Python tests still pass",
            "  Yes, auto-accept edits",
            "  Yes, manually approve edits",
            "  ~/.claude/plans/elegant-spinning-pizza.md",
        ])
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="ExitPlanMode",
            raw_context=raw,
            raw_pre_chrome=raw,
        )
        _, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS

    def test_unnumbered_permission_choices(self):
        """Edit/Bash permission prompts with unnumbered Yes/No choices."""
        raw = "\n".join([
            "⏺ Update(telegram/tmux.py)",
            "  ⎿  Added 2 lines, removed 2 lines",
            " Do you want to make this edit to tmux.py?",
            "    Yes (Recommended)",
            "    Yes, allow all edits during this session",
            "    No",
            "",
            "       amend",
        ])
        options = _extract_options("", raw)
        assert len(options) == 3
        assert options[0] == ("1", "Yes (Recommended)")
        assert options[1] == ("2", "Yes, allow all edits during this session")
        assert options[2] == ("3", "No")

    def test_unnumbered_permission_with_cursor(self):
        """Permission prompt with cursor marker on selected option."""
        raw = "\n".join([
            "⏺ Bash(rm -f /tmp/test.txt)",
            " Do you want to run this command?",
            "    ❯ Yes (Recommended)",
            "    Yes, and don't ask again for this session",
            "    No",
        ])
        options = _extract_options("", raw)
        assert len(options) == 3
        assert options[0] == ("1", "Yes (Recommended)")
        assert options[1][1].startswith("Yes, and")
        assert options[2] == ("3", "No")

    def test_unnumbered_permission_keyboard_is_options(self):
        """Unnumbered permission choices should produce OPTIONS keyboard."""
        raw = "\n".join([
            "⏺ Update(models.py)",
            " Do you want to make this edit to models.py?",
            "    Yes (Recommended)",
            "    Yes, allow all edits during this session",
            "    No",
        ])
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="Edit",
            raw_context="",
            raw_pre_chrome=raw,
        )
        _, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS

    def test_ask_user_question_with_meta_options_below_separator(self):
        """Options 1-4 above separator, meta options 5-6 below — should capture 1-4."""
        pre_chrome = "\n".join([
            "⏺ Good question. Let me clarify.",
            "☐ Auth flow",
            "What kind of login flow?",
            "❯ 1. CloudFormation Quick Create link",
            "     Generate a URL that opens AWS Console.",
            "  2. AWS SSO / IAM Identity Center",
            "     Show a device code, user authenticates via SSO.",
            "  3. Manual key entry in UI",
            "     User pastes an Access Key ID + Secret.",
            "  4. Type something.",
            "───────────────────────────────────────",
            "  5. Chat about this",
            "  6. Skip interview and plan immediately",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ])
        options = _extract_options("", pre_chrome)
        assert len(options) == 4
        assert options[0] == ("1", "CloudFormation Quick Create link")
        assert options[1] == ("2", "AWS SSO / IAM Identity Center")
        assert options[2] == ("3", "Manual key entry in UI")
        assert options[3] == ("4", "Type something.")

    def test_cross_separator_single_meta_option(self):
        """4 options above separator, 1 meta option below — should extract all 5."""
        pre_chrome = "\n".join([
            "⏺ Which database driver should we use?",
            "☐ Database",
            "Which driver?",
            "❯ 1. PostgreSQL native (pg)",
            "     Direct connection, best performance.",
            "  2. Prisma ORM",
            "     Type-safe queries, migrations built-in.",
            "  3. Drizzle ORM",
            "     Lightweight, SQL-like syntax.",
            "  4. Raw SQL with connection pool",
            "───────────────────────────────────────",
            "  5. Chat about this",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ])
        options = _extract_options("", pre_chrome)
        assert len(options) == 4
        assert options[0] == ("1", "PostgreSQL native (pg)")
        assert options[1] == ("2", "Prisma ORM")
        assert options[2] == ("3", "Drizzle ORM")
        assert options[3] == ("4", "Raw SQL with connection pool")

    def test_option_label_truncation(self):
        """Option labels > 30 chars are truncated with ellipsis."""
        raw = "\n".join([
            "⏺ Pick one:",
            "  1. Short",
            "  2. This is a very long option label that exceeds thirty characters",
        ])
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            raw_context=raw,
        )
        kb, style = build_keyboard(ctx)
        assert style == KeyboardStyle.OPTIONS
        labels = [b.text for row in kb.inline_keyboard for b in row]
        # "2. This is a very long option..." should be truncated
        long_label = [l for l in labels if l.startswith("2.")][0]
        assert len(long_label) <= 30
        assert long_label.endswith("…")
        # Short label should be unchanged
        short_label = [l for l in labels if l.startswith("1.")][0]
        assert short_label == "1. Short"

    def test_body_without_pre_chrome_falls_back(self):
        """Without raw_pre_chrome, no separator → fallback to blockquote."""
        ctx = SendContext(
            event_type=EventType.WAITING,
            session="main",
            window="1",
            tool_name="mcp__traefik__doctor",
            raw_context=self.RAW_CONTEXT,
            # no raw_pre_chrome — simulates the bug
        )
        payload = build_message(ctx)
        # No separator in raw_context → extract_command_block returns ""
        # Falls back to extract_prompt_text → blockquote (not <code> body block)
        assert "<blockquote expandable>" in payload.text
