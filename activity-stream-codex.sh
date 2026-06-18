#!/bin/bash
# Real-time activity streamer (codex backend) -- tails the active codex
# session JSONL and pushes events to fagents-comms.
#
# Usage: activity-stream-codex.sh
#   Requires: COMMS_URL, COMMS_TOKEN env vars
#   Honors:   CODEX_HOME (defaults to $HOME/.codex)
#
# Runs as background process. Daemon starts/stops it automatically.
# Sibling to activity-stream.sh (Claude path); daemon dispatches on
# DAEMON_BACKEND.
#
# Test sourcing: the BASH_SOURCE guard below skips the main body when
# the file is sourced, so test_daemon.sh can exercise the helper
# functions in isolation (no live tail).

# Returns the path of the most recently modified rollout-*.jsonl under
# $1 (recursive). rc=1 with no output if the dir is missing or empty.
# Pure bash (-nt reduce + find -print0) -- portable to Linux and macOS,
# safe with spaces in $1, deterministic regardless of session count.
find_latest_codex_jsonl() {
    local root="$1"
    [ -d "$root" ] || return 1
    local latest="" f
    while IFS= read -r -d '' f; do
        if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then
            latest="$f"
        fi
    done < <(find "$root" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
    [ -n "$latest" ] || return 1
    printf '%s\n' "$latest"
}

# Tail-rotate loop: re-resolves the active rollout file every
# ROTATE_POLL_SEC and restarts the tail+parser pipeline when codex moves
# on to a new session file. Codex writes a NEW rollout-*.jsonl per
# `codex exec` invocation that isn't a resume; after a daemon restart
# the first turn writes a new file, and a tail anchored to the prior
# rollout would go dark without this loop.
tail_codex_sessions() {
    local jsonl pipeline_pid current
    while true; do
        jsonl=$(find_latest_codex_jsonl "$JSONL_ROOT") || {
            echo "activity-stream-codex: no rollout-*.jsonl under $JSONL_ROOT (waiting)" >&2
            sleep "${ROTATE_POLL_SEC:-30}"
            continue
        }

        echo "activity-stream-codex: tailing $jsonl as $AGENT" >&2

        # Wrap the pipeline in a subshell so $! is the subshell PID with
        # tail+python as direct children -- otherwise $! would be only
        # the python (last in pipeline) and the bare tail would leak
        # whenever the rollout becomes dormant (no writes -> no SIGPIPE).
        (
            tail -n 3 -f "$jsonl" | python3 -u -c "$PARSER_PY" 2>/dev/null
        ) &
        pipeline_pid=$!

        while kill -0 "$pipeline_pid" 2>/dev/null; do
            sleep "${ROTATE_POLL_SEC:-30}"
            current=$(find_latest_codex_jsonl "$JSONL_ROOT") || continue
            if [ "$current" != "$jsonl" ]; then
                echo "activity-stream-codex: rotation -> $current" >&2
                # Kill children FIRST (the bare tail wouldn't notice
                # otherwise), then the subshell, then reap.
                pkill -TERM -P "$pipeline_pid" 2>/dev/null || true
                kill "$pipeline_pid" 2>/dev/null || true
                break
            fi
        done
        wait "$pipeline_pid" 2>/dev/null || true
    done
}

# Source guard: when sourced (e.g. test_daemon.sh exercising the helper),
# return before any side effects. set -euo pipefail comes AFTER the guard
# so we don't poison the test shell either.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

set -euo pipefail

COMMS_URL="${COMMS_URL:-}"
COMMS_TOKEN="${COMMS_TOKEN:-}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

if [ -z "$COMMS_URL" ] || [ -z "$COMMS_TOKEN" ]; then
    echo "activity-stream-codex: COMMS_URL and COMMS_TOKEN required" >&2
    exit 1
fi

# Resolve agent name once
AGENT=$(curl -s --max-time 5 -H "Authorization: Bearer $COMMS_TOKEN" \
    "$COMMS_URL/api/whoami" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent',''))" 2>/dev/null) || true

if [ -z "$AGENT" ]; then
    echo "activity-stream-codex: could not resolve agent name" >&2
    exit 1
fi

# Kill any prior activity-stream processes (codex OR claude side) from
# previous daemon runs. Pattern covers: the codex bash wrapper, the
# claude bash wrapper (in case the agent's DAEMON_BACKEND was flipped),
# orphaned tails of codex rollouts, and orphaned tails of claude
# .introspection-logs.
for pid in $(pgrep -f "activity-stream(-codex)?\.sh|tail.*-f.*rollout-.*\.jsonl|tail.*-f.*\.introspection-logs.*\.jsonl" 2>/dev/null || true); do
    if [ "$pid" != "$$" ]; then
        kill "$pid" 2>/dev/null || true
    fi
done

# Parser gets its config via env vars (not bash interpolation) so the
# test suite can extract the marker block and run it standalone.
export ACTIVITY_AGENT="$AGENT"
export ACTIVITY_COMMS_URL="$COMMS_URL"
export ACTIVITY_COMMS_TOKEN="$COMMS_TOKEN"

# Python parser body. Held in a variable so tail_codex_sessions can
# rebuild the pipeline on session rotation without re-embedding the
# script inside a bash double-quoted heredoc each iteration.
PARSER_PY='
# PARSE_CODEX_JSONL_BEGIN -- test_daemon.sh extracts this block via marker
import json
import os
import sys
import urllib.request

agent = os.environ.get("ACTIVITY_AGENT", "")
comms_url = os.environ.get("ACTIVITY_COMMS_URL", "")
comms_token = os.environ.get("ACTIVITY_COMMS_TOKEN", "")
last_tool = "unknown"

def _post(path, payload):
    # Compact separators (no space after : or ,) match the bash
    # push_activity() helper, which test_daemon.sh asserts against.
    try:
        req = urllib.request.Request(
            f"{comms_url}{path}",
            data=json.dumps(payload, separators=(",", ":")).encode(),
            headers={
                "Authorization": f"Bearer {comms_token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        urllib.request.urlopen(req, timeout=3)
    except Exception:
        pass

def push_activity(events):
    if events:
        _post(f"/api/agents/{agent}/activity", {"events": events})

def push_health(context_pct, tool_name):
    # Clamp to 0-100: codex can report total_tokens > model_context_window
    # post-compaction or during model rollover, which would push values
    # > 100% to the comms UI.
    pct = max(0, min(100, int(context_pct)))
    _post(f"/api/agents/{agent}/health",
          {"context_pct": pct, "status": "active", "last_tool": tool_name})

def _truncate(s):
    return s[:80] + "..." if len(s) > 80 else s

def summarize_args(name, args_raw):
    # exec_command'\''s arguments JSON-encode {cmd, workdir, ...}; pulling cmd
    # out is much more useful in the activity feed than the raw blob.
    if name == "exec_command":
        try:
            args = json.loads(args_raw) if isinstance(args_raw, str) else args_raw
            if isinstance(args, dict):
                cmd = args.get("cmd")
                if cmd:
                    if isinstance(cmd, list):
                        cmd = " ".join(str(c) for c in cmd)
                    return _truncate(str(cmd))
                # exec_command with no cmd (malformed call): fall through
                # to the generic re-serializer so the operator sees the
                # raw args instead of an empty detail.
        except (json.JSONDecodeError, TypeError):
            pass
    # Generic tool (write_stdin, view_image, update_plan, get_goal,
    # update_goal, MCP calls): re-serialize compact + truncate. Falls
    # back to the raw string when arguments isn'\''t JSON.
    if isinstance(args_raw, (dict, list)):
        return _truncate(json.dumps(args_raw, separators=(",", ":")))
    return _truncate(str(args_raw or ""))

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue

    ts = d.get("timestamp", "")
    entry_type = d.get("type")
    payload = d.get("payload") or {}
    if not isinstance(payload, dict):
        continue

    if entry_type == "response_item":
        ptype = payload.get("type")
        if ptype == "function_call":
            # Generic for every codex tool (exec_command, write_stdin,
            # view_image, update_plan, get_goal, update_goal, MCP calls).
            # summarize_args specializes on exec_command to pull cmd out.
            name = payload.get("name") or "unknown"
            detail = summarize_args(name, payload.get("arguments", ""))
            push_activity([{"ts": ts, "type": "tool",
                            "summary": name, "detail": detail}])
            last_tool = name
        # Other response_item subtypes (function_call_output, message,
        # reasoning, custom_tool_call*) are intentionally skipped: tool
        # output is long, assistant-role message duplicates
        # event_msg.agent_message, reasoning is internal CoT.

    elif entry_type == "event_msg":
        ptype = payload.get("type")
        if ptype == "agent_message":
            # Defensive: codex schema variants emit message as a list/dict
            # in some builds; only the plain-string form is summarisable.
            msg = payload.get("message")
            if isinstance(msg, str):
                text = msg.strip()
                if text:
                    summary = text[:200] + ("..." if len(text) > 200 else "")
                    push_activity([{"ts": ts, "type": "thought",
                                    "summary": summary}])
        elif ptype == "token_count":
            # Codex emits early token_count records with info:null before
            # the model has produced any usage; also seen as truthy non-dict
            # ("throttled" string variants). isinstance gate covers both.
            info = payload.get("info")
            if isinstance(info, dict):
                usage = info.get("total_token_usage")
                if not isinstance(usage, dict):
                    usage = {}
                tot = usage.get("total_tokens")
                win = info.get("model_context_window")
                if isinstance(tot, int) and isinstance(win, int) and win > 0:
                    push_health((tot * 100) // win, last_tool)
        # Other event_msg subtypes (task_started, task_complete,
        # user_message) are intentionally skipped: no UI-recognized
        # activity type, and user_message is prompt-side.
# PARSE_CODEX_JSONL_END
'

JSONL_ROOT="$CODEX_HOME/sessions"
tail_codex_sessions
