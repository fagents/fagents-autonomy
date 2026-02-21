#!/bin/bash
# Freeturtle Daemon — autonomous agent loop via Claude Code
#
# Usage: AGENT=ftw COMMS_URL=... COMMS_TOKEN=... ./daemon.sh [interval_seconds]
#
# Required env vars:
#   AGENT                  Agent identity (for logging)
#   COMMS_URL              fagents-comms server URL (e.g. http://127.0.0.1:9754)
#   COMMS_TOKEN            Agent auth token from fagents-comms
#
# Optional env vars:
#   CHANNELS=general       Comma-separated channels to follow (default: general)
#   PROMPT_HEARTBEAT       Heartbeat prompt file (default: heartbeat.md)
#   PROMPT_MSG             Message wake prompt file (default: heartbeat-msg.md)
#   COMMS_POLL_INTERVAL=1  Seconds between HTTP polls (default: 1)
#   WAKE_MODE=mentions     mentions|channel (default: from server config)
#   MAX_TURNS=50           Max turns per heartbeat
#
# Requires: jq, curl
#
# Controls (state in $PROJECT_DIR/.autonomy/):
#   Pause:  touch $PROJECT_DIR/.autonomy/daemon.pause
#   Stop:   kill $(cat $PROJECT_DIR/.autonomy/daemon.pid)
#
# Examples:
#   AGENT=ftw CHANNELS=general,fagent-dev COMMS_URL=http://127.0.0.1:9754 COMMS_TOKEN=<tok> ./daemon.sh 300
#   AGENT=ftl COMMS_URL=http://localhost:9754 COMMS_TOKEN=<tok> ./daemon.sh 300

set -euo pipefail

# ── Validate required env vars ──
AGENT="${AGENT:-}"
COMMS_URL="${COMMS_URL:-}"
COMMS_TOKEN="${COMMS_TOKEN:-}"
COMMS_POLL_INTERVAL="${COMMS_POLL_INTERVAL:-1}"
WAKE_MODE="${WAKE_MODE:-}"  # mentions|channel — env overrides server config

