#!/bin/bash
# Test suite for fagents-autonomy daemon.sh
#
# Tests the wake mechanism (fetch_unread, wait_for_wake) using
# a mock HTTP server. No external dependencies beyond bash + python3.
#
# Usage: ./test_daemon.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ERRORS=""

# ── Test helpers ──

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}  FAIL: $1\n"
    echo "  FAIL: $1"
}

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$msg"
    else
        fail "$msg (expected to contain '$needle')"
    fi
}

assert_empty() {
    local val="$1" msg="$2"
    if [ -z "$val" ]; then
        pass "$msg"
    else
        fail "$msg (expected empty, got '$val')"
    fi
}

# ── Mock HTTP server ──

MOCK_PORT=""
MOCK_PID=""
MOCK_DIR=""

start_mock_server() {
    MOCK_DIR=$(mktemp -d)
    echo '{"total": 100, "unread": 0, "channels": 3}' > "$MOCK_DIR/poll.json"
    echo '{"channels": []}' > "$MOCK_DIR/unread.json"
    echo '{"agent": "TestAgent", "config": {"wake_mode": "mentions", "poll_interval": 1}}' > "$MOCK_DIR/config.json"

    python3 -c "
import http.server, os, sys

PORT = int(sys.argv[1])
DATA_DIR = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/api/poll':
            self._serve('poll.json')
        elif path == '/api/unread':
            self._serve('unread.json')
        elif path.startswith('/api/agents/') and path.endswith('/config'):
            self._serve('config.json')
        elif path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{\"ok\": true}')
        else:
            self.send_response(404)
            self.end_headers()
    def _serve(self, fname):
        fpath = os.path.join(DATA_DIR, fname)
        if os.path.exists(fpath):
            with open(fpath) as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())
        else:
            self.send_response(500)
            self.end_headers()
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(('127.0.0.1', PORT), Handler)
server.serve_forever()
" "$1" "$MOCK_DIR" &
    MOCK_PID=$!
    MOCK_PORT="$1"
    sleep 0.5
}

stop_mock_server() {
    [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
    [ -n "${MOCK_DIR:-}" ] && rm -rf "$MOCK_DIR" 2>/dev/null || true
    MOCK_PID=""
    MOCK_DIR=""
}

set_mock_response() {
    local endpoint="$1" json="$2"
    echo "$json" > "$MOCK_DIR/${endpoint}.json"
}

find_free_port() {
    python3 -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
"
}

# ── Extract functions from daemon.sh ──

extract_functions() {
    python3 -c "
import re, sys

with open(sys.argv[1]) as f:
    content = f.read()

# Extract globals
print('WAKE_MENTIONS=\"\"')
print('WAKE_MODE=\"\"')
print('_ENV_WAKE_MODE=\"\"')
print()

funcs = ['fetch_config', 'fetch_unread', 'wait_for_wake', 'read_prompt']
for name in funcs:
    pattern = rf'^{name}\(\) \{{.*?^\}}'
    match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
    if match:
        print(match.group())
        print()
" "$SCRIPT_DIR/daemon.sh"
}

# ── Setup ──

echo "=== fagents-autonomy daemon.sh tests ==="
echo ""

PORT=$(find_free_port)
start_mock_server "$PORT"
trap stop_mock_server EXIT

export COMMS_URL="http://127.0.0.1:$PORT"
export COMMS_TOKEN="test-token"
export AGENT="TestAgent"

eval "$(extract_functions)"

# ── fetch_unread tests ──

echo "fetch_unread():"

# Test 1: no mentions — returns 1, WAKE_MENTIONS empty
set_mock_response "unread" '{"channels": []}'
fetch_unread; RC=$?
assert_eq "1" "$RC" "returns 1 when no mentions"
assert_empty "$WAKE_MENTIONS" "WAKE_MENTIONS empty when no mentions"

# Test 2: has mentions — returns 0, WAKE_MENTIONS populated
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 2, "messages": [{"ts": "2026-02-17 16:00", "sender": "Juho", "message": "hey @TestAgent"}, {"ts": "2026-02-17 16:01", "sender": "FTW", "message": "ping"}]}]}'
fetch_unread; RC=$?
assert_eq "0" "$RC" "returns 0 when mentions exist"
assert_contains "$WAKE_MENTIONS" "#general" "WAKE_MENTIONS contains channel name"
assert_contains "$WAKE_MENTIONS" "Juho" "WAKE_MENTIONS contains sender"
assert_contains "$WAKE_MENTIONS" "hey @TestAgent" "WAKE_MENTIONS contains message text"

