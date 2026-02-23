#!/bin/bash
# Awareness: Context Window Usage
# Reads Claude Code session JSONL to determine context window utilization.
# Usage: awareness/context.sh
# Output (stdout): key=value pairs suitable for eval/source:
#   pct, label, formatted, remaining, used_tokens, ctx_size,
#   input_tokens, cache_create, cache_read
# On failure: outputs nothing (caller should handle empty output).

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HELPER="$AUTONOMY_DIR/awareness/context-usage.sh"

JSONL_DIR="${CLAUDE_PROJECT_DIR:-.}/.introspection-logs"
[ -d "$JSONL_DIR" ] || exit 0

JSONL=$(ls -t "$JSONL_DIR"/*.jsonl 2>/dev/null | head -1)
[ -n "$JSONL" ] || exit 0
[ -x "$HELPER" ] || exit 0

eval "$("$HELPER" "$JSONL" 2>/dev/null)" 2>/dev/null || exit 0
[ -z "${error:-}" ] || exit 0
[ -n "${pct:-}" ] || exit 0

LABEL='OK';       LABEL_LONG='HEALTHY'
[ "${pct:-0}" -ge 40 ] && LABEL='WARM' && LABEL_LONG='WARMING'
[ "${pct:-0}" -ge 70 ] && LABEL='HEAVY' && LABEL_LONG='HEAVY'
[ "${pct:-0}" -ge 90 ] && LABEL='CRIT' && LABEL_LONG='CRITICAL'

FORMATTED="Ctx: ${pct}% ($LABEL)"

echo "pct='$pct'"
echo "label='$LABEL'"
echo "label_long='$LABEL_LONG'"
echo "formatted='$FORMATTED'"
echo "remaining='$((100 - pct))'"
echo "used_tokens='$used_tokens'"
echo "ctx_size='$ctx_size'"
echo "input_tokens='$input_tokens'"
echo "cache_create='$cache_create'"
echo "cache_read='$cache_read'"
