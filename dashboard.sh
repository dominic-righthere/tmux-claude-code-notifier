#!/usr/bin/env bash
# Claude Code Notifier — popup dashboard
# Shows working/waiting/finished Claude sessions, allows direct window switching
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"
chmod 700 "$DATA_DIR"

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
    local file="$1"
    # Variables set globally (no local declaration) so caller can read them
    P_SESSION="" P_WINDOW="" P_WINDOW_NAME="" P_MESSAGE="" P_TYPE="" P_TIMESTAMP=""
    while IFS= read -r line; do
        case "${line%%=*}" in
            SESSION) P_SESSION="${line#*=}" ;;
            WINDOW) P_WINDOW="${line#*=}" ;;
            WINDOW_NAME) P_WINDOW_NAME="${line#*=}" ;;
            MESSAGE) P_MESSAGE="${line#*=}" ;;
            TYPE) P_TYPE="${line#*=}" ;;
            TIMESTAMP) P_TIMESTAMP="${line#*=}" ;;
        esac
    done < "$file" || true
    [ -z "$P_SESSION" ] && return 1
    return 0
}

# Arrays to hold entry data (indexed by internal entry number)
declare -a E_SESSION=() E_WINDOW=() E_WNAME=() E_MSG=() E_TS=() E_CAT=()
INDEX=0  # Total number of entries

# Display order: maps visual position (1-based) to internal index
declare -a DISPLAY_ORDER=()
DISPLAY_COUNT=0  # Number of entries in display order
CURSOR=1  # Currently selected visual position

# Search state
SEARCH_QUERY=""
SEARCH_MODE=0
DETAIL_MODE=0
SCROLL_OFFSET=1  # First visible position in display order

# Column width tracking for alignment
MAX_SESSWIN=0
MAX_WNAME=0

# Key mapping: 1-9 for entries 1-9, a-z for entries 10-35
KEYS="123456789abcdefghijklmnopqrstuvwxyz"

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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
    local cat query_lower
    query_lower="$(to_lower "$SEARCH_QUERY")"
    for cat in working waiting finished idle; do
        for i in $(seq 1 "$INDEX"); do
            [ "${E_CAT[$i]}" = "$cat" ] || continue
            # Apply search filter
            if [ -n "$query_lower" ]; then
                local match=0
                local sess_lower wname_lower msg_lower
                sess_lower="$(to_lower "${E_SESSION[$i]}")"
                wname_lower="$(to_lower "${E_WNAME[$i]}")"
                msg_lower="$(to_lower "${E_MSG[$i]}")"
                [[ "$sess_lower" == *"$query_lower"* ]] && match=1
                [[ "$wname_lower" == *"$query_lower"* ]] && match=1
                [[ "$msg_lower" == *"$query_lower"* ]] && match=1
                [ "$match" -eq 0 ] && continue
            fi
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
        # Remove stale entries based on age
        elif [ -n "$ts" ]; then
            local age=$(( NOW - ts ))
            if [ "$type" = "working" ] && [ "$age" -gt 3600 ]; then       # 1h
                rm -f "$f"
            elif [ "$type" = "idle" ] && [ "$age" -gt 43200 ]; then       # 12h
                rm -f "$f"
            elif [ "$type" = "finished" ] && [ "$age" -gt 21600 ]; then   # 6h
                rm -f "$f"
            elif [ "$type" = "waiting" ] && [ "$age" -gt 86400 ]; then    # 24h
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
    SCROLL_OFFSET=1

    # Read active entries (working + idle)
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] || continue
        if parse_file "$f"; then
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
        if parse_file "$f"; then
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
        msg_w=$(( remain - 2 ))
    fi
    if [ "$remain" -ge 24 ]; then
        show_wname=1
        wname_w=10
        msg_w=$(( remain - 14 ))
    fi
    if [ "$remain" -ge 34 ]; then
        show_status=1
        msg_w=$(( remain - 24 ))
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
    printf '\033[K'  # fill remainder of line with current background
    [ "$is_selected" -eq 1 ] && printf '\033[0m'
    printf '\n'
}

