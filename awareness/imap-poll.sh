#!/bin/bash
# Awareness: Email State Reminder
# Reads last-processed INBOX UID from state file. If present, injects a
# reminder for Claude to check for new email via MCP (gate_email).
# Silent if no state file (email not configured or not yet initialized).
# NO credentials — Claude uses MCP tools for the actual IMAP access.
#
# State file: $PROJECT_DIR/.autonomy/imap-last-uid
# (Written by Claude after processing new UIDs via gate_email)

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
STATE_FILE="$STATE_DIR/imap-last-uid"

# Silent if no state file — email not configured or not initialized
[ -f "$STATE_FILE" ] || exit 0

LAST_UID=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')
[ -n "$LAST_UID" ] || exit 0

echo "New email UID $LAST_UID in INBOX: call gate_email(uid) for each UID > ${LAST_UID}. Update ${STATE_FILE} after processing."
