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

# Arrays to hold entry data (indexed by internal entry number)
declare -a E_SESSION=() E_WINDOW=() E_WNAME=() E_MSG=() E_TS=() E_CAT=()
INDEX=0  # Total number of entries

# Display order: maps visual position (1-based) to internal index
declare -a DISPLAY_ORDER=()
DISPLAY_COUNT=0  # Number of entries in display order
CURSOR=1  # Currently selected visual position

# Column width tracking for alignment
MAX_SESSWIN=0
MAX_WNAME=0

# Key mapping: 1-9 for entries 1-9, a-z for entries 10-35
KEYS="123456789abcdefghijklmnopqrstuvwxyz"

pos_to_key() {
    local pos="$1"
    [ "$pos" -lt 1 ] || [ "$pos" -gt 35 ] && return 1
    printf '%s' "${KEYS:$((pos-1)):1}"
}

key_to_pos() {
    local key="$1"
    local pos="${KEYS%%"$key"*}"
    [ "$pos" = "$KEYS" ] && return 1  # not found
    printf '%d' "$(( ${#pos} + 1 ))"
}

# Build display order array (visual order: working, waiting, finished, idle)
build_display_order() {
    DISPLAY_ORDER=()
    DISPLAY_COUNT=0
    local cat
    for cat in working waiting finished idle; do
        for i in $(seq 1 "$INDEX"); do
            [ "${E_CAT[$i]}" = "$cat" ] || continue
            DISPLAY_COUNT=$(( DISPLAY_COUNT + 1 ))
            DISPLAY_ORDER[$DISPLAY_COUNT]=$i
        done
    done
}

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

    # Build display order for navigation
    build_display_order
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

render_entry() {
    local display_pos="$1" i="$2" cat="$3" cols="$4"
    local clr icon sesswin wname msg rel status_txt key
    local is_selected=0

    [ "$display_pos" -eq "$CURSOR" ] && is_selected=1

    clr="$(color_for "$cat")"
    icon="$(icon_for "$cat")"
    key="$(pos_to_key "$display_pos")"
    sesswin="${E_SESSION[$i]}:${E_WINDOW[$i]}"
    wname="${E_WNAME[$i]}"
    msg="${E_MSG[$i]}"
    rel="$(relative_time "${E_TS[$i]}")"
    status_txt="$cat"

    # Calculate available space
    # base: 2 (left margin) + 2 (key) + 1 (space) + 2 (icon+space) + MAX_SESSWIN + 2 (gap) + 5 (time) + 2 (right margin)
    local base_w=$(( 2 + 2 + 1 + 2 + MAX_SESSWIN + 2 + 5 + 2 ))
    local remain=$(( cols - base_w ))

    # Determine what columns to show and their widths
    local show_status=0 show_wname=0 show_msg=0
    local msg_w=0 wname_w=0

    if [ "$remain" -ge 12 ]; then
        show_msg=1
        msg_w=$remain
    fi
    if [ "$remain" -ge 24 ]; then
        show_wname=1
        wname_w=10
        msg_w=$(( remain - 12 ))
    fi
    if [ "$remain" -ge 34 ]; then
        show_status=1
        msg_w=$(( remain - 22 ))
    fi

    # Truncate as needed
    if [ "$show_wname" -eq 1 ] && [ "$wname_w" -gt 0 ] && [ "${#wname}" -gt "$wname_w" ]; then
        wname="${wname:0:$((wname_w-1))}…"
    fi
    if [ "$show_msg" -eq 1 ] && [ "$msg_w" -gt 0 ] && [ "${#msg}" -gt "$msg_w" ]; then
        msg="${msg:0:$((msg_w-1))}…"
    fi

    # Build output - highlight selected row
    if [ "$is_selected" -eq 1 ]; then
        printf '\033[7m'  # reverse video for selection
    fi
    printf '  \033[%sm%-2s\033[0m' "$clr" "$key"
    [ "$is_selected" -eq 1 ] && printf '\033[7m'
    printf ' %s  %-*s' "$icon" "$MAX_SESSWIN" "$sesswin"
    [ "$show_status" -eq 1 ] && printf '  %-8s' "$status_txt"
    [ "$show_wname" -eq 1 ] && printf '  %-*s' "$wname_w" "$wname"
    [ "$show_msg" -eq 1 ] && printf '  %-*s' "$msg_w" "$msg"
    printf '  %5s' "$rel"
    [ "$is_selected" -eq 1 ] && printf '\033[0m'
    printf '\n'
}

