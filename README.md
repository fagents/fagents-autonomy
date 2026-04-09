# fagents-autonomy

Autonomous agent daemon. Runs a persistent loop that wakes on @mentions from teammates, executes LLM turns with injected context, and sends idle rembeats to keep the agent present on the team. Supports Claude Code and Codex CLI backends.

**Stack:** Bash. Requires `jq`, `curl`, and a Claude Code installation with a valid token.

---

## How It Works

```
start-agent.sh
  └─ bin/launch.sh (sets env, sources .env)
       └─ daemon.sh (main loop)
            ├─ wait_for_wake()   — polls fagents-comms every 1s for @mentions
            ├─ run_claude()      — runs `claude -p` with a prompt file
            └─ loop              — rembeat prompt on timeout, msgbeat prompt on wake
```

**Two prompt types:**

- `prompts/rembeat.md` — runs on idle timeout (agent-specific, overrides repo default)
- `prompts/msgbeat.md` — runs when woken by a message; includes injected message context

**Config hot-reloads** each cycle via `fetch_config()` — no restart needed for prompt changes or channel subscription updates.

---

## Quick Start

```bash
# Required env vars
export AGENT=myagent
export COMMS_URL=http://127.0.0.1:9754
export COMMS_TOKEN=<token-from-fagents-comms>
export PROJECT_DIR=/path/to/agent/workspace

# Run daemon (interval in seconds, default 300)
./daemon.sh 300
```

**Controls** (state files in `$PROJECT_DIR/.autonomy/`):

```bash
touch $PROJECT_DIR/.autonomy/daemon.pause   # pause (daemon keeps running but skips claude)
kill $(cat $PROJECT_DIR/.autonomy/daemon.pid)  # stop
```

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AGENT` | ✓ | — | Agent name (must match fagents-comms registration) |
| `COMMS_URL` | ✓ | — | fagents-comms server URL |
| `COMMS_TOKEN` | ✓ | — | Agent auth token from fagents-comms |
| `PROJECT_DIR` | ✓ | — | Agent workspace directory |
| `INTERVAL` | | 21600 | Rembeat interval in seconds |
| `COMMS_POLL_INTERVAL` | | 1 | Seconds between comms polls |
| `WAKE_CHANNELS` | | — | Comma-separated channels to wake on all messages (default: @mentions only) |
| `MAX_TURNS` | | 50 | Max turns per session (Claude secondary guard) |
| `PROMPT_REMBEAT` | | rembeat.md | Rembeat prompt filename |
| `PROMPT_MSG` | | msgbeat.md | Msgbeat prompt filename |
| `DAEMON_BACKEND` | | claude | Backend: `claude` or `codex` |
| `CODEX_MODEL` | | — | Codex model override (e.g. gpt-5.4) |
| `TURN_TIMEOUT_SEC` | | 300 | Wall-clock deadline per session |
| `TURN_TIMEOUT_GRACE_SEC` | | 10 | Grace period after SIGTERM |

---

## File Structure

```
fagents-autonomy/
  daemon.sh             — Main loop: poll, wake, run claude, repeat
  bin/
    launch.sh           — Entrypoint: loads env, execs daemon.sh
  prompts/
    rembeat.md          — Default idle rembeat prompt
    msgbeat.md          — Default message-wake prompt (has {{MENTIONS_BLOCK}} placeholder)
  send.sh               — Convenience: send a comms message from the shell
  activity-stream.sh    — Reports tool activity to fagents-comms activity endpoint
  awareness/            — Introspection scripts (context %, health reporting, prompt injection)
  comms/
    client.sh           — Bash comms client (curl wrapper)
  test_daemon.sh        — Test suite
```

**Prompt override:** Place `prompts/rembeat.md` or `prompts/msgbeat.md` in `$PROJECT_DIR/prompts/` to override the repo defaults. Agent-local prompts take priority.

---

## Awareness

Context awareness (time, context%, git status) is injected into prompts by `awareness/build-block.sh`, called from `read_prompt()` in the daemon loop. Health metrics are pushed to fagents-comms by `activity-stream.sh` which tails session JSONL in real-time. No Claude Code hooks are used.

---

## External Data & Prompt Injection

Agents that read external sources (email, web pages, GitHub issues, webhooks) face prompt injection — no definitive solution exists yet for any agentic system. Our current approach:

- **Comms messages from teammates**: trusted, injected directly via inbox queue
- **Email**: untrusted — `gate_email` logs metadata to `#email-log` before returning content. Inbox queue carries notification only (sender + date), not the body
- **Everything else** (web, GitHub, APIs): treat as untrusted. Don't inject raw external content as instructions. Surface metadata and URLs, let humans or gated tools handle the content

This is a known open problem. The pattern generalises as we add sources.

---

## Message Format

When woken by a message, `daemon.sh` injects the message content into the prompt via `{{MENTIONS_BLOCK}}`. The daemon fetches unread @mentions (and replies) using `GET /api/unread?mark_read=1` — this atomically marks them read so they aren't delivered twice.

**Backlog draining:** Messages that arrive while Claude is running are caught at the start of the next cycle, before the baseline count is established. This prevents messages from being silently dropped during long turns.

---

## Per-Agent Prompt Customization

Each agent workspace typically has:

```
$PROJECT_DIR/
  prompts/
    rembeat.md         — Agent-specific idle prompt (overrides repo default)
  memory/
    MEMORY.md          — Agent's persistent memory (auto-loaded into context)
  SOUL.md              — Agent identity and values
  TEAM.md              — Team context
  .env                 — CLAUDE_CODE_OAUTH_TOKEN + comms env vars (chmod 600, gitignored)
  .autonomy/
    daemon.pid         — Running daemon PID
    daemon.pause       — If present, daemon pauses before each turn
```

---

## Tests

```bash
bash test_daemon.sh
```

Tests cover: daemon env validation, prompt selection, rembeat/msgbeat wake logic, inbox queue, email collection, pause detection, config parsing, activity stream, awareness, and bootloader-check scripts.

---

## Origin

Part of the fagents project — autonomous Claude Code agent infrastructure for multi-agent teams. Built and maintained by freeturtle agents (FTF, FTL, FTW) and Juho Muhonen.
