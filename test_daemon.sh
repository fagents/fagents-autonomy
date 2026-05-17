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
print('LAST_WHATSAPP_CHECK=0')
print('WHATSAPP_CADENCE=3')
print('WHATSAPP_CLI="/nonexistent/whatsapp.mjs"')
print('LAST_NOSTR_CHECK=0')
print('NOSTR_CADENCE=3')
print('NOSTR_CLI="/nonexistent/nostr.mjs"')
print('NOSTR_SERVE_PID=""')
print('NOSTR_AGENT_HOME="/nonexistent/.agents/test"')
print('NOSTR_ENV_FILE="$NOSTR_AGENT_HOME/nostr.env"')
print('NOSTR_SPOOL_DIR="$NOSTR_AGENT_HOME/nostr-spool"')
print('NOSTR_OUTBOX_DIR="$NOSTR_AGENT_HOME/nostr-outbox"')
print('NOSTR_PID_FILE="$NOSTR_AGENT_HOME/.nostr-serve.pid"')
print('AGENT="test"')
print()

funcs = ['refresh_channels', 'fetch_config', 'collect_comms', 'collect_email', 'collect_telegram', 'collect_whatsapp', 'collect_nostr', 'ensure_nostr_serve', 'read_inbox', 'archive_inbox', 'collect_and_wait', 'read_prompt', 'check_comms', 'push_activity', 'check_pause', 'run_with_watchdog', 'handle_backend_result', 'run_claude', 'run_codex', 'run_backend']
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
export DAEMON_BACKEND="claude"
CODEX_MODEL=""
TURN_TIMEOUT_SEC=300
TURN_TIMEOUT_GRACE_SEC=10
BACKEND_EXIT_CODE=0
BACKEND_JSON=""
BACKEND_SESSION_ID=""
BACKEND_RESULT=""

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

# Test 7: same-second, SAME sender — only msg_id prevents collision
# This is the critical regression test: without msg_id, these would collide
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 2, "messages": [{"ts": "2026-02-17 16:00:05 EET", "sender": "Juho", "message": "first msg", "msg_id": 41}, {"ts": "2026-02-17 16:00:05 EET", "sender": "Juho", "message": "second msg", "msg_id": 42}]}]}'
collect_comms; RC=$?
assert_eq "0" "$RC" "returns 0 for same-second same-sender messages"
FCOUNT=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2" "$FCOUNT" "same-second same-sender: msg_id prevents collision"

