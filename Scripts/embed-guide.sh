#!/bin/bash
# Regenerate the CLI's embedded operator guide from Docs/GUIDE.md.
#
# GUIDE.md is the full operator manual; this bakes it into the binary so
# `rocuronium guide` works with nothing but the CLI on hand. Called by
# embed-cli.sh before the CLI build; the generated file is committed so a
# plain `swift build` still compiles without running this.

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$PROJECT_DIR/Docs/GUIDE.md"
TARGET="$PROJECT_DIR/RocuroniumCLI/Sources/rocuronium/Guide.generated.swift"

{
    echo "// Generated from Docs/GUIDE.md by Scripts/embed-guide.sh — edit the guide, not this."
    echo "enum Guide {"
    echo '    static let text = ##"""'
    cat "$SOURCE"
    echo '"""##'
    echo "}"
} > "$TARGET"

echo "embedded $(wc -l < "$SOURCE" | tr -d ' ') lines of GUIDE.md into Guide.generated.swift"
