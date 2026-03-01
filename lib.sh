#!/usr/bin/env bash
# Claude Code Notifier — shared library
# Source this from other scripts: source "${SCRIPT_DIR}/lib.sh"

# ─── Event logging (SQLite) ──────────────────────────────────────────────────

EVENTS_DB="${HOME}/.local/share/claude-notifier/events.db"

init_events_db() {
    [ -f "$EVENTS_DB" ] && return 0
    mkdir -p "$(dirname "$EVENTS_DB")"
    chmod 700 "$(dirname "$EVENTS_DB")"
    sqlite3 "$EVENTS_DB" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime')),
    src TEXT NOT NULL,
    event TEXT NOT NULL,
    session TEXT,
    window TEXT,
    type TEXT,
    tool TEXT,
    action TEXT,
    msg_id TEXT,
    message TEXT,
    text TEXT,
    extra TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session, window);
PRAGMA journal_mode=WAL;
SQL
}

# log_event key val key val ...
# Builds INSERT from key-value pairs. Silently no-ops if DB missing or sqlite3 fails.
log_event() {
    [ -f "$EVENTS_DB" ] || return 0
    local cols="ts" vals="strftime('%Y-%m-%dT%H:%M:%S','now','localtime')"
    local _q="'"
    while [ $# -ge 2 ]; do
        cols="${cols},${1}"
        local v="$2"
        v="${v//$_q/$_q$_q}"
        vals="${vals},'${v}'"
        shift 2
    done
    sqlite3 "$EVENTS_DB" "INSERT INTO events(${cols}) VALUES(${vals});" 2>/dev/null || true
}

# ─── Utilities ────────────────────────────────────────────────────────────────

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

# Strip leading/trailing blank lines (macOS-compatible)
# Usage: echo "text" | trim_blank_lines
trim_blank_lines() {
    local line lines=() started=0
    while IFS= read -r line; do
        if [ "$started" -eq 0 ]; then
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            started=1
        fi
        lines+=("$line")
    done
    # Remove trailing blank lines
    local i=$(( ${#lines[@]} - 1 ))
    while [ "$i" -ge 0 ] && [[ "${lines[$i]}" =~ ^[[:space:]]*$ ]]; do
        unset 'lines[$i]'
        i=$(( i - 1 ))
    done
    printf '%s\n' "${lines[@]}"
}

# Reflow captured terminal output for Telegram readability.
# Claude Code hard-wraps output at the pane width. This rejoins wrapped prose
# while preserving structural lines (markers, diffs, lists, prompts).
# Usage: reflow_for_telegram [pane_width]
reflow_for_telegram() {
    local width="${1:-120}"
    awk -v thr="$((width - 5))" '
    function structural(s) {
        if (s ~ /^[[:space:]]*(⏺|⎿|❯|✻)/) return 1
        if (s ~ /…/) return 1
        if (s ~ /^[[:space:]]+[0-9]+[[:space:]]+[-+|]/) return 1
        if (s ~ /^[[:space:]]+[-*][ ]/) return 1
        if (s ~ /^[[:space:]]+[0-9]+\.[ ]/) return 1
        if (s ~ /^[[:space:]]*[$>][ ]/) return 1
        if (s ~ /^(===|---)/) return 1
        return 0
    }
    {
        rlen = length($0)
        if ($0 ~ /^[[:space:]]*$/) {
            if (buf != "") print buf; buf = ""; print; pl = 0
        } else if (structural($0)) {
            if (buf != "") print buf; buf = $0; pl = rlen
        } else if (pl >= thr && buf != "") {
            sub(/^[[:space:]]+/, ""); buf = buf " " $0; pl = rlen
        } else {
            if (buf != "") print buf; buf = $0; pl = rlen
        }
    }
    END { if (buf != "") print buf }
    '
}

# Extract activity log from terminal output.
# Finds ⎿ marker lines in the current work block (after last ❯ line),
# deduplicates, and formats as bullet list.
# Usage: extract_activity_log "text" [max_items]
extract_activity_log() {
    local text="$1" max="${2:-20}"
    # Get current work block: everything after the last ❯ line (user input boundary)
    local work_block
    work_block="$(printf '%s' "$text" | awk '/❯ / { buf="" } { buf = buf "\n" $0 } END { print buf }')"
    [ -z "$work_block" ] && work_block="$text"

    # Extract ⎿ lines, deduplicate, format as bullets
    printf '%s' "$work_block" \
        | grep -E '^\s*⎿' \
        | sed 's/^[[:space:]]*⎿[[:space:]]*//' \
        | sed 's/^[[:space:]]*//' \
        | grep -v '^[[:space:]]*$' \
        | awk '!seen[$0]++' \
        | head -"$max" \
        | sed 's/^/• /'
}

# Extract Claude's prompt/speech text.
# Finds text between the last ⏺ marker and the ❯/numbered options at the bottom.
# Usage: extract_prompt_text "text" [max_chars]
extract_prompt_text() {
    local text="$1" max_chars="${2:-1500}"
    # Find last ⏺ block, take lines until ❯ or numbered option
    local extracted
    extracted="$(printf '%s' "$text" \
        | awk '
        /⏺/ { buf = ""; capturing = 1; next }
        capturing && /^[[:space:]]*(❯|[0-9]+\.)/ { capturing = 0; next }
        capturing { buf = buf "\n" $0 }
        END { print buf }
        ' \
        | sed '/^[[:space:]]*$/d' \
        | sed 's/^[[:space:]]*//')"
    # Truncate at last newline before budget
    if [ "${#extracted}" -gt "$max_chars" ]; then
        extracted="${extracted:0:$max_chars}"
        # Find last newline for clean line boundary
        local last_nl="${extracted%$'\n'*}"
        if [ "$last_nl" != "$extracted" ] && [ -n "$last_nl" ]; then
            extracted="$last_nl"
        fi
        extracted="${extracted}..."
    fi
    printf '%s' "$extracted"
}

# Convert markdown pipe-delimited tables to bullet format for mobile.
# Pipe filter: detects |col|col| rows, skips |---| separators,
# outputs "- col1: col2" bullets. Non-table lines pass through unchanged.
# Usage: echo "text" | convert_tables_to_bullets
convert_tables_to_bullets() {
    awk '
    BEGIN { header_count = 0; split("", headers) }
    /^\|[-:[:space:]]+\|/ { next }
    /^\|.*\|$/ {
        # Strip leading/trailing |, split by |
        line = $0
        gsub(/^[[:space:]]*\|/, "", line)
        gsub(/\|[[:space:]]*$/, "", line)
        n = split(line, cols, "|")
        for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", cols[i])
        }
        if (header_count == 0) {
            header_count = n
            for (i = 1; i <= n; i++) headers[i] = cols[i]
        } else {
            out = "- "
            for (i = 1; i <= n; i++) {
                if (i > 1) out = out ", "
                if (i <= header_count && headers[i] != "") {
                    out = out headers[i] ": " cols[i]
                } else {
                    out = out cols[i]
                }
            }
            print out
        }
        next
    }
    { header_count = 0; print }
    '
}

# Wrap long lines for mobile-friendly display.
# Usage: echo "text" | wrap_long_lines [width]
wrap_long_lines() {
    local width="${1:-50}"
    fold -s -w "$width"
}
