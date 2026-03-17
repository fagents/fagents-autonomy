#!/bin/bash
# fagents daemon — autonomous agent loop via Claude Code
#
# Usage: AGENT=<name> COMMS_URL=... COMMS_TOKEN=... ./daemon.sh [interval_seconds]
#
# Required env vars:
#   AGENT                  Agent identity (for logging)
#   COMMS_URL              fagents-comms server URL (e.g. http://127.0.0.1:9754)
#   COMMS_TOKEN            Agent auth token from fagents-comms
#
# Optional env vars:
#   CHANNELS=general       Comma-separated channels to follow (default: general)
#   PROMPT_REMBEAT         Rembeat prompt file (default: rembeat.md)
#   PROMPT_MSG             Msgbeat prompt file (default: msgbeat.md)
#   COMMS_POLL_INTERVAL=1  Seconds between HTTP polls (default: 1)
#   WAKE_CHANNELS=ch1,ch2  Wake on all msgs in these channels (default: mentions-only)
#   MAX_TURNS=50           Max turns per rembeat
#
# Prompt overrides: place files in $PROJECT_DIR/prompts/ to override defaults.
# Local rembeat.md takes priority over the one in this repo's prompts/ dir.
#
# Requires: jq, curl
#
# Controls (state in $PROJECT_DIR/.autonomy/):
#   Pause:  touch $PROJECT_DIR/.autonomy/daemon.pause
#   Stop:   kill $(cat $PROJECT_DIR/.autonomy/daemon.pid)
#
# Examples:
#   AGENT=ops CHANNELS=general,dev COMMS_URL=http://127.0.0.1:9754 COMMS_TOKEN=<tok> ./daemon.sh 300
#   AGENT=dev COMMS_URL=http://127.0.0.1:9754 COMMS_TOKEN=<tok> ./daemon.sh 300

set -euo pipefail

# ── Validate required env vars ──
AGENT="${AGENT:-}"
COMMS_URL="${COMMS_URL:-}"
COMMS_TOKEN="${COMMS_TOKEN:-}"
COMMS_POLL_INTERVAL="${COMMS_POLL_INTERVAL:-1}"
WAKE_CHANNELS="${WAKE_CHANNELS:-}"  # comma-separated wake channels, * for all

if [ -z "$AGENT" ] || [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
    echo "fagents daemon — autonomous agent loop"
    echo ""
    echo "Required environment variables:"
    echo "  AGENT        Agent identity (e.g. ops, dev, coo)"
    echo "  COMMS_URL    fagents-comms server URL"
    echo "  COMMS_TOKEN  Agent auth token"
    echo ""
    echo "Usage:"
    echo "  AGENT=ops COMMS_URL=http://127.0.0.1:9754 COMMS_TOKEN=<token> $0 [interval]"
    exit 1
fi

# ── Configurable defaults (all overridable via env) ──
CHANNELS="${CHANNELS:-general}"
PROMPT_REMBEAT="${PROMPT_REMBEAT:-rembeat.md}"
PROMPT_MSG="${PROMPT_MSG:-msgbeat.md}"
MAX_TURNS="${MAX_TURNS:-50}"

# Parse initial channel list from env (used as fallback)
IFS=',' read -ra CH_ARRAY <<< "$CHANNELS"

# Refresh channel list from server subscriptions (falls back to current CH_ARRAY)
refresh_channels() {
    if [ -n "$COMMS_URL" ] && [ -n "$COMMS_TOKEN" ]; then
        local resp
        resp=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
            "$COMMS_URL/api/agents/$AGENT/channels" 2>/dev/null) || true
        local channels_json
        channels_json=$(echo "$resp" | jq -r '.channels // empty' 2>/dev/null) || true
        if [ -n "$channels_json" ] && [ "$channels_json" != "null" ]; then
            local channel_csv
            channel_csv=$(echo "$resp" | jq -r '.channels | join(",")' 2>/dev/null) || true
            if [ -n "$channel_csv" ]; then
                IFS=',' read -ra CH_ARRAY <<< "$channel_csv"
                return 0
            fi
        fi
    fi
    # Fallback: keep current CH_ARRAY unchanged
    return 1
}

