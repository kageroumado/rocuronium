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
# **Release-state isolation.** `Rilmazafone release build` rewrites the app's build *record*
# (~/Library/Application Support/Rilmazafone/Records/<identity>.json) with an unpublished
# build at the current version, and clobbers that version's release DMG. Left alone, the next
# `kagerou publish rocuronium` ships THAT stale local build — it ships the waiting build and
# ignores `-v` — and collides on the already-published tag. So this script snapshots the
# record and its DMG before building and restores them after: a local install never disturbs
# the release state, and `kagerou publish` still bumps and builds fresh afterward.
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

# The build record this plan writes to, keyed by the plan's identity. Empty if it cannot be
# read — the script then falls back to the old behavior rather than guessing at a path.
RECORDS_DIR="$HOME/Library/Application Support/Rilmazafone/Records"
PLAN_IDENTITY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"])' "$PLAN/plan.json" 2>/dev/null || true)"
RECORD=""
[ -n "$PLAN_IDENTITY" ] && RECORD="$RECORDS_DIR/$PLAN_IDENTITY.json"

SNAPSHOT="$(mktemp -d)"
SNAPSHOT_TAKEN=0
MOUNT=""

# Put the release record — and the release DMG it names — back exactly as they were before
# this local build touched them. Runs from the EXIT trap, so it fires on failure too.
restore_release_state() {
    # Detach the mounted DMG first: restoring may overwrite its backing file.
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    if [ "$SNAPSHOT_TAKEN" = 1 ] && [ -n "$RECORD" ]; then
        if [ -f "$SNAPSHOT/record.json" ]; then
            cp "$SNAPSHOT/record.json" "$RECORD"
            if [ -f "$SNAPSHOT/prev.dmg" ] && [ -s "$SNAPSHOT/prev_dmg_path" ]; then
                cp "$SNAPSHOT/prev.dmg" "$(cat "$SNAPSHOT/prev_dmg_path")"
            fi
        else
            # No record existed before this run — drop the one the local build created.
            rm -f "$RECORD"
        fi
    fi
    rm -rf "$SNAPSHOT"
}
trap restore_release_state EXIT

if [ "${1:-}" != "--skip-build" ]; then
    # Snapshot the release state before the local build overwrites it.
    if [ -n "$RECORD" ]; then
        SNAPSHOT_TAKEN=1
        if [ -f "$RECORD" ]; then
            cp "$RECORD" "$SNAPSHOT/record.json"
            PREV_DMG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dmgPath",""))' "$RECORD" 2>/dev/null || true)"
            if [ -n "$PREV_DMG" ] && [ -f "$PREV_DMG" ]; then
                cp "$PREV_DMG" "$SNAPSHOT/prev.dmg"
                printf '%s' "$PREV_DMG" > "$SNAPSHOT/prev_dmg_path"
            fi
        fi
    fi

    echo "==> Building (Rilmazafone: no version bump, no notarization)"
    "$RILMAZAFONE" release build "$PLAN" --republish --skip-notarize
fi

echo "==> Locating the built DMG"
DMG=$("$RILMAZAFONE" release status "$PLAN" | awk -F'dmg: ' '/^  dmg: /{sub(/ \([^)]*\).*$/,"",$2); print $2; exit}')
[ -f "$DMG" ] || { echo "no built DMG found — run without --skip-build first"; exit 1; }

MOUNT="$(mktemp -d)"
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
