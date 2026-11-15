#!/bin/bash
set -e
cd "$(dirname "$0")"
ROOT_DIR="$(cd .. && pwd)"
mkdir -p "$ROOT_DIR/cache/clang" "$ROOT_DIR/temp"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/cache/clang"
export TMPDIR="$ROOT_DIR/temp/"
swift build -c release --build-system native \
    --cache-path "$ROOT_DIR/cache/swiftpm" \
    --config-path "$ROOT_DIR/cache/swiftpm-config" \
    --security-path "$ROOT_DIR/cache/swiftpm-security"
echo 'Try: .build/release/MistralGauge usage --source edge --json'
echo 'For a non-default profile, add: --profile "Profile 1"'
