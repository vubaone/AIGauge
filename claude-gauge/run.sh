#!/bin/bash

# ClaudeGauge — CLI build + smoke test
# Builds the CLI in release mode and runs `usage --json` as a smoke test.

set -e

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: macOS only (uses Keychain + Chrome/Brave/Claude cookie DBs)" >&2
    exit 1
fi

if ! command -v swift &> /dev/null; then
    echo "Error: Swift not installed. Install Xcode or the Swift toolchain." >&2
    exit 1
fi

echo "Building ClaudeGauge CLI..."
swift build -c release

BIN="./.build/release/ClaudeGauge"
echo ""
echo "Built: $BIN"
echo ""
echo "Try:"
echo "  $BIN help"
echo "  $BIN usage --json"
echo "  $BIN refresh --json"
echo ""
echo "Smoke test (usage):"
"$BIN" usage || true
