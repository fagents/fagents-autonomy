#!/bin/bash
# install-team.sh — Provision a team of agents on one machine (colocated mode)
#
# Usage: sudo ./install-team.sh [options] AGENT1 AGENT2 ...
#
# Each AGENT can be NAME or NAME:WORKSPACE
#   NAME only:       workspace defaults to dev-team-<name lowercase>
#   NAME:WORKSPACE:  explicit workspace name
#
# Options:
#   --comms-port PORT       Comms server port (default: 9754)
#   --comms-repo URL        fagents-comms git repo URL
#   --mcp-port PORT         MCP local port (enables MCP for all agents)
#
# The first agent listed is the "bootstrap" agent — its user account
# runs the comms server. All agents connect via localhost.
#
# Example:
#   sudo ./install-team.sh FTF:dev-team-ftf FTW:dev-team-ftw FTL
#
# Prerequisites: git, python3, curl, jq

set -euo pipefail

# ── Defaults ──
COMMS_PORT=9754
COMMS_REPO=""
MCP_PORT=""
AGENTS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTONOMY_REPO="file://$SCRIPT_DIR"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --comms-port)   COMMS_PORT="$2"; shift 2 ;;
        --comms-repo)   COMMS_REPO="$2"; shift 2 ;;
        --mcp-port)     MCP_PORT="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  AGENTS+=("$1"); shift ;;
    esac
done

if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo "Usage: sudo $0 [options] AGENT1 AGENT2 ..."
    echo "Run with --help for details."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

if [[ -z "$COMMS_REPO" ]]; then
    echo "ERROR: --comms-repo is required (URL to clone fagents-comms)." >&2
    echo "  Example: --comms-repo ssh://freeturtle@imagine-wonder/home/freeturtle/repos/fagents-comms.git" >&2
    exit 1
fi

# ── Parse AGENT:WORKSPACE pairs ──
declare -A AGENT_WORKSPACES
AGENT_NAMES=()
for spec in "${AGENTS[@]}"; do
    name="${spec%%:*}"
    if [[ "$spec" == *":"* ]]; then
        ws="${spec#*:}"
    else
        ws="dev-team-$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    fi
    AGENT_NAMES+=("$name")
    AGENT_WORKSPACES["$name"]="$ws"
done

BOOTSTRAP="${AGENT_NAMES[0]}"

agent_user() {
    echo "agent-$(echo "$1" | tr '[:upper:]' '[:lower:]')"
}

BOOTSTRAP_USER=$(agent_user "$BOOTSTRAP")

echo "=== Freeturtle Team Install ==="
echo ""
echo "  Agents:    ${AGENT_NAMES[*]}"
echo "  Bootstrap: $BOOTSTRAP ($BOOTSTRAP_USER)"
echo "  Comms:     localhost:$COMMS_PORT"
echo "  Autonomy:  $AUTONOMY_REPO"
echo "  Comms src: $COMMS_REPO"
echo ""

# ── Step 1: Create group and users ──
echo "=== Step 1: Create users ==="
groupadd -f fagent

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    if id "$user" &>/dev/null; then
        echo "  $user already exists"
    else
        useradd -m -g fagent -s /bin/bash "$user"
        echo "  Created $user"
    fi
done
echo ""

# ── Step 2: Clone fagents-comms for bootstrap user ──
echo "=== Step 2: Comms server ==="
BOOTSTRAP_HOME=$(eval echo "~$BOOTSTRAP_USER")
COMMS_DIR="$BOOTSTRAP_HOME/workspace/fagents-comms"

if [[ -d "$COMMS_DIR" ]]; then
    echo "  fagents-comms already at $COMMS_DIR"
else
    su - "$BOOTSTRAP_USER" -c "mkdir -p ~/workspace && git clone '$COMMS_REPO' ~/workspace/fagents-comms" 2>&1 | sed 's/^/  /'
fi

# Start comms server (if not already running)
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/health" 2>/dev/null | grep -q "200"; then
    echo "  Comms server already running on port $COMMS_PORT"
else
    echo "  Starting comms server on port $COMMS_PORT..."
    su - "$BOOTSTRAP_USER" -c "cd ~/workspace/fagents-comms && PORT=$COMMS_PORT nohup python3 server.py serve > comms.log 2>&1 &"
    sleep 2
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/health" 2>/dev/null | grep -q "200"; then
        echo "  Comms server running"
    else
        echo "  WARNING: Comms server may not have started. Check $COMMS_DIR/comms.log"
    fi
fi
echo ""

# ── Step 3: Register agents with comms ──
echo "=== Step 3: Register agents ==="
declare -A AGENT_TOKENS

for name in "${AGENT_NAMES[@]}"; do
    output=$(su - "$BOOTSTRAP_USER" -c "cd ~/workspace/fagents-comms && python3 server.py add-agent '$name'" 2>&1) || true
    token=$(echo "$output" | grep "^Token: " | cut -d' ' -f2)
    if [[ -n "$token" ]]; then
        AGENT_TOKENS["$name"]="$token"
        echo "  Registered $name"

        # Subscribe to general + personal DM channel
        curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/subscriptions" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{\"channels\": [\"general\", \"dm-$(echo "$name" | tr '[:upper:]' '[:lower:]')\"]}" > /dev/null 2>&1 || true
    else
        echo "  WARNING: Failed to register $name"
        echo "    $output" | head -3
    fi
