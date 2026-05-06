#!/usr/bin/env bash
# Agent Notifier shared helpers.

: "${AGENT_NOTIFIER_DATA_DIR:=${HOME}/.local/share/agent-notifier}"
DATA_DIR="$AGENT_NOTIFIER_DATA_DIR"
LEGACY_DATA_DIR="${HOME}/.local/share/claude-notifier"
EVENTS_DB="${DATA_DIR}/events.db"

ensure_data_dirs() {
    mkdir -p "${DATA_DIR}/active" "${DATA_DIR}/notifications"
    chmod 700 "$DATA_DIR" 2>/dev/null || true
}

migrate_legacy_state() {
    [ -d "$LEGACY_DATA_DIR" ] || return 0
    [ "$DATA_DIR" != "$LEGACY_DATA_DIR" ] || return 0
    if [ -d "$DATA_DIR" ] && [ -n "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
        return 0
    fi

    mkdir -p "$DATA_DIR"
    for item in active notifications events.db installed_version status2.disabled; do
        [ -e "${LEGACY_DATA_DIR}/${item}" ] || continue
        cp -pR "${LEGACY_DATA_DIR}/${item}" "${DATA_DIR}/${item}" 2>/dev/null || true
    done
    mkdir -p "${DATA_DIR}/active" "${DATA_DIR}/notifications"
}

init_events_db() {
    ensure_data_dirs
    [ -f "$EVENTS_DB" ] && return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sqlite3 "$EVENTS_DB" <<'SQL' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime')),
    src TEXT NOT NULL,
    event TEXT NOT NULL,
    agent TEXT,
    session TEXT,
    window TEXT,
    type TEXT,
    tool TEXT,
    message TEXT,
    text TEXT,
    extra TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(agent, session, window);
PRAGMA journal_mode=WAL;
SQL
}

log_event() {
    [ -f "$EVENTS_DB" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
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

sanitize_key() {
    printf '%s' "$1" | tr '/ :' '___'
}

agent_key() {
    local agent="$1" session="$2" window="$3"
    printf '%s_%s_%s' "$(sanitize_key "$agent")" "$(sanitize_key "$session")" "$(sanitize_key "$window")"
}

write_state_file() {
    local dir="$1" key="$2" agent="$3" session="$4" window="$5" window_name="$6" type="$7" message="$8" timestamp="$9"
    local provider_session_id="${10:-}" cwd="${11:-}"
    mkdir -p "$dir"
    printf 'AGENT=%s\nSESSION=%s\nWINDOW=%s\nWINDOW_NAME=%s\nMESSAGE=%s\nTYPE=%s\nTIMESTAMP=%s\nPROVIDER_SESSION_ID=%s\nCWD=%s\n' \
        "$agent" "$session" "$window" "$window_name" "$message" "$type" "$timestamp" "$provider_session_id" "$cwd" \
        > "${dir}/${key}"
}

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

icon_for() {
    case "$1" in
        working)  printf '⟳' ;;
        waiting)  printf '⏳' ;;
        finished) printf '●' ;;
        idle)     printf '○' ;;
    esac
}

agent_label() {
    case "$1" in
        claude) printf 'Claude' ;;
        codex)  printf 'Codex' ;;
        pi)     printf 'Pi' ;;
        *)      printf '%s' "$1" ;;
    esac
}

short_message() {
    local msg="$1" max="${2:-80}"
    if [ "${#msg}" -gt "$max" ]; then
        msg="${msg:0:$((max - 3))}..."
    fi
    printf '%s' "$msg"
}