render_detail() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local i="${DISPLAY_ORDER[$CURSOR]}"
    local cat="${E_CAT[$i]}"
    local clr icon
    clr="$(color_for "$cat")"
    icon="$(icon_for "$cat")"

    printf '  \033[1mEntry Detail\033[0m\n\n'
    printf '  \033[90m%-12s\033[0m %s\n' "Session" "${E_SESSION[$i]}"
    printf '  \033[90m%-12s\033[0m %s\n' "Window" "${E_WINDOW[$i]}"
    printf '  \033[90m%-12s\033[0m %s\n' "Window Name" "${E_WNAME[$i]}"
    printf '  \033[90m%-12s\033[0m \033[%sm%s %s\033[0m\n' "Status" "$clr" "$icon" "$cat"
    printf '  \033[90m%-12s\033[0m %s\n' "Time" "$(relative_time "${E_TS[$i]}") ago"

    # Word-wrap message to fit terminal
    printf '  \033[90m%-12s\033[0m ' "Message"
    local msg="${E_MSG[$i]}"
    local wrap_w=$(( cols - 16 ))
    [ "$wrap_w" -lt 20 ] && wrap_w=20
    local pos=0
    while [ "$pos" -lt "${#msg}" ]; do
        local chunk="${msg:$pos:$wrap_w}"
        if [ "$pos" -gt 0 ]; then
            printf '  %14s' ""
        fi
        printf '%s\n' "$chunk"
        pos=$(( pos + wrap_w ))
    done
    [ -z "$msg" ] && printf '\n'

    printf '\n  [Enter] jump  [i/Esc] back  [q] quit\n'
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
    local cols rows
    cols=$(tput cols 2>/dev/null || echo 80)
    rows=$(tput lines 2>/dev/null || echo 24)
    clear

    if [ "$DETAIL_MODE" -eq 1 ] && [ "$DISPLAY_COUNT" -gt 0 ]; then
        render_detail
        return
    fi

    # Header (line 1)
    printf '  \033[1mClaude Code Sessions\033[0m\n'

    if [ "$DISPLAY_COUNT" -eq 0 ]; then
        if [ -n "$SEARCH_QUERY" ]; then
            printf '\n    No matching sessions.\n'
        else
            printf '\n    No active sessions.\n'
        fi
        # Footer pinned to bottom
        printf '\033[%d;1H' "$rows"
        if [ "$SEARCH_MODE" -eq 1 ]; then
            printf '  /%s_' "$SEARCH_QUERY"
        else
            printf '  [r] refresh  [/] search  [q] quit'
        fi
        return
    fi

    # Visible entry budget: rows minus header(1), scroll indicators(2), footer(1)
    local available=$(( rows - 4 ))
    [ "$available" -lt 3 ] && available=3

    # Render viewport: entries from SCROLL_OFFSET onward, stopping when full
    local last_cat="" pos i cat label lines_used=0
    for pos in $(seq "$SCROLL_OFFSET" "$DISPLAY_COUNT"); do
        i="${DISPLAY_ORDER[$pos]}"
        cat="${E_CAT[$i]}"

        # Section label — costs 1 line
        if [ "$cat" != "$last_cat" ]; then
            [ $(( lines_used + 1 )) -ge "$available" ] && break
            label="$(section_label "$cat")"
            printf '  \033[1m%s\033[0m\n' "$label"
            lines_used=$(( lines_used + 1 ))
            last_cat="$cat"
        fi

        # Entry row — costs 1 line
        [ $(( lines_used + 1 )) -gt "$available" ] && break
        render_entry "$pos" "$i" "$cat" "$cols"
        lines_used=$(( lines_used + 1 ))
    done

    # Scroll indicators just above footer
    local last_visible=$(( SCROLL_OFFSET + lines_used - 1 ))
    local indicator_row=$(( rows - 1 ))
    if [ "$SCROLL_OFFSET" -gt 1 ] && [ "$last_visible" -lt "$DISPLAY_COUNT" ]; then
        printf '\033[%d;1H' "$indicator_row"
        printf '  \033[90m▲ %d above  ▼ %d below\033[0m' \
            "$(( SCROLL_OFFSET - 1 ))" "$(( DISPLAY_COUNT - last_visible ))"
    elif [ "$SCROLL_OFFSET" -gt 1 ]; then
        printf '\033[%d;1H' "$indicator_row"
        printf '  \033[90m▲ %d more above\033[0m' "$(( SCROLL_OFFSET - 1 ))"
    elif [ "$last_visible" -lt "$DISPLAY_COUNT" ]; then
        printf '\033[%d;1H' "$indicator_row"
        printf '  \033[90m▼ %d more below\033[0m' "$(( DISPLAY_COUNT - last_visible ))"
    fi

    # Footer pinned to bottom row
    local status2_indicator
    if [ -f "${DATA_DIR}/status2.disabled" ]; then
        status2_indicator="[n] status2:off"
    else
        status2_indicator="[n] status2:on"
    fi
    printf '\033[%d;1H' "$rows"
    if [ "$SEARCH_MODE" -eq 1 ]; then
        printf '  /%s_' "$SEARCH_QUERY"
    else
        printf '  [jk/↑↓] nav  [Enter] select  [/] search  [r] refresh  [c] clear  %s  [q] quit' \
            "$status2_indicator"
    fi
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
            safe_sess="$(sanitize_key "$sess")"
            rm -f "${NOTIF_DIR}/${safe_sess}_${win}"
        fi
        # Switch to session and window
        tmux switch-client -t "$sess" 2>/dev/null || true
        tmux select-window -t "${sess}:${win}" 2>/dev/null || true
        exit 0
    fi
}