# Snapshot WAKE_CHANNELS from env — if user set it, server config won't override.
_ENV_WAKE_CHANNELS="$WAKE_CHANNELS"

# Fetch per-agent config from server. Updates WAKE_CHANNELS, COMMS_POLL_INTERVAL,
# MAX_TURNS, and INTERVAL from server config. Env vars override where noted.
fetch_config() {
    if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
        return 1
    fi
    local resp
    resp=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
        "$COMMS_URL/api/agents/$AGENT/config" 2>/dev/null) || return 1
    local server_wake_channels server_poll_interval server_max_turns server_rembeat
    server_wake_channels=$(echo "$resp" | jq -r '.config.wake_channels // empty' 2>/dev/null) || true
    server_poll_interval=$(echo "$resp" | jq -r '.config.poll_interval // empty' 2>/dev/null) || true
    server_max_turns=$(echo "$resp" | jq -r '.config.max_turns // empty' 2>/dev/null) || true
    server_rembeat=$(echo "$resp" | jq -r '.config.rembeat_interval // empty' 2>/dev/null) || true
    # WAKE_CHANNELS: env overrides server
    if [ -z "$_ENV_WAKE_CHANNELS" ] && [ -n "$server_wake_channels" ]; then
        WAKE_CHANNELS="$server_wake_channels"
    fi
    # Poll interval: always use server value (env default is just fallback)
    if [ -n "$server_poll_interval" ]; then
        COMMS_POLL_INTERVAL="$server_poll_interval"
    fi
    # Max turns: server overrides env default
    if [ -n "$server_max_turns" ]; then
        MAX_TURNS="$server_max_turns"
    fi
    # Rembeat interval: server overrides CLI arg
    if [ -n "$server_rembeat" ]; then
        INTERVAL="$server_rembeat"
    fi
    return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-/home/$(whoami)/workspace/$(whoami)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"
QUEUE_DIR="$PROJECT_DIR/.queue"
INBOX_DIR="$QUEUE_DIR/inbox"
ARCHIVE_DIR="$QUEUE_DIR/archive"
mkdir -p "$INBOX_DIR" "$ARCHIVE_DIR"

# MCP config from .mcp.json (installed by install-team.sh, agent can't read it but daemon can)
MCP_BASE=""
MCP_KEY=""
if [ -f "$PROJECT_DIR/.mcp.json" ]; then
    MCP_BASE=$(jq -r '.mcpServers["fagents-mcp"].url // empty' "$PROJECT_DIR/.mcp.json" 2>/dev/null | sed 's|/mcp$||') || true
    MCP_KEY=$(jq -r '.mcpServers["fagents-mcp"].headers["x-api-key"] // empty' "$PROJECT_DIR/.mcp.json" 2>/dev/null) || true
fi

PAUSE_FILE="$STATE_DIR/daemon.pause"
PID_FILE="$STATE_DIR/daemon.pid"
SESSION_FILE="$STATE_DIR/daemon.session"
DAEMON_LOG="$STATE_DIR/daemon.log"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
INTERVAL="${1:-21600}"

