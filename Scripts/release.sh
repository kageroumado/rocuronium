#!/bin/bash
# Build, sign, notarize, and staple Rocuronium.
#
# The CLI is embedded in the app bundle rather than shipped separately, for two reasons:
# one notarization covers both, and — more importantly — it means the CLI carries the same
# Developer ID signature as the app, which is what lets the control socket verify that the
# process talking to it is one of ours rather than any local program.
#
# Usage: Scripts/release.sh [--install]

set -euo pipefail

IDENTITY="Developer ID Application: Elysia Muñoz (52K336H235)"
TEAM_ID="52K336H235"
NOTARY_PROFILE="kagerou-notary"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Rocuronium.app"

cd "$PROJECT_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# The fresh DerivedData below has no plugin trust record, so mlx-swift's CudaBuild plugin
# fails validation without the skip flags; xcodebuild cannot prompt for trust.
echo "==> Building the app (Release, Developer ID)"
xcodebuild -project Rocuronium.xcodeproj -scheme Rocuronium -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build >"$BUILD_DIR/xcodebuild.log" 2>&1 ||
    { tail -30 "$BUILD_DIR/xcodebuild.log"; exit 1; }

APP="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME"
[ -d "$APP" ] || { echo "no app produced at $APP"; exit 1; }

# The guide-embed + CLI-build + CLI-embed the release pipeline does not know about, factored
# out so the pipeline can call the same script as a post-archive / pre-sign hook.
"$PROJECT_DIR/Scripts/embed-cli.sh" "$APP"

# Inner binaries first, then the bundle: signing the outer bundle seals the inner signatures,
# so doing it the other way round produces a bundle that fails validation.
echo "==> Signing"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/rocuronium"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing (this takes a few minutes)"
ZIP="$BUILD_DIR/Rocuronium.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t exec "$APP" 2>&1 || true

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    # -x, not -f "$APP_NAME": the -f pattern also matches every CLI/MCP process whose
    # *path* contains Rocuronium.app, killing clients that would have reconnected anyway.
    launchctl bootout "gui/$UID/glass.kagerou.rocuronium" 2>/dev/null || true
    pkill -x Rocuronium 2>/dev/null || true
    sleep 1
    # The old bundle must go first: ditto *merges* into an existing directory, and files
    # from a previous build left inside a sealed bundle fail strict signature validation.
    trash "/Applications/$APP_NAME" 2>/dev/null || true
    ditto "$APP" "/Applications/$APP_NAME"
    "$PROJECT_DIR/Scripts/install-launchagent.sh"
fi

echo
echo "Done. App: $APP"
echo "Embedded CLI: /Applications/$APP_NAME/Contents/Resources/rocuronium"
