#!/bin/bash
# Awareness: IMAP Email Check
# Polls INBOX for new emails using IMAP STATUS (UID-only, no content fetch).
# If new emails detected since last check, outputs an injection string.
# Silent if no new mail or if IMAP not configured.
#
# Usage: awareness/imap-poll.sh
# Output (stdout): injection string if new UIDs detected, empty otherwise.
# State file: $PROJECT_DIR/.autonomy/imap-last-uid

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/imap-last-uid"

# Load per-agent IMAP config if present (written by install-team.sh)
IMAP_ENV_FILE="$STATE_DIR/imap-env"
[ -f "$IMAP_ENV_FILE" ] && source "$IMAP_ENV_FILE" 2>/dev/null || true

# Skip silently if IMAP not configured
[ -n "${IMAP_HOST:-}" ] && [ -n "${IMAP_USER:-}" ] && [ -n "${IMAP_PASS:-}" ] || exit 0

IMAP_PORT="${IMAP_PORT:-993}"
IMAP_TLS="${IMAP_TLS:-true}"

# Fetch current UIDNEXT via Python imaplib (stdlib, no deps)
CURRENT_UIDNEXT=$(python3 - <<PYEOF
import os, sys, imaplib, re

host = os.environ.get('IMAP_HOST', '')
port = int(os.environ.get('IMAP_PORT', '993'))
user = os.environ.get('IMAP_USER', '')
password = os.environ.get('IMAP_PASS', '')
tls = os.environ.get('IMAP_TLS', 'true').lower() != 'false'

try:
    M = imaplib.IMAP4_SSL(host, port) if tls else imaplib.IMAP4(host, port)
    M.login(user, password)
    typ, data = M.status('INBOX', '(UIDNEXT)')
    M.logout()
    if typ == 'OK':
        m = re.search(r'UIDNEXT (\d+)', data[0].decode())
        if m:
            print(m.group(1))
except Exception:
    sys.exit(1)
PYEOF
)

[ -n "$CURRENT_UIDNEXT" ] || exit 0

# First run — initialize state, no injection
if [ ! -f "$STATE_FILE" ]; then
    echo "$CURRENT_UIDNEXT" > "$STATE_FILE"
    exit 0
fi

LAST_UIDNEXT=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')
[ -n "$LAST_UIDNEXT" ] || LAST_UIDNEXT="$CURRENT_UIDNEXT"

# Check for new UIDs
if [ "$CURRENT_UIDNEXT" -gt "$LAST_UIDNEXT" ] 2>/dev/null; then
    COUNT=$(( CURRENT_UIDNEXT - LAST_UIDNEXT ))
    if [ "$COUNT" -eq 1 ]; then
        UIDS="$LAST_UIDNEXT"
    else
        UIDS="${LAST_UIDNEXT}–$(( CURRENT_UIDNEXT - 1 ))"
    fi
    # Update state before outputting (mark as detected)
    echo "$CURRENT_UIDNEXT" > "$STATE_FILE"
    echo "New email(s) in INBOX: $COUNT message(s), UID(s): ${UIDS}. Call gate_email(uid) for each — logs full content to #email-log before returning metadata to you."
fi