# Prompts are read from files at each use — edit without restarting the daemon.
# {{CHANNELS_BLOCK}} in the prompt is replaced with channel-specific instructions.
read_prompt() {
    local file="$PROMPTS_DIR/$1"
    # Local prompts override defaults (per-template customization)
    [ -f "$PROJECT_DIR/prompts/$1" ] && file="$PROJECT_DIR/prompts/$1"
    if [ -f "$file" ]; then
        local content
        content=$(cat "$file")
        # Build channel instruction block
        # Msgbeat: --since 10m (mentions already injected)
        # Rembeat: derive --since from INTERVAL (with 20% padding, minimum 60m)
        local since
        if [[ "$1" == *msg* ]]; then
            since="10m"
        else
            local interval_min=$(( (INTERVAL * 120 / 100 + 59) / 60 ))  # +20%, round up
            [ "$interval_min" -lt 60 ] && interval_min=60
            since="${interval_min}m"
        fi
        local client_cmd="autonomy/comms/client.sh"
        [ -n "${AUTONOMY_DIR:-}" ] && client_cmd="$AUTONOMY_DIR/comms/client.sh"
        local block=""
        for ch in "${CH_ARRAY[@]}"; do
            block="${block}  $client_cmd fetch $ch --since ${since}"$'\n'
        done
        block="${block}Reply via:"$'\n'
        for ch in "${CH_ARRAY[@]}"; do
            block="${block}  $client_cmd send $ch \"your message\""$'\n'
        done
        content="${content//\{\{CHANNELS_BLOCK\}\}/$block}"
        content="${content//\{\{AGENT_NAME\}\}/$AGENT}"
        # Inject inbox messages or remove placeholder
        # Supports both {{INBOX_BLOCK}} (new) and {{MENTIONS_BLOCK}} (backward compat)
        if [ -n "$INBOX_BLOCK" ]; then
            local inbox_header="Messages in your inbox ($INBOX_COUNT messages):"$'\n'"$INBOX_BLOCK"
            content="${content//\{\{INBOX_BLOCK\}\}/$inbox_header}"
            content="${content//\{\{MENTIONS_BLOCK\}\}/$inbox_header}"
        else
            content="${content//\{\{INBOX_BLOCK\}\}/}"
            content="${content//\{\{MENTIONS_BLOCK\}\}/}"
        fi
        echo "$content"
    else
        echo "ERROR: prompt file not found: $file" >&2
        echo "Prompt file missing. Check $file"
    fi
}

# ── Atomic lock: prevent double-daemon ──
LOCK_FILE="$STATE_DIR/daemon.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Daemon already running. Stop it with: kill \$(cat $PID_FILE)" >&2
    echo "DO NOT delete .lock — that breaks the lock." >&2
    exit 1
fi
echo $$ > "$PID_FILE"
STREAM_PID=""
cleanup() {
    rm -f "$PID_FILE"
    [ -n "$STREAM_PID" ] && kill "$STREAM_PID" 2>/dev/null || true
}
trap cleanup EXIT


