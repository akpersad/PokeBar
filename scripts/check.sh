#!/bin/bash
# Pre-push gate. Run this instead of `swift test` directly.
#
# `xcode-select -p` on this machine points at /Library/Developer/CommandLineTools,
# which ships no XCTest, so `swift test` fails with "no such module 'XCTest'".
# Scoping DEVELOPER_DIR here fixes it per invocation without `sudo xcode-select -s`
# changing a global machine setting.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "✗ DEVELOPER_DIR not found: $DEVELOPER_DIR" >&2
    echo "  Point it at an Xcode.app that contains XCTest." >&2
    exit 1
fi

echo "==> toolchain"
swift --version | head -1

echo "==> build"
swift build --package-path "$ROOT"

echo "==> test"
swift test --package-path "$ROOT"

# Opt-in: reads the live ~/.claude/projects tree (hundreds of MB) and prints
# real totals. Not part of the default gate because it is not hermetic.
if [ "${POKEBAR_CORPUS:-0}" = "1" ]; then
    echo "==> corpus parity (live ~/.claude/projects)"
    swift test --package-path "$ROOT" --filter CorpusParityTests
fi

echo "✓ all checks passed"
