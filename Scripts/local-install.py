#!/usr/bin/env python3
"""Build and install a signed Release app using isolated local artifacts."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Rocuronium.app"
LABEL = "glass.kagerou.rocuronium"
MACH_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
)}


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, **kwargs)


def signing_identity():
    override = os.environ.get("ROCURONIUM_SIGNING_IDENTITY")
    if override:
        return override
    project = (ROOT / "Rocuronium.xcodeproj/project.pbxproj").read_text()
    teams = set(re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", project))
    identities = run("security", "find-identity", "-v", "-p", "codesigning",
                     capture_output=True, text=True).stdout
    matches = re.findall(r'([A-F0-9]{40}) "Developer ID Application: .*?\(([A-Z0-9]+)\)"', identities)
    eligible = [identity for identity, team in matches if team in teams]
    if len(eligible) != 1:
        raise RuntimeError("Set ROCURONIUM_SIGNING_IDENTITY to one Developer ID Application identity for this project's team")
    return eligible[0]


def nested_code(app):
    contents = app / "Contents"
    bundles = []
    for directory in ("PlugIns", "Extensions", "Helpers", "Frameworks",
                      "Library/LaunchAgents", "Library/LaunchDaemons"):
        folder = contents / directory
        if folder.exists():
            bundles.extend(path for path in folder.iterdir() if path.is_dir())
    for path in sorted(contents.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_symlink() or not path.is_file() or path == contents / "MacOS/Rocuronium":
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACH_MAGICS:
                yield path
    yield from sorted(bundles, key=lambda item: len(item.parts), reverse=True)


def install(app):
    run("codesign", "--verify", "--deep", "--strict", app)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=False)
    subprocess.run(["pkill", "-u", str(os.getuid()), "-x", "Rocuronium"], check=False)
    destination = Path("/Applications") / APP_NAME
    if destination.exists():
        run("trash", destination)
    run("ditto", app, destination)
    run("codesign", "--verify", "--deep", "--strict", destination)
    run(ROOT / "Scripts/install-launchagent.sh")
    print(f"Installed {destination}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="install the last verified local build")
    args = parser.parse_args()
    cache = Path.home() / "Library/Caches/glass.kagerou.rocuronium/local-install"
    cache.mkdir(parents=True, exist_ok=True)
    last_build = cache / "last-build.txt"
    if args.skip_build:
        install(Path(last_build.read_text().strip()))
        return

    identity = signing_identity()
    staging = Path(tempfile.mkdtemp(prefix="build-", dir=cache))
    print(f"Local build: {staging}", flush=True)
    archive = staging / "Rocuronium.xcarchive"
    derived = Path(os.environ.get("ROCURONIUM_DERIVED_DATA", str(cache / "DerivedData")))
    run("xcodebuild", "archive", "-project", ROOT / "Rocuronium.xcodeproj",
        "-scheme", "Rocuronium", "-configuration", "Release",
        "-archivePath", archive, "-derivedDataPath", derived,
        "-allowProvisioningUpdates", "-skipPackagePluginValidation", "-skipMacroValidation",
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "SWIFT_COMPILATION_MODE=incremental")
    app = archive / "Products/Applications" / APP_NAME
    run(ROOT / "Scripts/embed-cli.sh", app)
    for code in [*nested_code(app), app]:
        run("codesign", "--force", "--options", "runtime", "--sign", identity,
            "--timestamp", "--preserve-metadata=entitlements", code)
    run("codesign", "--verify", "--deep", "--strict", app)
    last_build.write_text(str(app) + "\n")
    install(app)


if __name__ == "__main__":
    main()
