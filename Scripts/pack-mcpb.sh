#!/bin/bash
# Pack a released Rocuronium's CLI into an MCP Bundle (.mcpb) and point server.json at it.
#
# The bundle carries the CLI exactly as the release shipped it — Developer ID signed and
# notarized inside Rocuronium.app — because the control socket admits only peers signed by the
# team (ControlServer's peer check), and a rebuilt or re-signed binary would be refused. So the
# input is the published DMG, never a local build. Run it after `kagerou publish rocuronium`.
#
# The manifest's tool list is read from the binary's own `tools/list`, so it cannot drift from
# MCPServer.tools.
#
# Usage: Scripts/pack-mcpb.sh <version>             e.g. 1.2 — fetches Rocuronium-1.2.dmg from release v1.2
#        Scripts/pack-mcpb.sh <version> <path.dmg|path.app>

set -euo pipefail

VERSION="${1:?usage: Scripts/pack-mcpb.sh <version> [Rocuronium.dmg|Rocuronium.app]}"
SOURCE="${2:-}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="52K336H235"
MCPB_CLI="@anthropic-ai/mcpb@2.1.2"
ASSET="rocuronium-$VERSION.mcpb"
# Release tags are two-part (v1.2); the registry sorts versions as semver and marks any
# unparseable one "latest" unconditionally, so the metadata carries the three-part form.
SEMVER="$VERSION"
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+$ ]] && SEMVER="$SEMVER.0"

if [ -d /Volumes/Ugreen ]; then
    WORK="/Volumes/Ugreen/Build/rocuronium/mcpb/$VERSION"
else
    WORK="${TMPDIR:-/tmp}/rocuronium-mcpb/$VERSION"
fi
STAGE="$WORK/stage"
[ -e "$WORK" ] && trash "$WORK"
mkdir -p "$STAGE/server"

if [ -z "$SOURCE" ]; then
    echo "==> Downloading Rocuronium-$VERSION.dmg from release v$VERSION"
    gh release download "v$VERSION" -R kageroumado/rocuronium -p "Rocuronium-$VERSION.dmg" -D "$WORK"
    SOURCE="$WORK/Rocuronium-$VERSION.dmg"
fi

if [[ "$SOURCE" == *.dmg ]]; then
    MOUNT="$WORK/mount"
    mkdir -p "$MOUNT"
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MOUNT" "$SOURCE"
    trap 'hdiutil detach -quiet "$MOUNT" || true' EXIT
    APP="$MOUNT/Rocuronium.app"
else
    APP="$SOURCE"
fi

SHIPPED_VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
[ "$SHIPPED_VERSION" = "$VERSION" ] || { echo "app is $SHIPPED_VERSION, expected $VERSION"; exit 1; }

echo "==> Copying the signed CLI out of $APP"
CLI="$STAGE/server/rocuronium"
ditto "$APP/Contents/Resources/rocuronium" "$CLI"

echo "==> Verifying its signature and notarization"
codesign --verify --strict -R="identifier \"rocuronium\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$CLI"
spctl --assess --type install -vv "$CLI" 2>&1 | grep -q "source=Notarized Developer ID" \
    || { echo "the CLI is not notarized — pack from a published release"; exit 1; }

echo "==> Writing the manifest"
ditto "$PROJECT_DIR/.github/rocuronium-icon.png" "$STAGE/icon.png"
python3 - "$PROJECT_DIR/MCPB/manifest.json" "$STAGE/manifest.json" "$CLI" "$SEMVER" <<'PY'
import json, subprocess, sys

template, output, cli, version = sys.argv[1:]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "pack-mcpb", "version": version}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]
server = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
for request in requests:
    server.stdin.write(json.dumps(request) + "\n")
server.stdin.flush()
tools = None
for line in server.stdout:
    message = json.loads(line)
    if message.get("id") == 2:
        tools = message["result"]["tools"]
        break
server.stdin.close()
server.wait(timeout=10)
if not tools:
    sys.exit("tools/list returned nothing")

manifest = json.load(open(template))
manifest["version"] = version
# The first paragraph of each description; the full contract reaches the client from the server.
manifest["tools"] = [
    {"name": tool["name"], "description": tool["description"].split("\n\n")[0].strip()}
    for tool in tools
]
json.dump(manifest, open(output, "w"), indent=2, ensure_ascii=False)
print(f"   {len(tools)} tools")
PY

echo "==> Packing $ASSET"
npx -y "$MCPB_CLI" validate "$STAGE/manifest.json"
npx -y "$MCPB_CLI" pack "$STAGE" "$WORK/$ASSET"
SHA="$(shasum -a 256 "$WORK/$ASSET" | cut -d' ' -f1)"

echo "==> Pointing server.json at it"
python3 - "$PROJECT_DIR/server.json" "$SEMVER" "v$VERSION/$ASSET" "$SHA" <<'PY'
import json, sys

path, version, asset, sha = sys.argv[1:]
server = json.load(open(path))
server["version"] = version
package = server["packages"][0]
package["version"] = version
package["identifier"] = f"https://github.com/kageroumado/rocuronium/releases/download/{asset}"
package["fileSha256"] = sha
with open(path, "w") as file:
    json.dump(server, file, indent=2, ensure_ascii=False)
    file.write("\n")
PY

echo
echo "Bundle:  $WORK/$ASSET"
echo "SHA-256: $SHA"
echo "Next:    gh release upload v$VERSION \"$WORK/$ASSET\" -R kageroumado/rocuronium"
echo "         mcp-publisher validate && mcp-publisher publish"