if [ -z "$AGENT" ] || [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
    echo "Freeturtle Daemon — autonomous agent loop"
    echo ""
    echo "Required environment variables:"
    echo "  AGENT        Agent identity (ftw or ftl)"
    echo "  COMMS_URL    fagents-comms server URL"
    echo "  COMMS_TOKEN  Agent auth token"
    echo ""
    echo "Usage:"
    echo "  AGENT=ftl COMMS_URL=http://localhost:9754 COMMS_TOKEN=<token> $0 [interval]"
    exit 1
fi

# ── Configurable defaults (all overridable via env) ──
CHANNELS="${CHANNELS:-general}"
PROMPT_HEARTBEAT="${PROMPT_HEARTBEAT:-heartbeat.md}"
PROMPT_MSG="${PROMPT_MSG:-heartbeat-msg.md}"
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

# Snapshot WAKE_MODE from env — if user set it, server config won't override.
_ENV_WAKE_MODE="$WAKE_MODE"

# Fetch per-agent config from server. Updates WAKE_MODE, COMMS_POLL_INTERVAL,
# MAX_TURNS, and INTERVAL from server config. Env vars override where noted.
fetch_config() {
    if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
        return 1
    fi
    local resp
    resp=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
        "$COMMS_URL/api/agents/$AGENT/config" 2>/dev/null) || return 1
    local server_wake_mode server_poll_interval server_max_turns server_heartbeat
    server_wake_mode=$(echo "$resp" | jq -r '.config.wake_mode // empty' 2>/dev/null) || true
    server_poll_interval=$(echo "$resp" | jq -r '.config.poll_interval // empty' 2>/dev/null) || true
    server_max_turns=$(echo "$resp" | jq -r '.config.max_turns // empty' 2>/dev/null) || true
    server_heartbeat=$(echo "$resp" | jq -r '.config.heartbeat_interval // empty' 2>/dev/null) || true
    # WAKE_MODE: env overrides server
    if [ -z "$_ENV_WAKE_MODE" ] && [ -n "$server_wake_mode" ]; then
        WAKE_MODE="$server_wake_mode"
    fi
    # Poll interval: always use server value (env default is just fallback)
    if [ -n "$server_poll_interval" ]; then
        COMMS_POLL_INTERVAL="$server_poll_interval"
    fi
    # Max turns: server overrides env default
    if [ -n "$server_max_turns" ]; then
        MAX_TURNS="$server_max_turns"
    fi
    # Heartbeat interval: server overrides CLI arg
    if [ -n "$server_heartbeat" ]; then
        INTERVAL="$server_heartbeat"
    fi
    return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"
PAUSE_FILE="$STATE_DIR/daemon.pause"
PID_FILE="$STATE_DIR/daemon.pid"
SESSION_FILE="$STATE_DIR/daemon.session"
DAEMON_LOG="$STATE_DIR/daemon.log"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
INTERVAL="${1:-300}"

# Prompts are read from files at each use — edit without restarting the daemon.
# {{CHANNELS_BLOCK}} in the prompt is replaced with channel-specific instructions.
read_prompt() {
    local file="$PROMPTS_DIR/$1"
    if [ -f "$file" ]; then
        local content
        content=$(cat "$file")
        # Build channel instruction block
        # Message-triggered heartbeats get --since 10m (mentions already injected)
        # Regular heartbeats derive --since from INTERVAL (with 20% padding, minimum 60m)
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
        # Inject pre-fetched mentions (from fetch_unread) or remove placeholder
        if [ -n "$WAKE_MENTIONS" ]; then
            local mentions_block="Messages that triggered this wake:"$'\n'"$WAKE_MENTIONS"
            content="${content//\{\{MENTIONS_BLOCK\}\}/$mentions_block}"
        else
            content="${content//\{\{MENTIONS_BLOCK\}\}/}"
        fi
        echo "$content"
    else
        echo "ERROR: prompt file not found: $file" >&2
        echo "Heartbeat prompt file missing. Check $file"
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

# Fetch @mentions/replies directed at this agent and mark them as read.
# Sets WAKE_MENTIONS to formatted message text (empty if none).
# Returns 0 if mentions found, 1 if none.
WAKE_MENTIONS=""
fetch_unread() {
    WAKE_MENTIONS=""
    if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
        return 1
    fi
    # In mentions mode, only fetch @mentions. In channel mode, fetch all unread.
    local url="$COMMS_URL/api/unread?mark_read=1"
    [ "${WAKE_MODE:-mentions}" = "mentions" ] && url="$url&mentions=1"
    local resp
    resp=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
        "$url" 2>/dev/null) || return 1
    local mention_count
    mention_count=$(echo "$resp" | jq '[.channels[]?.unread_count // 0] | add // 0' 2>/dev/null) || return 1
    if [ "$mention_count" -gt 0 ] 2>/dev/null; then
        # Format mentions for prompt injection
        WAKE_MENTIONS=$(echo "$resp" | jq -r '
            .channels[] | select(.unread_count > 0) |
            "--- #\(.channel) (\(.unread_count) mentions) ---",
            (.messages[] | "[\(.ts)] [\(.sender)] \(.message)"),
            ""
        ' 2>/dev/null) || true
        return 0
    fi
    return 1
}

# Wait for message or timeout.
# Returns 0 if wake triggered (message), 1 if timeout (regular heartbeat).
# WAKE_MODE controls behavior:
#   mentions (default): only wake on @mentions/replies directed at this agent
#   channel: wake on ANY new message in subscribed channels
wait_for_wake() {
    local deadline=$((SECONDS + INTERVAL))

    # Get baseline total from /api/poll
    local baseline_total="-1"
    if [ -n "$COMMS_URL" ] && [ -n "$COMMS_TOKEN" ]; then
        baseline_total=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
            "$COMMS_URL/api/poll" 2>/dev/null \
            | jq -r '.total // -1' 2>/dev/null) || baseline_total="-1"
    fi

    while [ $SECONDS -lt $deadline ]; do
        if [ -n "$COMMS_URL" ] && [ -n "$COMMS_TOKEN" ]; then
            # Single HTTP call to check for new messages
            local current_total
            current_total=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
                "$COMMS_URL/api/poll" 2>/dev/null \
                | jq -r '.total // -1' 2>/dev/null) || current_total="-1"

            # If total changed and we have valid counts, check for wake
            if [ "$current_total" != "$baseline_total" ] && \
               [ "$current_total" != "-1" ] && [ "$baseline_total" != "-1" ]; then
                if [ "${WAKE_MODE:-mentions}" = "channel" ]; then
                    # Channel mode: wake on any new message
                    fetch_unread || true  # still try to grab mentions for context
                    return 0
                else
                    # Mentions mode: only wake if messages are directed at us
                    if fetch_unread; then
                        return 0
                    fi
                fi
                # New messages but not for us — update baseline, keep sleeping
                baseline_total="$current_total"
            fi
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
    CLAUDE_JSON=$(cd "$PROJECT_DIR" && read_prompt "$prompt_file" | claude -p \
        $resume_args \
        --output-format json \
        --dangerously-skip-permissions \
        --max-turns "$MAX_TURNS" \
        9>&- 2>/dev/null) || true
}

