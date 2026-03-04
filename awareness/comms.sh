#!/bin/bash
# Awareness: PAUSE check
# Scans inbox for PAUSE/GO directives from any team member.
# No network calls — reads local .jsonl files only.
# Usage: awareness/comms.sh
# Output (stdout): PAUSE alert with sender and message, or empty.

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-/home/$(whoami)/workspace/$(whoami)}"
INBOX_DIR="$PROJECT_DIR/.queue/inbox"

[ -d "$INBOX_DIR" ] || exit 0

# Scan inbox for PAUSE or GO (files sort by timestamp in filename)
PAUSE_FROM=""
PAUSE_BODY=""
for f in "$INBOX_DIR"/*.jsonl; do
    [ -f "$f" ] || continue
    body=$(jq -r '.body // ""' "$f" 2>/dev/null) || continue
    if echo "$body" | grep -qiE '^GO( |$)'; then
        PAUSE_FROM=""
        PAUSE_BODY=""
    elif echo "$body" | grep -qiE '^PAUSE( |$)'; then
        PAUSE_FROM=$(jq -r '.from // "someone"' "$f" 2>/dev/null)
        PAUSE_BODY="$body"
    fi
done

if [ -n "$PAUSE_FROM" ]; then
    cat <<EOF
**PAUSE — MANDATORY STOP**
From: $PAUSE_FROM
Message: $PAUSE_BODY

YOU MUST STOP IMMEDIATELY. Do not continue your current task.
1. Post your current state to comms right now
2. Do NOT make any more tool calls after posting
3. Wait for GO before resuming

This is not optional. Stop what you are doing.
EOF
fi

exit 0
