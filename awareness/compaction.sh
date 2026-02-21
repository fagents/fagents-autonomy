#!/bin/bash
# Awareness: Compaction Detection
# Tracks context % across calls. When a large drop is detected (30+ points),
# injects a reminder to re-read SOUL.md, TEAM.md, and MEMORY.md.
# Usage: awareness/compaction.sh <current_pct>
# Output (stdout): alert string if compaction detected, empty otherwise.
# State file: $PROJECT_DIR/.autonomy/.compact (last seen context %)

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/.compact"
CURRENT_PCT="${1:-0}"

# Need a numeric value
[ "$CURRENT_PCT" -gt 0 ] 2>/dev/null || exit 0

# Read last stored value
LAST_PCT=0
[ -f "$STATE_FILE" ] && LAST_PCT=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')
[ "$LAST_PCT" -gt 0 ] 2>/dev/null || LAST_PCT=0

# Store current value
echo "$CURRENT_PCT" > "$STATE_FILE"

# Detect compaction: current is 30+ points below last stored
DROP=$(( LAST_PCT - CURRENT_PCT ))
if [ "$DROP" -ge 30 ]; then
    echo "COMPACTION DETECTED — Re-read SOUL.md, TEAM.md. Check MEMORY.md After Compaction section."
fi