# Fetch per-agent config from server before first session
if fetch_config; then
    log "Config from server: wake_mode=${WAKE_MODE:-mentions}, poll_interval=$COMMS_POLL_INTERVAL, max_turns=$MAX_TURNS, heartbeat=$INTERVAL"
else
    log "Using defaults: wake_mode=${WAKE_MODE:-mentions}, poll_interval=$COMMS_POLL_INTERVAL"
fi

log "Freeturtle daemon starting (agent: $AGENT, PID: $$, interval: ${INTERVAL}s, max-turns: $MAX_TURNS, channels: $CHANNELS)"

# First iteration — resume existing session if available, else create new
check_pause
OLD_SID=""
if [ -f "$SESSION_FILE" ]; then
    OLD_SID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
fi

if [ -n "$OLD_SID" ]; then
    log "Resuming session: $OLD_SID"
    run_claude "$PROMPT_HEARTBEAT" "$OLD_SID"
    SID=$(echo "$CLAUDE_JSON" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -z "$SID" ]; then
        log "Resume failed, creating new session..."
        run_claude "$PROMPT_HEARTBEAT"
        SID=$(echo "$CLAUDE_JSON" | jq -r '.session_id')
    fi
else
    log "Creating session..."
    run_claude "$PROMPT_HEARTBEAT"
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

    if wait_for_wake; then
        PROMPT_FILE="$PROMPT_MSG"
        # Extract wake channel from mentions for Stop hook
        export WAKE_CHANNEL
        WAKE_CHANNEL=$(echo "$WAKE_MENTIONS" | grep -oP '(?<=--- #)\S+' | head -1)
        [ -z "$WAKE_CHANNEL" ] && WAKE_CHANNEL="general"
        log "[$AGENT] Woke on message (channel: $WAKE_CHANNEL)..."
    else
        PROMPT_FILE="$PROMPT_HEARTBEAT"
        export WAKE_CHANNEL="general"
        log "[$AGENT] Heartbeat..."
    fi
    check_pause

    run_claude "$PROMPT_FILE" "$SID"

    # Extract result text for daemon log
    RESULT=$(echo "$CLAUDE_JSON" | jq -r '.result // ""' 2>/dev/null)
    [ -n "$RESULT" ] && log "Result: $RESULT"

    # Check comms connectivity each cycle
    check_comms || true

    # Restart activity stream if it died
    ensure_activity_stream

    # Awareness: collect state, push health, log summary
    WAKE_TYPE="heartbeat"
    [ "$PROMPT_FILE" = "$PROMPT_MSG" ] && WAKE_TYPE="message"
    if [ -x "$INTROSPECT" ]; then
        (cd "$PROJECT_DIR" && "$INTROSPECT" "$WAKE_TYPE") 2>/dev/null >> "$DAEMON_LOG" || true
    fi

    log "Heartbeat complete."
done
