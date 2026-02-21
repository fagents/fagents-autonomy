#!/bin/bash

# Activity Push — PostToolUse hook (async)
# Thin orchestrator: gets context % from awareness, pushes to server.
# Runs async — does not block Claude.
# Trigger: PostToolUse

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Need COMMS_URL and COMMS_TOKEN from env
COMMS_URL="${COMMS_URL:-http://127.0.0.1:9754}"
COMMS_TOKEN="${COMMS_TOKEN:-}"

# Determine agent name
if [ -z "${AGENT:-}" ]; then
    echo "WARNING: AGENT not set — skipping health push" >&2
    exit 0
fi

# Awareness: context window usage
PCT=""
CTX_OUT=$("$AUTONOMY_DIR/awareness/context.sh" 2>/dev/null) || true
if [ -n "$CTX_OUT" ]; then
    eval "$CTX_OUT"
    PCT="${pct:-}"
fi

[ -z "$PCT" ] && exit 0
[ -z "$COMMS_TOKEN" ] && exit 0

# Read tool info from stdin
INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name','?'))" 2>/dev/null || echo "?")

# Push context to health endpoint
curl -s -X POST --max-time 3 \
    -H "Authorization: Bearer $COMMS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"context_pct\":$PCT,\"status\":\"active\",\"last_tool\":\"$TOOL\"}" \
    "$COMMS_URL/api/agents/$AGENT/health" >/dev/null 2>&1 || true

exit 0