# Test 3: zero unread count
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 0, "messages": []}]}'
fetch_unread; RC=$?
assert_eq "1" "$RC" "returns 1 when mention channels have 0 unread"
assert_empty "$WAKE_MENTIONS" "WAKE_MENTIONS cleared on no mentions"

# Test 4: multiple channels, some with mentions
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 0, "messages": []}, {"channel": "dm-test", "unread_count": 1, "messages": [{"ts": "2026-02-17 16:05", "sender": "FTL", "message": "check this"}]}]}'
fetch_unread; RC=$?
assert_eq "0" "$RC" "returns 0 when any channel has mentions"
assert_contains "$WAKE_MENTIONS" "#dm-test" "WAKE_MENTIONS shows correct channel"
assert_contains "$WAKE_MENTIONS" "FTL" "WAKE_MENTIONS shows correct sender"

# Test 5: no COMMS_URL
SAVE_URL="$COMMS_URL"
unset COMMS_URL
fetch_unread; RC=$?
assert_eq "1" "$RC" "returns 1 when COMMS_URL not set"
export COMMS_URL="$SAVE_URL"

# Test 6: no COMMS_TOKEN
SAVE_TOKEN="$COMMS_TOKEN"
unset COMMS_TOKEN
fetch_unread; RC=$?
assert_eq "1" "$RC" "returns 1 when COMMS_TOKEN not set"
export COMMS_TOKEN="$SAVE_TOKEN"

echo ""

# ── wait_for_wake tests ──

echo "wait_for_wake():"

# Test 7: mention arrives → wakes (return 0), WAKE_MENTIONS populated
set_mock_response "poll" '{"total": 100, "unread": 0, "channels": 3}'
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 1, "messages": [{"ts": "2026-02-17 16:10", "sender": "Juho", "message": "wake up"}]}]}'
(
    sleep 0.5
    set_mock_response "poll" '{"total": 101, "unread": 1, "channels": 3}'
) &
UPD=$!
INTERVAL=4
COMMS_POLL_INTERVAL=0.2
SECONDS=0
wait_for_wake; RC=$?
wait "$UPD" 2>/dev/null || true
assert_eq "0" "$RC" "wakes on mention (return 0)"
assert_contains "$WAKE_MENTIONS" "wake up" "WAKE_MENTIONS populated after wake"

# Test 8: new messages but no mentions → timeout (return 1)
set_mock_response "poll" '{"total": 200, "unread": 0, "channels": 3}'
set_mock_response "unread" '{"channels": []}'
(
    sleep 0.3
    set_mock_response "poll" '{"total": 201, "unread": 1, "channels": 3}'
) &
UPD=$!
INTERVAL=2
COMMS_POLL_INTERVAL=0.2
SECONDS=0
wait_for_wake; RC=$?
wait "$UPD" 2>/dev/null || true
assert_eq "1" "$RC" "doesn't wake on non-mention messages (return 1)"

# Test 9: no new messages → timeout (return 1)
set_mock_response "poll" '{"total": 300, "unread": 0, "channels": 3}'
set_mock_response "unread" '{"channels": []}'
INTERVAL=1
COMMS_POLL_INTERVAL=0.2
SECONDS=0
wait_for_wake; RC=$?
assert_eq "1" "$RC" "times out with no new messages (return 1)"

