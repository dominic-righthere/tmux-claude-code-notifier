#!/usr/bin/env bash
# Thin wrapper: calls Python telegram bot with same CLI interface
# Usage: telegram-bot.sh start|stop|status|run
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}" && exec uv run --project "${SCRIPT_DIR}/telegram" python -m telegram bot "$@"
