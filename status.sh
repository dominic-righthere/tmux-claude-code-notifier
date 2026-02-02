#!/usr/bin/env bash
# Claude Code Notifier — status bar widget
# Outputs per-type badges and toggles a second status line with details
DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"

WORKING=0
IDLE=0
WAITING=0
FINISHED=0

# Count active entries by type (working vs idle)
if [ -d "$ACTIVE_DIR" ]; then
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            case "$line" in
                TYPE=idle) IDLE=$(( IDLE + 1 )); break ;;
                TYPE=*) WORKING=$(( WORKING + 1 )); break ;;
            esac
        done < "$f"
    done
fi

# Count notification entries by type
if [ -d "$NOTIF_DIR" ]; then
    for f in "$NOTIF_DIR"/*; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            case "$line" in
                TYPE=waiting) WAITING=$(( WAITING + 1 )); break ;;
                TYPE=finished) FINISHED=$(( FINISHED + 1 )); break ;;
                TYPE=*) FINISHED=$(( FINISHED + 1 )); break ;;
            esac
        done < "$f"
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

# Toggle second status line
if [ "$TOTAL" -gt 0 ]; then
    # Build detail string for the second line
    DETAILS=""

    # Active entries (working + idle)
    if [ -d "$ACTIVE_DIR" ]; then
        for f in "$ACTIVE_DIR"/*; do
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
            if [ -n "$_sess" ]; then
                case "$_type" in
                    idle) DETAILS="${DETAILS} ○ ${_sess}:${_win} ${_msg} |" ;;
                    *)    DETAILS="${DETAILS} ⟳ ${_sess}:${_win} ${_msg} |" ;;
                esac
            fi
        done
    fi

    # Notification entries (waiting + finished)
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
            if [ -n "$_sess" ]; then
                case "$_type" in
                    waiting)  DETAILS="${DETAILS} ⏳ ${_sess}:${_win} ${_msg} |" ;;
                    *)        DETAILS="${DETAILS} ● ${_sess}:${_win} ${_msg} |" ;;
                esac
            fi
        done
    fi

    # Remove trailing " |"
    DETAILS="${DETAILS% |}"

    tmux set -g status 2 2>/dev/null
    tmux set -g 'status-format[1]' "#[align=left]${DETAILS}" 2>/dev/null
else
    tmux set -g status on 2>/dev/null
fi
