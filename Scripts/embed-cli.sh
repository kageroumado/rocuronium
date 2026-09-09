#!/bin/bash
# Prepare a freshly built Rocuronium.app for signing: build the dependency-free SwiftPM CLI
# and copy it into Contents/Resources. One signature and one
# notarization then cover both, and the embedded CLI carries the app's Developer ID — which
# is what lets the control socket verify that a process talking to it is one of ours.
#
# This is the rocuronium-specific step the generic release pipeline does not know about.
# Rilmazafone (the `.releaseplan`) archives, signs inside-out, notarizes, builds the DMG,
# and releases — but it archives only the Xcode scheme, and the CLI is a separate SwiftPM
# package, so it must be embedded here BEFORE the pipeline's signing stage seals the bundle.
#
# Run it after the archive and before signing — the release pipeline calls it as its
# post-archive / pre-sign hook (`hooks.preSign` in the `.releaseplan`). The local
# `Scripts/install.sh` reaches it through that same pipeline.
#
# Usage: Scripts/embed-cli.sh <path-to-Rocuronium.app>

set -euo pipefail

APP="${1:?usage: Scripts/embed-cli.sh <path-to-Rocuronium.app>}"
[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "==> Baking the agent skill into the CLI"
python3 Scripts/embed-skill.py

echo "==> Building the CLI (release)"
(cd RocuroniumCLI && swift build -c release)
CLI="$PROJECT_DIR/RocuroniumCLI/.build/release/rocuronium"
[ -x "$CLI" ] || { echo "CLI not produced at $CLI"; exit 1; }

echo "==> Embedding the CLI"
# NOT Contents/MacOS/rocuronium: the filesystem is case-insensitive, so that path is the same
# file as the app's own "Rocuronium" executable and silently replaces it — the bundle then
# launches the CLI, which prints usage and exits. Resources/ keeps the clean binary name.
mkdir -p "$APP/Contents/Resources"
cp "$CLI" "$APP/Contents/Resources/rocuronium"
