#!/usr/bin/env bash
# health-check.sh — daemon watchdog, run via fagents user cron (hourly)
#
# Detects unexpected daemon deaths and posts an alert to comms #general.
# Does NOT auto-restart — the ops agent investigates and decides.
#
# How it works:
#   - Iterates fagent group users with start-agent.sh (daemon agents)
#   - Checks PID file + kill -0 to see if the daemon is alive
#   - .autonomy/daemon.stopped = intentional stop (created by stop-team.sh) → skip
#   - .autonomy/daemon.alerted = already alerted for this incident → skip
#   - Otherwise → unexpected death, post alert, create .alerted marker
#
# Markers are cleared by daemon.sh on startup (rm -f daemon.stopped daemon.alerted).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_HOME="$(dirname "$SCRIPT_DIR")"
COMMS_CHANNELS="$INFRA_HOME/.agents/comms/channels"

# Find all fagent group users (Linux: getent, macOS: dscl)
if command -v getent &>/dev/null; then
    FAGENT_GID=$(getent group fagent | cut -d: -f3 2>/dev/null) || exit 0
    [[ -n "$FAGENT_GID" ]] || exit 0
    AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')
else
    FAGENT_GID=$(dscl . -read /Groups/fagent PrimaryGroupID 2>/dev/null | awk '{print $2}') || exit 0
    [[ -n "$FAGENT_GID" ]] || exit 0
    AGENT_USERS=$(dscl . -list /Users PrimaryGroupID 2>/dev/null | awk -v gid="$FAGENT_GID" '$2==gid {print $1}')
fi
[[ -n "$AGENT_USERS" ]] || exit 0

for USER in $AGENT_USERS; do
    HOME_DIR=$(eval echo "~$USER")
    WS="$HOME_DIR/workspace/$USER"
    STATE="$WS/.autonomy"

    # Skip non-daemon agents (no start-agent.sh = interactive or not installed)
    [[ -f "$WS/start-agent.sh" ]] || continue

    # Check if running
    if [[ -f "$STATE/daemon.pid" ]]; then
        pid=$(cat "$STATE/daemon.pid" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && continue
    fi

    # Not running — intentional stop?
    [[ -f "$STATE/daemon.stopped" ]] && continue

    # Already alerted for this incident?
    [[ -f "$STATE/daemon.alerted" ]] && continue

    # Unexpected death — alert on comms (direct file append, bypasses server API;
    # avoids needing a token but drifts server message count cache by one per alert)
    if [[ -d "$COMMS_CHANNELS" ]]; then
        ts=$(date '+%Y-%m-%d %H:%M %Z')
        last_log=$(tail -1 "$STATE/daemon.log" 2>/dev/null || echo "no log")
        echo "[$ts] [System] $USER daemon is down (unexpected). Last log: $last_log" \
            >> "$COMMS_CHANNELS/general.log"
    fi

    # Create marker so we don't spam
    mkdir -p "$STATE"
    touch "$STATE/daemon.alerted"
done
