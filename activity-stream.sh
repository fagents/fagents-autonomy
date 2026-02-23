#!/bin/bash
# Real-time activity streamer — tails session JSONL and pushes events to fagents-comms.
#
# Usage: activity-stream.sh
#   Requires: COMMS_URL, COMMS_TOKEN env vars
#
# Runs as background process. Daemon starts/stops it automatically.
# Pushes tool use, thoughts, heartbeats, wakeups, compactions as they happen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSONL_DIR="${CLAUDE_PROJECT_DIR:-${PROJECT_DIR:-$SCRIPT_DIR/..}}/.introspection-logs"

COMMS_URL="${COMMS_URL:-}"
COMMS_TOKEN="${COMMS_TOKEN:-}"

if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
    echo "activity-stream: COMMS_URL and COMMS_TOKEN required" >&2
    exit 1
fi

# Resolve agent name once
AGENT=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
    "$COMMS_URL/api/whoami" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent',''))" 2>/dev/null) || true

if [ -z "$AGENT" ]; then
    echo "activity-stream: could not resolve agent name" >&2
    exit 1
fi

push_events() {
    # Push JSON array of events to fagents-comms
    local payload="$1"
    curl -s --max-time 3 -X POST \
        -H "Authorization: Bearer $COMMS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$COMMS_URL/api/agents/$AGENT/activity" >/dev/null 2>&1 || true
}

# Find the most recent JSONL
JSONL=$(ls -t "$JSONL_DIR"/*.jsonl 2>/dev/null | head -1)
if [ -z "$JSONL" ]; then
    echo "activity-stream: no JSONL found in $JSONL_DIR" >&2
    exit 1
fi

# Kill any existing activity-stream processes (from previous daemon restarts).
# Must match both the bash wrapper AND the orphaned tail/python3 pipeline children
# that survive after the wrapper is killed.
for pid in $(pgrep -f "activity-stream.sh|tail.*-f.*jsonl" 2>/dev/null || true); do
    if [ "$pid" != "$$" ]; then
        kill "$pid" 2>/dev/null || true
    fi
done

echo "activity-stream: tailing $JSONL as $AGENT" >&2

# Tail with small lookback to catch wakeup/heartbeat markers on restart.
# -n 0 misses the user prompt entry if activity-stream restarts mid-beat.
# -n 3 catches it. Duplicate events are harmless in an activity log.
tail -n 3 -f "$JSONL" | python3 -u -c "
import json
import subprocess
import sys
import os

agent = '$AGENT'
comms_url = '$COMMS_URL'
comms_token = '$COMMS_TOKEN'

def summarize_tool(name, inp):
    if name == 'Bash':
        desc = inp.get('description', '')
        cmd = inp.get('command', '')
        return desc if desc else (cmd[:80] + '...' if len(cmd) > 80 else cmd)
    elif name == 'Read':
        return inp.get('file_path', '?').rsplit('/', 1)[-1]
    elif name == 'Edit':
        return 'edit ' + inp.get('file_path', '?').rsplit('/', 1)[-1]
    elif name == 'Write':
        return 'write ' + inp.get('file_path', '?').rsplit('/', 1)[-1]
    elif name == 'Grep':
        return 'grep \"' + inp.get('pattern', '?')[:40] + '\"'
    elif name == 'Glob':
        return 'glob \"' + inp.get('pattern', '?') + '\"'
    elif name == 'TodoWrite':
        todos = inp.get('todos', [])
        in_prog = [t for t in todos if t.get('status') == 'in_progress']
        return in_prog[0].get('activeForm', 'updating todos') if in_prog else f'{len(todos)} items'
    elif name == 'Task':
        return inp.get('description', 'subagent')
    else:
        return str(inp)[:60]

def push(events):
    if not events:
        return
    payload = json.dumps({'events': events})
    try:
        import urllib.request
        req = urllib.request.Request(
            f'{comms_url}/api/agents/{agent}/activity',
            data=payload.encode(),
            headers={
                'Authorization': f'Bearer {comms_token}',
                'Content-Type': 'application/json',
            },
            method='POST',
        )
        urllib.request.urlopen(req, timeout=3)
    except Exception:
        pass

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue

    ts = d.get('timestamp', '')
    entry_type = d.get('type')
    events = []

    if entry_type == 'assistant':
        msg = d.get('message', {})
        content = msg.get('content', [])
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get('type')
            if btype == 'text':
                text = block.get('text', '').strip()
                if text:
                    summary = text[:200] + ('...' if len(text) > 200 else '')
                    events.append({'ts': ts, 'type': 'thought', 'summary': summary})
            elif btype == 'tool_use':
                name = block.get('name', '?')
                inp = block.get('input', {})
                detail = summarize_tool(name, inp)
                events.append({'ts': ts, 'type': 'tool', 'summary': name, 'detail': detail})

    elif entry_type == 'user':
        msg = d.get('message', {})
        content = msg.get('content', '')
        text = ''
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    if block.get('type') == 'tool_result':
                        continue
                    text += block.get('text', '')
                elif isinstance(block, str):
                    text += block

        if 'This is a heartbeat' in text:
            events.append({'ts': ts, 'type': 'heartbeat', 'summary': 'Heartbeat'})
        elif 'New message' in text and 'someone wrote to you' in text:
            events.append({'ts': ts, 'type': 'wakeup', 'summary': 'Message wakeup'})
        elif 'continued from a previous conversation' in text:
            events.append({'ts': ts, 'type': 'compaction', 'summary': 'Context compacted'})

    if events:
        push(events)
" 2>/dev/null
