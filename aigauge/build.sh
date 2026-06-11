#!/bin/bash
#
# Builds ClaudeGauge, CodexGauge, and AIGauge in release mode, then assembles
# a drag-to-/Applications macOS .app bundle that embeds both CLIs.
#
# Outputs in aigauge/release/:
#   AIGauge.app/         — drag this into /Applications
#   AIGauge.app.zip      — same, zipped for distribution
#   ClaudeGauge           — standalone CLI (also embedded inside the .app)
#   CodexGauge            — standalone CLI (also embedded inside the .app)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$SCRIPT_DIR/release"
APP_DIR="$RELEASE_DIR/AIGauge.app"

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: macOS only." >&2
    exit 1
fi
if ! command -v swift &> /dev/null; then
    echo "Error: Swift not installed (need Xcode CLT or swift.org toolchain)." >&2
    exit 1
fi

build_package() {
    local name="$1"
    local dir="$2"
    echo "==> Building $name"
    ( cd "$dir" && swift build -c release )
}

build_package "ClaudeGauge" "$ROOT_DIR/claude-gauge"
build_package "CodexGauge"  "$ROOT_DIR/codex-gauge"
build_package "AIGauge"    "$SCRIPT_DIR"

mkdir -p "$RELEASE_DIR"

# --- Standalone binaries (for users who only want the CLIs) ---
# Remove any stale flat AIGauge binary — the GUI now lives only in the .app.
rm -f "$RELEASE_DIR/AIGauge"
echo "==> Staging standalone CLI binaries into release/"
cp "$ROOT_DIR/claude-gauge/.build/release/ClaudeGauge" "$RELEASE_DIR/"
cp "$ROOT_DIR/codex-gauge/.build/release/CodexGauge"   "$RELEASE_DIR/"

# --- .app bundle ---
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$SCRIPT_DIR/Info.plist"                       "$APP_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/.build/release/AIGauge"          "$APP_DIR/Contents/MacOS/AIGauge"
cp "$ROOT_DIR/claude-gauge/.build/release/ClaudeGauge"  "$APP_DIR/Contents/Resources/ClaudeGauge"
cp "$ROOT_DIR/codex-gauge/.build/release/CodexGauge"    "$APP_DIR/Contents/Resources/CodexGauge"

# --- AppIcon.icns from resources/icon.png ---
ICON_SRC="$ROOT_DIR/resources/icon.png"
if [ -f "$ICON_SRC" ] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
    echo "==> Generating AppIcon.icns from resources/icon.png"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16   16   "$ICON_SRC" --out "$ICONSET/icon_16x16.png"       >/dev/null
    sips -z 32   32   "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
    sips -z 32   32   "$ICON_SRC" --out "$ICONSET/icon_32x32.png"       >/dev/null
    sips -z 64   64   "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
    sips -z 128  128  "$ICON_SRC" --out "$ICONSET/icon_128x128.png"     >/dev/null
    sips -z 256  256  "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
    sips -z 256  256  "$ICON_SRC" --out "$ICONSET/icon_256x256.png"     >/dev/null
    sips -z 512  512  "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
    sips -z 512  512  "$ICON_SRC" --out "$ICONSET/icon_512x512.png"     >/dev/null
    cp           "$ICON_SRC"            "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "   (warning: resources/icon.png missing or sips/iconutil unavailable — no app icon)"
fi

# Ad-hoc sign (no developer ID needed). Required on Apple Silicon for the
# bundle to launch without "is damaged" errors after copying around.
echo "==> Ad-hoc signing the bundle"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "   (warning: codesign failed — app may need manual approval on first launch)"

# --- Zip the .app for easy sharing ---
echo "==> Zipping $APP_DIR"
( cd "$RELEASE_DIR" && rm -f AIGauge.app.zip && /usr/bin/zip -qry AIGauge.app.zip AIGauge.app )

echo ""
echo "Done."
echo ""
echo "Install:"
echo "  open $RELEASE_DIR        # then drag AIGauge.app to /Applications"
echo ""
echo "Or run in place:"
echo "  open $APP_DIR"
echo ""
echo "Standalone CLIs (optional, separate from the .app):"
echo "  $RELEASE_DIR/ClaudeGauge"
echo "  $RELEASE_DIR/CodexGauge"
