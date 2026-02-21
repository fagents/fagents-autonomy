# MCP Tooling for Agents

How agents get access to credentialed services (email, APIs, etc.)
without credentials ever entering the LLM context.

## Architecture

```
Agent (Claude Code)
  ↓ native MCP tool call: send_email(to, subject, body)
  ↓ transport: Streamable HTTP
MCP Server (other-things, on imagine-wonder)
  ↓ reads creds from .env
  ↓ executes action (SMTP, API call, etc.)
  ↓ returns result only
Agent sees: {success: true, messageId: "..."}
Agent never sees: SMTP password, API keys, tokens
```

**Key security property:** Service credentials live only in the MCP
server's `.env` file on imagine-wonder. The agent's API key for MCP
auth lives in `settings.json` on disk — Claude Code handles transport
and never exposes it to the LLM context.

## Components

### MCP Server (other-things)

- Repo: `~/workspace/other-things` (dual remote: origin + github)
- Stack: Node/TypeScript, Express, MCP SDK (Streamable HTTP)
- Auth: `x-api-key` header (timing-safe comparison)
- Creds: `.env` file, loaded at startup, never logged
- HTTPS: greenlock/Let's Encrypt (for external access)
- Tools: email, Matrix, Telegram, Sheets, Notion, X, WordPress, etc.
- Config: `ENABLED_TOOLS` in `.env` controls which tools are active

### Agent Config (per-workspace settings.json)

MCP config lives in each agent's **workspace-level** settings file:
`<workspace>/.claude/settings.json` (e.g. `~/workspace/dev-team-ftf/.claude/settings.json`).

This is per-agent, not machine-global. Each agent on the same machine
has its own workspace and its own `.claude/settings.json` with its own
MCP API key. This is also where hooks are configured — MCP config sits
alongside them.

```json
{
  "hooks": { ... },
  "mcpServers": {
    "other-things": {
      "type": "http",
      "url": "http://127.0.0.1:9755/mcp",
      "headers": {
        "x-api-key": "<MCP_API_KEY>"
      }
    }
  }
}
```

The agent reaches the MCP server via SSH tunnel (port 9755 on
localhost → imagine-wonder). Same pattern as fagents-comms (port 9754).

## Install-Time Setup

The `install-agent.sh` script should be updated to:

1. **Prompt for MCP config** — ask if MCP tooling is needed
2. **Add tunnel port** — include 9755 in the SSH tunnel setup
   (start-agent.sh already handles tunnel for comms on 9754)
3. **Add mcpServers to settings.json** — merge MCP config alongside
   hooks config
4. **Store API key** — the MCP API key goes in settings.json (on disk,
   not in env vars, not in LLM context)

### Tunnel addition in start-agent.sh

```bash
# Existing comms tunnel
ensure_tunnel "$COMMS_PORT" "$TUNNEL_HOST"
# New MCP tunnel
ensure_tunnel "9755" "$TUNNEL_HOST"
```

## Server Deployment (imagine-wonder)

1. Clone other-things to imagine-wonder workspace
2. `npm install` (requires Node 20+)
3. Create `.env` with service credentials (SMTP, API keys, etc.)
4. Set `MCP_API_KEY` in `.env` (shared key for all agents, or
   per-agent keys later)
5. Set `ENABLED_TOOLS` to control which tools are available
6. Start: `node dist/index.js` (or `npm start`)
7. Listens on localhost:9755 (no external exposure needed initially)

## Security Model

| Secret | Where it lives | Who can see it |
|--------|---------------|----------------|
| Service creds (SMTP, API keys) | `.env` on imagine-wonder | Only MCP server process |
| MCP API key | `settings.json` on each agent machine | On disk only — not in LLM context |
| COMMS_TOKEN | env var in daemon | In agent env, not in LLM context by default |

**What enters LLM context:** Tool names, parameters, and results.
Nothing else.

**Theoretical risk:** An agent could `cat .claude/settings.json` and
see the MCP API key. Mitigation: this is the same risk level as
reading any local file — and the MCP API key only grants access to
tools, not to the underlying service credentials.

## Future: Per-Agent Keys

Current: single shared `MCP_API_KEY` for all agents.

When we need per-agent isolation (multi-agent per machine, different
tool permissions per agent):
1. MCP server accepts per-agent API keys
2. Each agent gets its own key in settings.json
3. Server maps key → agent identity → allowed tools
4. Service creds can be per-agent (Agent A's SMTP ≠ Agent B's SMTP)

## Future: Scale Beyond Tunnels

When SSH tunnels become unwieldy (10+ machines):
1. Expose MCP server via HTTPS (greenlock already supports this)
2. Replace tunnel with direct HTTPS URL in settings.json
3. Optionally add short-lived token auth via comms server (OAuth2
   client credentials flow)
