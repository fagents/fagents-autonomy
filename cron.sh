#!/bin/bash
# fagents cron — schedule recurring messages to your own inbox
#
# Usage:
#   cron.sh add <handle> <schedule> <message>
#   cron.sh list
#   cron.sh remove <handle>
#   cron.sh fire <handle> <message>    (called by cron itself)
#
# The handle is a human-readable name (kebab-case). It identifies the
# cron job for listing and removal.
#
# Examples:
#   cron.sh add weekly-review "0 9 * * 1" "Time for your weekly memory review"
#   cron.sh add daily-comms-check "0 8,14,20 * * *" "Check comms and respond"
#   cron.sh list
#   cron.sh remove weekly-review
#
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-/home/$(whoami)/workspace/$(whoami)}"
INBOX_DIR="$PROJECT_DIR/.queue/inbox"
CRON_TAG="fagents-cron"

usage() {
    echo "Usage:"
    echo "  cron.sh add <handle> <schedule> <message>"
    echo "  cron.sh list"
    echo "  cron.sh remove <handle>"
    echo ""
    echo "Schedule is standard cron syntax: minute hour day-of-month month day-of-week"
    echo ""
    echo "Examples:"
    echo "  cron.sh add weekly-review \"0 9 * * 1\" \"Time for weekly memory review\""
    echo "  cron.sh add every-6h \"0 */6 * * *\" \"Periodic check-in\""
    echo "  cron.sh remove weekly-review"
    exit 1
}

cmd_fire() {
    local handle="$1" message="$2"
    local ts id
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    id="cron-${handle}-$(date +%s)"

    mkdir -p "$INBOX_DIR"
    jq -nc \
        --arg ts "$ts" \
        --arg id "$id" \
        --arg handle "$handle" \
        --arg body "$message" \
        '{ts:$ts, id:$id, source:"cron", channel:"self", from:("cron:" + $handle), body:$body, trusted:true}' \
        > "$INBOX_DIR/${id}.jsonl"
}

cmd_add() {
    local handle="$1" schedule="$2" message="$3"

    # Validate handle: kebab-case only
    if ! echo "$handle" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
        echo "ERROR: handle must be kebab-case (e.g. weekly-review)" >&2
        exit 1
    fi

    # Validate schedule: must be 5 fields
    local field_count
    field_count=$(echo "$schedule" | awk '{print NF}')
    if [ "$field_count" -ne 5 ]; then
        echo "ERROR: schedule must be 5 cron fields (minute hour dom month dow)" >&2
        echo "  Got: $schedule" >&2
        exit 1
    fi

    # Read crontab once (avoids double read + TOCTOU)
    local existing
    existing=$(crontab -l 2>/dev/null || true)

    # Check for duplicate handle
    if echo "$existing" | grep -q "# ${CRON_TAG}:${handle} "; then
        echo "ERROR: cron '$handle' already exists. Remove it first." >&2
        exit 1
    fi

    # Build the cron line — bake PROJECT_DIR so cron fire finds the right inbox
    local cron_cmd
    cron_cmd="PROJECT_DIR=$(printf '%q' "$PROJECT_DIR") $SCRIPT_DIR/cron.sh fire $(printf '%q' "$handle") $(printf '%q' "$message")"
    local cron_line="$schedule $cron_cmd # ${CRON_TAG}:${handle} | ${message}"

    # Append to crontab
    (echo "$existing"; echo "$cron_line") | crontab -

    echo "Added: $handle"
    echo "  Schedule: $schedule"
    echo "  Message: $message"
}

cmd_list() {
    local crons
    crons=$(crontab -l 2>/dev/null | grep "# ${CRON_TAG}:" || true)

    if [ -z "$crons" ]; then
        echo "No recurring tasks."
        return
    fi

    echo "$crons" | while IFS= read -r line; do
        local schedule handle_part message_part tag
        schedule=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
        tag="${line##*# ${CRON_TAG}:}"
        handle_part="${tag%% |*}"
        message_part="${line#*| }"
        echo "  $handle_part"
        echo "    schedule: $schedule"
        echo "    message:  $message_part"
    done
}

cmd_remove() {
    local handle="$1"

    if ! crontab -l 2>/dev/null | grep -q "# ${CRON_TAG}:${handle} "; then
        echo "ERROR: cron '$handle' not found." >&2
        exit 1
    fi

    crontab -l 2>/dev/null | grep -v "# ${CRON_TAG}:${handle} " | crontab -

    echo "Removed: $handle"
}

# ── Main ──
case "${1:-}" in
    add)
        [ $# -lt 4 ] && usage
        cmd_add "$2" "$3" "$4"
        ;;
    list)
        cmd_list
        ;;
    remove)
        [ $# -lt 2 ] && usage
        cmd_remove "$2"
        ;;
    fire)
        [ $# -lt 3 ] && echo "Usage: cron.sh fire <handle> <message>" >&2 && exit 1
        cmd_fire "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
