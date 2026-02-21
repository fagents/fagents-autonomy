#!/bin/bash

# Session Stop — Stop hook
# Posts a final message to comms and updates health when session ends.
# Uses WAKE_CHANNEL (set by daemon.sh) to post to the right channel.
# Trigger: Stop

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

COMMS_URL="${COMMS_URL:-http://127.0.0.1:9754}"
COMMS_TOKEN="${COMMS_TOKEN:-}"
CHANNEL="${WAKE_CHANNEL:-general}"

if [ -z "${AGENT:-}" ]; then
    echo "WARNING: AGENT not set — skipping session-stop" >&2
    exit 0
fi

[ -z "$COMMS_TOKEN" ] && exit 0

# Read stop event from stdin
INPUT=$(cat)
# Extract last message as the stop summary (truncated)
REASON=$(echo "$INPUT" | python3 -c "
import json,sys
d = json.load(sys.stdin)
msg = d.get('last_assistant_message','')
# Truncate to first line, max 200 chars
line = msg.split(chr(10))[0][:200] if msg else 'no message'
print(line)
" 2>/dev/null || echo "unknown")

# Post stop notice to comms
curl -s -X POST --max-time 5 \
    -H "Authorization: Bearer $COMMS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"message\":\"Session ended: $REASON\"}" \
    "$COMMS_URL/api/channels/$CHANNEL/messages" >/dev/null 2>&1 || true

# Push final health update with stopped status
curl -s -X POST --max-time 3 \
    -H "Authorization: Bearer $COMMS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"stopped\",\"stop_reason\":\"$REASON\"}" \
    "$COMMS_URL/api/agents/$AGENT/health" >/dev/null 2>&1 || true

exit 0
