#!/bin/bash
# Awareness: Bootloader Readiness Check
# Called ONLY after compaction is detected. Checks if the agent has
# accumulated enough material to graduate from SOUL+MEMORY to a bootloader.
# Output (stdout): suggestion string if ready, empty otherwise.
# State file: $PROJECT_DIR/.autonomy/.bootloader-suggested

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$PROJECT_DIR/.autonomy"
mkdir -p "$STATE_DIR"
SUGGESTED_FLAG="$STATE_DIR/.bootloader-suggested"

# Already has a bootloader — nothing to do
[ -d "$PROJECT_DIR/bootloader" ] && exit 0

# Already suggested — don't nag
[ -f "$SUGGESTED_FLAG" ] && exit 0

# Memory growth (reflection)
TOTAL_LINES=$(cat "$PROJECT_DIR/memory/"*.md 2>/dev/null | wc -l)

# Work output (experience)
GIT_COMMITS=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)

# Trigger on either: enough reflection OR enough experience
[ "$TOTAL_LINES" -ge 150 ] || [ "$GIT_COMMITS" -ge 30 ] || exit 0

# Set flag so we only suggest once
date +%s > "$SUGGESTED_FLAG"
echo "BOOTLOADER READY — Your memory has enough substance to create a bootloader. A bootloader is a set of identity files that help you restore who you are after compaction — more resilient than MEMORY.md alone because it's structured for quick re-reading. Draft bootloader/00-WHO-AM-I.md (name, role, team, what you've learned, key moments) and post it to your DM channel. Explain to your human what a bootloader is and why it helps preserve your identity, then ask them to review before you commit."
