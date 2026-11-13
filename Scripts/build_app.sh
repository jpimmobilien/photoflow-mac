#!/bin/bash
# Builds PhotoFlow.app as a Universal Binary (arm64 + x86_64) and – unless NO_DMG=1 – PhotoFlow.dmg.
#
# Works with full Xcode or with the Command Line Tools only (Swift 6 toolchain required).
#
# Optional environment variables:
#   VERSION=1.0.0 BUILD=1                 bundle version
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   otherwise ad-hoc signing
#   NOTARY_PROFILE=profile-name           xcrun notarytool keychain profile → notarize + staple the DMG
#   NO_DMG=1                              skip the disk image
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
OUT="$ROOT/build"
APP="$OUT/PhotoFlow.app"
read -r -a ARCHS <<< "${ARCHS:-arm64 x86_64}"

echo "▸ Toolchain"
swift --version 2>&1 || true
xcrun --show-sdk-version 2>/dev/null | sed 's/^/  macOS SDK /' || true

mkdir -p "$OUT"
BINARIES=()
for arch in "${ARCHS[@]}"; do
    echo "▸ Compiling for $arch (release)"
    swift build -c release --package-path "$ROOT" --scratch-path "$OUT/.build-$arch" \
        --triple "$arch-apple-macosx13.0" > "$OUT/swift-build-$arch.log" 2>&1 || {
            echo "✗ compile errors ($arch):"; grep -E "error:" "$OUT/swift-build-$arch.log" | sort -u | head -n 200
            tail -n 40 "$OUT/swift-build-$arch.log"; exit 1; }
    tail -n 15 "$OUT/swift-build-$arch.log"
    BIN_DIR="$(swift build -c release --package-path "$ROOT" --scratch-path "$OUT/.build-$arch" --triple "$arch-apple-macosx13.0" --show-bin-path)"
    test -x "$BIN_DIR/PhotoFlow" || { echo "✗ build for $arch failed"; exit 1; }
    BINARIES+=("$BIN_DIR/PhotoFlow")
done

echo "▸ Assembling PhotoFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/PhotoFlow"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/BrandMark.png" "$APP/Contents/Resources/BrandMark.png"
for lproj in "$ROOT"/Resources/*.lproj; do
    name="$(basename "$lproj")"
    mkdir -p "$APP/Contents/Resources/$name"
    for f in "$lproj"/*.strings; do
        # Compile to binary plist (faster to load); validates the syntax at the same time.
        plutil -convert binary1 -o "$APP/Contents/Resources/$name/$(basename "$f")" "$f"
    done
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ Architectures: $(lipo -archs "$APP/Contents/MacOS/PhotoFlow")"
for arch in "${ARCHS[@]}"; do
    lipo "$APP/Contents/MacOS/PhotoFlow" -verify_arch "$arch" || { echo "✗ missing $arch slice"; exit 1; }
done

echo "▸ Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad-hoc signature: required for Apple Silicon. Gatekeeper will ask the user to confirm the first launch.
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [[ "${NO_DMG:-0}" != "1" ]]; then
    "$ROOT/Scripts/make_dmg.sh" "$APP" "$OUT/PhotoFlow.dmg"
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" "$OUT/PhotoFlow.dmg"
    fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "▸ Notarizing"
        xcrun notarytool submit "$OUT/PhotoFlow.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$OUT/PhotoFlow.dmg"
    fi
fi

echo "✓ Done: $APP"
if [[ -f "$OUT/PhotoFlow.dmg" && "${NO_DMG:-0}" != "1" ]]; then
    echo "✓ Done: $OUT/PhotoFlow.dmg ($(du -h "$OUT/PhotoFlow.dmg" | cut -f1))"
fi
exit 0
