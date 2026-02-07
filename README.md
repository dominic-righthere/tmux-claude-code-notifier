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

The installer registers Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) for `UserPromptSubmit`, `Stop`, `Notification`, and `PermissionRequest` events. Each hook invokes `notify.sh`, which writes state files to `~/.local/share/claude-notifier/`.

`status.sh` runs on a tmux polling interval, reads those files, and renders badge counts + a detail line in your status bar. The dashboard (`dashboard.sh`) provides a full overview and lets you jump directly to any session window.

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