done
echo ""

# ── Step 4: Install each agent ──
echo "=== Step 4: Install agents ==="

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    token="${AGENT_TOKENS[$name]:-}"

    echo "--- $name ($user) ---"

    MCP_ENABLED="n"
    MCP_LOCAL_PORT_VAL=""
    MCP_REMOTE_PORT_VAL=""
    if [[ -n "$MCP_PORT" ]]; then
        MCP_ENABLED="Y"
        MCP_LOCAL_PORT_VAL="$MCP_PORT"
        MCP_REMOTE_PORT_VAL="$MCP_PORT"
    fi

    su - "$user" -c "
        export NONINTERACTIVE=1
        export AGENT_NAME='$name'
        export WORKSPACE='$ws'
        export GIT_HOST='local'
        export COMMS_URL='http://127.0.0.1:$COMMS_PORT'
        export COMMS_TOKEN='$token'
        export AUTONOMY_REPO='$AUTONOMY_REPO'
        export MCP_ENABLED='$MCP_ENABLED'
        export MCP_LOCAL_PORT='$MCP_LOCAL_PORT_VAL'
        export MCP_REMOTE_PORT='$MCP_REMOTE_PORT_VAL'
        bash ~/workspace/fagents-autonomy/install-agent.sh
    " 2>&1 | sed 's/^/  /'

    echo ""
done

# ── Step 5: Create team management scripts ──
echo "=== Step 5: Team scripts ==="
TEAM_DIR="$BOOTSTRAP_HOME/workspace/team"
mkdir -p "$TEAM_DIR"

# start-team.sh
cat > "$TEAM_DIR/start-team.sh" << 'TEAMSTART'
#!/bin/bash
# Start all agents in the team
set -euo pipefail
TEAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEAMSTART

# Append comms server start (as bootstrap user)
cat >> "$TEAM_DIR/start-team.sh" << COMMSSTART

# Start comms server
echo "Starting comms server..."
COMMS_DIR="$COMMS_DIR"
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/health" 2>/dev/null | grep -q "200"; then
    echo "  Already running"
else
    su - "$BOOTSTRAP_USER" -c "cd ~/workspace/fagents-comms && PORT=$COMMS_PORT nohup python3 server.py serve > comms.log 2>&1 &"
    sleep 2
    echo "  Started"
fi

# Start agent daemons
COMMSSTART

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/start-team.sh" << AGENTSTART
echo "Starting $name..."
su - "$user" -c "cd ~/workspace/$ws && ./start-agent.sh" || echo "  WARNING: failed to start $name"
AGENTSTART
done

chmod +x "$TEAM_DIR/start-team.sh"
echo "  Created $TEAM_DIR/start-team.sh"

# stop-team.sh — runs as root, reads PID files directly
cat > "$TEAM_DIR/stop-team.sh" << 'TEAMSTOP'
#!/bin/bash
# Stop all agents in the team (run as root)
set -euo pipefail

stop_pid_file() {
    local label="$1" pid_file="$2"
    echo "Stopping $label..."
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill "$pid" 2>/dev/null; then
            echo "  Stopped (PID $pid)"
        else
            echo "  Not running (stale PID file)"
        fi
        rm -f "$pid_file"
    else
        echo "  No PID file"
    fi
}
TEAMSTOP

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    user_home=$(eval echo "~$user")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/stop-team.sh" << AGENTSTOP
stop_pid_file "$name" "$user_home/workspace/$ws/.autonomy/daemon.pid"
AGENTSTOP
done

# Stop comms server
cat >> "$TEAM_DIR/stop-team.sh" << COMMSSTOP

echo "Stopping comms server..."
COMMS_PID=\$(pgrep -f "python3 server.py serve" -u $BOOTSTRAP_USER 2>/dev/null || true)
if [[ -n "\$COMMS_PID" ]]; then
    kill \$COMMS_PID 2>/dev/null && echo "  Stopped" || echo "  Not running"
else
    echo "  Not running"
fi
COMMSSTOP

chmod +x "$TEAM_DIR/stop-team.sh"
echo "  Created $TEAM_DIR/stop-team.sh"

chown -R "$BOOTSTRAP_USER:fagent" "$TEAM_DIR"
echo ""

# ── Done ──
echo "========================================"
echo "  Team provisioned!"
echo "========================================"
echo ""
echo "Users created:"
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    echo "  $name → $user (~/workspace/$ws)"
done
echo ""
echo "Next steps:"
echo "  1. Run 'claude login' for each agent user:"
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    echo "     sudo su - $user -c 'claude login'"
done
echo ""
echo "  2. Start the team:"
echo "     sudo $TEAM_DIR/start-team.sh"
echo ""
echo "  3. Stop the team:"
echo "     sudo $TEAM_DIR/stop-team.sh"
echo ""
echo "  4. View logs:"
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    echo "     sudo su - $user -c 'tail -f ~/workspace/$ws/.autonomy/daemon.log'"
done
echo ""