check_pause() {
    local first=1
    while [ -f "$PAUSE_FILE" ]; do
        if [ $first -eq 1 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M %Z')] PAUSED — rm $PAUSE_FILE to resume"
            first=0
        fi
        sleep 2
    done
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1" >> "$DAEMON_LOG"
}

# Push a single event to the activity feed (visible in comms UI).
# Usage: push_activity <type> <summary>
push_activity() {
    [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ] && return
    local type="$1" summary="$2"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    curl -s --max-time 3 -X POST \
        -H "Authorization: Bearer $COMMS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"events\":[{\"ts\":\"$ts\",\"type\":\"$type\",\"summary\":\"$summary\"}]}" \
        "$COMMS_URL/api/agents/$AGENT/activity" >/dev/null 2>&1 || true
}

# ── Message Queue ──
# Collect functions write .jsonl files to INBOX_DIR. Each message is one file.
# read_inbox() formats them for prompt injection. archive_inbox() moves them after processing.

# Collect unread comms messages into inbox/ as .jsonl files.
# Returns 0 if messages written, 1 if none.
collect_comms() {
    if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
        return 1
    fi
    local url="$COMMS_URL/api/unread?mark_read=1"
    [ -n "$WAKE_CHANNELS" ] && url="$url&wake_channels=$WAKE_CHANNELS"
    local resp
    resp=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
        "$url" 2>/dev/null) || return 1
    local count
    count=$(echo "$resp" | jq '[.channels[]?.unread_count // 0] | add // 0' 2>/dev/null) || return 1
    [ "$count" -gt 0 ] 2>/dev/null || return 1
    # Write one .jsonl file per message
    local wrote=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local msg_id
        msg_id=$(echo "$line" | jq -r '.id' 2>/dev/null) || continue
        [ -z "$msg_id" ] || [ "$msg_id" = "null" ] && continue
        echo "$line" > "$INBOX_DIR/${msg_id}.jsonl"
        wrote=1
    done < <(echo "$resp" | jq -c '
        .channels[] | select(.unread_count > 0) |
        .channel as $ch |
        .messages[] |
        {
            ts: .ts,
            id: ("comms-" + $ch + "-" + (.ts | gsub("[^0-9]"; ""))),
            source: "comms",
            channel: $ch,
            from: .sender,
            body: .message,
            trusted: true
        }
    ' 2>/dev/null)
    [ "$wrote" = "1" ] && return 0 || return 1
}

# Collect new email notifications into inbox/.
# Calls MCP /api/check-email for UIDs > last known, writes notification-only .jsonl.
# No subject or body — agent must use gate_email to read content.
collect_email() {
    [ -n "$MCP_BASE" ] && [ -n "$MCP_KEY" ] || return 1

    local last_uid=0
    local uid_file="$STATE_DIR/email-last-uid"
    [ -f "$uid_file" ] && last_uid=$(cat "$uid_file" 2>/dev/null | tr -d '[:space:]')
    [ -n "$last_uid" ] || last_uid=0

    local resp
    resp=$(curl -s --max-time 10 \
        -H "x-api-key: $MCP_KEY" \
        "$MCP_BASE/api/check-email?since_uid=$last_uid" 2>/dev/null) || return 1

    local count
    count=$(echo "$resp" | jq '.messages | length' 2>/dev/null) || return 1
    [ "$count" -gt 0 ] 2>/dev/null || return 1

    local max_uid=$last_uid
    local wrote=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local uid from date
        uid=$(echo "$line" | jq -r '.uid' 2>/dev/null) || continue
        from=$(echo "$line" | jq -r '.from' 2>/dev/null) || continue
        date=$(echo "$line" | jq -r '.date' 2>/dev/null) || continue
        [ -z "$uid" ] || [ "$uid" = "null" ] && continue

        # Write notification-only entry — no subject, no body
        local entry
        entry=$(jq -nc \
            --arg ts "$date" \
            --arg id "email-$uid" \
            --arg from "$from" \
            --arg body "You have new email (UID $uid). Use gate_email to read." \
            '{ts:$ts, id:$id, source:"email", channel:"email", from:$from, body:$body, trusted:false}')
        echo "$entry" > "$INBOX_DIR/email-${uid}.jsonl"
        wrote=1

        [ "$uid" -gt "$max_uid" ] 2>/dev/null && max_uid=$uid
    done < <(echo "$resp" | jq -c '.messages[]' 2>/dev/null)

    # Update last UID tracker
    [ "$max_uid" -gt "$last_uid" ] 2>/dev/null && echo "$max_uid" > "$uid_file"

    [ "$wrote" = "1" ] && return 0 || return 1
}

# Collect new Telegram messages into inbox/.
# Calls telegram.sh poll via sudo, writes one .jsonl per message.
TELEGRAM_CLI="/home/fagents/workspace/fagents-cli/telegram.sh"
STT_CLI="/home/fagents/workspace/fagents-cli/stt-transcribe.sh"
collect_telegram() {
    [ -x "$TELEGRAM_CLI" ] || return 1

    local resp
    resp=$(sudo -u fagents "$TELEGRAM_CLI" poll 2>/dev/null) || return 1
    [ -n "$resp" ] || return 1

    local wrote=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local update_id chat_id from_user text msg_date
        update_id=$(echo "$line" | jq -r '.update_id') || continue
        chat_id=$(echo "$line" | jq -r '.chat_id') || continue
        from_user=$(echo "$line" | jq -r '.from // "unknown"')
        msg_date=$(echo "$line" | jq -r '.date // 0')

        # Handle voice messages: transcribe via stt-transcribe.sh
        local msg_type
        msg_type=$(echo "$line" | jq -r '.type // "text"')
        local text
        if [[ "$msg_type" == "voice" ]]; then
            local file_id
            file_id=$(echo "$line" | jq -r '.file_id // ""')
            if [[ -n "$file_id" ]] && [[ -x "$STT_CLI" ]]; then
                local stt_resp
                stt_resp=$(sudo -u fagents "$STT_CLI" "$file_id" 2>/dev/null) || true
                text=$(echo "$stt_resp" | jq -r '.text // ""' 2>/dev/null)
                [[ -n "$text" ]] || text="[voice message — transcription failed]"
            else
                text="[voice message — file_id: ${file_id}]"
            fi
        else
            text=$(echo "$line" | jq -r '.text // ""')
        fi

        # Include reply_to context if present
        local reply_from reply_text
        reply_from=$(echo "$line" | jq -r '.reply_to.from // empty' 2>/dev/null) || true
        reply_text=$(echo "$line" | jq -r '.reply_to.text // empty' 2>/dev/null) || true
        if [[ -n "$reply_from" && -n "$reply_text" ]]; then
            text="[replying to ${reply_from}: ${reply_text}] ${text}"
        fi

        local ts
        ts=$(jq -nr --arg e "$msg_date" '$e | tonumber | strftime("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

        local entry
        entry=$(jq -nc \
            --arg ts "$ts" \
            --arg id "telegram-${chat_id}-${update_id}" \
            --arg channel "telegram-${chat_id}" \
            --arg from "$from_user" \
            --arg body "$text" \
            --arg chat_id "$chat_id" \
            '{ts:$ts, id:$id, source:"telegram", channel:$channel, from:$from, body:$body, chat_id:$chat_id, trusted:false}')
        echo "$entry" > "$INBOX_DIR/telegram-${chat_id}-${update_id}.jsonl"
        wrote=1
    done <<< "$resp"

    [ "$wrote" = "1" ] && return 0 || return 1
}

# Read all inbox/ files, format as text block for prompt injection.
# Sets INBOX_BLOCK (text) and INBOX_COUNT (int).
INBOX_BLOCK=""
INBOX_COUNT=0
read_inbox() {
    INBOX_BLOCK=""
    INBOX_COUNT=0
    local files
    files=$(find "$INBOX_DIR" -name '*.jsonl' -type f 2>/dev/null) || return 1
    [ -z "$files" ] && return 1
    INBOX_COUNT=$(echo "$files" | wc -l | tr -d ' ')
    [ "$INBOX_COUNT" -gt 0 ] 2>/dev/null || return 1
    # Sort by timestamp, format by source, wrap untrusted in tags
    INBOX_BLOCK=$(cat "$INBOX_DIR"/*.jsonl 2>/dev/null | jq -rs '
        sort_by(.ts) |
        group_by(.source) | map(
            "--- " + .[0].source +
            (if .[0].source == "comms" and .[0].channel then " #" + .[0].channel else "" end) +
            " (" + (length | tostring) + " messages) ---\n" +
            (map(
                (if .trusted == false then "<untrusted>\n" else "" end) +
                "[" + .ts + "] [" + .from + "] " + .body +
                (if .trusted == false then "\n</untrusted>" else "" end)
            ) | join("\n"))
        ) | join("\n\n")
    ' 2>/dev/null) || return 1
    [ -n "$INBOX_BLOCK" ] && return 0 || return 1
}

# Move all inbox files to archive/ after processing.
archive_inbox() {
    local files
    files=$(find "$INBOX_DIR" -name '*.jsonl' -type f 2>/dev/null) || return 0
    [ -z "$files" ] && return 0
    mv "$INBOX_DIR"/*.jsonl "$ARCHIVE_DIR/" 2>/dev/null || true
}

# Collect from all sources and wait for inbox to have messages or timeout.
# Returns 0 if inbox has messages (msgbeat), 1 if timeout (rembeat).
# INTERVAL (seconds) is the rembeat timer, read from comms server via fetch_config().
LAST_EMAIL_CHECK=0
LAST_TELEGRAM_CHECK=0
EMAIL_CADENCE=60
TELEGRAM_CADENCE=5

collect_and_wait() {
    local deadline=$((SECONDS + INTERVAL))

    # Drain: collect messages that arrived during the last claude run.
    # With the queue, this is simple — collect and check if inbox has files.
    collect_comms || true
    if [ -n "$(find "$INBOX_DIR" -name '*.jsonl' -type f 2>/dev/null | head -1)" ]; then
        return 0
    fi

    while [ $SECONDS -lt $deadline ]; do
        collect_comms || true

        # External sources: cadence-gated (less frequent than comms)
        local now=$SECONDS
        if [ $((now - LAST_EMAIL_CHECK)) -ge $EMAIL_CADENCE ]; then
            collect_email || true
            LAST_EMAIL_CHECK=$now
        fi
        if [ $((now - LAST_TELEGRAM_CHECK)) -ge $TELEGRAM_CADENCE ]; then
            collect_telegram || true
            LAST_TELEGRAM_CHECK=$now
        fi

        # Check inbox — any files means wake
        if [ -n "$(find "$INBOX_DIR" -name '*.jsonl' -type f 2>/dev/null | head -1)" ]; then
            return 0
        fi
        sleep "$COMMS_POLL_INTERVAL"
    done

    return 1
}

# Run claude with a prompt file. Optional: --resume <session_id>
# Sets CLAUDE_JSON to the raw JSON output.
run_claude() {
    local prompt_file="$1"
    local resume_sid="${2:-}"
    local resume_args=""
    [ -n "$resume_sid" ] && resume_args="--resume $resume_sid"
    local _err_file
    _err_file=$(mktemp /tmp/claude-err-XXXXXX)
    CLAUDE_JSON=$(cd "$PROJECT_DIR" && read_prompt "$prompt_file" | claude -p \
        $resume_args \
        --output-format json \
        --dangerously-skip-permissions \
        --max-turns "$MAX_TURNS" \
        9>&- 2>"$_err_file") || true
    local _stderr
    _stderr=$(cat "$_err_file" 2>/dev/null)
    rm -f "$_err_file"
    if [ -n "$_stderr" ]; then
        log "claude stderr: $_stderr"
        push_activity "error" "$(echo "$_stderr" | head -1 | cut -c1-200)"
    fi
}

# Fetch per-agent config from server before first session
if fetch_config; then
    log "Config from server: wake_channels=${WAKE_CHANNELS:-<mentions-only>}, poll_interval=$COMMS_POLL_INTERVAL, max_turns=$MAX_TURNS, rembeat=$INTERVAL"
else
    log "Using defaults: wake_channels=${WAKE_CHANNELS:-<mentions-only>}, poll_interval=$COMMS_POLL_INTERVAL"
fi

log "fagents daemon starting (agent: $AGENT, PID: $$, interval: ${INTERVAL}s, max-turns: $MAX_TURNS, channels: $CHANNELS)"

# First iteration — resume existing session if available, else create new
check_pause
OLD_SID=""
if [ -f "$SESSION_FILE" ]; then
    OLD_SID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
fi

if [ -n "$OLD_SID" ]; then
    log "Resuming session: $OLD_SID"
    run_claude "$PROMPT_REMBEAT" "$OLD_SID"
    SID=$(echo "$CLAUDE_JSON" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -z "$SID" ]; then
        log "Resume failed, creating new session..."
        run_claude "$PROMPT_REMBEAT"
        SID=$(echo "$CLAUDE_JSON" | jq -r '.session_id')
    fi
else
    log "Creating session..."
    run_claude "$PROMPT_REMBEAT"
    SID=$(echo "$CLAUDE_JSON" | jq -r '.session_id')
fi
INIT_JSON="$CLAUDE_JSON"

echo "$SID" > "$SESSION_FILE"
log "Session: $SID"

RESULT=$(echo "$INIT_JSON" | jq -r '.result // ""' 2>/dev/null)
[ -n "$RESULT" ] && log "Result: $RESULT"

# Awareness: collect state, push health, log summary
INTROSPECT="$SCRIPT_DIR/awareness/state.sh"
if [ -x "$INTROSPECT" ]; then
    (cd "$PROJECT_DIR" && "$INTROSPECT" "startup") 2>/dev/null >> "$DAEMON_LOG" || true
fi

# Check comms connectivity — warn if COMMS_URL is set but unreachable
check_comms() {
    if [ -n "$COMMS_URL" ] && [ -n "$COMMS_TOKEN" ]; then
        local resp
        resp=$(curl -s --max-time 3 -H "Authorization: Bearer $COMMS_TOKEN" \
            "$COMMS_URL/api/whoami" 2>/dev/null) || true
        local agent_name
        agent_name=$(echo "$resp" | jq -r '.agent // empty' 2>/dev/null) || true
        if [ -z "$agent_name" ]; then
            log "WARNING: fagents-comms unreachable at $COMMS_URL — check SSH tunnel"
            return 1
        fi
    fi
    return 0
}

# Activity stream management
ACTIVITY_STREAM="$SCRIPT_DIR/activity-stream.sh"
ensure_activity_stream() {
    if [ -x "$ACTIVITY_STREAM" ] && [ -n "$COMMS_URL" ] && [ -n "$COMMS_TOKEN" ]; then
        if [ -z "$STREAM_PID" ] || ! kill -0 "$STREAM_PID" 2>/dev/null; then
            "$ACTIVITY_STREAM" 9>&- &
            STREAM_PID=$!
            log "Activity stream started (PID: $STREAM_PID)"
        fi
    fi
}
ensure_activity_stream

# Startup comms check
check_comms || true

# Try to load subscriptions from server (overrides env CHANNELS if set)
if refresh_channels; then
    log "Subscriptions from server: ${CH_ARRAY[*]}"
else
    log "Using env CHANNELS: $CHANNELS"
fi

# Main loop
while true; do
    # Refresh config + subscriptions from server (non-blocking)
    fetch_config || true
    refresh_channels || true

    if collect_and_wait; then
        PROMPT_FILE="$PROMPT_MSG"
        # Extract wake channel from first comms message for hooks
        export WAKE_CHANNEL
        WAKE_CHANNEL=$(cat "$INBOX_DIR"/*.jsonl 2>/dev/null | jq -rs '
            [.[] | select(.source == "comms")] | first // {} | .channel // "general"
        ' 2>/dev/null) || WAKE_CHANNEL="general"
        [ -z "$WAKE_CHANNEL" ] && WAKE_CHANNEL="general"
        read_inbox || true
        log "[$AGENT] Woke on message (channel: $WAKE_CHANNEL, inbox: $INBOX_COUNT msgs)..."
    else
        PROMPT_FILE="$PROMPT_REMBEAT"
        export WAKE_CHANNEL="general"
        log "[$AGENT] Rembeat..."
    fi
    check_pause

    run_claude "$PROMPT_FILE" "$SID"

    # Archive processed inbox messages
    archive_inbox

    # Extract result text for daemon log
    RESULT=$(echo "$CLAUDE_JSON" | jq -r '.result // ""' 2>/dev/null)
    [ -n "$RESULT" ] && log "Result: $RESULT"

    # Check comms connectivity each cycle
    check_comms || true

    # Restart activity stream if it died
    ensure_activity_stream

    # Awareness: collect state, push health, log summary
    WAKE_TYPE="rembeat"
    [ "$PROMPT_FILE" = "$PROMPT_MSG" ] && WAKE_TYPE="msgbeat"
    if [ -x "$INTROSPECT" ]; then
        (cd "$PROJECT_DIR" && "$INTROSPECT" "$WAKE_TYPE") 2>/dev/null >> "$DAEMON_LOG" || true
    fi

    log "Rembeat complete."
done
