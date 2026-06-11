#!/bin/bash

# CodexGauge — CLI build + smoke test

set -e

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: macOS only" >&2
    exit 1
fi

if ! command -v swift &> /dev/null; then
    echo "Error: Swift not installed" >&2
    exit 1
fi

echo "Building CodexGauge CLI..."
swift build -c release

BIN="./.build/release/CodexGauge"
echo ""
echo "Built: $BIN"
echo ""
echo "Try:"
echo "  $BIN help"
echo "  $BIN usage --auto-detect --raw -v"
echo "  $BIN refresh --auto-detect --raw -v"