# Test 10: no comms → timeout (return 1)
SAVE_URL="$COMMS_URL"
SAVE_TOKEN="$COMMS_TOKEN"
unset COMMS_URL
unset COMMS_TOKEN
INTERVAL=1
COMMS_POLL_INTERVAL=0.2
SECONDS=0
wait_for_wake; RC=$?
assert_eq "1" "$RC" "times out when comms not configured (return 1)"
export COMMS_URL="$SAVE_URL"
export COMMS_TOKEN="$SAVE_TOKEN"

echo ""

# ── fetch_config tests ──

echo "fetch_config():"

# Test 11: fetches config from server
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_mode": "channel", "poll_interval": 2}}'
WAKE_MODE=""
_ENV_WAKE_MODE=""
COMMS_POLL_INTERVAL=1
fetch_config; RC=$?
assert_eq "0" "$RC" "returns 0 on success"
assert_eq "channel" "$WAKE_MODE" "sets WAKE_MODE from server"
assert_eq "2" "$COMMS_POLL_INTERVAL" "sets COMMS_POLL_INTERVAL from server"

# Test 12: env WAKE_MODE overrides server
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_mode": "channel", "poll_interval": 3}}'
WAKE_MODE="mentions"
_ENV_WAKE_MODE="mentions"
fetch_config; RC=$?
assert_eq "mentions" "$WAKE_MODE" "env WAKE_MODE overrides server"
assert_eq "3" "$COMMS_POLL_INTERVAL" "poll_interval still updated from server"

# Test 13: returns 1 when comms not configured
SAVE_URL="$COMMS_URL"
unset COMMS_URL
WAKE_MODE=""
_ENV_WAKE_MODE=""
fetch_config; RC=$?
assert_eq "1" "$RC" "returns 1 when COMMS_URL not set"
export COMMS_URL="$SAVE_URL"

# Test 14: defaults when server returns defaults
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_mode": "mentions", "poll_interval": 1}}'
WAKE_MODE=""
_ENV_WAKE_MODE=""
COMMS_POLL_INTERVAL=5
fetch_config; RC=$?
assert_eq "mentions" "$WAKE_MODE" "sets default wake_mode from server"
assert_eq "1" "$COMMS_POLL_INTERVAL" "sets default poll_interval from server"

# Test 15: fetch_config sets MAX_TURNS from server
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_mode": "mentions", "poll_interval": 1, "max_turns": 50, "heartbeat_interval": 3600}}'
WAKE_MODE=""
_ENV_WAKE_MODE=""
MAX_TURNS=200
INTERVAL=300
fetch_config; RC=$?
assert_eq "50" "$MAX_TURNS" "sets MAX_TURNS from server"
assert_eq "3600" "$INTERVAL" "sets INTERVAL (heartbeat_interval) from server"

# Test 16: server omits new keys — env defaults preserved
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_mode": "mentions", "poll_interval": 1}}'
WAKE_MODE=""
_ENV_WAKE_MODE=""
MAX_TURNS=200
INTERVAL=15000
fetch_config; RC=$?
assert_eq "200" "$MAX_TURNS" "MAX_TURNS preserved when server omits it"
assert_eq "15000" "$INTERVAL" "INTERVAL preserved when server omits heartbeat_interval"

# Reset for next tests
WAKE_MODE=""
_ENV_WAKE_MODE=""

echo ""

# ── wait_for_wake with WAKE_MODE=channel ──

echo "wait_for_wake() with WAKE_MODE=channel:"

# Test 15: channel mode — wakes on any new message (no mentions needed)
set_mock_response "poll" '{"total": 400, "unread": 0, "channels": 3}'
set_mock_response "unread" '{"channels": []}'
(
    sleep 0.5
    set_mock_response "poll" '{"total": 401, "unread": 1, "channels": 3}'
) &
UPD=$!
INTERVAL=4
COMMS_POLL_INTERVAL=0.2
WAKE_MODE="channel"
SECONDS=0
wait_for_wake; RC=$?
wait "$UPD" 2>/dev/null || true
assert_eq "0" "$RC" "channel mode: wakes on any new message"

