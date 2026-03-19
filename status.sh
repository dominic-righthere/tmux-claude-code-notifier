#!/usr/bin/env bash
# Claude Code Notifier — status bar widget
# Outputs per-type badges and manages a second status line with details
DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"

# Persistent second status bar: shown always unless status2.disabled flag exists
STATUS2_PERSISTENT=1
[ -f "${DATA_DIR}/status2.disabled" ] && STATUS2_PERSISTENT=0

NOW="$(date +%s)"

WORKING=0
IDLE=0
WAITING=0
FINISHED=0

# Count active entries by type (working vs idle), skip aged-out
if [ -d "$ACTIVE_DIR" ]; then
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] || continue
        _type="" _ts=""
        while IFS= read -r line; do
            case "$line" in
                TYPE=*) _type="${line#TYPE=}" ;;
                TIMESTAMP=*) _ts="${line#TIMESTAMP=}" ;;
            esac
        done < "$f"
        # Skip aged-out entries
        if [ -n "$_ts" ]; then
            _age=$(( NOW - _ts ))
            [ "$_type" = "working" ] && [ "$_age" -gt 3600 ] && continue   # 1h
            [ "$_type" = "idle" ] && [ "$_age" -gt 43200 ] && continue     # 12h
        fi
        case "$_type" in
            idle) IDLE=$(( IDLE + 1 )) ;;
            *)    WORKING=$(( WORKING + 1 )) ;;
        esac
    done
fi

# Count notification entries by type, skip aged-out
if [ -d "$NOTIF_DIR" ]; then
    for f in "$NOTIF_DIR"/*; do
        [ -f "$f" ] || continue
        _type="" _ts=""
        while IFS= read -r line; do
            case "$line" in
                TYPE=*) _type="${line#TYPE=}" ;;
                TIMESTAMP=*) _ts="${line#TIMESTAMP=}" ;;
            esac
        done < "$f"
        # Skip aged-out entries
        if [ -n "$_ts" ]; then
            _age=$(( NOW - _ts ))
            [ "$_type" = "finished" ] && [ "$_age" -gt 21600 ] && continue  # 6h
            [ "$_type" = "waiting" ] && [ "$_age" -gt 86400 ] && continue   # 24h
        fi
        case "$_type" in
            waiting)  WAITING=$(( WAITING + 1 )) ;;
            finished) FINISHED=$(( FINISHED + 1 )) ;;
            *)        FINISHED=$(( FINISHED + 1 )) ;;
        esac
    done
fi

TOTAL=$(( WORKING + IDLE + WAITING + FINISHED ))

# Build main badge output
OUTPUT=""
if [ "$WORKING" -gt 0 ]; then
    OUTPUT="${OUTPUT}⟳${WORKING} "
fi
if [ "$WAITING" -gt 0 ]; then
    OUTPUT="${OUTPUT}⏳${WAITING} "
fi
if [ "$FINISHED" -gt 0 ]; then
    OUTPUT="${OUTPUT}●${FINISHED} "
fi
if [ "$IDLE" -gt 0 ]; then
    OUTPUT="${OUTPUT}○${IDLE} "
fi

printf '%s' "$OUTPUT"

# Build notification detail line (waiting + finished entries)
DETAIL=""
if [ "$WAITING" -gt 0 ] || [ "$FINISHED" -gt 0 ]; then
    if [ -d "$NOTIF_DIR" ]; then
        for f in "$NOTIF_DIR"/*; do
            [ -f "$f" ] || continue
            _sess="" _win="" _msg="" _type=""
            while IFS= read -r line; do
                case "$line" in
                    SESSION=*) _sess="${line#SESSION=}" ;;
                    WINDOW=*) _win="${line#WINDOW=}" ;;
                    MESSAGE=*) _msg="${line#MESSAGE=}" ;;
                    TYPE=*) _type="${line#TYPE=}" ;;
                esac
            done < "$f"

            entry=""
            if [ "$_type" = "waiting" ] && [ -n "$_sess" ]; then
                _msg="${_msg#Waiting: }"
                _msg="${_msg#Waiting}"
                if [ -n "$_msg" ]; then
                    entry="⏳ ${_sess}:${_win} — Waiting: ${_msg}"
                else
                    entry="⏳ ${_sess}:${_win} — Waiting for input"
                fi
            elif [ "$_type" = "finished" ] && [ -n "$_sess" ]; then
                entry="● ${_sess}:${_win} — Task complete"
            fi

            if [ -n "$entry" ]; then
                if [ -n "$DETAIL" ]; then
                    DETAIL="${DETAIL} | ${entry}"
                else
                    DETAIL=" ${entry}"
                fi
            fi
        done
    fi
fi

# Manage second status bar:
# - Persistent mode (default): always show status 2 when there are any sessions
# - Non-persistent (status2.disabled flag): only show when actionable notifications exist
if [ "$STATUS2_PERSISTENT" -eq 1 ] && [ "$TOTAL" -gt 0 ]; then
    tmux set -g status 2 2>/dev/null
    tmux set -g 'status-format[1]' "#[align=left]${OUTPUT}${DETAIL}" 2>/dev/null
elif [ -n "$DETAIL" ]; then
    tmux set -g status 2 2>/dev/null
    tmux set -g 'status-format[1]' "#[align=left]${OUTPUT}${DETAIL}" 2>/dev/null
else
    tmux set -g status on 2>/dev/null
fi
