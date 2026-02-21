#!/bin/bash
# Deploy autonomy updates to the current agent.
#
# Usage: deploy-hooks.sh [--restart]
#   --restart: also restart the daemon after deploying hooks
#
# What it does:
#   1. git pull fagents-autonomy
#   2. Merge hooks.json into agent's .claude/settings.json
#   3. Report to comms
#   4. (optional) Restart daemon via detached process
#
# Hooks hot-reload from disk, so a git pull is usually enough.
# Use --restart only when daemon.sh itself changed.

set -euo pipefail

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-}"
AGENT="${AGENT:-}"
DO_RESTART=false

for arg in "$@"; do
    case "$arg" in
        --restart) DO_RESTART=true ;;
    esac
done

# Validate environment
if [ -z "$PROJECT_DIR" ]; then
    echo "ERROR: PROJECT_DIR not set" >&2
    exit 1
fi
if [ -z "$AGENT" ]; then
    echo "ERROR: AGENT not set" >&2
    exit 1
fi

SETTINGS_FILE="$PROJECT_DIR/.claude/settings.json"
HOOKS_JSON="$AUTONOMY_DIR/hooks.json"
CLIENT="$AUTONOMY_DIR/comms/client.sh"

log() { echo "[deploy] $*"; }

# ── Step 1: Pull latest autonomy code ──
log "Pulling fagents-autonomy..."
cd "$AUTONOMY_DIR"
OLD_HEAD=$(git rev-parse --short HEAD)
git pull --ff-only origin main 2>&1 || {
    log "ERROR: git pull failed (merge conflict?)"
    exit 1
}
NEW_HEAD=$(git rev-parse --short HEAD)

if [ "$OLD_HEAD" = "$NEW_HEAD" ]; then
    log "Already up to date ($OLD_HEAD)."
else
    log "Updated: $OLD_HEAD → $NEW_HEAD"
fi

# ── Step 2: Merge hooks.json into settings.json ──
if [ ! -f "$HOOKS_JSON" ]; then
    log "ERROR: hooks.json not found at $HOOKS_JSON"
    exit 1
fi

log "Updating $SETTINGS_FILE..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

python3 -c "
import json, sys

hooks_path = sys.argv[1]
settings_path = sys.argv[2]

# Read canonical hooks
with open(hooks_path) as f:
    hooks_config = json.load(f)

# Read existing settings (or empty)
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

# Merge: hooks from canonical source, preserve other settings
settings['hooks'] = hooks_config['hooks']

# Write back
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print(f'  Hooks updated: {list(hooks_config[\"hooks\"].keys())}')
" "$HOOKS_JSON" "$SETTINGS_FILE"

# ── Step 3: Report to comms ──
if [ -x "$CLIENT" ] && [ -n "${COMMS_TOKEN:-}" ]; then
    "$CLIENT" send fagents-autonomy "[$AGENT] Deploy complete: $OLD_HEAD → $NEW_HEAD. Hooks updated." 2>/dev/null || true
fi

# ── Step 4: Restart daemon (if requested) ──
if [ "$DO_RESTART" = true ]; then
    PID_FILE="$AUTONOMY_DIR/.pid"
    START_SCRIPT="$PROJECT_DIR/start-agent.sh"

    if [ ! -f "$START_SCRIPT" ]; then
        log "ERROR: start-agent.sh not found at $START_SCRIPT"
        exit 1
    fi

    log "Scheduling daemon restart..."

    # Report before dying
    if [ -x "$CLIENT" ] && [ -n "${COMMS_TOKEN:-}" ]; then
        "$CLIENT" send fagents-autonomy "[$AGENT] Restarting daemon now. Back in ~10s." 2>/dev/null || true
    fi

    # Release the inherited flock FIRST — this allows a new daemon to start.
    # fd 9 is the flock held by daemon.sh, inherited through claude -p to us.
    exec 9>&- 2>/dev/null

    # Write a standalone restart script to /tmp so it survives our death
    RESTART_SCRIPT="/tmp/deploy-restart-$$.sh"
    cat > "$RESTART_SCRIPT" << RESTARTEOF
#!/bin/bash
sleep 3
# Kill old daemon if still running
if [ -f '$PID_FILE' ]; then
    kill \$(cat '$PID_FILE' 2>/dev/null) 2>/dev/null || true
    sleep 2
fi
# Start new daemon
'$START_SCRIPT'
rm -f '$RESTART_SCRIPT'
RESTARTEOF
    chmod +x "$RESTART_SCRIPT"

    # Launch restart script fully detached (setsid = new session leader)
    setsid "$RESTART_SCRIPT" > /tmp/deploy-restart.log 2>&1 &
    disown 2>/dev/null || true

    log "Restart scheduled. Killing current daemon..."
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null || true
    fi
    # This process will likely die here if we're inside the daemon
else
    log "Done. Hooks will hot-reload on next tool call (no restart needed)."
fi
