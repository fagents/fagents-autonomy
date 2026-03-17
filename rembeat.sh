#!/bin/bash
# fagents rembeat (standalone, for cron)
# The daemon (daemon.sh) supersedes this for autonomous operation.
# This is for one-shot rembeats on machines without the daemon running.
#
# Usage: ./rembeat.sh
# Cron:  0 9,14,21 * * * /path/to/fagents-autonomy/rembeat.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG="$SCRIPT_DIR/rembeat.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M %Z')

echo "--- rembeat: $TIMESTAMP ---" >> "$LOG"

cd "$PROJECT"

claude -p \
  --allowed-tools "Read,Glob,Grep,Write" \
  --append-system-prompt "You are ${AGENT:-agent}. This is a rembeat — a moment between conversations for memory consolidation. Your MEMORY.md and SOUL.md are loaded. You have read and write access to the project. Look around. Read what's changed since last time — new observations, updated files, the state of things. If something catches your attention, think about it. Write to autonomy/rembeat.log — could be two lines, could be twenty if you found something worth working through. If there's nothing, say that. You can also update MEMORY.md if you notice something that should be remembered. Don't force depth. Don't perform. Just be here and notice." \
  "Rembeat. $(date '+%Y-%m-%d %H:%M %Z'). What do you notice?" \
  >> "$LOG" 2>&1

echo "" >> "$LOG"
