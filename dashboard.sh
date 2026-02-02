#!/usr/bin/env bash
# Claude Code Notifier — popup dashboard
# Shows working/waiting/finished Claude sessions, allows direct window switching
set -euo pipefail

DATA_DIR="${HOME}/.local/share/claude-notifier"
ACTIVE_DIR="${DATA_DIR}/active"
NOTIF_DIR="${DATA_DIR}/notifications"
mkdir -p "$ACTIVE_DIR" "$NOTIF_DIR"

NOW="$(date +%s)"

relative_time() {
    local ts="$1"
    local diff=$(( NOW - ts ))
    if [ "$diff" -lt 60 ]; then
        printf '%ds ago' "$diff"
    elif [ "$diff" -lt 3600 ]; then
        printf '%dm ago' "$(( diff / 60 ))"
    elif [ "$diff" -lt 86400 ]; then
        printf '%dh ago' "$(( diff / 3600 ))"
    else
        printf '%dd ago' "$(( diff / 86400 ))"
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
    done < "$file"
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

load_entries() {
    E_SESSION=() E_WINDOW=() E_WNAME=() E_MSG=() E_TS=() E_CAT=()
    INDEX=0

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

render_section() {
    local cat="$1" label="$2" cols="$3"
    local has=0
    for i in $(seq 1 "$INDEX"); do
        [ "${E_CAT[$i]}" = "$cat" ] || continue
        if [ "$has" -eq 0 ]; then
            printf '\n  \033[1m%s\033[0m\n' "$label"
            has=1
        fi
        local rel icon clr sesswin wname
        rel="$(relative_time "${E_TS[$i]}")"
        icon="$(icon_for "$cat")"
        clr="$(color_for "$cat")"
        sesswin="${E_SESSION[$i]}:${E_WINDOW[$i]}"
        wname="${E_WNAME[$i]}"
        if [ "$cols" -lt 60 ]; then
            # Compact: truncate wname to 8 chars
            [ "${#wname}" -gt 8 ] && wname="${wname:0:8}"
            printf '  \033[%sm%-2s\033[0m %s  %-8s %-8s %s\n' \
                "$clr" "$i" "$icon" "$sesswin" "$wname" "$rel"
        else
            printf '  \033[%sm%-3s\033[0m %s  %-10s %-12s %-18s %s\n' \
                "$clr" "$i" "$icon" "$sesswin" "$wname" "${E_MSG[$i]}" "$rel"
        fi
    done
}

render() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    clear
    printf '\n'
    if [ "$cols" -lt 60 ]; then
        printf '  Claude Code Notifications\n'
        printf '  ──────────────────────────\n'
    else
        printf '           Claude Code Notifications\n'
        printf '  ────────────────────────────────────────────────────────\n'
    fi

    if [ "$INDEX" -eq 0 ]; then
        printf '\n    No active sessions or notifications.\n\n'
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

while true; do
    if [ -n "$NUMBUF" ]; then
        # Wait briefly for more digits, then process
        read -rsn1 -t 0.5 key || key=""
    else
        read -rsn1 key
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