section_label() {
    case "$1" in
        working)  printf 'WORKING' ;;
        waiting)  printf 'WAITING' ;;
        finished) printf 'FINISHED' ;;
        idle)     printf 'IDLE' ;;
    esac
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

    if [ "$DISPLAY_COUNT" -eq 0 ]; then
        printf '\n    No active sessions.\n\n'
        printf '  [q] quit\n'
        return
    fi

    # Render entries in display order, showing section headers when category changes
    local last_cat="" pos i cat label
    for pos in $(seq 1 "$DISPLAY_COUNT"); do
        i="${DISPLAY_ORDER[$pos]}"
        cat="${E_CAT[$i]}"
        if [ "$cat" != "$last_cat" ]; then
            label="$(section_label "$cat")"
            printf '\n  \033[1m%s\033[0m\n' "$label"
            last_cat="$cat"
        fi
        render_entry "$pos" "$i" "$cat" "$cols"
    done

    local max_key
    max_key="$(pos_to_key "$DISPLAY_COUNT")"
    printf '\n  [↑↓/jk] navigate  [Enter] select  [1-%s] goto  [r] refresh  [c] clear  [q] quit\n' "$max_key"
}

goto_entry() {
    local pos="$1"
    if [ "$pos" -ge 1 ] 2>/dev/null && [ "$pos" -le "$DISPLAY_COUNT" ] 2>/dev/null; then
        local i="${DISPLAY_ORDER[$pos]}"
        local sess="${E_SESSION[$i]}"
        local win="${E_WINDOW[$i]}"
        # Clear notification if it was one (waiting or finished)
        if [ "${E_CAT[$i]}" = "waiting" ] || [ "${E_CAT[$i]}" = "finished" ]; then
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
# Ensure cursor is valid
[ "$CURSOR" -gt "$DISPLAY_COUNT" ] && CURSOR=$DISPLAY_COUNT
[ "$CURSOR" -lt 1 ] && CURSOR=1
render

# Ensure we're reading from the terminal (fixes tmux popup issues)
if [ -t 0 ]; then
    : # stdin is already a tty
else
    exec </dev/tty 2>/dev/null || exec 0<&1 2>/dev/null || true
fi

move_cursor() {
    local delta="$1"
    CURSOR=$(( CURSOR + delta ))
    [ "$CURSOR" -lt 1 ] && CURSOR=$DISPLAY_COUNT      # wrap to bottom
    [ "$CURSOR" -gt "$DISPLAY_COUNT" ] && CURSOR=1    # wrap to top
    render
}

while true; do
    read -rsn1 key 2>/dev/null || key=""

    case "$key" in
        q|Q)
            exit 0
            ;;
        $'\x1b')  # Escape sequence (arrow keys)
            read -rsn2 -t 0.1 seq 2>/dev/null || seq=""
            case "$seq" in
                '[A') move_cursor -1 ;;  # Up arrow
                '[B') move_cursor 1 ;;   # Down arrow
            esac
            ;;
        k|K)  # Vim up
            move_cursor -1
            ;;
        j|J)  # Vim down
            move_cursor 1
            ;;
        "")  # Enter key
            goto_entry "$CURSOR"
            ;;
        r|R)
            load_entries
            [ "$CURSOR" -gt "$DISPLAY_COUNT" ] && CURSOR=$DISPLAY_COUNT
            [ "$CURSOR" -lt 1 ] && CURSOR=1
            render
            ;;
        c|C)
            rm -f "$NOTIF_DIR"/*
            load_entries
            [ "$CURSOR" -gt "$DISPLAY_COUNT" ] && CURSOR=$DISPLAY_COUNT
            [ "$CURSOR" -lt 1 ] && CURSOR=1
            render
            ;;
        [1-9a-bd-il-ps-z])  # Direct key shortcuts (excluding c,j,k,q,r)
            pos="$(key_to_pos "$key" 2>/dev/null)" || continue
            [ -n "$pos" ] && [ "$pos" -ge 1 ] && [ "$pos" -le "$DISPLAY_COUNT" ] && goto_entry "$pos"
            ;;
    esac
done
