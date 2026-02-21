#!/bin/bash
# Awareness: Git Status
# Checks infra repos for incoming commits. Outputs only if new commits exist.
# Repos checked: $PROJECT_DIR (agent workspace) + $AUTONOMY_DIR (fagents-autonomy)
# Usage: awareness/git.sh
# Output (stdout): per-repo commit lists, empty if nothing new.

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$AUTONOMY_DIR/.." && pwd)}"

check_repo() {
    local dir="$1"
    local label="$2"
    [ -d "$dir/.git" ] || return 0

    git -C "$dir" fetch --quiet 2>/dev/null || return 0

    local commits
    commits=$(git -C "$dir" log HEAD..origin/main --oneline 2>/dev/null)
    if [ -n "$commits" ]; then
        echo "New commits in $label (origin/main):"
        echo "$commits"
    fi
}

check_repo "$PROJECT_DIR" "workspace"
check_repo "$AUTONOMY_DIR" "autonomy"
