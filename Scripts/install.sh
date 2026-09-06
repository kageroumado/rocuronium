#!/bin/bash
# Build Rocuronium and install it to /Applications for local testing.
#
# Rilmazafone (the `.releaseplan`) does the build, inside-out Developer ID signing, and the
# DMG — everything the old hand-rolled release did. This script adds the one thing it does
# not: installing the result over the running daemon and restarting it, so you test on the
# same signed Release bundle the control socket's peer check trusts. `--republish` keeps the
# version (no bump for a local build), and `--skip-notarize` skips the minutes-long Apple
# round trip — a locally built bundle runs without a ticket, and the socket check wants the
# Developer ID signature, not notarization.
#
# The real release is `kagerou publish rocuronium` (or `Rilmazafone release build <plan>`
# for a full notarized dry run).
#
# Usage: Scripts/install.sh [--skip-build]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN="${ROCURONIUM_RELEASEPLAN:-$HOME/Developer/infrastructure/publish/plans/rocuronium.releaseplan}"
RILMAZAFONE="/Applications/Rilmazafone.app/Contents/MacOS/Rilmazafone"
APP_NAME="Rocuronium.app"
LABEL="glass.kagerou.rocuronium"

[ -x "$RILMAZAFONE" ] || { echo "Rilmazafone is not installed at $RILMAZAFONE — install it first"; exit 1; }
[ -d "$PLAN" ] || { echo "no release plan at $PLAN (set ROCURONIUM_RELEASEPLAN to override)"; exit 1; }

if [ "${1:-}" != "--skip-build" ]; then
    echo "==> Building (Rilmazafone: no version bump, no notarization)"
    "$RILMAZAFONE" release build "$PLAN" --republish --skip-notarize
fi

echo "==> Locating the built DMG"
DMG=$("$RILMAZAFONE" release status "$PLAN" | awk -F'dmg: ' '/^  dmg: /{sub(/ \([^)]*\).*$/,"",$2); print $2; exit}')
[ -f "$DMG" ] || { echo "no built DMG found — run without --skip-build first"; exit 1; }

MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -nobrowse -mountpoint "$MOUNT" -quiet

echo "==> Installing to /Applications"
# Stop the running daemon so it releases the control socket before the bundle is replaced.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x Rocuronium 2>/dev/null || true
sleep 1
# The old bundle must go first: ditto *merges* into an existing directory, and files from a
# previous build left inside a sealed bundle fail strict signature validation.
trash "/Applications/$APP_NAME" 2>/dev/null || true
ditto "$MOUNT/$APP_NAME" "/Applications/$APP_NAME"

"$PROJECT_DIR/Scripts/install-launchagent.sh"

echo
echo "Done. Installed /Applications/$APP_NAME"
echo "Embedded CLI: /Applications/$APP_NAME/Contents/Resources/rocuronium"
