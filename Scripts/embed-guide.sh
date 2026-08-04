#!/bin/bash
# Regenerate the CLI's embedded operator guide from README.md.
#
# README.md is the single source; this bakes it into the binary so `rocuronium guide`
# works with nothing but the CLI on hand — no repo, no docs directory, no skill. Called
# by release.sh before the CLI build; the generated file is committed so a plain
# `swift build` still compiles without running this.

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$PROJECT_DIR/README.md"
TARGET="$PROJECT_DIR/RocuroniumCLI/Sources/rocuronium/Guide.generated.swift"

# A raw string with enough pound signs that no README content can terminate it early.
{
    echo "// Generated from README.md by Scripts/embed-guide.sh — edit the README, not this."
    echo "enum Guide {"
    echo '    static let text = ##"""'
    cat "$SOURCE"
    echo '"""##'
    echo "}"
} > "$TARGET"

echo "embedded $(wc -l < "$SOURCE" | tr -d ' ') lines of README.md into Guide.generated.swift"
