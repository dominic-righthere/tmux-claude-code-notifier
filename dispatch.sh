#!/usr/bin/env bash
# Optional backend dispatcher. No backends are enabled by default.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TYPE="${1:-}"
SESSION="${2:-}"
WINDOW="${3:-}"
MESSAGE="${4:-}"

CONF="${DATA_DIR}/backends.conf"
[ -f "$CONF" ] || exit 0

while IFS='=' read -r name cmd; do
    case "$name" in
        ''|\#*) continue ;;
    esac
    [ -n "$cmd" ] || continue
    cmd="${cmd//\$\{SCRIPT_DIR\}/$SCRIPT_DIR}"
    [ -x "$cmd" ] || continue
    "$cmd" "$TYPE" "$SESSION" "$WINDOW" "$MESSAGE" &
done < "$CONF"
