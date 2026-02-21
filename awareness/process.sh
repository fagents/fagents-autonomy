#!/bin/bash
# Collect process metadata about the current Claude invocation.
# Outputs JSON: {"is_daemon": bool, "has_resume": bool, "session_id": "...", "pid": N, "daemon_pid": N}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_FILE="$SCRIPT_DIR/../.session"

# Find the actual claude binary (not bash shells that mention "claude" in args)
CLAUDE_LINE=$(ps aux 2>/dev/null | grep '[c]laude -p' | grep -v '/bin/bash' | head -1)

is_daemon=false
has_resume=false
session_id=""
claude_pid=0
daemon_pid=0

if [ -n "$CLAUDE_LINE" ]; then
    claude_pid=$(echo "$CLAUDE_LINE" | awk '{print $2}')
    if echo "$CLAUDE_LINE" | grep -q '\-\-resume'; then
        has_resume=true
        session_id=$(echo "$CLAUDE_LINE" | grep -oP '(?<=--resume )\S+')
    fi
fi

# Check if daemon.sh is running
DAEMON_LINE=$(ps aux 2>/dev/null | grep 'daemon\.sh' | grep -v grep | head -1)
if [ -n "$DAEMON_LINE" ]; then
    is_daemon=true
    daemon_pid=$(echo "$DAEMON_LINE" | awk '{print $2}')
fi

# Fallback session ID from file
if [ -z "$session_id" ] && [ -f "$SESSION_FILE" ]; then
    session_id=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
fi

echo "{\"is_daemon\": $is_daemon, \"has_resume\": $has_resume, \"session_id\": \"$session_id\", \"pid\": $claude_pid, \"daemon_pid\": $daemon_pid}"
