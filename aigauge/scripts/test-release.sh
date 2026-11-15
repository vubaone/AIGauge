#!/usr/bin/env bash
# Desktop-free checks. No app launch, browser session, real Keychain, or simulator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
mkdir -p "$ROOT_DIR/temp/release-tests" "$ROOT_DIR/cache/clang"
export TMPDIR="$ROOT_DIR/temp/release-tests/"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/cache/clang"
export PYTHONDONTWRITEBYTECODE=1
cd "$ROOT_DIR"
"$ROOT_DIR/make_version.sh" --check
python3 -B -m unittest discover -s "$SCRIPT_DIR/tests" -v
for package in claude-gauge codex-gauge mistral-gauge aigauge; do
    swift test --build-system native --package-path "$ROOT_DIR/$package" \
        --cache-path "$ROOT_DIR/cache/swiftpm" \
        --config-path "$ROOT_DIR/cache/swiftpm-config" \
        --security-path "$ROOT_DIR/cache/swiftpm-security" \
        2>&1 | tee "$ROOT_DIR/temp/release-tests/$package.log"
done
python3 -B "$SCRIPT_DIR/verify-test-logs.py" "$ROOT_DIR/temp/release-tests"
