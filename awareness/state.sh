#!/bin/bash
# Awareness: State Collector
# Collects agent state from awareness scripts, writes snapshot, reports health.
#
# Usage: awareness/state.sh [wake_reason]
#   wake_reason: "heartbeat", "message", "startup" (default: heartbeat)
#
# Outputs one summary line to stdout (for daemon log).
# Writes full state to $PROJECT_DIR/.autonomy/.state.json.
# Pushes health to fagents-comms if COMMS_URL/COMMS_TOKEN are set.

set -euo pipefail

AWARENESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$AWARENESS_DIR/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/.state.json"
WAKE_REASON="${1:-heartbeat}"
TS=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ── Collect context ──
CTX_PCT=0
CTX_TOKENS=0
CTX_SIZE=0
CTX_LABEL="UNKNOWN"

CTX_OUT=$("$AWARENESS_DIR/context.sh" 2>/dev/null) || true
if [ -n "$CTX_OUT" ]; then
    eval "$CTX_OUT"
    CTX_PCT="${pct:-0}"
    CTX_TOKENS="${used_tokens:-0}"
    CTX_SIZE="${ctx_size:-0}"
    CTX_LABEL="${label_long:-UNKNOWN}"
fi

# ── Collect process metadata ──
PROC=$("$AWARENESS_DIR/process.sh" 2>/dev/null || echo '{}')

# ── Assemble state ──
python3 -c "
import json, sys

proc = json.loads(sys.argv[1])

state = {
    'ts': sys.argv[2],
    'wake_reason': sys.argv[3],
    'context_pct': int(sys.argv[4]),
    'tokens': int(sys.argv[5]),
    'ctx_size': int(sys.argv[6]),
    'label': sys.argv[7],
    'is_daemon': proc.get('is_daemon', False),
    'has_resume': proc.get('has_resume', False),
    'session_id': proc.get('session_id', ''),
    'pid': proc.get('pid', 0),
    'daemon_pid': proc.get('daemon_pid', 0),
}

# Write state file
with open(sys.argv[8], 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')

# Output summary line
mode = 'daemon' if state['is_daemon'] else 'interactive'
sid_short = state['session_id'][:8] if state['session_id'] else '?'
print(f'[{state[\"ts\"]}] {state[\"label\"]} {state[\"context_pct\"]}% ~{state[\"tokens\"]}tok | {mode} session:{sid_short} | wake:{state[\"wake_reason\"]}')
" "$PROC" "$TS" "$WAKE_REASON" "$CTX_PCT" "$CTX_TOKENS" "$CTX_SIZE" "$CTX_LABEL" "$STATE_FILE"

# ── Report health to fagents-comms ──
"$AWARENESS_DIR/health.sh" "$STATE_FILE" &