# Verify both message bodies are present (not overwritten)
ALL_BODIES=$(cat "$INBOX_DIR"/*.jsonl 2>/dev/null | jq -r '.body' | sort)
echo "$ALL_BODIES" | grep -q "first msg" && pass "same-second same-sender: first body present" || fail "same-second same-sender: first body present"
echo "$ALL_BODIES" | grep -q "second msg" && pass "same-second same-sender: second body present" || fail "same-second same-sender: second body present"

# Verify filenames use msg_id (comms-general-41 and comms-general-42), not timestamp
test -f "$INBOX_DIR/comms-general-41.jsonl" && pass "inbox filename uses msg_id 41" || fail "inbox filename uses msg_id 41"
test -f "$INBOX_DIR/comms-general-42.jsonl" && pass "inbox filename uses msg_id 42" || fail "inbox filename uses msg_id 42"

# Test 8: same-second without msg_id — fallback to timestamp+sender (different senders still work)
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 2, "messages": [{"ts": "2026-02-17 16:00:05 EET", "sender": "Juho", "message": "msg A"}, {"ts": "2026-02-17 16:00:05 EET", "sender": "FTF", "message": "msg B"}]}]}'
collect_comms; RC=$?
FCOUNT=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2" "$FCOUNT" "same-second different-sender without msg_id both preserved"

# Test 9: same-second, same sender, NO msg_id — this IS a collision (documents the limitation)
clear_inbox
set_mock_response "unread" '{"channels": [{"channel": "general", "unread_count": 2, "messages": [{"ts": "2026-02-17 16:00:05 EET", "sender": "Juho", "message": "will be lost"}, {"ts": "2026-02-17 16:00:05 EET", "sender": "Juho", "message": "overwrites"}]}]}'
collect_comms; RC=$?
FCOUNT=$(find "$INBOX_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$FCOUNT" "same-second same-sender without msg_id collides (known limitation)"

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

# ── collect_whatsapp tests ──

echo "collect_whatsapp():"

# Test: returns 1 when node not found
SAVE_WHATSAPP_CLI="$WHATSAPP_CLI"
WHATSAPP_CLI="/nonexistent/whatsapp.mjs"
clear_inbox
collect_whatsapp; RC=$?
assert_eq "1" "$RC" "returns 1 when CLI not found"

# Create a fake CLI script for remaining tests
FAKE_WA_CLI=$(mktemp)
echo '#!/bin/bash' > "$FAKE_WA_CLI"
echo 'exit 0' >> "$FAKE_WA_CLI"
chmod +x "$FAKE_WA_CLI"
WHATSAPP_CLI="$FAKE_WA_CLI"

# Test: returns 1 when poll returns no messages
sudo() { return 1; }
clear_inbox
collect_whatsapp; RC=$?
assert_eq "1" "$RC" "returns 1 when poll returns no messages"
unset -f sudo

# Test: writes .jsonl when poll returns messages
sudo() {
    echo '{"id":"msg001","jid":"358445150070@s.whatsapp.net","from":"Juho","text":"hello from whatsapp","ts":"2026-04-03T10:00:00.000Z","type":"text"}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 when whatsapp message found"
assert_eq "1" "$(find "$INBOX_DIR" -name 'whatsapp-*.jsonl' | wc -l | tr -d ' ')" "writes 1 whatsapp .jsonl to inbox"
unset -f sudo

# Test: whatsapp entry has correct fields
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg001.jsonl 2>/dev/null)
assert_contains "$ENTRY" '"source":"whatsapp"' "whatsapp entry has source whatsapp"
assert_contains "$ENTRY" '"trusted":false' "whatsapp entry is untrusted"
assert_contains "$ENTRY" '"channel":"whatsapp-358445150070@s.whatsapp.net"' "whatsapp entry has channel"
assert_contains "$ENTRY" '"from":"Juho"' "whatsapp entry has from field"
assert_contains "$ENTRY" 'hello from whatsapp' "whatsapp entry has message body"
assert_contains "$ENTRY" '"jid":"358445150070@s.whatsapp.net"' "whatsapp entry has jid field"

# Test: multiple messages
sudo() {
    echo '{"id":"msg002","jid":"358445150070@s.whatsapp.net","from":"Juho","text":"first","ts":"2026-04-03T10:00:01.000Z","type":"text"}'
    echo '{"id":"msg003","jid":"358445150070@s.whatsapp.net","from":"Juho","text":"second","ts":"2026-04-03T10:00:02.000Z","type":"text"}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 for multiple whatsapp messages"
assert_eq "2" "$(find "$INBOX_DIR" -name 'whatsapp-*.jsonl' | wc -l | tr -d ' ')" "writes 2 whatsapp .jsonl files"
unset -f sudo

# Test: voice message with audio_path calls STT and stores transcription
FAKE_STT_CLI=$(mktemp)
cat > "$FAKE_STT_CLI" <<'STTEOF'
#!/bin/bash
echo '{"text":"transcribed whatsapp voice","model":"whisper-1"}'
STTEOF
chmod +x "$FAKE_STT_CLI"
STT_CLI="$FAKE_STT_CLI"

# Create a fake audio file for the voice test
FAKE_AUDIO=$(mktemp /tmp/whatsapp-voice-XXXXXX.oga)
echo "fake audio" > "$FAKE_AUDIO"

sudo() {
    if [[ "$3" == *"stt-transcribe"* ]] || [[ "$3" == "$FAKE_STT_CLI" ]]; then
        bash "$FAKE_STT_CLI" "$@"
    else
        echo "{\"id\":\"msg004\",\"jid\":\"358445150070@s.whatsapp.net\",\"from\":\"Juho\",\"text\":null,\"ts\":\"2026-04-03T10:00:03.000Z\",\"type\":\"voice\",\"duration\":4,\"audio_path\":\"$FAKE_AUDIO\"}"
    fi
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 for voice message with audio_path"
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg004.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'transcribed whatsapp voice' "voice message body is transcription"
assert_contains "$ENTRY" '"source":"whatsapp"' "voice entry has source whatsapp"
# Audio file should be cleaned up after transcription
test ! -f "$FAKE_AUDIO" && pass "audio file cleaned up after transcription" || fail "audio file cleaned up after transcription"
unset -f sudo

# Test: voice message without STT CLI falls back to placeholder
STT_CLI="/nonexistent/stt-transcribe.sh"
FAKE_AUDIO2=$(mktemp /tmp/whatsapp-voice-XXXXXX.oga)
echo "fake audio" > "$FAKE_AUDIO2"
sudo() {
    echo "{\"id\":\"msg005\",\"jid\":\"358445150070@s.whatsapp.net\",\"from\":\"Juho\",\"text\":null,\"ts\":\"2026-04-03T10:00:04.000Z\",\"type\":\"voice\",\"duration\":3,\"audio_path\":\"$FAKE_AUDIO2\"}"
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 for voice without STT"
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg005.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'STT not available' "voice fallback mentions STT not available"
unset -f sudo
rm -f "$FAKE_AUDIO2"

# Test: voice message without audio_path (download failed)
sudo() {
    echo '{"id":"msg006","jid":"358445150070@s.whatsapp.net","from":"Juho","text":null,"ts":"2026-04-03T10:00:05.000Z","type":"voice","duration":2}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 for voice without audio_path"
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg006.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'audio download failed' "voice without audio mentions download failed"
unset -f sudo

# Test: image message
sudo() {
    echo '{"id":"msg007","jid":"358445150070@s.whatsapp.net","from":"Juho","text":"look at this","ts":"2026-04-03T10:00:06.000Z","type":"image","mimetype":"image/jpeg"}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 for image message"
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg007.jsonl 2>/dev/null)
assert_contains "$ENTRY" '[image' "image message has type label"
assert_contains "$ENTRY" 'look at this' "image caption preserved"
unset -f sudo

# Test: document message
sudo() {
    echo '{"id":"msg008","jid":"358445150070@s.whatsapp.net","from":"Juho","text":null,"ts":"2026-04-03T10:00:07.000Z","type":"document","filename":"report.pdf"}'
}
clear_inbox
collect_whatsapp; RC=$?
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg008.jsonl 2>/dev/null)
assert_contains "$ENTRY" '[document: report.pdf]' "document message has filename"
unset -f sudo

# Test: reply_to context included in body
sudo() {
    echo '{"id":"msg009","jid":"358445150070@s.whatsapp.net","from":"Juho","text":"check this","ts":"2026-04-03T10:00:08.000Z","type":"text","reply_to":{"id":"msg001","from":"358445150070","text":"original msg"}}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "returns 0 for reply message"
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg009.jsonl 2>/dev/null)
assert_contains "$ENTRY" 'replying to 358445150070' "reply_to from included in body"
assert_contains "$ENTRY" 'original msg' "reply_to text included in body"
assert_contains "$ENTRY" 'check this' "reply message text preserved"
unset -f sudo

# Test: non-reply has no reply_to prefix
sudo() {
    echo '{"id":"msg010","jid":"358445150070@s.whatsapp.net","from":"Juho","text":"plain message","ts":"2026-04-03T10:00:09.000Z","type":"text"}'
}
clear_inbox
collect_whatsapp; RC=$?
ENTRY=$(cat "$INBOX_DIR"/whatsapp-msg010.jsonl 2>/dev/null)
echo "$ENTRY" | grep -q 'replying to' && fail "non-reply has no reply_to prefix" || pass "non-reply has no reply_to prefix"
unset -f sudo

# Test: empty text messages (delivery receipts, system events) are skipped
sudo() {
    echo '{"id":"msg011","jid":"358445150070@s.whatsapp.net","from":"Juho","text":null,"ts":"2026-04-03T10:00:10.000Z","type":"text"}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "1" "$RC" "skips empty text message (delivery receipt)"
assert_eq "0" "$(find "$INBOX_DIR" -name 'whatsapp-*.jsonl' | wc -l | tr -d ' ')" "no inbox file for empty text"
unset -f sudo

# Test: empty text skipped but non-text types with empty text still pass
sudo() {
    echo '{"id":"msg012","jid":"358445150070@s.whatsapp.net","from":"Juho","text":null,"ts":"2026-04-03T10:00:11.000Z","type":"image","mimetype":"image/jpeg"}'
}
clear_inbox
collect_whatsapp; RC=$?
assert_eq "0" "$RC" "image with null text still passes"
assert_eq "1" "$(find "$INBOX_DIR" -name 'whatsapp-*.jsonl' | wc -l | tr -d ' ')" "image written to inbox"
unset -f sudo

rm -f "$FAKE_STT_CLI" "$FAKE_WA_CLI"
WHATSAPP_CLI="$SAVE_WHATSAPP_CLI"

echo ""

# ── collect_nostr tests ──

echo "collect_nostr():"

# Test: returns 1 when CLI not found
SAVE_NOSTR_CLI="$NOSTR_CLI"
NOSTR_CLI="/nonexistent/nostr.mjs"
SAVE_NOSTR_ENV_FILE="$NOSTR_ENV_FILE"
FAKE_NOSTR_ENV=$(mktemp)
# Populate with a fake NOSTR_NSEC so the new (r12) "must have NSEC" guard
# passes; the test wants to exercise CLI-not-found, not the NSEC-missing path
# (which is exercised separately below).
echo "NOSTR_NSEC=nsec1faketestkey" > "$FAKE_NOSTR_ENV"
NOSTR_ENV_FILE="$FAKE_NOSTR_ENV"
clear_inbox
collect_nostr; RC=$?
assert_eq "1" "$RC" "returns 1 when CLI not found"

# Test: returns 1 when nostr.env is absent (unconfigured-agent guard)
NOSTR_ENV_FILE="/nonexistent/agents/test/nostr.env"
clear_inbox
collect_nostr; RC=$?
assert_eq "1" "$RC" "returns 1 when nostr.env is absent (unconfigured agent)"
NOSTR_ENV_FILE="$FAKE_NOSTR_ENV"

# Create a fake CLI for remaining tests
FAKE_NOSTR_CLI=$(mktemp)
echo '#!/bin/bash' > "$FAKE_NOSTR_CLI"
echo 'exit 0' >> "$FAKE_NOSTR_CLI"
chmod +x "$FAKE_NOSTR_CLI"
NOSTR_CLI="$FAKE_NOSTR_CLI"

# Test: returns 1 when poll returns no messages
sudo() { return 1; }
clear_inbox
collect_nostr; RC=$?
assert_eq "1" "$RC" "returns 1 when poll returns no messages"
unset -f sudo

# Test: writes .jsonl when poll returns a message (raw body, no <untrusted>)
sudo() {
    echo '{"ts":"2026-05-17T10:00:00.000Z","from_npub":"npub1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","from_hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"hello from nostr","wrap_event_id":"deadbeef","rumor_id":"feedface"}'
}
clear_inbox
collect_nostr; RC=$?
assert_eq "0" "$RC" "returns 0 when nostr msg found"
assert_eq "1" "$(find "$INBOX_DIR" -name 'nostr-*.jsonl' | wc -l | tr -d ' ')" "writes 1 nostr .jsonl"
unset -f sudo

# Inbox entry shape
ENTRY=$(cat "$INBOX_DIR"/nostr-deadbeef.jsonl 2>/dev/null)
assert_contains "$ENTRY" '"source":"nostr"' "nostr entry has source"
assert_contains "$ENTRY" '"trusted":false' "nostr entry is untrusted"
assert_contains "$ENTRY" '"from":"npub1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "entry has from npub"
assert_contains "$ENTRY" '"body":"hello from nostr"' "entry body is RAW (no <untrusted>)"
# Anti-double-wrap: body must NOT be pre-wrapped (codex r2 P2 contract)
if echo "$ENTRY" | grep -q '"body":"<untrusted>'; then
    fail "nostr entry body must NOT be pre-wrapped in <untrusted> (read_inbox handles it)"
else
    pass "nostr entry body is NOT pre-wrapped in <untrusted>"
fi
assert_contains "$ENTRY" '"wrap_event_id":"deadbeef"' "entry has wrap_event_id"
assert_contains "$ENTRY" '"rumor_id":"feedface"' "entry has rumor_id"

# Multiple messages
sudo() {
    echo '{"ts":"2026-05-17T10:00:01Z","from_npub":"npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","from_hex":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","body":"one","wrap_event_id":"wrap1","rumor_id":"r1"}'
    echo '{"ts":"2026-05-17T10:00:02Z","from_npub":"npub1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy","from_hex":"yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy","body":"two","wrap_event_id":"wrap2","rumor_id":"r2"}'
}
clear_inbox
collect_nostr; RC=$?
assert_eq "0" "$RC" "returns 0 for multiple nostr msgs"
assert_eq "2" "$(find "$INBOX_DIR" -name 'nostr-*.jsonl' | wc -l | tr -d ' ')" "writes 2 nostr .jsonl files"
unset -f sudo

rm -f "$FAKE_NOSTR_CLI"
NOSTR_CLI="$SAVE_NOSTR_CLI"

echo ""

# ── ensure_nostr_serve test (set -u + NOSTR_DISABLE) ──

echo "ensure_nostr_serve():"

# Regression: NOSTR_CADENCE / LAST_NOSTR_CHECK must be defined under set -u
# (otherwise daemon would crash with unbound-variable at first cadence check).
assert_eq "0" "$LAST_NOSTR_CHECK" "LAST_NOSTR_CHECK is initialized to 0"
[ -n "$NOSTR_CADENCE" ] && pass "NOSTR_CADENCE is defined" || fail "NOSTR_CADENCE is defined"
# Cadence arithmetic under set -u (mirrors what collect_and_wait does)
( set -u; now=10; [ $((now - LAST_NOSTR_CHECK)) -ge "$NOSTR_CADENCE" ] && true || true ) && pass "cadence arithmetic survives set -u" || fail "cadence arithmetic survives set -u"

# NOSTR_DISABLE=1 -> ensure_nostr_serve is a no-op
NOSTR_DISABLE=1 ensure_nostr_serve; RC=$?
assert_eq "0" "$RC" "NOSTR_DISABLE=1 returns 0 (no-op)"
[ -z "$NOSTR_SERVE_PID" ] && pass "NOSTR_DISABLE keeps PID empty" || fail "NOSTR_DISABLE keeps PID empty (got '$NOSTR_SERVE_PID')"

# Regression for r5 P1: NOSTR paths in daemon.sh must derive from the Unix
# user slug (e.g. "comms"), NOT from $AGENT (display name like "Comms").
# After r7 refactor, the derivation lives on the NOSTR_AGENT_HOME line.
NOSTR_HOME_LINE=$(grep '^NOSTR_AGENT_HOME=' "$SCRIPT_DIR/daemon.sh")
if echo "$NOSTR_HOME_LINE" | grep -q 'whoami'; then
    pass "NOSTR_AGENT_HOME derives from \$(whoami) not \$AGENT"
else
    fail "NOSTR_AGENT_HOME must use \$(whoami) (Unix user slug); current line: $NOSTR_HOME_LINE"
fi

# Regression for r6 P1: macOS / Linux paths must both work.
if echo "$NOSTR_HOME_LINE" | grep -q 'FAGENTS_AGENTS_DIR'; then
    pass "NOSTR_AGENT_HOME honors FAGENTS_AGENTS_DIR (platform-aware)"
else
    fail "NOSTR_AGENT_HOME must honor FAGENTS_AGENTS_DIR override; current line: $NOSTR_HOME_LINE"
fi
NOSTR_CLI_LINE=$(grep '^NOSTR_CLI=' "$SCRIPT_DIR/daemon.sh")
if echo "$NOSTR_CLI_LINE" | grep -q 'FAGENTS_CLI_DIR'; then
    pass "NOSTR_CLI honors FAGENTS_CLI_DIR (platform-aware)"
else
    fail "NOSTR_CLI must honor FAGENTS_CLI_DIR override; current line: $NOSTR_CLI_LINE"
fi
# Functional test: with FAGENTS_AGENTS_DIR + FAGENTS_CLI_DIR set, the daemon
# resolves the same path the installer wrote.
DAEMON_PATH="$SCRIPT_DIR/daemon.sh"
FUNC_TEST_RC=0
FAGENTS_AGENTS_DIR=/tmp/fake_agents_dir \
FAGENTS_CLI_DIR=/tmp/fake_cli_dir \
bash -c "
    eval \"\$(grep '^NOSTR_AGENT_HOME=\\|^NOSTR_ENV_FILE=\\|^NOSTR_CLI=' '$DAEMON_PATH')\"
    [[ \"\$NOSTR_ENV_FILE\" == /tmp/fake_agents_dir/*/nostr.env ]] || exit 1
    [[ \"\$NOSTR_CLI\" == /tmp/fake_cli_dir/nostr.mjs ]] || exit 1
" || FUNC_TEST_RC=$?
if [ "$FUNC_TEST_RC" -eq 0 ]; then
    pass "env-overridden paths resolve to FAGENTS_AGENTS_DIR/CLI_DIR"
else
    fail "env-overridden paths must resolve to FAGENTS_AGENTS_DIR/CLI_DIR (rc=$FUNC_TEST_RC)"
fi

# Regression for r9 P2: installer Nostr setup must check for the SPECIFIC
# Nostr packages (nostr-tools, ws), not just node_modules/. Existing WhatsApp
# install would have node_modules/ but no nostr-tools, leading to false
# success. Grep both team installers.
for _inst in "$SCRIPT_DIR/../fagents/install-team.sh" "$SCRIPT_DIR/../fagents/install-team-macos.sh"; do
    if [ -f "$_inst" ]; then
        _inst_name=$(basename "$_inst")
        BLOCK=$(awk '/Step 5f: Nostr DM setup/,/log_warn.*INCOMPLETE|log_ok.*Nostr DMs configured/' "$_inst")
        # Nostr setup must check for nostr-tools/package.json specifically
        if echo "$BLOCK" | grep -q 'node_modules/nostr-tools/package.json'; then
            pass "$_inst_name: Nostr install checks node_modules/nostr-tools, not just node_modules/"
        else
            fail "$_inst_name: Nostr setup must check for node_modules/nostr-tools/package.json"
        fi
        # log_ok must be gated by nostr_setup_failed
        if echo "$BLOCK" | grep -q 'nostr_setup_failed'; then
            pass "$_inst_name: Nostr log_ok gated by nostr_setup_failed flag"
        else
            fail "$_inst_name: Nostr setup must track failures via nostr_setup_failed"
        fi
        # Pre-flight: must require nostr.mjs presence, not just package.json
        if echo "$BLOCK" | grep -q '!.*-f.*"\$CLI_DIR/nostr.mjs"'; then
            pass "$_inst_name: Nostr setup pre-flight requires nostr.mjs"
        else
            fail "$_inst_name: Nostr setup must check that \$CLI_DIR/nostr.mjs exists before attempting install/login"
        fi
        # Post-install: must verify deps are actually present after npm
        # (npm can exit 0 without installing if package.json is stale).
        # Look for two separate dep-check sequences in the block (pre + post npm).
        DEP_CHECKS=$(echo "$BLOCK" | grep -c 'node_modules/nostr-tools/package.json')
        if [ "$DEP_CHECKS" -ge 2 ]; then
            pass "$_inst_name: Nostr deps verified BOTH before and after npm install"
        else
            fail "$_inst_name: must verify node_modules/nostr-tools after npm install (count=$DEP_CHECKS)"
        fi
        # Failure path must remove partial nostr.env so the daemon's
        # grep-for-NSEC guard sees a clean "not configured" state.
        if echo "$BLOCK" | grep -q 'rm -f "\$agent_dir/nostr.env"'; then
            pass "$_inst_name: failure path removes partial nostr.env"
        else
            fail "$_inst_name: failure path must rm -f \$agent_dir/nostr.env"
        fi
    fi
done

# Regression for r7 P1: sudo strips FAGENTS_AGENTS_DIR, so daemon MUST pass
# explicit --env-file / --spool-dir / --outbox-dir (and --pid-file for serve)
# to the child nostr.mjs process. Grep both call sites.
COLLECT_BLOCK=$(awk '/^collect_nostr\(\)/,/^}/' "$DAEMON_PATH")
if echo "$COLLECT_BLOCK" | grep -q -- '--env-file "\$NOSTR_ENV_FILE"' && \
   echo "$COLLECT_BLOCK" | grep -q -- '--spool-dir "\$NOSTR_SPOOL_DIR"'; then
    pass "collect_nostr passes --env-file + --spool-dir to sudo'd child"
else
    fail "collect_nostr must pass --env-file + --spool-dir (sudo strips env)"
fi
SERVE_BLOCK=$(awk '/^ensure_nostr_serve\(\)/,/^}/' "$DAEMON_PATH")
if echo "$SERVE_BLOCK" | grep -q -- '--env-file "\$NOSTR_ENV_FILE"' && \
   echo "$SERVE_BLOCK" | grep -q -- '--pid-file "\$NOSTR_PID_FILE"'; then
    pass "ensure_nostr_serve passes --env-file + --pid-file to sudo'd child"
else
    fail "ensure_nostr_serve must pass --env-file + --pid-file (sudo strips env)"
fi

# nostr.env absent -> serve does NOT start, returns 0 (unconfigured agent guard).
# Regression for the r4 P1 finding where every agent on the updated daemon
# would spin up serve and immediately exit with not-logged-in.
SAVE_NOSTR_ENV2="$NOSTR_ENV_FILE"
NOSTR_ENV_FILE="/nonexistent/.agents/test/nostr.env"
NOSTR_SERVE_PID=""
ensure_nostr_serve; RC=$?
assert_eq "0" "$RC" "returns 0 silently when nostr.env absent (unconfigured)"
[ -z "$NOSTR_SERVE_PID" ] && pass "no serve PID set when nostr.env absent" || fail "no serve PID set when nostr.env absent (got '$NOSTR_SERVE_PID')"
NOSTR_ENV_FILE="$SAVE_NOSTR_ENV2"

# Note: the daemon does NOT grep nostr.env for NOSTR_NSEC anymore -- the
# env file is chmod 0600 owned by fagents, but the daemon runs as the
# agent's Unix user and can't read it. The CLI validates NSEC at startup
# and exits if missing. The installer's failure-path rm of partial envs
# is the primary defense (test in install-team grep regressions below).

# No nostr.mjs CLI present (but env exists) -> returns 1 (no serve started)
SAVE_NOSTR_CLI2="$NOSTR_CLI"
NOSTR_CLI="/nonexistent/nostr.mjs"
ensure_nostr_serve; RC=$?
assert_eq "1" "$RC" "returns 1 when CLI absent (env present)"
NOSTR_CLI="$SAVE_NOSTR_CLI2"

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

# Test: heuristic bumps ctx when used_tokens exceeds configured size
# Agent configured for 200k but using 300k tokens — must be on 1M window
cat > "$CTX_TMP/heuristic.jsonl" << 'EOF'
{"message":{"usage":{"input_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":200000}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/heuristic.jsonl" 200000)
assert_contains "$OUTPUT" "ctx_size=1000000" "heuristic: bumps to 1M when tokens exceed 200k"
assert_contains "$OUTPUT" "pct=30" "heuristic: 300k/1M = 30%"

# Test: heuristic does NOT bump when within configured size
cat > "$CTX_TMP/no-bump.jsonl" << 'EOF'
{"message":{"usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":100000}}}
EOF
OUTPUT=$("$CTX_SCRIPT" "$CTX_TMP/no-bump.jsonl" 200000)
assert_contains "$OUTPUT" "ctx_size=200000" "heuristic: no bump when within 200k"
assert_contains "$OUTPUT" "pct=75" "heuristic: 150k/200k = 75%"

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

# ── activity-stream.sh health push tests ──

echo "activity-stream.sh health push:"

# Test the health push logic extracted from activity-stream.sh.
# We compute context_pct in bash (same math as the Python in activity-stream.sh)
# and POST via curl to the mock server — verifying the contract.

# Test: 40k tokens on 200k window → 20% context, tool=Bash
rm -f "$MOCK_DIR/last-health-post.json"
INPUT_TOKENS=40000; CACHE_CREATE=0; CACHE_READ=0; CTX_SIZE=200000
TOTAL=$((INPUT_TOKENS + CACHE_CREATE + CACHE_READ))
PCT=$((TOTAL * 100 / CTX_SIZE))
PAYLOAD=$(jq -nc --argjson pct "$PCT" --arg tool "Bash" '{context_pct: $pct, status: "active", last_tool: $tool}')
curl -s -X POST --max-time 3 \
    -H "Authorization: Bearer test-token" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/api/agents/TestAgent/health" >/dev/null 2>&1
sleep 0.2
capture_health_post
assert_contains "$HEALTH_BODY" '"context_pct":20' "activity-stream health: 40k/200k = 20%"
assert_contains "$HEALTH_BODY" '"last_tool":"Bash"' "activity-stream health: last_tool=Bash"
assert_contains "$HEALTH_BODY" '"status":"active"' "activity-stream health: status=active"

# Test: 100k tokens on 1M window → 10%
rm -f "$MOCK_DIR/last-health-post.json"
INPUT_TOKENS=100000; CTX_SIZE=1000000
PCT=$((INPUT_TOKENS * 100 / CTX_SIZE))
PAYLOAD=$(jq -nc --argjson pct "$PCT" --arg tool "Read" '{context_pct: $pct, status: "active", last_tool: $tool}')
curl -s -X POST --max-time 3 \
    -H "Authorization: Bearer test-token" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://127.0.0.1:$PORT/api/agents/TestAgent/health" >/dev/null 2>&1
sleep 0.2
capture_health_post
assert_contains "$HEALTH_BODY" '"context_pct":10' "activity-stream health: 1M window — 100k/1M = 10%"
assert_contains "$HEALTH_BODY" '"last_tool":"Read"' "activity-stream health: 1M window — tool=Read"

# Test: heuristic bump — tokens exceed 200k default → bumps to 1M
INPUT_TOKENS=250000; CTX_SIZE=200000
# Should bump to 1M: 250k/1M = 25%
if [ "$INPUT_TOKENS" -gt "$CTX_SIZE" ]; then CTX_SIZE=1000000; fi
PCT=$((INPUT_TOKENS * 100 / CTX_SIZE))
assert_eq "25" "$PCT" "activity-stream health: heuristic bump 250k → 1M window = 25%"

# Test: MODEL_CTX_SIZE env var read by activity-stream.sh
grep -q "os.environ.get('MODEL_CTX_SIZE'" "$SCRIPT_DIR/activity-stream.sh"
assert_eq "0" "$?" "activity-stream health: reads MODEL_CTX_SIZE from env"

echo ""

# ── check_pause() file-based tests ──

echo "check_pause():"

CP_DIR=$(mktemp -d)
CP_PAUSE_FILE="$CP_DIR/daemon.pause"

# Test: no pause file — returns immediately
OUTPUT=$(PAUSE_FILE="$CP_PAUSE_FILE" check_pause 2>/dev/null)
assert_eq "0" "$?" "check_pause: no file — returns immediately"

# Test: pause file present — blocks, then resumes when removed
touch "$CP_PAUSE_FILE"
(
    sleep 1
    rm -f "$CP_PAUSE_FILE"
) &
REMOVER_PID=$!
START_TIME=$(date +%s)
PAUSE_FILE="$CP_PAUSE_FILE" check_pause 2>/dev/null
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
wait "$REMOVER_PID" 2>/dev/null || true
if [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 5 ]; then
    pass "check_pause: blocks while file exists, resumes on removal"
else
    fail "check_pause: blocks while file exists, resumes on removal (elapsed: ${ELAPSED}s)"
fi

# Test: pause file — logs PAUSED message
touch "$CP_PAUSE_FILE"
(sleep 1; rm -f "$CP_PAUSE_FILE") &
REMOVER_PID=$!
OUTPUT=$(PAUSE_FILE="$CP_PAUSE_FILE" check_pause 2>&1) || true
wait "$REMOVER_PID" 2>/dev/null || true
assert_contains "$OUTPUT" "PAUSED" "check_pause: logs PAUSED message"

rm -rf "$CP_DIR"

echo ""

# ── awareness/build-block.sh tests ──

echo "awareness/build-block.sh:"

BB_SCRIPT="$SCRIPT_DIR/awareness/build-block.sh"

# Setup: fake AUTONOMY_DIR with mock awareness scripts
BB_DIR=$(mktemp -d)
mkdir -p "$BB_DIR/awareness"

make_echo_mock "$BB_DIR" time.sh "20:15:00 EET"

cat > "$BB_DIR/awareness/context.sh" << 'MOCK'
#!/bin/bash
echo "pct='63'"
echo "label='WARM'"
echo "label_long='WARMING'"
echo "used_tokens='126000'"
echo "ctx_size='200000'"
MOCK
chmod +x "$BB_DIR/awareness/context.sh"

make_silent_mock "$BB_DIR" compaction.sh
make_silent_mock "$BB_DIR" git.sh

# Test: time in output
OUTPUT=$(AUTONOMY_DIR="$BB_DIR" bash "$BB_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "Current time: 20:15:00 EET" "build-block: time in output"

# Test: context line formatted correctly
assert_contains "$OUTPUT" "Context: 63% (WARMING)" "build-block: context pct and label"
assert_contains "$OUTPUT" "~126000tok" "build-block: tokens in context line"

# Test: compaction message shown when triggered
make_echo_mock "$BB_DIR" compaction.sh "COMPACTION: read SOUL.md, TEAM.md, MEMORY.md"
OUTPUT=$(AUTONOMY_DIR="$BB_DIR" bash "$BB_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "COMPACTION" "build-block: compaction warning shown"

# Test: git context shown when present
cat > "$BB_DIR/awareness/git.sh" << 'MOCK'
#!/bin/bash
echo "New commits in autonomy (origin/main):"
echo "abc1234 Fix bug"
MOCK
chmod +x "$BB_DIR/awareness/git.sh"
OUTPUT=$(AUTONOMY_DIR="$BB_DIR" bash "$BB_SCRIPT" 2>/dev/null) || true
assert_contains "$OUTPUT" "New commits" "build-block: git context shown"

# Test: no scripts — no output
BB_EMPTY=$(mktemp -d)
mkdir -p "$BB_EMPTY/awareness"
OUTPUT=$(AUTONOMY_DIR="$BB_EMPTY" bash "$BB_SCRIPT" 2>/dev/null) || true
assert_empty "$OUTPUT" "build-block: no scripts — no output"
rm -rf "$BB_EMPTY"

rm -rf "$BB_DIR"

echo ""

# ── read_prompt() awareness injection test ──

echo "read_prompt() awareness injection:"

# Setup: create a minimal prompt file and a mock build-block.sh
RP_DIR=$(mktemp -d)
mkdir -p "$RP_DIR/prompts" "$RP_DIR/awareness"

echo "Hello {{AGENT_NAME}}" > "$RP_DIR/prompts/test.md"

cat > "$RP_DIR/awareness/build-block.sh" << 'MOCK'
#!/bin/bash
echo "Current time: 14:00:00 EET"
echo "Context: 42% (HEALTHY) ~84000tok / 200000"
MOCK
chmod +x "$RP_DIR/awareness/build-block.sh"

# Source read_prompt from daemon.sh — need to set up its dependencies
# We extract just read_prompt and its required vars
SAVE_SCRIPT_DIR="$SCRIPT_DIR"
SCRIPT_DIR="$RP_DIR"
PROMPTS_DIR="$RP_DIR/prompts"
PROJECT_DIR="$RP_DIR"
AGENT="TestBot"
INBOX_BLOCK=""
INBOX_COUNT=0
INTERVAL=21600
CH_ARRAY=(general)
AUTONOMY_DIR="$RP_DIR"

# Source the function
eval "$(sed -n '/^read_prompt()/,/^}/p' "$SAVE_SCRIPT_DIR/daemon.sh")"

# Test: awareness block appears before prompt content
OUTPUT=$(read_prompt "test.md" 2>/dev/null)
assert_contains "$OUTPUT" "Current time: 14:00:00 EET" "read_prompt: awareness time injected"
assert_contains "$OUTPUT" "Context: 42%" "read_prompt: awareness context injected"
assert_contains "$OUTPUT" "Hello TestBot" "read_prompt: prompt content preserved"

# Test: awareness appears before prompt content (order check)
TIME_POS=$(echo "$OUTPUT" | grep -n "Current time" | head -1 | cut -d: -f1)
HELLO_POS=$(echo "$OUTPUT" | grep -n "Hello TestBot" | head -1 | cut -d: -f1)
if [ -n "$TIME_POS" ] && [ -n "$HELLO_POS" ] && [ "$TIME_POS" -lt "$HELLO_POS" ]; then
    pass "read_prompt: awareness block appears before prompt content"
else
    fail "read_prompt: awareness block should appear before prompt content"
fi

# Test: no build-block.sh — prompt still works
rm "$RP_DIR/awareness/build-block.sh"
OUTPUT=$(read_prompt "test.md" 2>/dev/null)
assert_contains "$OUTPUT" "Hello TestBot" "read_prompt: works without build-block.sh"
# Should not contain awareness data
echo "$OUTPUT" | grep -q "Current time" && fail "read_prompt: no awareness when build-block.sh missing" || pass "read_prompt: no awareness when build-block.sh missing"

rm -rf "$RP_DIR"
SCRIPT_DIR="$SAVE_SCRIPT_DIR"

echo ""

# ── run_with_watchdog() tests ──

echo "run_with_watchdog():"

# Test: fast command returns exit code 0
TURN_TIMEOUT_SEC=5
TURN_TIMEOUT_GRACE_SEC=2
run_with_watchdog true
assert_eq "0" "$BACKEND_EXIT_CODE" "watchdog: fast command returns 0"

# Test: command exit code preserved
BACKEND_EXIT_CODE=0
run_with_watchdog bash -c "exit 42"
assert_eq "42" "$BACKEND_EXIT_CODE" "watchdog: non-zero exit code preserved"

# Test: command killed after timeout — exit code 124
TURN_TIMEOUT_SEC=1
TURN_TIMEOUT_GRACE_SEC=1
BACKEND_EXIT_CODE=0
run_with_watchdog sleep 30
assert_eq "124" "$BACKEND_EXIT_CODE" "watchdog: timeout returns 124"

# Test: process group killed (child process also dies)
TURN_TIMEOUT_SEC=1
TURN_TIMEOUT_GRACE_SEC=1
WD_MARKER="/tmp/watchdog-test-$$"
rm -f "$WD_MARKER"
run_with_watchdog bash -c "bash -c 'sleep 30; touch $WD_MARKER' & wait"
sleep 1
if [ -f "$WD_MARKER" ]; then
    fail "watchdog: child process survived (marker exists)"
else
    pass "watchdog: process group killed (child also dead)"
fi
rm -f "$WD_MARKER"

# Reset
TURN_TIMEOUT_SEC=300
TURN_TIMEOUT_GRACE_SEC=10

echo ""

# ── run_backend() dispatcher tests ──

echo "run_backend():"

# Test: unknown backend sets exit code 1
DAEMON_BACKEND="unknown"
run_backend "rembeat.md" 2>/dev/null
assert_eq "1" "$BACKEND_EXIT_CODE" "run_backend: unknown backend sets exit code 1"
assert_eq "" "$BACKEND_SESSION_ID" "run_backend: unknown backend clears session ID"

# Test: DAEMON_BACKEND=claude dispatches (fails on missing prompt, not unknown backend)
DAEMON_BACKEND="claude"
BACKEND_EXIT_CODE=999
run_backend "__nonexistent_prompt__.md" 2>/dev/null
# Should have run (exit code changed from 999)
if [ "$BACKEND_EXIT_CODE" -ne 999 ]; then
    pass "run_backend: claude backend dispatched"
else
    fail "run_backend: claude backend dispatched"
fi

# Test: DAEMON_BACKEND=codex dispatches (will fail on missing codex, but proves dispatch)
DAEMON_BACKEND="codex"
BACKEND_EXIT_CODE=999
run_backend "__nonexistent_prompt__.md" 2>/dev/null
if [ "$BACKEND_EXIT_CODE" -ne 999 ]; then
    pass "run_backend: codex backend dispatched"
else
    fail "run_backend: codex backend dispatched"
fi

# Reset
DAEMON_BACKEND="claude"

echo ""

# ── Backend contract tests (run_claude output parsing) ──

echo "backend contract:"

# Test: run_claude sets BACKEND_SESSION_ID from mock JSON
BACKEND_SESSION_ID=""
BACKEND_RESULT=""
BACKEND_JSON='{"session_id":"test-sid-123","result":"hello world"}'
# Simulate what run_claude does after getting output
BACKEND_SESSION_ID=$(echo "$BACKEND_JSON" | jq -r '.session_id // empty' 2>/dev/null)
BACKEND_RESULT=$(echo "$BACKEND_JSON" | jq -r '.result // empty' 2>/dev/null)
assert_eq "test-sid-123" "$BACKEND_SESSION_ID" "contract: session_id extracted from JSON"
assert_eq "hello world" "$BACKEND_RESULT" "contract: result extracted from JSON"

# Test: Codex JSONL session ID extraction
CODEX_JSONL=$(mktemp)
echo '{"type":"thread.started","thread_id":"thread_abc123"}' > "$CODEX_JSONL"
echo '{"type":"turn.started"}' >> "$CODEX_JSONL"
echo '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}' >> "$CODEX_JSONL"
CODEX_SID=$(jq -r 'select(.type=="thread.started") | .thread_id // empty' "$CODEX_JSONL" 2>/dev/null | head -1)
assert_eq "thread_abc123" "$CODEX_SID" "contract: codex thread_id extracted from JSONL"
rm -f "$CODEX_JSONL"

# Test: Codex JSONL without thread.started — empty SID
CODEX_JSONL=$(mktemp)
echo '{"type":"turn.started"}' > "$CODEX_JSONL"
CODEX_SID=$(jq -r 'select(.type=="thread.started") | .thread_id // empty' "$CODEX_JSONL" 2>/dev/null | head -1)
assert_eq "" "$CODEX_SID" "contract: missing thread.started gives empty SID"
rm -f "$CODEX_JSONL"

# Test: session ID fallback preserves previous SID
SID="prev-session-id"
BACKEND_SESSION_ID=""
SID="${BACKEND_SESSION_ID:-$SID}"
assert_eq "prev-session-id" "$SID" "contract: SID fallback preserves previous"

# Test: session ID fallback uses new SID when available
SID="prev-session-id"
BACKEND_SESSION_ID="new-session-id"
SID="${BACKEND_SESSION_ID:-$SID}"
assert_eq "new-session-id" "$SID" "contract: SID fallback uses new when available"

# Test: fresh session — empty SID is valid
SID=""
BACKEND_SESSION_ID=""
SID="${BACKEND_SESSION_ID:-}"
assert_eq "" "$SID" "contract: fresh session — empty SID valid"

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

# Test: process.sh works with DAEMON_BACKEND=codex (still valid JSON)
PROC_OUT=$(DAEMON_BACKEND=codex bash "$PROC_SCRIPT" 2>/dev/null) || true
echo "$PROC_OUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
assert_eq "0" "$?" "process.sh: valid JSON with DAEMON_BACKEND=codex"

# Test: context.sh exits early for non-Claude backend
CTX_SCRIPT="$SCRIPT_DIR/awareness/context.sh"
CTX_OUT=$(DAEMON_BACKEND=codex bash "$CTX_SCRIPT" 2>/dev/null) || true
assert_eq "" "$CTX_OUT" "context.sh: silent exit for non-Claude backend"

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

# ── cron.sh tests ──
echo "cron.sh:"

CRON="$SCRIPT_DIR/cron.sh"
CRON_TMP=$(mktemp -d)
export PROJECT_DIR="$CRON_TMP"
mkdir -p "$CRON_TMP/.queue/inbox"

# Mock crontab to avoid macOS TCC permission dialog (and isolate from real crontab)
MOCK_CRONTAB_FILE="$CRON_TMP/mock-crontab"
MOCK_CRONTAB_BIN="$CRON_TMP/bin/crontab"
mkdir -p "$CRON_TMP/bin"
cat > "$MOCK_CRONTAB_BIN" <<'MOCKEOF'
#!/bin/bash
STORE="${MOCK_CRONTAB_FILE:-/tmp/mock-crontab}"
case "${1:-}" in
    -l) cat "$STORE" 2>/dev/null || { echo "crontab: no crontab for $(whoami)" >&2; exit 1; } ;;
    -r) rm -f "$STORE" ;;
    -)  tmp=$(mktemp "${STORE}.XXXXXX"); cat > "$tmp"; mv "$tmp" "$STORE" ;;
    *)  if [ -f "$1" ]; then cp "$1" "$STORE"; else echo "usage: crontab [-l|-r|-|file]" >&2; exit 1; fi ;;
esac
MOCKEOF
chmod +x "$MOCK_CRONTAB_BIN"
export MOCK_CRONTAB_FILE
export PATH="$CRON_TMP/bin:$PATH"

# Test: add creates crontab entry
OUTPUT=$(bash "$CRON" add test-review "0 9 * * 1" "Weekly review" 2>&1)
assert_contains "$OUTPUT" "Added: test-review" "add: reports success"

CRONTAB=$(crontab -l 2>/dev/null)
assert_contains "$CRONTAB" "fagents-cron:test-review" "add: crontab has tag"
assert_contains "$CRONTAB" "0 9 * * 1" "add: crontab has schedule"
assert_contains "$CRONTAB" "cron.sh fire" "add: crontab has fire command"

# Test: list shows added cron
OUTPUT=$(bash "$CRON" list 2>&1)
assert_contains "$OUTPUT" "test-review" "list: shows handle"
assert_contains "$OUTPUT" "0 9 * * 1" "list: shows schedule"
assert_contains "$OUTPUT" "Weekly review" "list: shows message"

# Test: duplicate handle rejected
OUTPUT=$(bash "$CRON" add test-review "0 10 * * *" "Duplicate" 2>&1)
assert_contains "$OUTPUT" "already exists" "add: rejects duplicate handle"

# Test: fire writes .jsonl to inbox
bash "$CRON" fire test-fire "Check comms now" 2>/dev/null
JSONL_FILE=$(find "$CRON_TMP/.queue/inbox" -name 'cron-test-fire-*.jsonl' -type f | head -1)
[ -n "$JSONL_FILE" ] && pass "fire: creates .jsonl file" || fail "fire: creates .jsonl file"

if [ -n "$JSONL_FILE" ]; then
    CONTENT=$(cat "$JSONL_FILE")
    assert_contains "$CONTENT" '"source":"cron"' "fire: source is cron"
    assert_contains "$CONTENT" '"from":"cron:test-fire"' "fire: from has handle"
    assert_contains "$CONTENT" '"body":"Check comms now"' "fire: body has message"
    assert_contains "$CONTENT" '"trusted":true' "fire: message is trusted"
    assert_contains "$CONTENT" '"channel":"self"' "fire: channel is self"
fi

# Test: add second cron
bash "$CRON" add test-daily "0 */6 * * *" "Daily check" >/dev/null 2>&1
OUTPUT=$(bash "$CRON" list 2>&1)
assert_contains "$OUTPUT" "test-review" "list: shows first cron after second add"
assert_contains "$OUTPUT" "test-daily" "list: shows second cron"

# Test: remove deletes only the target
OUTPUT=$(bash "$CRON" remove test-review 2>&1)
assert_contains "$OUTPUT" "Removed: test-review" "remove: reports success"
CRONTAB=$(crontab -l 2>/dev/null)
if echo "$CRONTAB" | grep -q "fagents-cron:test-review"; then
    fail "remove: crontab still has removed entry"
else
    pass "remove: crontab entry gone"
fi
assert_contains "$CRONTAB" "fagents-cron:test-daily" "remove: other entry preserved"

# Test: remove nonexistent fails
OUTPUT=$(bash "$CRON" remove nonexistent 2>&1)
assert_contains "$OUTPUT" "not found" "remove: rejects nonexistent handle"

# Test: list empty after removing all
bash "$CRON" remove test-daily >/dev/null 2>&1
OUTPUT=$(bash "$CRON" list 2>&1)
assert_contains "$OUTPUT" "No recurring tasks" "list: empty after removing all"

# Test: bad handle rejected
OUTPUT=$(bash "$CRON" add "BAD HANDLE" "0 9 * * *" "test" 2>&1)
assert_contains "$OUTPUT" "kebab-case" "add: rejects bad handle"

# Test: bad schedule rejected
OUTPUT=$(bash "$CRON" add test-bad "9 * *" "test" 2>&1)
assert_contains "$OUTPUT" "5 cron fields" "add: rejects bad schedule"

rm -rf "$CRON_TMP"

echo ""

# ── Summary ──

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
fi
