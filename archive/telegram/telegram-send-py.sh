#!/usr/bin/env bash
# Thin wrapper: calls Python telegram sender with same CLI interface
# Usage: telegram-send-py.sh <type> <session> <window> <message> [tool_name]
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}" && exec uv run --project "${SCRIPT_DIR}/telegram" python -m telegram send "$@"
