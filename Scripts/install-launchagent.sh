#!/bin/bash
# Register the daemon with launchd so it survives reboots and crashes.
#
# The agent's KeepAlive is SuccessfulExit=false: launchd respawns the daemon after a crash
# or a kill, but a clean Quit from the menu bar stays quit until the next login or an
# explicit `launchctl kickstart gui/$UID/glass.kagerou.rocuronium`.
#
# Usage: Scripts/install-launchagent.sh

set -euo pipefail

LABEL="glass.kagerou.rocuronium"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
cp "$SCRIPT_DIR/$LABEL.plist" "$DEST"

# Re-registering: drop any loaded copy, then stop an instance launchd is not managing
# (one started by `open` or Xcode) so bootstrap does not race it for the control socket.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x Rocuronium 2>/dev/null || true
sleep 1

launchctl bootstrap "gui/$UID" "$DEST"
launchctl print "gui/$UID/$LABEL" | grep -E 'state|pid' | head -3
echo "LaunchAgent installed at $DEST"
