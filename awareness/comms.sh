#!/bin/bash
# Awareness: Comms Check
# Checks fagents-comms for PAUSE directives and new teammate messages.
# Uses a 30-second cache to avoid hammering the server.
# Usage: awareness/comms.sh
# Output (stdout): alert string, or empty if nothing noteworthy.
# Requires: AGENT env var (or defaults based on hostname)

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLIENT="$AUTONOMY_DIR/comms/client.sh"

[ -x "$CLIENT" ] || exit 0

CACHE_DIR="/tmp/.comms-check"
CACHE_FILE="$CACHE_DIR/last-ts"
CACHE_RESULT="$CACHE_DIR/result"
CACHE_INTERVAL=30
mkdir -p "$CACHE_DIR" 2>/dev/null || true

NOW=$(date +%s)
DO_CHECK=1

if [ -f "$CACHE_FILE" ]; then
    LAST=$(cat "$CACHE_FILE" 2>/dev/null || echo 0)
    LAST=${LAST:-0}
    ELAPSED=$((NOW - LAST))
    if [ "$ELAPSED" -lt "$CACHE_INTERVAL" ]; then
        DO_CHECK=0
        cat "$CACHE_RESULT" 2>/dev/null || true
        exit 0
    fi
fi

echo "$NOW" > "$CACHE_FILE"

# Fetch recent messages from monitored channels
CHANNELS="${CHANNELS:-general}"
IFS=',' read -ra _CH_ARRAY <<< "$CHANNELS"
MSGS=""
for CHANNEL in "${_CH_ARRAY[@]}"; do
    RESULT=$("$CLIENT" fetch "$CHANNEL" --since 2m 2>/dev/null) || true
    [ -n "$RESULT" ] && MSGS="${MSGS}${RESULT}"$'\n'
done

COMMS_CTX=""

if [ -n "$MSGS" ]; then
    # PAUSE/GO check — Juho only
    JUHO_MSGS=$(echo "$MSGS" | grep '\[Juho\]' || true)
    if [ -n "$JUHO_MSGS" ]; then
        LATEST_JUHO=$(echo "$JUHO_MSGS" | tail -1)
        if echo "$LATEST_JUHO" | grep -qP '\] GO\b'; then
            : # GO cancels PAUSE
        elif echo "$JUHO_MSGS" | grep -qP '\] PAUSE(\s|$)'; then
            COMMS_CTX="PAUSE FROM JUHO — STOP NOW. Post state to comms. Wait for GO."
        fi
    fi

    # New teammate messages
    if [ -z "$COMMS_CTX" ]; then
        if [ -n "${AGENT:-}" ]; then
            SELF="$AGENT"
        else
            SELF="unknown"
        fi

        TEAMMATE_MSGS=$(echo "$MSGS" | grep -v "\[$SELF\]" | grep '\[' || true)
        if [ -n "$TEAMMATE_MSGS" ]; then
            PREV_TS=$(cat "$CACHE_DIR/last-alert-ts" 2>/dev/null || echo 0)
            PREV_TS=${PREV_TS:-0}
            LATEST_TS=$(echo "$TEAMMATE_MSGS" | tail -1 | grep -oP '^\[\K[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' || true)
            if [ -n "$LATEST_TS" ]; then
                TEAM_EPOCH=$(date -d "$LATEST_TS" +%s 2>/dev/null || echo 0)
                if [ "$TEAM_EPOCH" -gt "$PREV_TS" ]; then
                    echo "$TEAM_EPOCH" > "$CACHE_DIR/last-alert-ts"
                    SENDER=$(echo "$TEAMMATE_MSGS" | tail -1 | grep -oP '\[\K[^\]]+(?=\])' | tail -1 || echo "teammate")
                    COMMS_CTX="New message from $SENDER on comms. Check when convenient."
                fi
            fi
        fi
    fi
fi

echo "$COMMS_CTX" > "$CACHE_RESULT"
[ -n "$COMMS_CTX" ] && echo "$COMMS_CTX"

exit 0
