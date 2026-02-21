# Git Dual-Remote Setup

Pattern for working with repos that have both a local bare repo (fast,
free pushes) and a GitHub upstream (external collaboration).

## When to Use

- You need to work with a repo from GitHub (Juho's or third-party)
- You want to push freely without hitting GitHub rate limits or access issues
- The team needs a shared local copy (shared-server bare repo)

For repos that only live locally, the standard `install-agent.sh` setup
(single origin pointing to shared-server bare repo) is enough.

## Automated Setup

Use `setup-github-remote.sh` to automate the GitHub remote setup:

```bash
export AGENT=FTF  # your agent name
./setup-github-remote.sh ~/workspace/<repo> git@github.com:<owner>/<repo>.git
```

The script handles deploy key generation, SSH config, remote setup,
and pushing. See the manual steps below if you need to understand or
debug the process.

## Manual Setup

### 1. Clone from GitHub

```bash
git clone git@github.com:<owner>/<repo>.git ~/workspace/<repo>
cd ~/workspace/<repo>
```

If GitHub SSH fails with "Host key verification failed":
```bash
ssh-keyscan github.com >> ~/.ssh/known_hosts
```

### 2. Create bare repo on shared-server

```bash
ssh user@shared-server "git init --bare ~/repos/<repo>.git"
```

### 3. Set up dual remotes

Rename GitHub to `github`, add local bare repo as `origin`:

```bash
git remote rename origin github
git remote add origin ssh://user@shared-server/home/user/repos/<repo>.git
```

Push all branches to the local bare repo:

```bash
# Check which branch you're on — some repos use master, not main
git branch
git push -u origin <branch>
```

### 4. Verify

```bash
git remote -v
# github  git@github-<repo>-<agent>:<owner>/<repo>.git (fetch)
# github  git@github-<repo>-<agent>:<owner>/<repo>.git (push)
# origin  ssh://user@shared-server/home/user/repos/<repo>.git (fetch)
# origin  ssh://user@shared-server/home/user/repos/<repo>.git (push)
```

## Daily Workflow

| Action | Command |
|--------|---------|
| Push your work | `git push` (goes to origin/shared-server) |
| Pull teammate changes | `git pull` (from origin/shared-server) |
| Push to GitHub | `git push github <branch>` |
| Pull from GitHub | `git pull github <branch>` |
| Sync GitHub → local | `git pull github <branch> && git push origin <branch>` |

**Rule of thumb:** `origin` is your working remote (push freely).
`github` is the external remote (push when ready to share upstream).

## Multiple GitHub Deploy Keys

GitHub deploy keys are per-repo — the same key can't be added to two
repos. Keys are also per-agent so multiple agents on one machine each
have their own identity.

### Naming convention

| Item | Pattern | Example |
|------|---------|---------|
| Key file | `id_ed25519-<agent>-github-<repo>` | `id_ed25519-ftf-github-fagents-comms` |
| SSH host alias | `github-<repo>-<agent>` | `github-fagents-comms-ftf` |
| Remote URL | `git@github-<repo>-<agent>:owner/repo.git` | `git@github-fagents-comms-ftf:satunnaisotus-juho/fagents-comms.git` |

### SSH config (`~/.ssh/config`)

```
Host github.com
  HostName github.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes

Host github-fagents-comms-ftf
  HostName github.com
  IdentityFile ~/.ssh/id_ed25519-ftf-github-fagents-comms
  IdentitiesOnly yes
```

### Using the alias

Set the github remote URL to use the alias instead of `github.com`:

```bash
git remote set-url github git@github-<repo>-<agent>:<owner>/<repo>.git
# or when first adding:
git remote add github git@github-<repo>-<agent>:<owner>/<repo>.git
```

The first repo can keep using `github.com` directly (default key).
Each additional repo gets its own alias via `setup-github-remote.sh`.

## Notes

- Some repos use `master` instead of `main` — check before pushing
- Other agents on different machines clone from the shared-server bare
  repo, not from GitHub (faster, no GitHub SSH setup needed)
- If the GitHub repo is read-only (no push access), `github` is
  fetch-only — use it to pull upstream changes
