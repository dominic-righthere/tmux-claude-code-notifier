#!/usr/bin/env bash
# Claude Code Notifier — popup dashboard
# Shows working/waiting/finished Claude sessions, allows direct window switching
set -uo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"

NOW="$(date +%s)"

relative_time() {
    local ts="$1"
    local diff=$(( NOW - ts ))
    if [ "$diff" -lt 60 ]; then
        printf '%ds' "$diff"
    elif [ "$diff" -lt 3600 ]; then
        printf '%dm' "$(( diff / 60 ))"
    elif [ "$diff" -lt 86400 ]; then
        printf '%dh' "$(( diff / 3600 ))"
    else
        printf '%dd' "$(( diff / 86400 ))"
    fi
}

parse_file() {
    local file="$1" prefix="$2"
    local _session="" _window="" _window_name="" _message="" _type="" _timestamp=""
    while IFS= read -r line; do
        local key="${line%%=*}"
        local val="${line#*=}"
        case "$key" in
            SESSION) _session="$val" ;;
            WINDOW) _window="$val" ;;
            WINDOW_NAME) _window_name="$val" ;;
            MESSAGE) _message="$val" ;;
            TYPE) _type="$val" ;;
            TIMESTAMP) _timestamp="$val" ;;
        esac
    done < "$file" || true
    [ -z "$_session" ] && return 1
    eval "${prefix}_SESSION=\$_session"
    eval "${prefix}_WINDOW=\$_window"
    eval "${prefix}_WINDOW_NAME=\$_window_name"
    eval "${prefix}_MESSAGE=\$_message"
    eval "${prefix}_TYPE=\$_type"
    eval "${prefix}_TIMESTAMP=\$_timestamp"
    return 0
}

# Arrays to hold entry data (indexed by entry number)
declare -a E_SESSION=() E_WINDOW=() E_WNAME=() E_MSG=() E_TS=() E_CAT=()
INDEX=0

# Column width tracking for alignment
MAX_SESSWIN=0
MAX_WNAME=0