# Test 16: channel mode — still times out with no messages
set_mock_response "poll" '{"total": 500, "unread": 0, "channels": 3}'
set_mock_response "unread" '{"channels": []}'
INTERVAL=1
COMMS_POLL_INTERVAL=0.2
WAKE_MODE="channel"
SECONDS=0
wait_for_wake; RC=$?
assert_eq "1" "$RC" "channel mode: times out with no new messages"

# Test 17: mentions mode — still ignores non-mention messages
set_mock_response "poll" '{"total": 600, "unread": 0, "channels": 3}'
set_mock_response "unread" '{"channels": []}'
(
    sleep 0.3
    set_mock_response "poll" '{"total": 601, "unread": 1, "channels": 3}'
) &
UPD=$!
INTERVAL=2
COMMS_POLL_INTERVAL=0.2
WAKE_MODE="mentions"
SECONDS=0
wait_for_wake; RC=$?
wait "$UPD" 2>/dev/null || true
assert_eq "1" "$RC" "mentions mode: ignores non-mention messages"

# Reset
WAKE_MODE=""

echo ""

# ── read_prompt tests ──

echo "read_prompt():"

# Set up temp prompts directory with test templates
TEST_PROMPTS_DIR=$(mktemp -d)
PROMPTS_DIR="$TEST_PROMPTS_DIR"

# Template with both placeholders
cat > "$TEST_PROMPTS_DIR/test.md" << 'TMPL'
Check channels:
{{CHANNELS_BLOCK}}
{{MENTIONS_BLOCK}}
Done.
TMPL

# Test: channels block uses 'fetch' not 'read'
CH_ARRAY=("general" "dm-test")
INTERVAL=300
WAKE_MENTIONS=""
AUTONOMY_DIR=""
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "fetch general" "channels block uses 'fetch' subcommand"
assert_contains "$OUTPUT" "fetch dm-test" "channels block includes all channels"
assert_contains "$OUTPUT" "send general" "reply block includes send commands"
assert_contains "$OUTPUT" "send dm-test" "reply block includes all channels for send"

# Test: mentions block injected when WAKE_MENTIONS is set
WAKE_MENTIONS="--- #general (1 mentions) ---
[2026-02-17 16:00] [Juho] hey"
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "Messages that triggered this wake" "mentions header injected"
assert_contains "$OUTPUT" "#general (1 mentions)" "mentions content injected"

# Test: mentions block removed when empty
WAKE_MENTIONS=""
OUTPUT=$(read_prompt "test.md")
if echo "$OUTPUT" | grep -qF "Messages that triggered"; then
    fail "mentions block should be removed when empty"
else
    pass "mentions block removed when WAKE_MENTIONS empty"
fi

# Test: --since uses interval-based calculation for non-msg prompts
INTERVAL=300
CH_ARRAY=("general")
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "--since 60m" "non-msg prompt uses interval-based --since (min 60m)"

# Test: --since uses 10m for msg prompts
cat > "$TEST_PROMPTS_DIR/test-msg.md" << 'TMPL'
{{CHANNELS_BLOCK}}
TMPL
OUTPUT=$(read_prompt "test-msg.md")
assert_contains "$OUTPUT" "--since 10m" "msg prompt uses --since 10m"

# Test: AUTONOMY_DIR overrides client path
AUTONOMY_DIR="/custom/path"
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "/custom/path/comms/client.sh" "AUTONOMY_DIR overrides client path"
AUTONOMY_DIR=""

# Test: missing prompt file
OUTPUT=$(read_prompt "nonexistent.md" 2>/dev/null)
assert_contains "$OUTPUT" "prompt file missing" "missing prompt file returns error"

rm -rf "$TEST_PROMPTS_DIR"

echo ""

# ── Summary ──

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
fi
