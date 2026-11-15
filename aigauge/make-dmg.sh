#!/bin/bash
#
# Build a styled drag-to-Applications DMG from aigauge/release/AIGauge.app.
#
# Uses only macOS built-ins (hdiutil + osascript) — no external deps.
# Output: aigauge/release/AIGauge.dmg

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$SCRIPT_DIR/release"
APP="$RELEASE_DIR/AIGauge.app"
DMG="$RELEASE_DIR/AIGauge.dmg"
VOL_NAME="AIGauge"

# Build the .app first if missing.
if [ ! -d "$APP" ]; then
    echo "==> AIGauge.app not found, invoking build.sh"
    "$SCRIPT_DIR/build.sh"
fi

# 1. Stage the contents in a temp dir: the .app + a symlink to /Applications.
STAGING="$(mktemp -d)/dmg-stage"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 2. Create a writable temporary DMG so we can style the Finder window.
TMP_DMG="$(mktemp -t aigauge-tmp).dmg"
rm -f "$TMP_DMG"
echo "==> Creating writable DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    "$TMP_DMG" >/dev/null

# 3. Mount at the standard /Volumes path so Finder can address it by disk name.
echo "==> Mounting and styling"
hdiutil attach "$TMP_DMG" -noverify -noautoopen >/dev/null
MOUNT_DIR="/Volumes/$VOL_NAME"

# Poll until Finder sees the disk (up to ~10s).
for i in 1 2 3 4 5 6 7 8 9 10; do
    if /usr/bin/osascript -e "tell application \"Finder\" to exists disk \"$VOL_NAME\"" 2>/dev/null | grep -q true; then
        break
    fi
    sleep 1
done

/usr/bin/osascript <<EOF || echo "   (warning: Finder styling failed — DMG is still functional)"
tell application "Finder"
    activate
    tell disk "$VOL_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        try
            set sidebar width of container window to 0
        end try
        set the bounds of container window to {200, 200, 800, 580}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        set position of item "AIGauge.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
sleep 1
hdiutil detach "$MOUNT_DIR" -force >/dev/null

# 4. Convert to compressed read-only DMG (the user-facing artifact).
rm -f "$DMG"
echo "==> Compressing"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGING" "$MOUNT_DIR"

SIZE=$(du -h "$DMG" | cut -f1)
echo ""
echo "Done: $DMG ($SIZE)"
echo ""
echo "Test it:"
echo "  open $DMG"
echo ""
echo "When the Finder window opens you should see AIGauge.app on the left and"
echo "Applications on the right — drag the app icon onto the folder to install."