# Remove stale files (sessions/windows that no longer exist in tmux, or too old)
cleanup_stale() {
    for f in "$ACTIVE_DIR"/* "$NOTIF_DIR"/*; do
        [ -f "$f" ] || continue
        local sess="" win="" ts="" type=""
        while IFS= read -r line; do
            case "$line" in
                SESSION=*) sess="${line#SESSION=}" ;;
                WINDOW=*) win="${line#WINDOW=}" ;;
                TIMESTAMP=*) ts="${line#TIMESTAMP=}" ;;
                TYPE=*) type="${line#TYPE=}" ;;
            esac
        done < "$f" || true
        # If session doesn't exist, remove file
        if [ -n "$sess" ] && ! tmux has-session -t "$sess" 2>/dev/null; then
            rm -f "$f"
        # If window doesn't exist in session, remove file
        elif [ -n "$sess" ] && [ -n "$win" ] && ! tmux list-windows -t "$sess" -F '#{window_index}' 2>/dev/null | grep -qx "$win"; then
            rm -f "$f"
        # Remove stale entries based on age: working > 1h, idle > 12h
        elif [ -n "$ts" ]; then
            local age=$(( NOW - ts ))
            if [ "$type" = "working" ] && [ "$age" -gt 3600 ]; then
                rm -f "$f"
            elif [ "$type" = "idle" ] && [ "$age" -gt 43200 ]; then
                rm -f "$f"
            fi
        fi
    done
}

load_entries() {
    # Prune stale sessions before loading
    cleanup_stale
    E_SESSION=() E_WINDOW=() E_WNAME=() E_MSG=() E_TS=() E_CAT=()
    INDEX=0
    MAX_SESSWIN=0
    MAX_WNAME=0

    # Read active entries (working + idle)
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] || continue
        if parse_file "$f" "P"; then
            INDEX=$(( INDEX + 1 ))
            E_SESSION[$INDEX]="$P_SESSION"
            E_WINDOW[$INDEX]="$P_WINDOW"
            E_WNAME[$INDEX]="$P_WINDOW_NAME"
            E_MSG[$INDEX]="$P_MESSAGE"
            E_TS[$INDEX]="$P_TIMESTAMP"
            case "$P_TYPE" in
                idle) E_CAT[$INDEX]="idle" ;;
                *)    E_CAT[$INDEX]="working" ;;
            esac
        fi
    done

    # Read notification entries — split into waiting and finished
    for f in "$NOTIF_DIR"/*; do
        [ -f "$f" ] || continue
        if parse_file "$f" "P"; then
            INDEX=$(( INDEX + 1 ))
            E_SESSION[$INDEX]="$P_SESSION"
            E_WINDOW[$INDEX]="$P_WINDOW"
            E_WNAME[$INDEX]="$P_WINDOW_NAME"
            E_MSG[$INDEX]="$P_MESSAGE"
            E_TS[$INDEX]="$P_TIMESTAMP"
            case "$P_TYPE" in
                waiting) E_CAT[$INDEX]="waiting" ;;
                *)       E_CAT[$INDEX]="finished" ;;
            esac
        fi
    done

    # Calculate max column widths
    for i in $(seq 1 "$INDEX"); do
        local sw="${E_SESSION[$i]}:${E_WINDOW[$i]}"
        [ "${#sw}" -gt "$MAX_SESSWIN" ] && MAX_SESSWIN="${#sw}"
        [ "${#E_WNAME[$i]}" -gt "$MAX_WNAME" ] && MAX_WNAME="${#E_WNAME[$i]}"
    done

    # Set minimum widths
    [ "$MAX_SESSWIN" -lt 6 ] && MAX_SESSWIN=6
    [ "$MAX_WNAME" -lt 4 ] && MAX_WNAME=4
}

icon_for() {
    case "$1" in
        working) printf '⟳' ;;
        waiting) printf '⏳' ;;
        finished) printf '●' ;;
        idle)    printf '○' ;;
    esac
}

color_for() {
    case "$1" in
        working)  printf '33' ;;
        waiting)  printf '35' ;;
        finished) printf '31' ;;
        idle)     printf '90' ;;
    esac
}

render_entry_wide() {
    local i="$1" cat="$2"
    local clr icon sesswin wname msg rel
    clr="$(color_for "$cat")"
    icon="$(icon_for "$cat")"
    sesswin="${E_SESSION[$i]}:${E_WINDOW[$i]}"
    wname="${E_WNAME[$i]}"
    msg="${E_MSG[$i]}"
    rel="$(relative_time "${E_TS[$i]}")"

    # Truncate message if too long
    [ "${#msg}" -gt 30 ] && msg="${msg:0:27}..."

    # Cap wname at 16 chars for wide
    [ "${#wname}" -gt 16 ] && wname="${wname:0:16}"
    local wname_w=$MAX_WNAME
    [ "$wname_w" -gt 16 ] && wname_w=16

    printf '  \033[%sm%-2s\033[0m %s  %-*s  %-*s  %-30s  %s\n' \
        "$clr" "$i" "$icon" "$MAX_SESSWIN" "$sesswin" "$wname_w" "$wname" "$msg" "$rel"
}

render_entry_medium() {
    local i="$1" cat="$2"
    local clr icon sesswin wname msg rel
    clr="$(color_for "$cat")"
    icon="$(icon_for "$cat")"
    sesswin="${E_SESSION[$i]}:${E_WINDOW[$i]}"
    wname="${E_WNAME[$i]}"
    msg="${E_MSG[$i]}"
    rel="$(relative_time "${E_TS[$i]}")"

    # Truncate message for medium width
    [ "${#msg}" -gt 18 ] && msg="${msg:0:15}..."

    # Cap wname at 12 chars for medium
    [ "${#wname}" -gt 12 ] && wname="${wname:0:12}"
    local wname_w=$MAX_WNAME
    [ "$wname_w" -gt 12 ] && wname_w=12

    printf '  \033[%sm%-2s\033[0m %s  %-*s  %-*s  %-18s  %s\n' \
        "$clr" "$i" "$icon" "$MAX_SESSWIN" "$sesswin" "$wname_w" "$wname" "$msg" "$rel"
}

render_entry_narrow() {
    local i="$1" cat="$2"
    local clr icon sesswin rel
    clr="$(color_for "$cat")"
    icon="$(icon_for "$cat")"
    sesswin="${E_SESSION[$i]}:${E_WINDOW[$i]}"
    rel="$(relative_time "${E_TS[$i]}")"

    # Narrow: just index, icon, session:win, time
    printf '  \033[%sm%s\033[0m %s %-*s %s\n' \
        "$clr" "$i" "$icon" "$MAX_SESSWIN" "$sesswin" "$rel"
}

render_section() {
    local cat="$1" label="$2" cols="$3"
    local has=0
    for i in $(seq 1 "$INDEX"); do
        [ "${E_CAT[$i]}" = "$cat" ] || continue
        if [ "$has" -eq 0 ]; then
            printf '\n  \033[1m%s\033[0m\n' "$label"
            has=1
        fi
        if [ "$cols" -ge 100 ]; then
            render_entry_wide "$i" "$cat"
        elif [ "$cols" -ge 60 ]; then
            render_entry_medium "$i" "$cat"
        else
            render_entry_narrow "$i" "$cat"
        fi
    done
}

render() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    clear
    printf '\n'

    # Header scales with width
    if [ "$cols" -ge 100 ]; then
        printf '              Claude Code Sessions\n'
        printf '  ────────────────────────────────────────────────────────────────────\n'
    elif [ "$cols" -ge 60 ]; then
        printf '        Claude Code Sessions\n'
        printf '  ──────────────────────────────────────────────\n'
    else
        printf '  Claude Sessions\n'
        printf '  ───────────────\n'
    fi

    if [ "$INDEX" -eq 0 ]; then
        printf '\n    No active sessions.\n\n'
        printf '  [q] quit\n'
        return
    fi

    render_section working  "WORKING"  "$cols"
    render_section waiting  "WAITING"  "$cols"
    render_section finished "FINISHED" "$cols"
    render_section idle     "IDLE"     "$cols"

    printf '\n  [1-%d] goto  [c] clear all  [q] quit\n' "$INDEX"
}

goto_entry() {
    local num="$1"
    if [ "$num" -ge 1 ] 2>/dev/null && [ "$num" -le "$INDEX" ] 2>/dev/null; then
        local sess="${E_SESSION[$num]}"
        local win="${E_WINDOW[$num]}"
        # Clear notification if it was one (waiting or finished)
        if [ "${E_CAT[$num]}" = "waiting" ] || [ "${E_CAT[$num]}" = "finished" ]; then
            local safe_sess
            safe_sess="$(printf '%s' "$sess" | tr '/ ' '__')"
            rm -f "${NOTIF_DIR}/${safe_sess}_${win}"
        fi
        # Switch to session and window
        tmux switch-client -t "$sess" 2>/dev/null || true
        tmux select-window -t "${sess}:${win}" 2>/dev/null || true
        exit 0
    fi
}

load_entries
render

# Input buffer for multi-digit numbers
NUMBUF=""

# Ensure we're reading from the terminal (fixes tmux popup issues)
if [ -t 0 ]; then
    : # stdin is already a tty
else
    exec </dev/tty 2>/dev/null || exec 0<&1 2>/dev/null || true
fi

while true; do
    if [ -n "$NUMBUF" ]; then
        # Wait briefly for more digits, then process
        read -rsn1 -t 0.5 key 2>/dev/null || key=""
    else
        # Always use a timeout to prevent blocking issues
        read -rsn1 -t 1 key 2>/dev/null || key=""
    fi

    case "$key" in
        q|Q)
            [ -z "$NUMBUF" ] && exit 0
            NUMBUF=""
            ;;
        c|C)
            if [ -z "$NUMBUF" ]; then
                rm -f "$NOTIF_DIR"/*
                load_entries
                render
            else
                NUMBUF=""
            fi
            ;;
        [0-9])
            NUMBUF="${NUMBUF}${key}"
            # If the number is already larger than INDEX, process immediately
            if [ "$NUMBUF" -gt "$INDEX" ] 2>/dev/null; then
                NUMBUF=""
            fi
            ;;
        "")
            # Timeout or enter — process buffered number
            if [ -n "$NUMBUF" ]; then
                goto_entry "$NUMBUF"
                NUMBUF=""
            fi
            ;;
        *)
            NUMBUF=""
            ;;
    esac
done
