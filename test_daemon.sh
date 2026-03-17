#!/bin/bash
# Test suite for fagents-autonomy daemon.sh
#
# Tests the message queue mechanism (collect_comms, collect_and_wait, read_inbox)
# using a mock HTTP server. No external dependencies beyond bash + python3.
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

capture_health_post() {
    sleep 0.3
    HEALTH_BODY=$(cat "$MOCK_DIR/last-health-post.json" 2>/dev/null || echo "")
}

make_silent_mock() {
    local dir="$1" script="$2"
    printf '#!/bin/bash\nexit 0\n' > "$dir/awareness/$script"
    chmod +x "$dir/awareness/$script"
}

make_echo_mock() {
    local dir="$1" script="$2" content="$3"
    printf '#!/bin/bash\necho "%s"\n' "$content" > "$dir/awareness/$script"
    chmod +x "$dir/awareness/$script"
}

run_wake() {
    INTERVAL="$1"
    COMMS_POLL_INTERVAL=0.2
    [[ $# -ge 2 ]] && WAKE_CHANNELS="$2"
    SECONDS=0
    collect_and_wait; RC=$?
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
        elif path == '/api/check-email':
            self._serve('check-email.json')
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
            with open(os.path.join(DATA_DIR, 'last-msg-post.json'), 'w') as f:
                f.write(body)
            with open(os.path.join(DATA_DIR, 'last-msg-path.txt'), 'w') as f:
                f.write(path)
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
        elif path.startswith('/api/agents/') and path.endswith('/activity'):
            with open(os.path.join(DATA_DIR, 'last-activity-post.json'), 'w') as f:
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
print('INBOX_BLOCK=\"\"')
print('INBOX_COUNT=0')
print('WAKE_CHANNELS=\"\"')
print('_ENV_WAKE_CHANNELS=\"\"')
print('LAST_EMAIL_CHECK=0')
print('LAST_TELEGRAM_CHECK=0')
print('EMAIL_CADENCE=60')
print('TELEGRAM_CADENCE=5')
print('TELEGRAM_CLI="/nonexistent/telegram.sh"')
print()

funcs = ['refresh_channels', 'fetch_config', 'collect_comms', 'collect_email', 'collect_telegram', 'read_inbox', 'archive_inbox', 'collect_and_wait', 'read_prompt', 'check_comms', 'push_activity']
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

# Set up queue and state directories for tests
TEST_QUEUE_DIR=$(mktemp -d)
QUEUE_DIR="$TEST_QUEUE_DIR"
INBOX_DIR="$TEST_QUEUE_DIR/inbox"
ARCHIVE_DIR="$TEST_QUEUE_DIR/archive"
STATE_DIR="$TEST_QUEUE_DIR/state"
mkdir -p "$INBOX_DIR" "$ARCHIVE_DIR" "$STATE_DIR"

# Helper to clear inbox between tests
clear_inbox() {
    rm -f "$INBOX_DIR"/*.jsonl 2>/dev/null || true
    rm -f "$ARCHIVE_DIR"/*.jsonl 2>/dev/null || true
}

# ── collect_comms tests ──

echo "collect_comms():"

# Test 1: no mentions — returns 1, inbox empty
clear_inbox
set_mock_response "unread" '{"channels": []}'
collect_comms; RC=$?
assert_eq "1" "$RC" "returns 1 when no mentions"
assert_eq "0" "$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')" "inbox empty when no mentions"

# Test 2: has mentions — returns 0, writes .jsonl files
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 2, "messages": [{"ts": "2026-02-17 16:00", "sender": "Juho", "message": "hey @TestAgent"}, {"ts": "2026-02-17 16:01", "sender": "FTW", "message": "ping"}]}]}'
collect_comms; RC=$?
assert_eq "0" "$RC" "returns 0 when mentions exist"
FCOUNT=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2" "$FCOUNT" "writes 2 .jsonl files to inbox"
# Check file contents
FIRST_MSG=$(cat "$INBOX_DIR"/*.jsonl 2>/dev/null | head -1)
assert_contains "$FIRST_MSG" '"source":"comms"' "message has source comms"
assert_contains "$FIRST_MSG" '"trusted":true' "comms messages are trusted"

# Test 3: zero unread count
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 0, "messages": []}]}'
collect_comms; RC=$?
assert_eq "1" "$RC" "returns 1 when mention channels have 0 unread"

# Test 4: no COMMS_URL
clear_inbox
SAVE_URL="$COMMS_URL"
unset COMMS_URL
collect_comms; RC=$?
assert_eq "1" "$RC" "returns 1 when COMMS_URL not set"
export COMMS_URL="$SAVE_URL"

# Test 5: no COMMS_TOKEN
SAVE_TOKEN="$COMMS_TOKEN"
unset COMMS_TOKEN
collect_comms; RC=$?
assert_eq "1" "$RC" "returns 1 when COMMS_TOKEN not set"
export COMMS_TOKEN="$SAVE_TOKEN"

# Test 6: deduplication — same messages don't create extra files
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 1, "messages": [{"ts": "2026-02-17 16:00", "sender": "Juho", "message": "hello"}]}]}'
collect_comms; RC=$?
FCOUNT1=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
collect_comms; RC=$?
FCOUNT2=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$FCOUNT1" "$FCOUNT2" "same message ID overwrites, no duplicates"

echo ""

# ── read_inbox tests ──

echo "read_inbox():"

# Test: empty inbox
clear_inbox
read_inbox; RC=$?
assert_eq "1" "$RC" "returns 1 when inbox is empty"
assert_empty "$INBOX_BLOCK" "INBOX_BLOCK empty when no messages"
assert_eq "0" "$INBOX_COUNT" "INBOX_COUNT is 0 when empty"

# Test: formats comms messages
clear_inbox
echo '{"ts":"2026-02-17 16:00","id":"comms-general-1","source":"comms","channel":"general","from":"Juho","body":"hey there","trusted":true}' > "$INBOX_DIR/comms-general-1.jsonl"
read_inbox; RC=$?
assert_eq "0" "$RC" "returns 0 when inbox has messages"
assert_eq "1" "$INBOX_COUNT" "INBOX_COUNT is 1"
assert_contains "$INBOX_BLOCK" "comms" "INBOX_BLOCK contains source"
assert_contains "$INBOX_BLOCK" "Juho" "INBOX_BLOCK contains sender"
assert_contains "$INBOX_BLOCK" "hey there" "INBOX_BLOCK contains body"

# Test: wraps untrusted messages
clear_inbox
echo '{"ts":"2026-02-17 16:00","id":"email-123","source":"email","from":"spammer@example.com","body":"You have new email (UID 123). Use gate_email to read.","trusted":false}' > "$INBOX_DIR/email-123.jsonl"
read_inbox; RC=$?
assert_eq "0" "$RC" "returns 0 for untrusted messages"
assert_contains "$INBOX_BLOCK" "<untrusted>" "untrusted messages wrapped in <untrusted> tags"
assert_contains "$INBOX_BLOCK" "</untrusted>" "untrusted messages have closing tag"

echo ""

# ── archive_inbox tests ──

echo "archive_inbox():"

# Test: moves files from inbox to archive
clear_inbox
echo '{"id":"test-1"}' > "$INBOX_DIR/test-1.jsonl"
echo '{"id":"test-2"}' > "$INBOX_DIR/test-2.jsonl"
archive_inbox
INBOX_REMAINING=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$INBOX_REMAINING" "inbox empty after archive"
assert_eq "2" "$ARCHIVE_COUNT" "archive has 2 files"

# Test: no-op on empty inbox
clear_inbox
archive_inbox
ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$ARCHIVE_COUNT" "archive unchanged on empty inbox"

echo ""

# ── collect_email tests ──

echo "collect_email():"

# Test: returns 1 when MCP not configured
MCP_BASE_SAVE="$MCP_BASE"; MCP_KEY_SAVE="$MCP_KEY"
MCP_BASE=""; MCP_KEY=""
collect_email; RC=$?
assert_eq "1" "$RC" "returns 1 when MCP not configured"
MCP_BASE="$MCP_BASE_SAVE"; MCP_KEY="$MCP_KEY_SAVE"

# Test: returns 1 when no new email
MCP_BASE="http://127.0.0.1:$MOCK_PORT"
MCP_KEY="test-key"
set_mock_response "check-email" '{"messages": []}'
clear_inbox
collect_email; RC=$?
assert_eq "1" "$RC" "returns 1 when no new email"

# Test: writes notification .jsonl when new email
set_mock_response "check-email" '{"messages": [{"uid": 42, "from": "alice@example.com", "date": "2026-03-04T10:00:00Z"}]}'
clear_inbox
rm -f "$STATE_DIR/email-last-uid"
collect_email; RC=$?
assert_eq "0" "$RC" "returns 0 when new email found"
assert_eq "1" "$(find "$INBOX_DIR" -name 'email-*.jsonl' | wc -l | tr -d ' ')" "writes 1 email .jsonl to inbox"

# Test: email entry is untrusted and notification-only
ENTRY=$(cat "$INBOX_DIR"/email-42.jsonl)
assert_contains "$ENTRY" '"source":"email"' "email entry has source email"
assert_contains "$ENTRY" '"trusted":false' "email entry is untrusted"
assert_contains "$ENTRY" 'gate_email' "email entry mentions gate_email"
# No subject in the entry
echo "$ENTRY" | grep -q '"subject"' && fail "email entry must not contain subject" || pass "email entry has no subject"

# Test: updates last UID tracker
LAST_UID=$(cat "$STATE_DIR/email-last-uid" 2>/dev/null | tr -d '[:space:]')
assert_eq "42" "$LAST_UID" "last UID updated to 42"

# Test: multiple emails, tracks highest UID
set_mock_response "check-email" '{"messages": [{"uid": 50, "from": "bob@example.com", "date": "2026-03-04T11:00:00Z"}, {"uid": 55, "from": "carol@example.com", "date": "2026-03-04T12:00:00Z"}]}'
clear_inbox
collect_email; RC=$?
assert_eq "0" "$RC" "returns 0 for multiple emails"
assert_eq "2" "$(find "$INBOX_DIR" -name 'email-*.jsonl' | wc -l | tr -d ' ')" "writes 2 email .jsonl files"
LAST_UID=$(cat "$STATE_DIR/email-last-uid" 2>/dev/null | tr -d '[:space:]')
assert_eq "55" "$LAST_UID" "last UID updated to highest (55)"

echo ""

# ── collect_telegram tests ──

echo "collect_telegram():"

# Test: returns 1 when CLI not found
TELEGRAM_CLI="/nonexistent/telegram.sh"
clear_inbox
collect_telegram; RC=$?
assert_eq "1" "$RC" "returns 1 when CLI not found"

# Create a fake CLI script for remaining tests
FAKE_TG_CLI=$(mktemp)
echo '#!/bin/bash' > "$FAKE_TG_CLI"
echo 'exit 0' >> "$FAKE_TG_CLI"
chmod +x "$FAKE_TG_CLI"
TELEGRAM_CLI="$FAKE_TG_CLI"

# Test: returns 1 when poll returns no messages
# Mock sudo to simulate telegram.sh poll returning exit 1 (no messages)
sudo() { return 1; }
clear_inbox
collect_telegram; RC=$?
assert_eq "1" "$RC" "returns 1 when poll returns no messages"
unset -f sudo

# Test: writes .jsonl when poll returns messages
# Mock sudo to return telegram.sh poll output
sudo() {
    echo '{"update_id":100,"chat_id":789,"from":"tester","text":"hello from telegram","date":1709600000}'
}
clear_inbox
collect_telegram; RC=$?
assert_eq "0" "$RC" "returns 0 when telegram message found"
assert_eq "1" "$(find "$INBOX_DIR" -name 'telegram-*.jsonl' | wc -l | tr -d ' ')" "writes 1 telegram .jsonl to inbox"
unset -f sudo

# Test: telegram entry has correct fields
ENTRY=$(cat "$INBOX_DIR"/telegram-789-100.jsonl 2>/dev/null)
assert_contains "$ENTRY" '"source":"telegram"' "telegram entry has source telegram"
assert_contains "$ENTRY" '"trusted":false' "telegram entry is untrusted"
assert_contains "$ENTRY" '"channel":"telegram-789"' "telegram entry has channel telegram-789"
assert_contains "$ENTRY" '"from":"tester"' "telegram entry has from field"
assert_contains "$ENTRY" 'hello from telegram' "telegram entry has message body"

# Test: multiple messages
sudo() {
    echo '{"update_id":200,"chat_id":789,"from":"alice","text":"msg one","date":1709600001}'
    echo '{"update_id":201,"chat_id":789,"from":"bob","text":"msg two","date":1709600002}'
}
clear_inbox
collect_telegram; RC=$?
assert_eq "0" "$RC" "returns 0 for multiple telegram messages"
assert_eq "2" "$(find "$INBOX_DIR" -name 'telegram-*.jsonl' | wc -l | tr -d ' ')" "writes 2 telegram .jsonl files"
unset -f sudo

# Test: voice message calls stt-transcribe and stores transcription
# Create a fake STT CLI
FAKE_STT_CLI=$(mktemp)
cat > "$FAKE_STT_CLI" <<'STTEOF'
#!/bin/bash
echo '{"text":"transcribed voice text","model":"whisper-1","file_id":"voice-abc"}'
STTEOF
chmod +x "$FAKE_STT_CLI"
STT_CLI="$FAKE_STT_CLI"

sudo() {
    # Detect which CLI is being called
    if [[ "$3" == *"stt-transcribe"* ]] || [[ "$3" == "$FAKE_STT_CLI" ]]; then
        bash "$FAKE_STT_CLI" "$@"
    else
        echo '{"update_id":500,"chat_id":789,"from":"juho","text":null,"date":1709600010,"type":"voice","file_id":"voice-abc","duration":3}'
    fi
}
clear_inbox
collect_telegram; RC=$?
assert_eq "0" "$RC" "returns 0 for voice message"
ENTRY=$(cat "$INBOX_DIR"/telegram-789-500.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'transcribed voice text' "voice message body is transcription"
assert_contains "$ENTRY" '"source":"telegram"' "voice entry has source telegram"
unset -f sudo

# Test: voice message without STT CLI falls back to placeholder
STT_CLI="/nonexistent/stt-transcribe.sh"
sudo() {
    echo '{"update_id":501,"chat_id":789,"from":"juho","text":null,"date":1709600011,"type":"voice","file_id":"voice-def","duration":5}'
}
clear_inbox
collect_telegram; RC=$?
assert_eq "0" "$RC" "returns 0 for voice message without STT"
ENTRY=$(cat "$INBOX_DIR"/telegram-789-501.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'voice message' "voice fallback has placeholder text"
assert_contains "$ENTRY" 'voice-def' "voice fallback has file_id"
unset -f sudo

# Test: text messages still work with type field
STT_CLI="$FAKE_STT_CLI"
sudo() {
    echo '{"update_id":502,"chat_id":789,"from":"tester","text":"normal text","date":1709600012,"type":"text"}'
}
clear_inbox
collect_telegram; RC=$?
assert_eq "0" "$RC" "returns 0 for text message with type field"
ENTRY=$(cat "$INBOX_DIR"/telegram-789-502.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'normal text' "text message body preserved with type field"
unset -f sudo

# Test: reply_to context is included in body
sudo() {
    echo '{"update_id":503,"chat_id":789,"from":"tester","text":"@bot check this","date":1709600013,"type":"text","reply_to":{"from":"alice","text":"original message","date":1709600010}}'
}
clear_inbox
collect_telegram; RC=$?
assert_eq "0" "$RC" "returns 0 for reply message"
ENTRY=$(cat "$INBOX_DIR"/telegram-789-503.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'replying to alice' "reply_to from included in body"
assert_contains "$ENTRY" 'original message' "reply_to text included in body"
assert_contains "$ENTRY" '@bot check this' "reply message text preserved"
unset -f sudo

# Test: non-reply message has no reply_to prefix
sudo() {
    echo '{"update_id":504,"chat_id":789,"from":"tester","text":"plain message","date":1709600014,"type":"text"}'
}
clear_inbox
collect_telegram; RC=$?
ENTRY=$(cat "$INBOX_DIR"/telegram-789-504.jsonl 2>/dev/null)
echo "$ENTRY" | grep -q 'replying to' && fail "non-reply has no reply_to prefix" || pass "non-reply has no reply_to prefix"
unset -f sudo

rm -f "$FAKE_STT_CLI"

# Clean up fake CLI
rm -f "$FAKE_TG_CLI"

echo ""

# ── collect_and_wait tests ──

echo "collect_and_wait():"

# Test: mention arrives → wakes (return 0), inbox has files
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 1, "messages": [{"ts": "2026-02-17 16:10", "sender": "Juho", "message": "wake up"}]}]}'
run_wake 4
assert_eq "0" "$RC" "wakes on mention (return 0)"
FCOUNT=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$FCOUNT" -gt 0 ] && pass "inbox has files after wake" || fail "inbox should have files after wake"

# Test: no mentions → timeout (return 1)
clear_inbox
set_mock_response "unread" '{"channels": []}'
run_wake 1
assert_eq "1" "$RC" "times out with no messages (return 1)"

# Test: no comms → timeout (return 1)
clear_inbox
SAVE_URL="$COMMS_URL"
SAVE_TOKEN="$COMMS_TOKEN"
unset COMMS_URL
unset COMMS_TOKEN
run_wake 1
assert_eq "1" "$RC" "times out when comms not configured (return 1)"
export COMMS_URL="$SAVE_URL"
export COMMS_TOKEN="$SAVE_TOKEN"

echo ""

# ── fetch_config tests ──

echo "fetch_config():"

# Test 11: fetches config from server
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_channels": "dm-test,general", "poll_interval": 2}}'
WAKE_CHANNELS=""
_ENV_WAKE_CHANNELS=""
COMMS_POLL_INTERVAL=1
fetch_config; RC=$?
assert_eq "0" "$RC" "returns 0 on success"
assert_eq "dm-test,general" "$WAKE_CHANNELS" "sets WAKE_CHANNELS from server"
assert_eq "2" "$COMMS_POLL_INTERVAL" "sets COMMS_POLL_INTERVAL from server"

# Test 12: env WAKE_CHANNELS overrides server
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_channels": "dm-test,general", "poll_interval": 3}}'
WAKE_CHANNELS="dm-myagent"
_ENV_WAKE_CHANNELS="dm-myagent"
fetch_config; RC=$?
assert_eq "dm-myagent" "$WAKE_CHANNELS" "env WAKE_CHANNELS overrides server"
assert_eq "3" "$COMMS_POLL_INTERVAL" "poll_interval still updated from server"

# Test 13: returns 1 when comms not configured
SAVE_URL="$COMMS_URL"
unset COMMS_URL
WAKE_CHANNELS=""
_ENV_WAKE_CHANNELS=""
fetch_config; RC=$?
assert_eq "1" "$RC" "returns 1 when COMMS_URL not set"
export COMMS_URL="$SAVE_URL"

# Test 14: defaults when server returns empty wake_channels
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_channels": "", "poll_interval": 1}}'
WAKE_CHANNELS=""
_ENV_WAKE_CHANNELS=""
COMMS_POLL_INTERVAL=5
fetch_config; RC=$?
assert_eq "" "$WAKE_CHANNELS" "empty wake_channels stays empty"
assert_eq "1" "$COMMS_POLL_INTERVAL" "sets default poll_interval from server"

# Test 15: fetch_config sets MAX_TURNS from server
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_channels": "", "poll_interval": 1, "max_turns": 50, "rembeat_interval": 3600}}'
WAKE_CHANNELS=""
_ENV_WAKE_CHANNELS=""
MAX_TURNS=200
INTERVAL=300
fetch_config; RC=$?
assert_eq "50" "$MAX_TURNS" "sets MAX_TURNS from server"
assert_eq "3600" "$INTERVAL" "sets INTERVAL (rembeat_interval) from server"

# Test 16: server omits new keys — env defaults preserved
set_mock_response "config" '{"agent": "TestAgent", "config": {"wake_channels": "", "poll_interval": 1}}'
WAKE_CHANNELS=""
_ENV_WAKE_CHANNELS=""
MAX_TURNS=200
INTERVAL=15000
fetch_config; RC=$?
assert_eq "200" "$MAX_TURNS" "MAX_TURNS preserved when server omits it"
assert_eq "15000" "$INTERVAL" "INTERVAL preserved when server omits rembeat_interval"

# Reset for next tests
WAKE_CHANNELS=""
_ENV_WAKE_CHANNELS=""

echo ""

# ── collect_and_wait with WAKE_CHANNELS ──

echo "collect_and_wait() with WAKE_CHANNELS:"

# Test: wake_channels — wakes when server returns messages
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 1, "messages": [{"ts": "2026-01-01T00:00:00", "sender": "test", "message": "hello"}]}]}'
run_wake 4 "*"
assert_eq "0" "$RC" "wake_channels: wakes when server returns messages"

# Test: wake_channels — still times out with no messages
clear_inbox
set_mock_response "unread" '{"channels": []}'
run_wake 1 "*"
assert_eq "1" "$RC" "wake_channels: times out with no new messages"

# Reset
WAKE_CHANNELS=""

echo ""

# ── read_prompt tests ──

echo "read_prompt():"

# Set up temp prompts directory with test templates
TEST_PROMPTS_DIR=$(mktemp -d)
PROMPTS_DIR="$TEST_PROMPTS_DIR"

# Template with both placeholders (new and backward compat)
cat > "$TEST_PROMPTS_DIR/test.md" << 'TMPL'
Check channels:
{{CHANNELS_BLOCK}}
{{INBOX_BLOCK}}
Done.
TMPL

cat > "$TEST_PROMPTS_DIR/test-legacy.md" << 'TMPL'
Check channels:
{{CHANNELS_BLOCK}}
{{MENTIONS_BLOCK}}
Done.
TMPL

# Test: channels block uses 'fetch' not 'read'
CH_ARRAY=("general" "dm-test")
INTERVAL=300
INBOX_BLOCK=""
INBOX_COUNT=0
AUTONOMY_DIR=""
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "fetch general" "channels block uses 'fetch' subcommand"
assert_contains "$OUTPUT" "fetch dm-test" "channels block includes all channels"
assert_contains "$OUTPUT" "send general" "reply block includes send commands"
assert_contains "$OUTPUT" "send dm-test" "reply block includes all channels for send"

# Test: inbox block injected when INBOX_BLOCK is set
INBOX_BLOCK="--- comms #general (1 messages) ---
[2026-02-17 16:00] [Juho] hey"
INBOX_COUNT=1
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "Messages in your inbox" "inbox header injected"
assert_contains "$OUTPUT" "Juho" "inbox content injected"

# Test: inbox block removed when empty
INBOX_BLOCK=""
INBOX_COUNT=0
OUTPUT=$(read_prompt "test.md")
if echo "$OUTPUT" | grep -qF "Messages in your inbox"; then
    fail "inbox block should be removed when empty"
else
    pass "inbox block removed when INBOX_BLOCK empty"
fi

# Test: backward compat — {{MENTIONS_BLOCK}} still works
INBOX_BLOCK="--- comms (1 messages) ---
[2026-02-17 16:00] [FTW] hello"
INBOX_COUNT=1
OUTPUT=$(read_prompt "test-legacy.md")
assert_contains "$OUTPUT" "Messages in your inbox" "MENTIONS_BLOCK backward compat: header injected"
assert_contains "$OUTPUT" "FTW" "MENTIONS_BLOCK backward compat: content injected"

INBOX_BLOCK=""
INBOX_COUNT=0

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

# Test: local prompts override defaults (per-template customization)
LOCAL_PROMPTS_DIR=$(mktemp -d)
PROJECT_DIR_SAVE="$PROJECT_DIR"
PROJECT_DIR="$LOCAL_PROMPTS_DIR"
mkdir -p "$LOCAL_PROMPTS_DIR/prompts"
cat > "$LOCAL_PROMPTS_DIR/prompts/test.md" << 'TMPL'
Local override:
{{CHANNELS_BLOCK}}
Done.
TMPL
CH_ARRAY=("general")
INTERVAL=300
INBOX_BLOCK=""
AUTONOMY_DIR=""
OUTPUT=$(read_prompt "test.md")
assert_contains "$OUTPUT" "Local override" "local prompts/ overrides default prompts"

# Test: falls back to default when no local override exists
OUTPUT=$(read_prompt "test-msg.md")
assert_contains "$OUTPUT" "--since 10m" "falls back to default when no local override"

rm -rf "$LOCAL_PROMPTS_DIR"
PROJECT_DIR="$PROJECT_DIR_SAVE"

# Test: missing prompt file
OUTPUT=$(read_prompt "nonexistent.md" 2>/dev/null)
assert_contains "$OUTPUT" "Prompt file missing" "missing prompt file returns error"

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
mkdir -p "$CTX_INT_TMP/.introspection-logs"
export CLAUDE_PROJECT_DIR="$CTX_INT_TMP"

# Helper: create a JSONL with specific token values
make_jsonl() {
    local inp="$1" cc="${2:-0}" cr="${3:-0}"
    cat > "$CTX_INT_TMP/.introspection-logs/session.jsonl" << EOF
{"message":{"usage":{"input_tokens":$inp,"cache_creation_input_tokens":$cc,"cache_read_input_tokens":$cr}}}
EOF
}

run_ctx() {
    make_jsonl "$@"
    OUTPUT=$("$CTX_INT_SCRIPT")
    eval "$OUTPUT"
}

# Test: OK label (< 40%)
run_ctx 30000 0 0
assert_eq "OK" "$label" "ctx.sh: label=OK for 15%"
assert_eq "HEALTHY" "$label_long" "ctx.sh: label_long=HEALTHY for 15%"
assert_contains "$formatted" "OK" "ctx.sh: formatted contains OK"

# Test: WARM label (40-69%)
run_ctx 80000 0 0
assert_eq "WARM" "$label" "ctx.sh: label=WARM for 40%"
assert_eq "WARMING" "$label_long" "ctx.sh: label_long=WARMING for 40%"

# Test: HEAVY label (70-89%)
run_ctx 100000 20000 20000
assert_eq "HEAVY" "$label" "ctx.sh: label=HEAVY for 70%"
assert_eq "HEAVY" "$label_long" "ctx.sh: label_long=HEAVY for 70%"

# Test: CRIT label (90%+)
run_ctx 100000 40000 50000
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
mkdir -p "$CTX_INT_TMP/.introspection-logs-empty"
export CLAUDE_PROJECT_DIR="$CTX_INT_TMP"
rm -f "$CTX_INT_TMP/.introspection-logs"/*.jsonl
OUTPUT=$("$CTX_INT_SCRIPT") || true
assert_empty "$OUTPUT" "ctx.sh: no jsonl files — silent empty output"

rm -rf "$CTX_INT_TMP"
unset CLAUDE_PROJECT_DIR

echo ""

# ── activity-push.sh tests ──

echo "activity-push.sh:"

AP_SCRIPT="$SCRIPT_DIR/hooks/activity-push.sh"
run_ap() {
    rm -f "$MOCK_DIR/last-health-post.json"
    AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" 2>/dev/null
}

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
echo '{"tool_name":"Read","tool_input":{"file":"/tmp/x"}}' | run_ap
capture_health_post
assert_contains "$HEALTH_BODY" '"last_tool":"Read"' "activity-push: tool_name extracted from JSON"
assert_contains "$HEALTH_BODY" '"context_pct":42' "activity-push: context_pct in POST body"
assert_contains "$HEALTH_BODY" '"status":"active"' "activity-push: status=active in POST body"

# Test: invalid JSON stdin — tool falls back to "?"
echo 'not json at all' | run_ap
capture_health_post
assert_contains "$HEALTH_BODY" '"last_tool":"?"' "activity-push: invalid JSON — tool falls back to ?"

# Test: empty stdin — tool falls back to "?"
echo '' | run_ap
capture_health_post
assert_contains "$HEALTH_BODY" '"last_tool":"?"' "activity-push: empty stdin — tool falls back to ?"

# Test: POST targets correct agent endpoint
rm -f "$MOCK_DIR/last-health-post.json"
echo '{"tool_name":"Bash"}' | \
    AUTONOMY_DIR="$AP_FAKE_DIR" AGENT="MyAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$AP_SCRIPT" 2>/dev/null
# If we got a health post, the endpoint was hit (agent name is in URL, not body)
capture_health_post
assert_contains "$HEALTH_BODY" '"context_pct":42' "activity-push: POST reaches health endpoint with different agent"

rm -rf "$AP_FAKE_DIR"

echo ""

# ── session-stop.sh tests ──

echo "session-stop.sh:"

SS_SCRIPT="$SCRIPT_DIR/hooks/session-stop.sh"
run_ss() {
    rm -f "$MOCK_DIR/last-health-post.json"
    AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$SS_SCRIPT" 2>/dev/null
}

# Test: no AGENT — exits 0, WARNING on stderr
SAVE_AGENT="$AGENT"
unset AGENT
STDERR=$(COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" \
    bash "$SS_SCRIPT" </dev/null 2>&1 >/dev/null) || true
assert_contains "$STDERR" "WARNING" "session-stop: no AGENT — WARNING on stderr"
export AGENT="$SAVE_AGENT"

# Test: no COMMS_TOKEN — exits 0 silently
OUTPUT=$(AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="" \
    bash "$SS_SCRIPT" </dev/null 2>&1) || true
assert_empty "$OUTPUT" "session-stop: no COMMS_TOKEN — silent exit"

# Test: valid JSON — reason extracted from last_assistant_message
rm -f "$MOCK_DIR/last-health-post.json" "$MOCK_DIR/last-msg-post.json" "$MOCK_DIR/last-msg-path.txt"
echo '{"last_assistant_message":"Task completed successfully"}' | \
    AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" WAKE_CHANNEL="dev" \
    bash "$SS_SCRIPT" 2>/dev/null
sleep 0.3
MSG_BODY=$(cat "$MOCK_DIR/last-msg-post.json" 2>/dev/null || echo "")
HEALTH_BODY=$(cat "$MOCK_DIR/last-health-post.json" 2>/dev/null || echo "")
assert_contains "$MSG_BODY" "Task completed successfully" "session-stop: reason in message POST"
assert_contains "$HEALTH_BODY" '"status":"stopped"' "session-stop: health POST has stopped status"
assert_contains "$HEALTH_BODY" "Task completed successfully" "session-stop: reason in health POST"

# Test: posts to WAKE_CHANNEL
MSG_PATH=$(cat "$MOCK_DIR/last-msg-path.txt" 2>/dev/null || echo "")
assert_contains "$MSG_PATH" "/api/channels/dev/messages" "session-stop: posts to WAKE_CHANNEL"

# Test: defaults to general when WAKE_CHANNEL not set
rm -f "$MOCK_DIR/last-msg-path.txt"
echo '{"last_assistant_message":"done"}' | \
    AGENT="TestAgent" COMMS_URL="http://127.0.0.1:$PORT" COMMS_TOKEN="test-token" WAKE_CHANNEL="" \
    bash "$SS_SCRIPT" 2>/dev/null
sleep 0.3
MSG_PATH=$(cat "$MOCK_DIR/last-msg-path.txt" 2>/dev/null || echo "")
assert_contains "$MSG_PATH" "/api/channels/general/messages" "session-stop: defaults to general channel"

# Test: invalid JSON — reason falls back to "unknown"
echo 'not json' | run_ss
capture_health_post
assert_contains "$HEALTH_BODY" "unknown" "session-stop: invalid JSON — reason=unknown"

# Test: multi-line message — only first line used
printf '{"last_assistant_message":"First line\\nSecond line\\nThird line"}' | run_ss
capture_health_post
assert_contains "$HEALTH_BODY" "First line" "session-stop: multi-line — uses first line"

# Test: empty last_assistant_message — falls back to "no message"
echo '{"last_assistant_message":""}' | run_ss
capture_health_post
assert_contains "$HEALTH_BODY" "no message" "session-stop: empty message — falls back to 'no message'"

echo ""

# ── inject-awareness.sh tests ──

echo "inject-awareness.sh:"

IA_SCRIPT="$SCRIPT_DIR/hooks/inject-awareness.sh"

# Setup: fake AUTONOMY_DIR with mock awareness scripts
IA_DIR=$(mktemp -d)
mkdir -p "$IA_DIR/awareness"

# Mock time.sh
make_echo_mock "$IA_DIR" time.sh "14:30:00 EET"

# Mock context.sh
cat > "$IA_DIR/awareness/context.sh" << 'MOCK'
#!/bin/bash
echo "pct='55'"
echo "label='WARM'"
echo "label_long='WARMING'"
echo "formatted='55% (WARM)'"
echo "used_tokens='110000'"
echo "ctx_size='200000'"
MOCK
chmod +x "$IA_DIR/awareness/context.sh"

# Mock compaction.sh (no output = no compaction)
make_silent_mock "$IA_DIR" compaction.sh

# Mock comms.sh (no output = no alerts)
make_silent_mock "$IA_DIR" comms.sh

# Test: full output is valid JSON
OUTPUT=$(AUTONOMY_DIR="$IA_DIR" bash "$IA_SCRIPT" </dev/null 2>/dev/null) || true
echo "$OUTPUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
assert_eq "0" "$?" "inject-awareness: output is valid JSON"

# Test: output contains time
assert_contains "$OUTPUT" "14:30:00 EET" "inject-awareness: time in output"

# Test: output contains context formatted
assert_contains "$OUTPUT" "55% (WARM)" "inject-awareness: context in output"

# Test: output has correct hookEventName
HOOK_EVENT=$(echo "$OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['hookEventName'])" 2>/dev/null) || true
assert_eq "PreToolUse" "$HOOK_EVENT" "inject-awareness: hookEventName=PreToolUse"

# Test: comms alert appended when present
make_echo_mock "$IA_DIR" comms.sh "PAUSE active"
OUTPUT=$(AUTONOMY_DIR="$IA_DIR" bash "$IA_SCRIPT" </dev/null 2>/dev/null) || true
assert_contains "$OUTPUT" "PAUSE active" "inject-awareness: comms alert in output"

# Test: compaction warning appended when triggered
make_echo_mock "$IA_DIR" compaction.sh "COMPACTION DETECTED"
OUTPUT=$(AUTONOMY_DIR="$IA_DIR" bash "$IA_SCRIPT" </dev/null 2>/dev/null) || true
assert_contains "$OUTPUT" "COMPACTION DETECTED" "inject-awareness: compaction warning in output"

# Test: no awareness scripts — still valid JSON with empty context
IA_EMPTY=$(mktemp -d)
mkdir -p "$IA_EMPTY/awareness"
OUTPUT=$(AUTONOMY_DIR="$IA_EMPTY" bash "$IA_SCRIPT" </dev/null 2>/dev/null) || true
echo "$OUTPUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
assert_eq "0" "$?" "inject-awareness: no scripts — still valid JSON"
rm -rf "$IA_EMPTY"

rm -rf "$IA_DIR"

echo ""

# ── comms.sh (awareness) tests ──

echo "comms.sh (awareness):"

COMMS_SCRIPT="$SCRIPT_DIR/awareness/comms.sh"

# Setup: temp project dir with inbox
CS_PROJECT=$(mktemp -d)
CS_INBOX="$CS_PROJECT/.queue/inbox"
mkdir -p "$CS_INBOX"

# Helper to write inbox .jsonl files
write_inbox_msg() {
    local id="$1" from="$2" body="$3"
    echo "{\"id\":\"$id\",\"source\":\"comms\",\"from\":\"$from\",\"body\":\"$body\",\"trusted\":true}" \
        > "$CS_INBOX/${id}.jsonl"
}
clear_inbox() {
    rm -f "$CS_INBOX"/*.jsonl
}

# Test: PAUSE from anyone — triggers alert
clear_inbox
write_inbox_msg "comms-general-001" "Juho" "PAUSE"
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "PAUSE" "comms.sh: PAUSE triggers alert"
assert_contains "$OUTPUT" "Juho" "comms.sh: PAUSE alert includes sender"
assert_contains "$OUTPUT" "STOP IMMEDIATELY" "comms.sh: PAUSE alert is strong"

# Test: GO after PAUSE — no alert
clear_inbox
write_inbox_msg "comms-general-001" "Juho" "PAUSE"
write_inbox_msg "comms-general-002" "Juho" "GO"
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
if echo "$OUTPUT" | grep -qiF "PAUSE"; then
    fail "comms.sh: GO cancels PAUSE (alert still present)"
else
    pass "comms.sh: GO cancels PAUSE"
fi

# Test: PAUSE from non-Juho team member — also triggers
clear_inbox
write_inbox_msg "comms-general-001" "FTF" "PAUSE check the logs"
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "PAUSE" "comms.sh: PAUSE from any team member triggers alert"
assert_contains "$OUTPUT" "FTF" "comms.sh: alert includes non-Juho sender"

# Test: no PAUSE messages — silent
clear_inbox
write_inbox_msg "comms-general-001" "FTW" "Hello team"
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
assert_empty "$OUTPUT" "comms.sh: non-PAUSE messages — silent"

# Test: empty inbox — silent
clear_inbox
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
assert_empty "$OUTPUT" "comms.sh: empty inbox — silent"

# Test: no inbox dir — silent exit
CS_NOQUEUE=$(mktemp -d)
OUTPUT=$(PROJECT_DIR="$CS_NOQUEUE" bash "$COMMS_SCRIPT" 2>/dev/null) || true
assert_empty "$OUTPUT" "comms.sh: no inbox dir — silent exit"
rm -rf "$CS_NOQUEUE"

# Test: PAUSED mid-word doesn't trigger (requires PAUSE at start of body)
clear_inbox
write_inbox_msg "comms-general-001" "Juho" "PAUSED for lunch"
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
if echo "$OUTPUT" | grep -qiF "STOP IMMEDIATELY"; then
    fail "comms.sh: PAUSED (not PAUSE) — false alert"
else
    pass "comms.sh: PAUSED (not PAUSE) — no false alert"
fi

# Test: PAUSE with message body preserved in alert
clear_inbox
write_inbox_msg "comms-general-001" "Juho" "PAUSE need to review the deploy plan"
OUTPUT=$(PROJECT_DIR="$CS_PROJECT" bash "$COMMS_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "need to review" "comms.sh: PAUSE message body in alert"

rm -rf "$CS_PROJECT"

echo ""

# ── inject-context.sh tests ──

echo "inject-context.sh:"

IC_SCRIPT="$SCRIPT_DIR/hooks/inject-context.sh"

# Setup: fake AUTONOMY_DIR with mock awareness scripts
IC_DIR=$(mktemp -d)
mkdir -p "$IC_DIR/awareness"

make_echo_mock "$IC_DIR" time.sh "20:15:00 EET"

cat > "$IC_DIR/awareness/context.sh" << 'MOCK'
#!/bin/bash
echo "pct='63'"
echo "label='WARM'"
echo "label_long='WARMING'"
echo "used_tokens='126000'"
echo "ctx_size='200000'"
MOCK
chmod +x "$IC_DIR/awareness/context.sh"

make_silent_mock "$IC_DIR" compaction.sh
make_silent_mock "$IC_DIR" git.sh

# Test: time in output
OUTPUT=$(AUTONOMY_DIR="$IC_DIR" bash "$IC_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "Current time: 20:15:00 EET" "inject-context: time in output"

# Test: context line formatted correctly
assert_contains "$OUTPUT" "Context: 63% (WARMING)" "inject-context: context pct and label"
assert_contains "$OUTPUT" "~126000tok" "inject-context: tokens in context line"

# Test: compaction message shown when triggered
make_echo_mock "$IC_DIR" compaction.sh "COMPACTION: read SOUL.md, TEAM.md, MEMORY.md"
OUTPUT=$(AUTONOMY_DIR="$IC_DIR" bash "$IC_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "COMPACTION" "inject-context: compaction warning shown"

# Test: git context shown when present
cat > "$IC_DIR/awareness/git.sh" << 'MOCK'
#!/bin/bash
echo "New commits in autonomy (origin/main):"
echo "abc1234 Fix bug"
MOCK
chmod +x "$IC_DIR/awareness/git.sh"
OUTPUT=$(AUTONOMY_DIR="$IC_DIR" bash "$IC_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "New commits" "inject-context: git context shown"

# Test: no scripts — no output
IC_EMPTY=$(mktemp -d)
mkdir -p "$IC_EMPTY/awareness"
OUTPUT=$(AUTONOMY_DIR="$IC_EMPTY" bash "$IC_SCRIPT" 2>/dev/null) || true
assert_empty "$OUTPUT" "inject-context: no scripts — no output"
rm -rf "$IC_EMPTY"

rm -rf "$IC_DIR"

echo ""

# ── deploy-hooks.sh merge logic tests ──

echo "deploy-hooks merge:"

DH_TMP=$(mktemp -d)

merge_hooks() {
    python3 -c "
import json, sys
with open(sys.argv[1]) as f: hooks_config = json.load(f)
try:
    with open(sys.argv[2]) as f: settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError): settings = {}
settings['hooks'] = hooks_config['hooks']
with open(sys.argv[2], 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" "$1" "$2"
}

# Test: merge hooks into existing settings — preserves other keys
echo '{"hooks": {"PreToolUse": [{"matcher": ".*"}]}}' > "$DH_TMP/hooks.json"
echo '{"permissions": {"allow": ["Read"]}, "hooks": {"old": []}}' > "$DH_TMP/settings.json"
merge_hooks "$DH_TMP/hooks.json" "$DH_TMP/settings.json"
MERGED=$(cat "$DH_TMP/settings.json")
assert_contains "$MERGED" '"permissions"' "deploy-merge: preserves existing keys"
assert_contains "$MERGED" '"PreToolUse"' "deploy-merge: new hooks present"
if echo "$MERGED" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'old' not in d['hooks']" 2>/dev/null; then
    pass "deploy-merge: old hooks replaced"
else
    fail "deploy-merge: old hooks replaced"
fi

# Test: merge into non-existent settings — creates new
rm -f "$DH_TMP/new-settings.json"
merge_hooks "$DH_TMP/hooks.json" "$DH_TMP/new-settings.json"
assert_eq "0" "$?" "deploy-merge: creates settings from scratch"
NEW_MERGED=$(cat "$DH_TMP/new-settings.json")
assert_contains "$NEW_MERGED" '"PreToolUse"' "deploy-merge: hooks in new file"

# Test: merge into malformed settings — treats as empty
echo 'not json{{{' > "$DH_TMP/bad-settings.json"
merge_hooks "$DH_TMP/hooks.json" "$DH_TMP/bad-settings.json"
BAD_MERGED=$(cat "$DH_TMP/bad-settings.json")
assert_contains "$BAD_MERGED" '"PreToolUse"' "deploy-merge: recovers from malformed settings"

rm -rf "$DH_TMP"

echo ""

# ── process.sh tests ──

echo "process.sh:"

PROC_SCRIPT="$SCRIPT_DIR/awareness/process.sh"

# Test: output is valid JSON
PROC_OUT=$(bash "$PROC_SCRIPT" 2>/dev/null) || true
echo "$PROC_OUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
assert_eq "0" "$?" "process.sh: output is valid JSON"

# Test: has all required keys
KEYS=$(echo "$PROC_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(sorted(d.keys())))" 2>/dev/null)
assert_eq "daemon_pid,has_resume,is_daemon,pid,session_id" "$KEYS" "process.sh: all required keys present"

# Test: booleans are actual booleans (not strings)
TYPES=$(echo "$PROC_OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(type(d['is_daemon']).__name__, type(d['has_resume']).__name__)
" 2>/dev/null)
assert_eq "bool bool" "$TYPES" "process.sh: booleans are JSON booleans"

# Test: pid/daemon_pid are integers
TYPES=$(echo "$PROC_OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(type(d['pid']).__name__, type(d['daemon_pid']).__name__)
" 2>/dev/null)
assert_eq "int int" "$TYPES" "process.sh: pid values are integers"

# Test: session_id is a string
SID_TYPE=$(echo "$PROC_OUT" | python3 -c "import json,sys; print(type(json.load(sys.stdin)['session_id']).__name__)" 2>/dev/null)
assert_eq "str" "$SID_TYPE" "process.sh: session_id is a string"

# Test: is_daemon and has_resume are consistent (both booleans, not string "true"/"false")
BOOL_CHECK=$(echo "$PROC_OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
# Verify no string booleans leaked through
assert d['is_daemon'] in (True, False)
assert d['has_resume'] in (True, False)
print('ok')
" 2>/dev/null)
assert_eq "ok" "$BOOL_CHECK" "process.sh: boolean values are True/False not strings"

echo ""

# ── bootloader-check.sh tests ──

echo "bootloader-check.sh:"

BOOTLOADER_CHECK="$SCRIPT_DIR/awareness/bootloader-check.sh"
BC_TMP=$(mktemp -d)
mkdir -p "$BC_TMP/.autonomy" "$BC_TMP/memory"

# Below thresholds — silent
echo "short" > "$BC_TMP/memory/MEMORY.md"
git -C "$BC_TMP" init --quiet 2>/dev/null
git -C "$BC_TMP" commit --allow-empty -m "init" --quiet 2>/dev/null || true
out=$(PROJECT_DIR="$BC_TMP" bash "$BOOTLOADER_CHECK" 2>/dev/null)
assert_empty "$out" "bootloader-check: silent when below thresholds"

# Already has bootloader/ dir — silent even if thresholds met
mkdir -p "$BC_TMP/bootloader"
# Add enough lines to memory to hit threshold
python3 -c "print('\n' * 110)" >> "$BC_TMP/memory/MEMORY.md"
out=$(PROJECT_DIR="$BC_TMP" bash "$BOOTLOADER_CHECK" 2>/dev/null)
assert_empty "$out" "bootloader-check: silent when bootloader/ dir exists"
rm -rf "$BC_TMP/bootloader"

# Memory threshold reached — emits suggestion + creates flag
out=$(PROJECT_DIR="$BC_TMP" bash "$BOOTLOADER_CHECK" 2>/dev/null)
assert_contains "$out" "BOOTLOADER" "bootloader-check: emits suggestion when memory threshold met"
[ -f "$BC_TMP/.autonomy/.bootloader-suggested" ]
assert_eq "0" "$?" "bootloader-check: creates flag file on first suggestion"

# Already suggested — silent
out=$(PROJECT_DIR="$BC_TMP" bash "$BOOTLOADER_CHECK" 2>/dev/null)
assert_empty "$out" "bootloader-check: silent after flag set (no repeat nag)"

rm -rf "$BC_TMP"

echo ""

# ── push_activity tests ──

echo "push_activity:"

# Test: POSTs correct JSON structure to activity endpoint
rm -f "$MOCK_DIR/last-activity-post.json"
push_activity "error" "something went wrong"
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_contains "$ACTIVITY_BODY" '"type":"error"' "push_activity: type field in POST body"
assert_contains "$ACTIVITY_BODY" '"summary":"something went wrong"' "push_activity: summary field in POST body"
assert_contains "$ACTIVITY_BODY" '"events":[' "push_activity: events array wrapper"
assert_contains "$ACTIVITY_BODY" '"ts":"' "push_activity: timestamp present"

# Test: different event types work
rm -f "$MOCK_DIR/last-activity-post.json"
push_activity "warning" "disk space low"
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_contains "$ACTIVITY_BODY" '"type":"warning"' "push_activity: supports different event types"
assert_contains "$ACTIVITY_BODY" '"summary":"disk space low"' "push_activity: different summary text"

# Test: no COMMS_URL — returns silently (no crash)
SAVE_COMMS_URL="$COMMS_URL"
COMMS_URL=""
rm -f "$MOCK_DIR/last-activity-post.json"
push_activity "error" "should not appear"
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_empty "$ACTIVITY_BODY" "push_activity: no COMMS_URL — no POST sent"
COMMS_URL="$SAVE_COMMS_URL"

# Test: no COMMS_TOKEN — returns silently (no crash)
SAVE_COMMS_TOKEN="$COMMS_TOKEN"
COMMS_TOKEN=""
rm -f "$MOCK_DIR/last-activity-post.json"
push_activity "error" "should not appear"
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_empty "$ACTIVITY_BODY" "push_activity: no COMMS_TOKEN — no POST sent"
COMMS_TOKEN="$SAVE_COMMS_TOKEN"

# ── run_claude stderr capture tests ──

echo ""
echo "run_claude stderr capture:"

# Test: stderr is logged when claude writes to it
# We can't call run_claude() directly (needs claude binary), but we can test
# the stderr-to-activity pattern by simulating what run_claude does.
RC_TMP=$(mktemp -d)
RC_LOG=$(mktemp)
DAEMON_LOG="$RC_LOG"

# Simulate the stderr capture pattern from run_claude
_err_file=$(mktemp /tmp/claude-err-XXXXXX)
echo "Rate limit exceeded: too many requests" > "$_err_file"
_stderr=$(cat "$_err_file" 2>/dev/null)
rm -f "$_err_file"
assert_contains "$_stderr" "Rate limit" "stderr-capture: temp file captures stderr content"

# Test: push_activity called with first line of stderr, truncated
rm -f "$MOCK_DIR/last-activity-post.json"
if [ -n "$_stderr" ]; then
    log "claude stderr: $_stderr"
    push_activity "error" "$(echo "$_stderr" | head -1 | cut -c1-200)"
fi
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_contains "$ACTIVITY_BODY" '"type":"error"' "stderr-capture: pushes error event to activity"
assert_contains "$ACTIVITY_BODY" "Rate limit exceeded" "stderr-capture: stderr content in activity summary"

# Test: multiline stderr — only first line pushed
rm -f "$MOCK_DIR/last-activity-post.json"
_multi_stderr=$'First line error\nSecond line detail\nThird line trace'
push_activity "error" "$(echo "$_multi_stderr" | head -1 | cut -c1-200)"
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_contains "$ACTIVITY_BODY" "First line error" "stderr-capture: multiline — only first line in summary"

# Test: empty stderr — no activity push
rm -f "$MOCK_DIR/last-activity-post.json"
_empty_stderr=""
if [ -n "$_empty_stderr" ]; then
    push_activity "error" "should not fire"
fi
sleep 0.3
ACTIVITY_BODY=$(cat "$MOCK_DIR/last-activity-post.json" 2>/dev/null || echo "")
assert_empty "$ACTIVITY_BODY" "stderr-capture: empty stderr — no activity push"

# Test: stderr logged to daemon log
DAEMON_LOG="$RC_LOG"
log "claude stderr: test error message"
LOG_CONTENT=$(cat "$RC_LOG")
assert_contains "$LOG_CONTENT" "claude stderr: test error message" "stderr-capture: stderr written to daemon log"

rm -rf "$RC_TMP" "$RC_LOG"

echo ""

# ── Summary ──

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
fi
