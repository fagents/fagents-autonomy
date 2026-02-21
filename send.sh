#!/bin/bash
# Send a message to the comms channel
#
# Local:  ./send.sh Juho "Check the new observation"
# Remote: ssh host "cd ~/workspace/red-team-imagine && autonomy/send.sh Juho 'Check the new observation'"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <sender> <message>"
    echo "  e.g.: $0 Juho \"Hey, check obs 054\""
    echo "  e.g.: $0 Freeclaw \"Analysis complete\""
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENDER="$1"
shift
MESSAGE="$*"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M %Z')

mkdir -p "$SCRIPT_DIR/comms"
echo "[$TIMESTAMP] [$SENDER] $MESSAGE" >> "$SCRIPT_DIR/comms/channel.log"

# Regenerate HTML viewer if python3 is available
if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/comms/viewer.py" ]; then
    python3 "$SCRIPT_DIR/comms/viewer.py" 2>/dev/null
fi
