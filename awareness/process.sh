#!/bin/bash
# Collect process metadata about the current Claude invocation.
# Outputs JSON: {"is_daemon": bool, "has_resume": bool, "session_id": "...", "pid": N, "daemon_pid": N}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_FILE="$SCRIPT_DIR/../.session"

# Find the backend process (not bash shells that mention it in args)
case "${DAEMON_BACKEND:-claude}" in
    claude) BACKEND_LINE=$(ps aux 2>/dev/null | grep '[c]laude -p' | grep -v '/bin/bash' | head -1) || true ;;
    codex)  BACKEND_LINE=$(ps aux 2>/dev/null | grep '[c]odex exec' | grep -v '/bin/bash' | head -1) || true ;;
    *)      BACKEND_LINE="" ;;
esac

is_daemon=false
has_resume=false
session_id=""
backend_pid=0
daemon_pid=0

if [ -n "$BACKEND_LINE" ]; then
    backend_pid=$(echo "$BACKEND_LINE" | awk '{print $2}')
    case "${DAEMON_BACKEND:-claude}" in
        claude)
            if echo "$BACKEND_LINE" | grep -q '\-\-resume'; then
                has_resume=true
                session_id=$(echo "$BACKEND_LINE" | sed -n 's/.*--resume \([^ ]*\).*/\1/p')
            fi
            ;;
        codex)
            if echo "$BACKEND_LINE" | grep -q ' resume '; then
                has_resume=true
                session_id=$(echo "$BACKEND_LINE" | sed -n 's/.* resume \([^ ]*\).*/\1/p')
            fi
            ;;
    esac
fi

# Check if daemon.sh is running
DAEMON_LINE=$(ps aux 2>/dev/null | grep 'daemon\.sh' | grep -v grep | head -1) || true
if [ -n "$DAEMON_LINE" ]; then
    is_daemon=true
    daemon_pid=$(echo "$DAEMON_LINE" | awk '{print $2}')
fi

# Fallback session ID from file
if [ -z "$session_id" ] && [ -f "$SESSION_FILE" ]; then
    session_id=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
fi

jq -nc \
    --argjson is_daemon "$is_daemon" \
    --argjson has_resume "$has_resume" \
    --arg session_id "$session_id" \
    --argjson pid "$backend_pid" \
    --argjson daemon_pid "$daemon_pid" \
    '{is_daemon: $is_daemon, has_resume: $has_resume, session_id: $session_id, pid: $pid, daemon_pid: $daemon_pid}'
