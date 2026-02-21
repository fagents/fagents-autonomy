#!/bin/bash

# Startup Notice — SessionStart hook
# Dynamically reads settings.json to show which hooks are active
# and what awareness scripts they use.
# Reports on change only: hashes config + scripts, compares to last run.
# Trigger: SessionStart

AUTONOMY_DIR="${AUTONOMY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SETTINGS="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"

# Only show when hooks/scripts change (uses shared change-detection helper)
"$AUTONOMY_DIR/awareness/has-changed.sh" "startup-notice" \
    "$SETTINGS" "$AUTONOMY_DIR"/hooks/*.sh "$AUTONOMY_DIR"/awareness/*.sh \
    || exit 0

# Build the notice
NOTICE="Active Hooks
------------"

if [ -f "$SETTINGS" ]; then
    # Parse hooks from settings.json
    HOOK_INFO=$(python3 -c "
import json, sys, os, re

settings_path = sys.argv[1]
autonomy_dir = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
for event, entries in sorted(hooks.items()):
    for entry in entries:
        for hook in entry.get('hooks', []):
            cmd = hook.get('command', '')
            is_async = hook.get('async', False)
            # Extract script name from command
            script = cmd.split('/')[-1].strip('\"')
            script_path = os.path.join(autonomy_dir, 'hooks', script)

            # Read first comment block for description
            desc = ''
            if os.path.isfile(script_path):
                with open(script_path) as sf:
                    for line in sf:
                        line = line.strip()
                        if line.startswith('#') and not line.startswith('#!'):
                            # First meaningful comment line
                            desc = line.lstrip('# ').split(' — ')[0] if ' — ' in line else line.lstrip('# ')
                            break

            # Find which awareness scripts it calls
            awareness = []
            if os.path.isfile(script_path):
                with open(script_path) as sf:
                    content = sf.read()
                    for match in re.findall(r'awareness/(\w+)\.sh', content):
                        if match not in awareness:
                            awareness.append(match)

            async_tag = ' (async)' if is_async else ''
            awareness_str = ''
            if awareness:
                awareness_str = f' -> {', '.join(awareness)}'

            print(f'- {script} [{event}]{async_tag}{awareness_str}')
            if desc:
                print(f'  {desc}')
" "$SETTINGS" "$AUTONOMY_DIR" 2>/dev/null) || true

    if [ -n "$HOOK_INFO" ]; then
        NOTICE="$NOTICE
$HOOK_INFO"
    else
        NOTICE="$NOTICE
  (could not parse settings.json)"
    fi
else
    NOTICE="$NOTICE
  (no settings.json found at $SETTINGS)"
fi

# List available awareness scripts
AWARENESS_DIR="$AUTONOMY_DIR/awareness"
if [ -d "$AWARENESS_DIR" ]; then
    NOTICE="$NOTICE

Awareness Scripts
-----------------"
    for script in "$AWARENESS_DIR"/*.sh; do
        [ -f "$script" ] || continue
        name=$(basename "$script")
        # Skip the raw helper
        [ "$name" = "context-usage.sh" ] && continue
        # Get first comment line for description
        desc=$(grep -m1 '^# Awareness:' "$script" 2>/dev/null | sed 's/^# Awareness: //' || true)
        [ -z "$desc" ] && desc=$(grep -m1 '^#[^!]' "$script" 2>/dev/null | sed 's/^# *//' || true)
        NOTICE="$NOTICE
- $name: $desc"
    done
fi

# Show to human on terminal
echo "" > /dev/tty 2>/dev/null || true
echo "$NOTICE" > /dev/tty 2>/dev/null || true
echo "" > /dev/tty 2>/dev/null || true

# Inject into Claude's context via stdout
echo "$NOTICE"