clamp_cursor() {
    [ "$CURSOR" -gt "$DISPLAY_COUNT" ] && CURSOR=$DISPLAY_COUNT
    [ "$CURSOR" -lt 1 ] && CURSOR=1
}

# Adjust SCROLL_OFFSET so CURSOR is within the visible viewport
ensure_cursor_visible() {
    local rows
    rows=$(tput lines 2>/dev/null || echo 24)
    # Overhead: 1 header + up to 4 section labels + 2 footer lines
    local visible=$(( rows - 7 ))
    [ "$visible" -lt 3 ] && visible=3

    if [ "$CURSOR" -lt "$SCROLL_OFFSET" ]; then
        SCROLL_OFFSET=$CURSOR
    elif [ "$CURSOR" -ge $(( SCROLL_OFFSET + visible )) ]; then
        SCROLL_OFFSET=$(( CURSOR - visible + 1 ))
    fi
    [ "$SCROLL_OFFSET" -lt 1 ] && SCROLL_OFFSET=1
}

# Auto-scan for untracked Claude Code sessions
"${SCRIPT_DIR}/scan.sh" >/dev/null 2>&1 || true

load_entries
clamp_cursor
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
    ensure_cursor_visible
    render
}

while true; do
    read -rsn1 key 2>/dev/null || key=""

    # Search mode key handling
    if [ "$SEARCH_MODE" -eq 1 ]; then
        case "$key" in
            $'\x1b')  # Escape — exit search or handle arrow keys
                read -rsn2 -t 0.1 seq 2>/dev/null || seq=""
                case "$seq" in
                    '[A') move_cursor -1 ;;
                    '[B') move_cursor 1 ;;
                    *)  # Plain Escape — clear search
                        SEARCH_MODE=0
                        SEARCH_QUERY=""
                        build_display_order
                        clamp_cursor
                        render
                        ;;
                esac
                ;;
            "")  # Enter — select current entry
                goto_entry "$CURSOR"
                ;;
            $'\x7f'|$'\b')  # Backspace/Delete
                if [ -n "$SEARCH_QUERY" ]; then
                    SEARCH_QUERY="${SEARCH_QUERY%?}"
                fi
                build_display_order
                SCROLL_OFFSET=1
                clamp_cursor
                render
                ;;
            j) move_cursor 1 ;;
            k) move_cursor -1 ;;
            *)  # Printable character — append to query
                if [[ "$key" =~ [[:print:]] ]]; then
                    SEARCH_QUERY="${SEARCH_QUERY}${key}"
                    build_display_order
                    CURSOR=1
                    SCROLL_OFFSET=1
                    clamp_cursor
                    render
                fi
                ;;
        esac
        continue
    fi

    # Detail mode key handling
    if [ "$DETAIL_MODE" -eq 1 ]; then
        case "$key" in
            q|Q)
                exit 0
                ;;
            "")  # Enter — jump to entry
                goto_entry "$CURSOR"
                ;;
            i)
                DETAIL_MODE=0
                render
                ;;
            $'\x1b')  # Escape — back to list
                read -rsn2 -t 0.1 _ 2>/dev/null || true
                DETAIL_MODE=0
                render
                ;;
        esac
        continue
    fi

    # Normal mode key handling
    case "$key" in
        q|Q)
            exit 0
            ;;
        /)  # Enter search mode
            SEARCH_MODE=1
            SEARCH_QUERY=""
            render
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
            clamp_cursor
            render
            ;;
        c|C)
            rm -f "$NOTIF_DIR"/*
            load_entries
            clamp_cursor
            render
            ;;
        n|N)  # Toggle persistent second status bar
            if [ -f "${DATA_DIR}/status2.disabled" ]; then
                rm -f "${DATA_DIR}/status2.disabled"
            else
                touch "${DATA_DIR}/status2.disabled"
            fi
            tmux refresh-client -S 2>/dev/null || true
            render
            ;;
        i)  # Detail view
            if [ "$DISPLAY_COUNT" -gt 0 ]; then
                DETAIL_MODE=1
                render
            fi
            ;;
        [1-9a-bd-hl-ps-z])  # Direct key shortcuts (excluding c,i,j,k,n,q,r)
            pos="$(key_to_pos "$key" 2>/dev/null)" || continue
            [ -n "$pos" ] && [ "$pos" -ge 1 ] && [ "$pos" -le "$DISPLAY_COUNT" ] && goto_entry "$pos"
            ;;
    esac
done
