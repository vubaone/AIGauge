#!/bin/bash

# ClaudeGauge - Build Script

set -e

echo "Building ClaudeGauge..."

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: This application only works on macOS"
    exit 1
fi

# Check if Swift is installed
if ! command -v swift &> /dev/null; then
    echo "Error: Swift is not installed. Please install Xcode or Swift toolchain."
    exit 1
fi

# Build the project
swift build -c release

echo "✅ Build complete!"
echo ""
echo "The executable is located at: .build/release/ClaudeGauge"
echo ""
echo "To run: ./.build/release/ClaudeGauge"
