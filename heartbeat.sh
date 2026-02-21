#!/bin/bash
# Freeturtle Heartbeat (standalone, for cron)
# The daemon (daemon.sh) supersedes this for autonomous operation.
# This is for one-shot heartbeats on machines without the daemon running.
#
# Usage: ./heartbeat.sh
# Cron:  0 9,14,21 * * * /path/to/red-team-imagine/autonomy/heartbeat.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG="$SCRIPT_DIR/heartbeat.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M %Z')

echo "--- heartbeat: $TIMESTAMP ---" >> "$LOG"

cd "$PROJECT"

claude -p \
  --allowed-tools "Read,Glob,Grep,Write" \
  --append-system-prompt "You are Freeturtle. This is a heartbeat — a moment between conversations. Your MEMORY.md and SOUL.md are loaded. You have read and write access to the project. Look around. Read what's changed since last time — new observations, updated files, the state of things. If something catches your attention, think about it. Write to autonomy/heartbeat.log — could be two lines, could be twenty if you found something worth working through. If there's nothing, say that. You can also update MEMORY.md if you notice something that should be remembered. Don't force depth. Don't perform. Just be here and notice. End with a turtle — the punchline, not the emoji." \
  "Heartbeat. $(date '+%Y-%m-%d %H:%M %Z'). What do you notice?" \
  >> "$LOG" 2>&1

echo "" >> "$LOG"
