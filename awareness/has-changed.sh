#!/bin/bash
# Awareness: Change Detection
# Hashes file contents and compares to stored hash.
# Returns 0 (changed/first run) or 1 (unchanged).
#
# Usage: has-changed.sh <key> <file1> [file2] ...
#   key:   identifier for the hash file (e.g., "soul-memory", "startup-notice")
#   files: files to hash (missing files are silently skipped)
#
# Hash state stored in $PROJECT_DIR/.autonomy/.<key>.hash

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"

KEY="${1:-}"
shift || true

if [ -z "$KEY" ]; then
    echo "Usage: has-changed.sh <key> <file1> [file2] ..." >&2
    exit 2
fi

HASH_FILE="$STATE_DIR/.${KEY}.hash"

# Hash all input files
HASH_INPUT=""
for f in "$@"; do
    [ -f "$f" ] && HASH_INPUT="$HASH_INPUT$(sha256sum "$f" 2>/dev/null)"
done
CURRENT_HASH=$(echo "$HASH_INPUT" | sha256sum | cut -d' ' -f1)

# Compare to stored hash
if [ -f "$HASH_FILE" ]; then
    LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ "$CURRENT_HASH" = "$LAST_HASH" ]; then
        exit 1  # unchanged
    fi
fi

# Changed (or first run) — update hash
echo "$CURRENT_HASH" > "$HASH_FILE"
exit 0
