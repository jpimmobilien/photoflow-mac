#!/bin/bash
# Creates a compressed, read-only installer disk image with a background, the app and an Applications link.
# Usage: make_dmg.sh <path/to/PhotoFlow.app> <output.dmg>
set -euo pipefail

APP="$1"
DMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOL="PhotoFlow"
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
trap 'hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "▸ Preparing disk image contents"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Retina-aware background (1x + 2x in one TIFF)
tiffutil -cathidpicheck "$ROOT/Packaging/dmg-background.png" "$ROOT/Packaging/dmg-background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
    || cp "$ROOT/Packaging/dmg-background.png" "$STAGE/.background/background.tiff"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW" -quiet

echo "▸ Arranging the window"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 1
# Finder layout via AppleScript (needs a logged-in GUI session; skipped gracefully otherwise).
osascript > /dev/null 2>&1 <<EOF &
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 562}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "PhotoFlow.app" of container window to {170, 205}
        set position of item "Applications" of container window to {490, 205}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
OSA_PID=$!
for _ in $(seq 1 60); do kill -0 "$OSA_PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$OSA_PID" 2>/dev/null; then
    kill "$OSA_PID" 2>/dev/null || true
    echo "  (Finder layout skipped – timed out waiting for Finder/automation permission; the DMG is still fully functional)"
elif wait "$OSA_PID"; then
    echo "  window layout applied"
else
    echo "  (Finder layout skipped – no GUI session or automation permission; the DMG is still fully functional)"
fi
SetFile -a C "/Volumes/$VOL" 2>/dev/null || true
sync
# Finder may still hold the volume for a moment – retry, then force.
osascript -e "tell application \"Finder\" to close every window" >/dev/null 2>&1 || true
DETACHED=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if hdiutil detach "$DEVICE" -quiet 2>/dev/null; then DETACHED=1; break; fi
    sleep 2
done
[[ $DETACHED == 1 ]] || hdiutil detach "$DEVICE" -force -quiet

echo "▸ Compressing"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
hdiutil verify "$DMG" -quiet && echo "  verified"
