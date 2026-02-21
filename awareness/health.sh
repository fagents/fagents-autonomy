#!/bin/bash
# Push agent health to fagents-comms server.
# Usage: report-health.sh <state_json_path>
#
# Reads .state.json and pushes context_pct, tokens, status, last_tool to server.
# SOUL.md and MEMORY.md are only read and sent when their content changes
# (hash-based change detection). The server merges partial pushes, so
# existing soul/memory data survives health-only updates.
# Requires COMMS_URL and COMMS_TOKEN env vars.

set -euo pipefail

STATE_FILE="${1:-}"
COMMS_URL="${COMMS_URL:-}"
COMMS_TOKEN="${COMMS_TOKEN:-}"

if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ] || [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
    exit 0  # silently skip if not configured
fi

# Check if SOUL.md / MEMORY.md changed since last push (shared change-detection)
AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INCLUDE_SOUL=false
"$AUTONOMY_DIR/awareness/has-changed.sh" "soul-memory" memory/SOUL.md memory/MEMORY.md && INCLUDE_SOUL=true

# Extract fields from state JSON — skip if no context data (avoids overwriting hook's good data)
PAYLOAD=$(python3 -c "
import json, sys, os
include_soul = sys.argv[2] == 'true'
with open(sys.argv[1]) as f:
    s = json.load(f)
if s.get('context_pct', 0) == 0:
    sys.exit(1)  # no context data — don't overwrite
payload = {
    'context_pct': s.get('context_pct', 0),
    'tokens': s.get('tokens', 0),
    'status': 'active',
    'last_tool': s.get('wake_reason', 'heartbeat'),
}
if include_soul:
    for name, key in [('memory/SOUL.md', 'soul_text'), ('memory/MEMORY.md', 'memory_text')]:
        if os.path.isfile(name):
            with open(name) as f:
                text = f.read().strip()
            if text:
                payload[key] = text
    import subprocess
    for fname, key in [('memory/MEMORY.md', 'memory_diff'), ('memory/SOUL.md', 'soul_diff')]:
        try:
            diff = subprocess.run(
                ['git', 'log', '-1', '-p', '--follow', '--diff-filter=AM', '--format=', '--', fname],
                capture_output=True, text=True, timeout=5
            ).stdout.strip()
            if diff:
                payload[key] = diff
        except Exception:
            pass
print(json.dumps(payload))
" "$STATE_FILE" "$INCLUDE_SOUL" 2>/dev/null) || exit 0

# Resolve agent name
AGENT=$(curl -s --max-time 3 -H "Authorization: Bearer $COMMS_TOKEN" \
    "$COMMS_URL/api/whoami" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent',''))" 2>/dev/null) || exit 0

if [ -z "$AGENT" ]; then exit 0; fi

curl -s --max-time 3 -X POST \
    -H "Authorization: Bearer $COMMS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$COMMS_URL/api/agents/$AGENT/health" >/dev/null 2>&1 || true
