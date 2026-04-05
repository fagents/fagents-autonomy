#!/bin/bash
# Build awareness block for prompt injection.
# Replaces hooks/inject-context.sh (UserPromptSubmit hook).
# Called by daemon.sh read_prompt() before each LLM invocation.
# Output: plain text block, empty if no data.

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Time
TIME=$("$AUTONOMY_DIR/awareness/time.sh" 2>/dev/null) || true
[ -n "$TIME" ] && echo "Current time: $TIME"

# Context window usage (eval sets pct, label_long, used_tokens, ctx_size)
CTX_OUT=$("$AUTONOMY_DIR/awareness/context.sh" 2>/dev/null) || true
if [ -n "$CTX_OUT" ]; then
    eval "$CTX_OUT"
    # shellcheck disable=SC2154
    echo "Context: ${pct}% (${label_long:-UNKNOWN}) ~${used_tokens}tok / ${ctx_size}"
    # Compaction detection
    COMPACT=$("$AUTONOMY_DIR/awareness/compaction.sh" "$pct" 2>/dev/null) || true
    if [ -n "$COMPACT" ]; then
        echo "$COMPACT"
        BOOTLOADER=$("$AUTONOMY_DIR/awareness/bootloader-check.sh" 2>/dev/null) || true
        [ -n "$BOOTLOADER" ] && echo "$BOOTLOADER"
    fi
fi

# Git incoming commits
GIT_CTX=$("$AUTONOMY_DIR/awareness/git.sh" 2>/dev/null) || true
[ -n "$GIT_CTX" ] && echo "$GIT_CTX"
