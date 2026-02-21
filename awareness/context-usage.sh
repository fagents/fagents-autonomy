#!/bin/bash
# Extract actual context window usage from a Claude Code JSONL session file.
#
# Usage: context-usage.sh <jsonl_path> [context_window_size]
#
# Reads the LAST API response's per-turn usage (not cumulative billing).
# These per-turn numbers match /context output exactly.
#
# Output: key=value pairs suitable for `source`:
#   pct, remaining, used_tokens, ctx_size, input_tokens,
#   cache_create, cache_read

set -euo pipefail

JSONL="${1:?Usage: context-usage.sh <jsonl_path> [ctx_size]}"
CTX_SIZE="${2:-200000}"

if [ ! -f "$JSONL" ]; then
    echo "error=file_not_found"
    exit 1
fi

# Grab last 50 lines — usage appears in assistant responses which are frequent.
# Use python to find the last line with usage data and extract per-turn tokens.
tail -50 "$JSONL" | python3 -c "
import json, sys

ctx = int(sys.argv[1])
last_usage = None

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except:
        continue
    u = d.get('message', {})
    if isinstance(u, dict):
        u = u.get('usage')
        if u and 'input_tokens' in u:
            last_usage = u

if not last_usage:
    print('error=no_usage_data')
    sys.exit(0)

inp = last_usage.get('input_tokens', 0)
cc = last_usage.get('cache_creation_input_tokens', 0)
cr = last_usage.get('cache_read_input_tokens', 0)
total = inp + cc + cr
pct = (total * 100) // ctx if ctx > 0 else 0
print(f'pct={pct}')
print(f'remaining={100 - pct}')
print(f'used_tokens={total}')
print(f'ctx_size={ctx}')
print(f'input_tokens={inp}')
print(f'cache_create={cc}')
print(f'cache_read={cr}')
" "$CTX_SIZE"
