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
    echo '{"channels": ["general", "dm-test"]}' > "$MOCK_DIR/channels.json"
    echo '{"channel": "general", "count": 2, "messages": [{"ts": "2026-02-21 10:00", "sender": "Juho", "message": "hello"}, {"ts": "2026-02-21 10:01", "sender": "FTF", "message": "hi"}]}' > "$MOCK_DIR/messages.json"
    echo '[{"name": "general", "message_count": 42}, {"name": "dm-test", "message_count": 5}]' > "$MOCK_DIR/channels-list.json"
    echo '{"agent": "TestAgent"}' > "$MOCK_DIR/whoami.json"

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
        elif path.startswith('/api/agents/') and path.endswith('/channels'):
            self._serve('channels.json')
        elif path.startswith('/api/channels/') and path.endswith('/messages') or '/messages?' in self.path:
            self._serve('messages.json')
        elif path == '/api/channels':
            self._serve('channels-list.json')
        elif path == '/api/whoami':
            self._serve('whoami.json')
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
    def do_POST(self):
        path = self.path.split('?')[0]
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode() if length else ''
        if path.startswith('/api/channels/') and path.endswith('/messages'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok": true}')
        elif path.startswith('/api/agents/') and path.endswith('/health'):
            with open(os.path.join(DATA_DIR, 'last-health-post.json'), 'w') as f:
                f.write(body)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok": true}')
        else:
            self.send_response(404)
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

funcs = ['refresh_channels', 'fetch_config', 'fetch_unread', 'wait_for_wake', 'read_prompt', 'check_comms']
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

# Stub for functions that call log()
DAEMON_LOG=$(mktemp)
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1" >> "$DAEMON_LOG"; }

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

# ── refresh_channels tests ──

echo "refresh_channels():"

# Test: fetches channels from server
CH_ARRAY=("old-channel")
set_mock_response "channels" '{"channels": ["general", "dm-test", "dev"]}'
refresh_channels; RC=$?
assert_eq "0" "$RC" "returns 0 on success"
assert_eq "3" "${#CH_ARRAY[@]}" "populates CH_ARRAY with 3 channels"
assert_eq "general" "${CH_ARRAY[0]}" "first channel is general"
assert_eq "dm-test" "${CH_ARRAY[1]}" "second channel is dm-test"
assert_eq "dev" "${CH_ARRAY[2]}" "third channel is dev"

# Test: single channel
set_mock_response "channels" '{"channels": ["only-one"]}'
refresh_channels; RC=$?
assert_eq "0" "$RC" "single channel: returns 0"
assert_eq "1" "${#CH_ARRAY[@]}" "single channel: CH_ARRAY has 1 entry"
assert_eq "only-one" "${CH_ARRAY[0]}" "single channel: correct name"

# Test: empty channels array — keeps old CH_ARRAY (fallback)
CH_ARRAY=("keep-me")
set_mock_response "channels" '{"channels": []}'
refresh_channels; RC=$?
assert_eq "1" "$RC" "empty channels: returns 1 (fallback)"
assert_eq "keep-me" "${CH_ARRAY[0]}" "empty channels: CH_ARRAY unchanged"

# Test: no comms configured — returns 1, keeps old CH_ARRAY
CH_ARRAY=("preserved")
SAVE_URL="$COMMS_URL"
unset COMMS_URL
refresh_channels; RC=$?
assert_eq "1" "$RC" "no comms: returns 1"
assert_eq "preserved" "${CH_ARRAY[0]}" "no comms: CH_ARRAY unchanged"
export COMMS_URL="$SAVE_URL"

# Test: server returns no channels key — fallback
CH_ARRAY=("fallback")
set_mock_response "channels" '{"error": "not found"}'
refresh_channels; RC=$?
assert_eq "1" "$RC" "no channels key: returns 1"
assert_eq "fallback" "${CH_ARRAY[0]}" "no channels key: CH_ARRAY unchanged"

echo ""

# ── client.sh tests ──

echo "client.sh:"

CLIENT_SCRIPT="$SCRIPT_DIR/comms/client.sh"

# Test: fetch formats output correctly
set_mock_response "messages" '{"channel": "general", "count": 2, "messages": [{"ts": "2026-02-21 10:00", "sender": "Juho", "message": "hello"}, {"ts": "2026-02-21 10:01", "sender": "FTF", "message": "hi"}]}'
OUTPUT=$("$CLIENT_SCRIPT" fetch general 2>/dev/null)
assert_contains "$OUTPUT" "[Juho] hello" "fetch: formats sender and message"
assert_contains "$OUTPUT" "[2026-02-21 10:00]" "fetch: formats timestamp"

# Test: read shows deprecation warning
STDERR=$("$CLIENT_SCRIPT" read general 2>&1 >/dev/null)
assert_contains "$STDERR" "deprecated" "read: shows deprecation warning"

# Test: send missing args — error
OUTPUT=$("$CLIENT_SCRIPT" send 2>&1) || true
assert_contains "$OUTPUT" "Usage" "send: missing args shows usage"

# Test: no token — error
SAVE_TOKEN="$COMMS_TOKEN"
unset COMMS_TOKEN
OUTPUT=$("$CLIENT_SCRIPT" fetch general 2>&1) || true
assert_contains "$OUTPUT" "COMMS_TOKEN" "no token: error mentions COMMS_TOKEN"
export COMMS_TOKEN="$SAVE_TOKEN"

# Test: channels lists channels
set_mock_response "channels-list" '[{"name": "general", "message_count": 42}]'
OUTPUT=$("$CLIENT_SCRIPT" channels 2>/dev/null)
assert_contains "$OUTPUT" "#general" "channels: shows channel name"
assert_contains "$OUTPUT" "42 msgs" "channels: shows message count"

# Test: send succeeds
OUTPUT=$("$CLIENT_SCRIPT" send general "test message" 2>/dev/null)
assert_contains "$OUTPUT" "ok" "send: returns ok"

# Test: help shows usage
OUTPUT=$("$CLIENT_SCRIPT" help 2>/dev/null)
assert_contains "$OUTPUT" "Usage" "help: shows usage"
assert_contains "$OUTPUT" "fetch" "help: lists fetch command"
assert_contains "$OUTPUT" "send" "help: lists send command"

echo ""

# ── check_comms tests ──

echo "check_comms():"

# Test: returns 0 when server is reachable
set_mock_response "whoami" '{"agent": "TestAgent"}'
check_comms; RC=$?
assert_eq "0" "$RC" "returns 0 when comms reachable"

# Test: returns 1 when server returns empty agent
set_mock_response "whoami" '{"agent": ""}'
check_comms; RC=$?
assert_eq "1" "$RC" "returns 1 when agent name empty"

# Test: returns 1 when server returns invalid JSON
set_mock_response "whoami" 'not json'
check_comms; RC=$?
assert_eq "1" "$RC" "returns 1 when server returns bad JSON"

# Test: returns 0 when comms not configured (skips check)
SAVE_URL="$COMMS_URL"
unset COMMS_URL
check_comms; RC=$?
assert_eq "0" "$RC" "returns 0 when COMMS_URL not set (skips)"
export COMMS_URL="$SAVE_URL"

# Test: logs warning on unreachable server
> "$DAEMON_LOG"
set_mock_response "whoami" '{"agent": ""}'
check_comms || true
LOG_CONTENT=$(cat "$DAEMON_LOG")
assert_contains "$LOG_CONTENT" "WARNING" "logs WARNING on unreachable"

echo ""

# ── WAKE_CHANNEL extraction tests ──

echo "WAKE_CHANNEL extraction (sed):"

# Helper matching daemon.sh line 388
extract_channel() { echo "$1" | sed -n 's/^--- #\([^ ]*\).*/\1/p' | head -1; }

# Test: normal channel extraction
RESULT=$(extract_channel "--- #general (1 mentions) ---
[2026-02-21 10:00] [Juho] hello")
assert_eq "general" "$RESULT" "extracts channel from mentions"

# Test: hyphenated channel name
RESULT=$(extract_channel "--- #dm-ftf (2 mentions) ---")
assert_eq "dm-ftf" "$RESULT" "extracts hyphenated channel name"

# Test: multiple channels — picks first
RESULT=$(extract_channel "--- #general (1 mentions) ---
[2026-02-21 10:00] [Juho] hello
--- #dm-ftf (1 mentions) ---
[2026-02-21 10:01] [FTW] ping")
assert_eq "general" "$RESULT" "multiple channels: picks first"

# Test: no channel — empty
RESULT=$(extract_channel "no channel markers here")
assert_empty "$RESULT" "no channel marker: returns empty"

# Test: empty input
RESULT=$(extract_channel "")
assert_empty "$RESULT" "empty input: returns empty"

# Test: channel with underscores
RESULT=$(extract_channel "--- #fagent_dev (3 mentions) ---")
assert_eq "fagent_dev" "$RESULT" "extracts underscored channel name"

echo ""

# ── context-usage.sh tests ──

echo "context-usage.sh:"

CTX_SCRIPT="$SCRIPT_DIR/awareness/context-usage.sh"
CTX_TMP=$(mktemp -d)

# Test: normal usage data — correct calculation
cat > "$CTX_TMP/normal.jsonl" << 'EOF'
{"type":"other","data":"irrelevant"}
{"message":{"usage":{"input_tokens":50000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":40000}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/normal.jsonl" 200000)
assert_contains "$OUTPUT" "pct=50" "normal: pct=50 for 100k/200k"
assert_contains "$OUTPUT" "remaining=50" "normal: remaining=50"
assert_contains "$OUTPUT" "used_tokens=100000" "normal: used_tokens=100000"
assert_contains "$OUTPUT" "ctx_size=200000" "normal: ctx_size=200000"
assert_contains "$OUTPUT" "input_tokens=50000" "normal: input_tokens=50000"
assert_contains "$OUTPUT" "cache_create=10000" "normal: cache_create=10000"
assert_contains "$OUTPUT" "cache_read=40000" "normal: cache_read=40000"

# Test: picks last usage entry, not first
cat > "$CTX_TMP/multi.jsonl" << 'EOF'
{"message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"message":{"usage":{"input_tokens":80000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/multi.jsonl" 200000)
assert_contains "$OUTPUT" "pct=40" "multi: picks last entry (80k not 1k)"
assert_contains "$OUTPUT" "input_tokens=80000" "multi: input_tokens from last entry"

# Test: custom context window size
cat > "$CTX_TMP/custom.jsonl" << 'EOF'
{"message":{"usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/custom.jsonl" 100000)
assert_contains "$OUTPUT" "pct=50" "custom ctx: 50k/100k = 50%"
assert_contains "$OUTPUT" "ctx_size=100000" "custom ctx: ctx_size=100000"

# Test: default context window size (200000)
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/custom.jsonl")
assert_contains "$OUTPUT" "pct=25" "default ctx: 50k/200k = 25%"
assert_contains "$OUTPUT" "ctx_size=200000" "default ctx: ctx_size=200000"

# Test: missing file — error output
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/nonexistent.jsonl" 2>/dev/null) || true
assert_contains "$OUTPUT" "error=file_not_found" "missing file: error=file_not_found"

# Test: no usage data in JSONL
cat > "$CTX_TMP/no_usage.jsonl" << 'EOF'
{"type":"request","data":"no usage here"}
{"message":{"content":"just text, no usage"}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/no_usage.jsonl")
assert_contains "$OUTPUT" "error=no_usage_data" "no usage: error=no_usage_data"

# Test: malformed JSON lines skipped gracefully
cat > "$CTX_TMP/malformed.jsonl" << 'EOF'
not json at all
{"broken json
{"message":{"usage":{"input_tokens":30000,"cache_creation_input_tokens":5000,"cache_read_input_tokens":15000}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/malformed.jsonl" 200000)
assert_contains "$OUTPUT" "pct=25" "malformed: skips bad lines, reads valid one (50k/200k)"
assert_contains "$OUTPUT" "used_tokens=50000" "malformed: used_tokens=50000"

# Test: integer division (no decimals)
cat > "$CTX_TMP/rounding.jsonl" << 'EOF'
{"message":{"usage":{"input_tokens":33333,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/rounding.jsonl" 200000)
assert_contains "$OUTPUT" "pct=16" "rounding: 33333/200000 = 16% (integer division)"

rm -rf "$CTX_TMP"

echo ""

# ── compaction.sh tests ──

echo "compaction.sh:"

COMPACT_SCRIPT="$SCRIPT_DIR/awareness/compaction.sh"
COMPACT_TMP=$(mktemp -d)
export PROJECT_DIR="$COMPACT_TMP"
mkdir -p "$COMPACT_TMP/.autonomy"

# Test: no argument — silent exit
OUTPUT=$("$COMPACT_SCRIPT" 2>/dev/null) || true
assert_empty "$OUTPUT" "no arg: silent exit"

# Test: first call — stores value, no compaction
rm -f "$COMPACT_TMP/.autonomy/.compact"
OUTPUT=$("$COMPACT_SCRIPT" 80)
assert_empty "$OUTPUT" "first call: no compaction (no previous value)"
STORED=$(cat "$COMPACT_TMP/.autonomy/.compact")
assert_eq "80" "$STORED" "first call: stores current pct"

# Test: small drop — no compaction
echo "80" > "$COMPACT_TMP/.autonomy/.compact"
OUTPUT=$("$COMPACT_SCRIPT" 60)
assert_empty "$OUTPUT" "20-point drop: no compaction"

# Test: exactly 30-point drop — triggers compaction
echo "70" > "$COMPACT_TMP/.autonomy/.compact"
OUTPUT=$("$COMPACT_SCRIPT" 40)
assert_contains "$OUTPUT" "COMPACTION DETECTED" "30-point drop: triggers compaction"

# Test: 29-point drop — does not trigger
echo "70" > "$COMPACT_TMP/.autonomy/.compact"
OUTPUT=$("$COMPACT_SCRIPT" 41)
assert_empty "$OUTPUT" "29-point drop: no compaction"

# Test: increase in pct — no compaction
echo "40" > "$COMPACT_TMP/.autonomy/.compact"
OUTPUT=$("$COMPACT_SCRIPT" 80)
assert_empty "$OUTPUT" "pct increase: no compaction"

# Test: large drop — includes re-read instructions
echo "90" > "$COMPACT_TMP/.autonomy/.compact"
OUTPUT=$("$COMPACT_SCRIPT" 25)
assert_contains "$OUTPUT" "SOUL.md" "large drop: mentions SOUL.md"
assert_contains "$OUTPUT" "TEAM.md" "large drop: mentions TEAM.md"
assert_contains "$OUTPUT" "MEMORY.md" "large drop: mentions MEMORY.md"

# Test: non-numeric input — silent exit
OUTPUT=$("$COMPACT_SCRIPT" "abc" 2>/dev/null) || true
assert_empty "$OUTPUT" "non-numeric: silent exit"

rm -rf "$COMPACT_TMP"
unset PROJECT_DIR

echo ""

# ── has-changed.sh tests ──

echo "has-changed.sh:"

HC_SCRIPT="$SCRIPT_DIR/awareness/has-changed.sh"
HC_TMP=$(mktemp -d)
export PROJECT_DIR="$HC_TMP"
mkdir -p "$HC_TMP/.autonomy"

# Test: no key — exit 2
"$HC_SCRIPT" 2>/dev/null; RC=$?
assert_eq "2" "$RC" "no key: exit 2"

# Test: first run — exit 0 (changed)
echo "hello" > "$HC_TMP/file1.txt"
rm -f "$HC_TMP/.autonomy/.test-key.hash"
"$HC_SCRIPT" "test-key" "$HC_TMP/file1.txt"; RC=$?
assert_eq "0" "$RC" "first run: exit 0 (changed)"

# Test: second run same file — exit 1 (unchanged)
"$HC_SCRIPT" "test-key" "$HC_TMP/file1.txt"; RC=$?
assert_eq "1" "$RC" "same file: exit 1 (unchanged)"

# Test: file modified — exit 0 (changed)
echo "world" > "$HC_TMP/file1.txt"
"$HC_SCRIPT" "test-key" "$HC_TMP/file1.txt"; RC=$?
assert_eq "0" "$RC" "modified file: exit 0 (changed)"

# Test: multiple files — detects change in any
echo "aaa" > "$HC_TMP/a.txt"
echo "bbb" > "$HC_TMP/b.txt"
rm -f "$HC_TMP/.autonomy/.multi-key.hash"
"$HC_SCRIPT" "multi-key" "$HC_TMP/a.txt" "$HC_TMP/b.txt"; RC=$?
assert_eq "0" "$RC" "multi first run: exit 0"
"$HC_SCRIPT" "multi-key" "$HC_TMP/a.txt" "$HC_TMP/b.txt"; RC=$?
assert_eq "1" "$RC" "multi unchanged: exit 1"
echo "ccc" > "$HC_TMP/b.txt"
"$HC_SCRIPT" "multi-key" "$HC_TMP/a.txt" "$HC_TMP/b.txt"; RC=$?
assert_eq "0" "$RC" "multi one changed: exit 0"

# Test: missing file — skipped silently, no error
rm -f "$HC_TMP/.autonomy/.miss-key.hash"
"$HC_SCRIPT" "miss-key" "$HC_TMP/a.txt" "$HC_TMP/nonexistent.txt"; RC=$?
assert_eq "0" "$RC" "missing file: first run still exit 0"
"$HC_SCRIPT" "miss-key" "$HC_TMP/a.txt" "$HC_TMP/nonexistent.txt"; RC=$?
assert_eq "1" "$RC" "missing file: second run unchanged exit 1"

rm -rf "$HC_TMP"
unset PROJECT_DIR

echo ""

# ── context.sh integration tests ──

echo "context.sh:"

CTX_INT_SCRIPT="$SCRIPT_DIR/awareness/context.sh"
CTX_INT_TMP=$(mktemp -d)
mkdir -p "$CTX_INT_TMP/.freeturtle"
export CLAUDE_PROJECT_DIR="$CTX_INT_TMP"

# Helper: create a JSONL with specific token values
make_jsonl() {
    local inp="$1" cc="${2:-0}" cr="${3:-0}"
    cat > "$CTX_INT_TMP/.freeturtle/session.jsonl" << EOF
{"message":{"usage":{"input_tokens":$inp,"cache_creation_input_tokens":$cc,"cache_read_input_tokens":$cr}}}
EOF
}

# Test: OK label (< 40%)
make_jsonl 30000 0 0
OUTPUT=$("$CTX_INT_SCRIPT")
eval "$OUTPUT"
assert_eq "OK" "$label" "ctx.sh: label=OK for 15%"
assert_eq "HEALTHY" "$label_long" "ctx.sh: label_long=HEALTHY for 15%"
assert_contains "$formatted" "OK" "ctx.sh: formatted contains OK"

# Test: WARM label (40-69%)
make_jsonl 80000 0 0
OUTPUT=$("$CTX_INT_SCRIPT")
eval "$OUTPUT"
assert_eq "WARM" "$label" "ctx.sh: label=WARM for 40%"
assert_eq "WARMING" "$label_long" "ctx.sh: label_long=WARMING for 40%"

# Test: HEAVY label (70-89%)
make_jsonl 100000 20000 20000
OUTPUT=$("$CTX_INT_SCRIPT")
eval "$OUTPUT"
assert_eq "HEAVY" "$label" "ctx.sh: label=HEAVY for 70%"
assert_eq "HEAVY" "$label_long" "ctx.sh: label_long=HEAVY for 70%"

# Test: CRIT label (90%+)
make_jsonl 100000 40000 50000
OUTPUT=$("$CTX_INT_SCRIPT")
eval "$OUTPUT"
assert_eq "CRIT" "$label" "ctx.sh: label=CRIT for 95%"
assert_eq "CRITICAL" "$label_long" "ctx.sh: label_long=CRITICAL for 95%"

# Test: outputs all expected keys
make_jsonl 50000 10000 40000
OUTPUT=$("$CTX_INT_SCRIPT")
assert_contains "$OUTPUT" "pct=" "ctx.sh: outputs pct"
assert_contains "$OUTPUT" "label=" "ctx.sh: outputs label"
assert_contains "$OUTPUT" "label_long=" "ctx.sh: outputs label_long"
assert_contains "$OUTPUT" "formatted=" "ctx.sh: outputs formatted"
assert_contains "$OUTPUT" "remaining=" "ctx.sh: outputs remaining"
assert_contains "$OUTPUT" "used_tokens=" "ctx.sh: outputs used_tokens"
assert_contains "$OUTPUT" "input_tokens=" "ctx.sh: outputs input_tokens"
assert_contains "$OUTPUT" "cache_create=" "ctx.sh: outputs cache_create"
assert_contains "$OUTPUT" "cache_read=" "ctx.sh: outputs cache_read"

# Test: no JSONL dir — silent exit, no output
SAVE_PROJ="$CLAUDE_PROJECT_DIR"
export CLAUDE_PROJECT_DIR="/tmp/nonexistent-$$"
OUTPUT=$("$CTX_INT_SCRIPT") || true
assert_empty "$OUTPUT" "ctx.sh: no jsonl dir — silent empty output"
export CLAUDE_PROJECT_DIR="$SAVE_PROJ"

# Test: empty JSONL dir — silent exit
mkdir -p "$CTX_INT_TMP/.freeturtle-empty"
export CLAUDE_PROJECT_DIR="$CTX_INT_TMP"
rm -f "$CTX_INT_TMP/.freeturtle"/*.jsonl
OUTPUT=$("$CTX_INT_SCRIPT") || true
assert_empty "$OUTPUT" "ctx.sh: no jsonl files — silent empty output"

rm -rf "$CTX_INT_TMP"
unset CLAUDE_PROJECT_DIR

echo ""

# ── activity-push.sh tests ──

echo "activity-push.sh:"

AP_SCRIPT="$SCRIPT_DIR/hooks/activity-push.sh"

# Setup: fake AUTONOMY_DIR with mock context.sh
AP_FAKE_DIR=$(mktemp -d)
mkdir -p "$AP_FAKE_DIR/awareness"
cat > "$AP_FAKE_DIR/awareness/context.sh" << 'MOCKCTX'
#!/bin/bash
echo "pct='42'"
echo "label='WARM'"
echo "label_long='WARMING'"
MOCKCTX
chmod +x "$AP_FAKE_DIR/awareness/context.sh"

# Test: no AGENT — exits 0, WARNING on stderr
SAVE_AGENT="$AGENT"
unset AGENT
STDERR=$(AUTONOMY_DIR="$AP_FAKE_DIR" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" </dev/null 2>&1 >/dev/null) || true
assert_contains "$STDERR" "WARNING" "activity-push: no AGENT — WARNING on stderr"
export AGENT="$SAVE_AGENT"

# Test: context.sh returns nothing — exits 0 silently
AP_EMPTY_DIR=$(mktemp -d)
mkdir -p "$AP_EMPTY_DIR/awareness"
cat > "$AP_EMPTY_DIR/awareness/context.sh" << 'MOCKCTX2'
#!/bin/bash
exit 1
MOCKCTX2
chmod +x "$AP_EMPTY_DIR/awareness/context.sh"
OUTPUT=$(AUTONOMY_DIR="$AP_EMPTY_DIR" AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" </dev/null 2>&1) || true
assert_empty "$OUTPUT" "activity-push: no context data — silent exit"
rm -rf "$AP_EMPTY_DIR"

# Test: no COMMS_TOKEN — exits 0 silently
OUTPUT=$(AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="" \
    bash "$AP_SCRIPT" </dev/null 2>&1) || true
assert_empty "$OUTPUT" "activity-push: no COMMS_TOKEN — silent exit"

# Test: valid JSON stdin — tool_name extracted, POST sent
rm -f "$MOCK_DIR/last-health-post.json"
echo '{"tool_name":"Read","tool_input":{"file":"/tmp/x"}}' | \
    AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" 2>/dev/null
sleep 0.3
HEALTH_BODY=$(cat "$MOCK_DIR/last-health-post.json" 2>/dev/null || echo "")
assert_contains "$HEALTH_BODY" '"last_tool":"Read"' "activity-push: tool_name extracted from JSON"
assert_contains "$HEALTH_BODY" '"context_pct":42' "activity-push: context_pct in POST body"
assert_contains "$HEALTH_BODY" '"status":"active"' "activity-push: status=active in POST body"

# Test: invalid JSON stdin — tool falls back to "?"
rm -f "$MOCK_DIR/last-health-post.json"
echo 'not json at all' | \
    AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" 2>/dev/null
sleep 0.3
HEALTH_BODY=$(cat "$MOCK_DIR/last-health-post.json" 2>/dev/null || echo "")
assert_contains "$HEALTH_BODY" '"last_tool":"?"' "activity-push: invalid JSON — tool falls back to ?"

# Test: empty stdin — tool falls back to "?"
rm -f "$MOCK_DIR/last-health-post.json"
echo '' | \
    AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" 2>/dev/null
sleep 0.3
HEALTH_BODY=$(cat "$MOCK_DIR/last-health-post.json" 2>/dev/null || echo "")
assert_contains "$HEALTH_BODY" '"last_tool":"?"' "activity-push: empty stdin — tool falls back to ?"

# Test: POST targets correct agent endpoint
rm -f "$MOCK_DIR/last-health-post.json"
echo '{"tool_name":"Bash"}' | \
    AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="MyAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" 2>/dev/null
sleep 0.3
# If we got a health post, the endpoint was hit (agent name is in URL, not body)
HEALTH_BODY=$(cat "$MOCK_DIR/last-health-post.json" 2>/dev/null || echo "")
assert_contains "$HEALTH_BODY" '"context_pct":42' "activity-push: POST reaches health endpoint with different agent"

rm -rf "$AP_FAKE_DIR"

echo ""

# ── Summary ──

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
fi
