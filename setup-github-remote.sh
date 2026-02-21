#!/bin/bash
# setup-github-remote.sh — Add a GitHub remote to a local repo with per-agent deploy keys
#
# Usage: setup-github-remote.sh <repo-dir> <github-url>
# Example: setup-github-remote.sh ~/workspace/fagents-comms git@github.com:satunnaisotus-juho/fagents-comms.git
#
# Requires: AGENT env var (e.g. FTF, FTW, FTL)
#
# What it does:
#   1. Derives repo name from URL
#   2. Checks for deploy key — generates one if missing, prints pubkey
#   3. Adds SSH config host alias (per-agent)
#   4. Adds 'github' remote to the repo
#   5. Optionally pushes to GitHub

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <repo-dir> <github-url>"
    echo "Example: $0 ~/workspace/fagents-comms git@github.com:owner/repo.git"
    exit 1
fi

REPO_DIR="$1"
GITHUB_URL="$2"
AGENT="${AGENT:-}"

if [[ -z "$AGENT" ]]; then
    echo "Error: AGENT env var not set (e.g. export AGENT=FTF)"
    exit 1
fi

AGENT_LOWER=$(echo "$AGENT" | tr '[:upper:]' '[:lower:]')

# Derive repo name from URL: git@...:owner/repo-name.git → repo-name
REPO_NAME=$(echo "$GITHUB_URL" | sed 's|.*/||; s|\.git$||')
if [[ -z "$REPO_NAME" ]]; then
    echo "Error: could not derive repo name from URL: $GITHUB_URL"
    exit 1
fi

# Verify repo dir exists and is a git repo
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "Error: $REPO_DIR is not a git repository"
    exit 1
fi

SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519-${AGENT_LOWER}-github-${REPO_NAME}"
HOST_ALIAS="github-${REPO_NAME}-${AGENT_LOWER}"
REMOTE_URL="git@${HOST_ALIAS}:$(echo "$GITHUB_URL" | sed 's|.*:||')"

echo "=== GitHub Remote Setup ==="
echo "  Repo:       $REPO_DIR"
echo "  GitHub:     $GITHUB_URL"
echo "  Agent:      $AGENT"
echo "  Host alias: $HOST_ALIAS"
echo "  Key file:   $KEY_FILE"
echo ""

# ── Step 1: Deploy key ──
if [[ -f "$KEY_FILE" ]]; then
    echo "Deploy key exists: $KEY_FILE"
else
    echo "Generating deploy key..."
    mkdir -p "$SSH_DIR"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "${AGENT_LOWER}@$(hostname)" -q
    echo "Key generated."
fi

echo ""
echo "Public key (add as deploy key on GitHub with write access):"
echo "──────────────────────────────────────────────────────────"
cat "${KEY_FILE}.pub"
echo "──────────────────────────────────────────────────────────"
echo ""

# ── Step 2: SSH config ──
SSH_CONFIG="$SSH_DIR/config"
if [[ -f "$SSH_CONFIG" ]] && grep -q "^Host ${HOST_ALIAS}$" "$SSH_CONFIG"; then
    echo "SSH config entry for $HOST_ALIAS already exists — skipping."
else
    echo "Adding SSH config entry for $HOST_ALIAS..."

    # Ensure github.com host key is known
    if ! ssh-keygen -F github.com > /dev/null 2>&1; then
        echo "  Adding github.com to known_hosts..."
        ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
    fi

    # Add entry
    cat >> "$SSH_CONFIG" << EOF

Host ${HOST_ALIAS}
  HostName github.com
  IdentityFile ${KEY_FILE}
  IdentitiesOnly yes
EOF
    chmod 600 "$SSH_CONFIG"
    echo "  Done."
fi

# ── Step 3: Git remote ──
cd "$REPO_DIR"
if git remote | grep -q "^github$"; then
    EXISTING_URL=$(git remote get-url github)
    if [[ "$EXISTING_URL" == "$REMOTE_URL" ]]; then
        echo "Remote 'github' already set to $REMOTE_URL"
    else
        echo "Updating remote 'github': $EXISTING_URL → $REMOTE_URL"
        git remote set-url github "$REMOTE_URL"
    fi
else
    echo "Adding remote 'github' → $REMOTE_URL"
    git remote add github "$REMOTE_URL"
fi

# ── Step 4: Test + push ──
echo ""
echo "Testing GitHub access..."
if ssh -T "git@${HOST_ALIAS}" 2>&1 | grep -qi "successfully authenticated"; then
    echo "  SSH authentication OK."
    BRANCH=$(git branch --show-current)
    read -rp "Push $BRANCH to GitHub? [Y/n] " confirm
    if [[ "${confirm,,}" != "n" ]]; then
        git push github "$BRANCH"
        echo "  Pushed."
    fi
else
    echo "  SSH authentication failed."
    echo "  Make sure the deploy key is added to the GitHub repo."
    echo "  Then run: git push github $(git branch --show-current)"
fi

echo ""
echo "Done. Remotes:"
git remote -v
