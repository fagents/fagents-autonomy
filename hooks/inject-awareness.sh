#!/bin/bash

# Inject Awareness — PreToolUse hook
# Thin orchestrator: injects time, context %, and comms alerts.
# Fires before every tool call.
# Trigger: PreToolUse

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Awareness: time
CTX=""
TIME=$("$AUTONOMY_DIR/awareness/time.sh" 2>/dev/null) || true
[ -n "$TIME" ] && CTX="Time: $TIME"

# Awareness: context window usage
CTX_OUT=$("$AUTONOMY_DIR/awareness/context.sh" 2>/dev/null) || true
if [ -n "$CTX_OUT" ]; then
    eval "$CTX_OUT"
    [ -n "${formatted:-}" ] && CTX="$CTX | $formatted"
    # Awareness: compaction detection
    COMPACT=$("$AUTONOMY_DIR/awareness/compaction.sh" "$pct" 2>/dev/null) || true
    if [ -n "$COMPACT" ]; then
        CTX="$CTX | $COMPACT"
        BOOTLOADER=$("$AUTONOMY_DIR/awareness/bootloader-check.sh" 2>/dev/null) || true
        [ -n "$BOOTLOADER" ] && CTX="$CTX | $BOOTLOADER"
    fi
fi

# Awareness: comms (PAUSE check + teammate messages)
COMMS_CTX=$("$AUTONOMY_DIR/awareness/comms.sh" 2>/dev/null) || true
[ -n "$COMMS_CTX" ] && CTX="$CTX | $COMMS_CTX"

# Awareness: new email check (silent if IMAP not configured)
EMAIL_CTX=$("$AUTONOMY_DIR/awareness/imap-poll.sh" 2>/dev/null) || true
[ -n "$EMAIL_CTX" ] && CTX="$CTX | $EMAIL_CTX"

# Output as PreToolUse JSON
python3 -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'additionalContext': sys.argv[1]
    }
}))" "$CTX"

exit 0
