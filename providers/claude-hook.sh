#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export AGENT_NOTIFIER_AGENT=claude
exec "${SCRIPT_DIR}/notify.sh"
