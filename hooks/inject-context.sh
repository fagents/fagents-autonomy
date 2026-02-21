#!/bin/bash

# Context Inject — UserPromptSubmit hook
# Thin orchestrator: calls awareness scripts and prints results.
# Trigger: UserPromptSubmit

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Awareness: time
TIME=$("$AUTONOMY_DIR/awareness/time.sh" 2>/dev/null) || true
[ -n "$TIME" ] && echo "Current time: $TIME"

# Awareness: context window usage
CTX_OUT=$("$AUTONOMY_DIR/awareness/context.sh" 2>/dev/null) || true
if [ -n "$CTX_OUT" ]; then
    eval "$CTX_OUT"
    echo "Context: ${pct}% (${label_long:-UNKNOWN}) ~${used_tokens}tok / ${ctx_size}"
    # Awareness: compaction detection
    COMPACT=$("$AUTONOMY_DIR/awareness/compaction.sh" "$pct" 2>/dev/null) || true
    [ -n "$COMPACT" ] && echo "$COMPACT"
fi

# Awareness: git (incoming commits)
GIT_CTX=$("$AUTONOMY_DIR/awareness/git.sh" 2>/dev/null) || true
[ -n "$GIT_CTX" ] && echo "$GIT_CTX"
