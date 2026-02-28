#!/usr/bin/env bash
# Claude Code Notifier — shared library
# Source this from other scripts: source "${SCRIPT_DIR}/lib.sh"

# Sanitize a tmux session name for use as a filename
# Usage: sanitize_key "my session/name"
sanitize_key() {
    printf '%s' "$1" | tr '/ ' '__'
}

# Write a state file (active/ or notifications/ entry)
# Usage: write_state_file <dir> <key> <session> <window> <window_name> <type> <message> <timestamp>
write_state_file() {
    local dir="$1" key="$2" session="$3" window="$4" window_name="$5" type="$6" message="$7" timestamp="$8"
    printf 'SESSION=%s\nWINDOW=%s\nWINDOW_NAME=%s\nMESSAGE=%s\nTYPE=%s\nTIMESTAMP=%s\n' \
        "$session" "$window" "$window_name" "$message" "$type" "$timestamp" \
        > "${dir}/${key}"
}

# Read a specific field from a state file
# Usage: read_state_field <file> <field_name>
# Returns the value via stdout, exit 1 if not found
read_state_field() {
    local file="$1" field="$2"
    [ -f "$file" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "${field}"=*) printf '%s' "${line#"${field}"=}"; return 0 ;;
        esac
    done < "$file"
    return 1
}

# HTML-escape &<> for Telegram messages
# Usage: html_escape "string with <html>"
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Extract last N non-blank meaningful lines from text
# Usage: extract_preview "text" [count]
extract_preview() {
    local text="$1" count="${2:-3}"
    printf '%s' "$text" | grep -v '^[[:space:]]*$' | tail -"$count"
}

# Strip ANSI escape codes from text
# Usage: strip_ansi "text with \033[31mcolor\033[0m"
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Icon for notification category
# Usage: icon_for "working"
icon_for() {
    case "$1" in
        working)  printf '⟳' ;;
        waiting)  printf '⏳' ;;
        finished) printf '●' ;;
        idle)     printf '○' ;;
    esac
}
