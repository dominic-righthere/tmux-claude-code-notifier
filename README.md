# tmux-claude-code-notifier

Real-time tmux status bar notifications for Claude Code sessions.

## Requirements

- tmux
- [jq](https://jqlang.github.io/jq/) — `brew install jq` / `apt install jq`

## Install

```sh
git clone https://github.com/dominic-righthere/tmux-claude-code-notifier.git
cd tmux-claude-code-notifier
./install.sh
tmux source ~/.tmux.conf
```

Restart any running Claude Code sessions so hooks take effect.

## Keybindings

| Key | Action |
|-----|--------|
| `prefix + N` | Open notification dashboard |
| `prefix + J` | Jump to most recent notification |
| `prefix + K` | Cycle through Claude Code sessions |

## Status Icons

| Icon | Meaning |
|------|---------|
| `⟳` | Working — Claude is processing |
| `⏳` | Waiting — needs input (tool name shown) |
| `●` | Finished — task complete |
| `○` | Idle — session open, not active |

## How It Works

The installer registers Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) for all 7 lifecycle events (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `Stop`, `Notification`, `PermissionRequest`). Each hook invokes `notify.sh`, which writes state files to `~/.local/share/claude-notifier/`.

`status.sh` runs on a tmux polling interval, reads those files, and renders badge counts + a detail line in your status bar. The dashboard (`dashboard.sh`) provides a full overview and lets you jump directly to any session window.

## Telegram Bot (Optional)

Control Claude Code sessions from your phone — get notifications, view output, approve permissions.

### Setup

```sh
./telegram-setup.sh
```

The wizard walks you through creating a bot via BotFather and linking your Telegram account.

### Start the bot daemon

```sh
./telegram.sh start    # background daemon
./telegram.sh stop     # stop daemon
./telegram.sh status   # check if running
./telegram.sh run      # foreground (debug)
```

Notifications (permission requests, task finished) are sent automatically without the daemon. The daemon enables interactive commands.

### Commands

| Command | Action |
|---------|--------|
| `/s` | Interactive session list with inline buttons |
| `/v <n>` | View last 200 lines of pane output |
| `/a <n>` | Approve — send `y` + Enter to pane |
| `/d <n>` | Deny — send `n` + Enter to pane |
| `/send <n> <msg>` | Send arbitrary text to pane |
| `/run <n> <cmd>` | Run command in adjacent tmux window |
| `/restart [ver]` | Restart all Claude Code sessions (optional version) |
| `/doctor` | Run diagnostics |
| `/help` | Show available commands |

Permission request notifications include inline **Approve** / **Deny** / **View** buttons. When Claude presents numbered options, those appear as individual buttons too (max 4).

## Uninstall

```sh
./uninstall.sh
tmux source ~/.tmux.conf
```

<details>
<summary>Manual uninstall</summary>

1. Remove the `# claude-notifier-begin` ... `# claude-notifier-end` block from `~/.tmux.conf`
2. Remove the hook entries from `~/.claude/settings.json`
3. `rm -rf ~/.local/share/claude-notifier`
4. `tmux source ~/.tmux.conf`

</details>
