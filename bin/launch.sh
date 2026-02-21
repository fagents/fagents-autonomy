#!/bin/bash
# Launch the daemon for the current agent.
# Called by each agent's start-agent.sh after setting env vars.
#
# Required env vars (set by start-agent.sh):
#   AUTONOMY_DIR  — path to fagents-autonomy clone
#   AGENT         — agent name (e.g. FTF)
#   COMMS_URL     — comms server URL
#   COMMS_TOKEN   — agent auth token
#   PROJECT_DIR   — agent workspace directory
#
# Optional env vars:
#   MAX_TURNS     — max turns per session (default: server config)
#   TUNNEL_HOST   — SSH host for tunnels (e.g. user@server)
#   COMMS_PORT    — comms port to tunnel (default: extracted from COMMS_URL)
#   MCP_LOCAL_PORT  — local port for MCP tunnel
#   MCP_REMOTE_PORT — remote port for MCP tunnel
#   HEARTBEAT_INTERVAL — seconds between heartbeats (default: 300)

set -euo pipefail

# ── Validate required env vars ──
for var in AUTONOMY_DIR AGENT COMMS_URL COMMS_TOKEN PROJECT_DIR; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set. Set it in start-agent.sh." >&2
        exit 1
    fi
done

# ── Defaults ──
COMMS_PORT="${COMMS_PORT:-$(echo "$COMMS_URL" | sed 's|.*:\([0-9]*\).*|\1|')}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"

# ── SSH tunnel helpers ──
port_reachable() {
    local port="$1" code
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/health" 2>/dev/null)
    [[ "$code" =~ ^[0-9]+$ && "$code" != "000" ]]
}

ensure_tunnel() {
    local local_port="$1" remote_port="$2" host="$3"
    if [[ -z "$host" ]]; then
        return 0
    fi
    if port_reachable "$local_port"; then
        echo "  Port $local_port already reachable."
        return 0
    fi
    echo "  Opening SSH tunnel $local_port -> $host:$remote_port..."
    ssh -f -N -L "${local_port}:127.0.0.1:${remote_port}" "$host"
    sleep 1
    if port_reachable "$local_port"; then
        echo "  Tunnel established."
        return 0
    else
        echo "  Warning: tunnel opened but port $local_port not responding."
        return 1
    fi
}

# ── Set up tunnels if needed ──
if [[ -n "${TUNNEL_HOST:-}" ]]; then
    echo "Checking SSH tunnels..."
    ensure_tunnel "$COMMS_PORT" "$COMMS_PORT" "$TUNNEL_HOST"
    if [[ -n "${MCP_LOCAL_PORT:-}" && -n "${MCP_REMOTE_PORT:-}" ]]; then
        ensure_tunnel "$MCP_LOCAL_PORT" "$MCP_REMOTE_PORT" "$TUNNEL_HOST"
    fi
fi

# ── Launch daemon ──
echo "Starting $AGENT daemon..."
nohup "$AUTONOMY_DIR/daemon.sh" "$HEARTBEAT_INTERVAL" > /dev/null 2>&1 &
echo "PID: $!"
echo "Log: tail -f $PROJECT_DIR/.autonomy/daemon.log"
