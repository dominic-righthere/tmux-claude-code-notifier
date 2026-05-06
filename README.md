# tmux-agent-notifier

Local tmux status and navigation for coding agents.

This repo started as a Claude Code notifier. The active implementation now tracks Claude Code, OpenAI Codex, and Pi sessions through provider adapters that all write the same local state files under `~/.local/share/agent-notifier/`.

Telegram support is archived under `archive/telegram/` and is not installed or used by default.

## Install

```bash
./install.sh
tmux source ~/.tmux.conf
```

Restart running Claude, Codex, and Pi sessions after install so their hooks or extensions load.

To confirm the installation:

```bash
./doctor.sh
```

Expected healthy output is zero failures. A warning about `~/.local/share/claude-notifier` only means legacy Claude-only state still exists; install migrates useful state and leaves the old directory untouched.

## Tmux Keys

| Key | Action |
| --- | --- |
| `prefix + N` | Open dashboard |
| `prefix + J` | Jump to newest notification |
| `prefix + K` | Cycle tracked agent windows |
| `prefix + M` | Open monitor session with linked agent windows |

## Providers

Claude Code hooks are installed into `~/.claude/settings.json` and call `providers/claude-hook.sh`.

Codex hooks are installed into `~/.codex/hooks.json` and call `providers/codex-hook.sh`. The installer registers `UserPromptSubmit` and `Stop`, and adds `codex_hooks = true` to `~/.codex/config.toml` when it is missing.

Pi uses a TypeScript extension installed to `~/.pi/agent/extensions/agent-notifier.ts`.

All providers call `notify.sh`, which writes `AGENT`, `SESSION`, `WINDOW`, `TYPE`, `MESSAGE`, and timing fields into:

```text
~/.local/share/agent-notifier/active/
~/.local/share/agent-notifier/notifications/
```

If legacy state exists in `~/.local/share/claude-notifier`, install copies useful state into the new directory and leaves the old directory untouched.

## Diagnostics

```bash
./doctor.sh
./test.sh
```

## Uninstall

```bash
./uninstall.sh
tmux source ~/.tmux.conf
```

Uninstall removes this repo's hook entries, the Pi extension it generated, the tmux block, and `~/.local/share/agent-notifier/`. It does not remove archived Telegram code or legacy `~/.local/share/claude-notifier/` state.
