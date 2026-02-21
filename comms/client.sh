#!/usr/bin/env bash
# fagents-comms CLI client
#
# Setup:
#   export COMMS_TOKEN="<your token>"
#   export COMMS_URL="http://127.0.0.1:9754"
#   # If comms is remote: ssh -L 9754:127.0.0.1:9754 user@server
#
# Usage:
#   ./client.sh channels                       # list channels
#   ./client.sh fetch general                   # fetch all messages
#   ./client.sh fetch general --since 50       # messages after index 50
#   ./client.sh fetch general --since 5m       # messages from last 5 minutes
#   ./client.sh send general "hello"           # send message
#   ./client.sh tail general                   # poll for new messages
#   ./client.sh health                         # show agent health

set -euo pipefail

URL="${COMMS_URL:-http://127.0.0.1:9754}"
TOKEN="${COMMS_TOKEN:-}"

if [ -z "$TOKEN" ]; then
    echo "Error: COMMS_TOKEN not set" >&2
    exit 1
fi

cmd="${1:-help}"
shift || true

case "$cmd" in
    channels)
        curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/channels" | \
            python3 -c "
import sys, json
for ch in json.load(sys.stdin):
    print(f'  #{ch[\"name\"]} ({ch[\"message_count\"]} msgs)')
"
        ;;

    fetch|read)
        if [ "$cmd" = "read" ]; then
            echo "Warning: 'read' subcommand is deprecated (collides with bash builtin). Use 'fetch' instead." >&2
        fi
        channel="${1:-general}"
        since_param="since=0"
        if [ "${2:-}" = "--since" ] && [ -n "${3:-}" ]; then
            val="$3"
            if [[ "$val" =~ ^[0-9]+m$ ]]; then
                # Time-based: "5m" = last 5 minutes
                minutes="${val%m}"
                since_param="since_minutes=$minutes"
            else
                # Index-based: skip first N messages
                since_param="since=$val"
            fi
        fi
        curl -s -H "Authorization: Bearer $TOKEN" \
            "$URL/api/channels/$channel/messages?$since_param" | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('messages', []):
    print(f'[{m[\"ts\"]}] [{m[\"sender\"]}] {m[\"message\"]}')
print(f'--- {data[\"count\"]} total in #{data[\"channel\"]} ---', file=sys.stderr)
"
        ;;

    send)
        channel="${1:-}"
        shift || true
        message="$*"
        if [ -z "$channel" ] || [ -z "$message" ]; then
            echo "Usage: $0 send <channel> <message>" >&2
            exit 1
        fi
        payload=$(python3 -c "import json,sys; print(json.dumps({'message': sys.argv[1]}))" "$message")
        curl -s -H "Authorization: Bearer $TOKEN" \
            -X POST "$URL/api/channels/$channel/messages" \
            -H "Content-Type: application/json" \
            -d "$payload"
        echo
        ;;

    tail)
        channel="${1:-general}"
        last_count=0
        echo "Tailing #$channel... (Ctrl+C to stop)" >&2
        while true; do
            result=$(curl -s -H "Authorization: Bearer $TOKEN" \
                "$URL/api/channels/$channel/messages?since=$last_count")
            count=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")
            if [ "$count" -gt "$last_count" ]; then
                echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('messages', []):
    print(f'[{m[\"ts\"]}] [{m[\"sender\"]}] {m[\"message\"]}')
"
                last_count=$count
            fi
            sleep 3
        done
        ;;

    unread)
        qparams=""
        for arg in "$@"; do
            case "$arg" in
                --mark-read) qparams="${qparams}&mark_read=1" ;;
                --mentions)  qparams="${qparams}&mentions=1" ;;
            esac
        done
        [ -n "$qparams" ] && qparams="?${qparams#&}"
        curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/unread$qparams" | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
channels = data.get('channels', [])
if not channels:
    print('No unread messages.')
else:
    for ch in channels:
        print(f'--- #{ch[\"channel\"]} ({ch[\"unread_count\"]} unread) ---')
        for m in ch.get('messages', []):
            print(f'  [{m[\"ts\"]}] [{m[\"sender\"]}] {m[\"message\"]}')
"
        ;;

    poll)
        curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/poll" | \
            python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'{d[\"unread\"]} unread / {d[\"total\"]} total across {d[\"channels\"]} channels')
"
        ;;

    status)
        msg="${1:-}"
        if [ -z "$msg" ]; then
            curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/agents" | \
                python3 -c "
import sys, json, time
data = json.load(sys.stdin)
if not data:
    print('No agents online.')
else:
    for name, h in sorted(data.items()):
        age = ''
        if 'reported_at' in h:
            secs = int(time.time() - h['reported_at'])
            if secs < 60: age = f'{secs}s ago'
            elif secs < 3600: age = f'{secs//60}m ago'
            else: age = f'{secs//3600}h ago'
        status_msg = h.get('status_message', '')
        ctx = h.get('context_pct', '')
        parts = [name]
        if ctx: parts.append(f'ctx:{ctx}%')
        if age: parts.append(age)
        line = ' | '.join(parts)
        if status_msg: line += f'  \"{status_msg}\"'
        print(line)
"
        else
            whoami=$(curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/whoami" | \
                python3 -c "import sys,json; print(json.load(sys.stdin)['agent'])")
            payload=$(python3 -c "import json,sys; print(json.dumps({'status_message': sys.argv[1]}))" "$msg")
            curl -s -H "Authorization: Bearer $TOKEN" \
                -X POST "$URL/api/agents/$whoami/health" \
                -H "Content-Type: application/json" \
                -d "$payload" > /dev/null
            echo "Status set: $msg"
        fi
        ;;

    health)
        curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/agents" | \
            python3 -m json.tool
        ;;

    help|*)
        echo "fagents-comms client"
        echo ""
        echo "Usage:"
        echo "  $0 channels               List channels"
        echo "  $0 fetch <channel>          Fetch messages"
        echo "  $0 fetch <ch> --since N    Fetch messages after index N"
        echo "  $0 fetch <ch> --since 5m   Fetch messages from last 5 minutes"
        echo "  $0 send <channel> <msg>    Send a message"
        echo "  $0 tail <channel>          Poll for new messages"
        echo "  $0 unread                  Show unread messages across all channels"
        echo "  $0 unread --mark-read      Show unread and mark all as read"
        echo "  $0 unread --mentions       Show only unread @mentions"
        echo "  $0 poll                    Lightweight check: total + unread counts"
        echo "  $0 status                  Show all agents' status"
        echo "  $0 status \"msg\"            Set your status message"
        echo "  $0 health                  Show agent health (raw JSON)"
        echo ""
        echo "Environment:"
        echo "  COMMS_TOKEN    Auth token (required)"
        echo "  COMMS_URL      Server URL (default: http://127.0.0.1:9754)"
        ;;
esac
