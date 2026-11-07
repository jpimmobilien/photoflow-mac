# Build instructions

## Requirements

- A Mac (Intel or Apple Silicon) with **Xcode 16 or newer** (Swift 6 toolchain). The Command Line Tools alone (`xcode-select --install`) are enough for `Scripts/build_app.sh`.
- Liquid Glass styling is compiled in when building with **Xcode 26 / Swift 6.2+** (macOS 26 SDK). With older toolchains the app automatically uses its material-based fallback design. Both builds run on macOS 13+.
- No third-party dependencies, no package downloads.

## One-step build (app + DMG)

```bash
cd PhotoFlow
./Scripts/build_app.sh
```

Produces:

- `build/PhotoFlow.app` – Universal Binary (`lipo -archs` → `x86_64 arm64`), ad-hoc signed
- `build/PhotoFlow.dmg` – compressed installer with background image and Applications shortcut

The script compiles each architecture separately (`swift build --triple <arch>-apple-macosx13.0`), merges them with `lipo`, assembles the bundle (Info.plist, icon, compiled `.strings`), verifies both architecture slices, signs and builds the DMG.

Options (environment variables):

| Variable | Effect |
|---|---|
| `VERSION=1.0.0 BUILD=1` | Bundle version |
| `SIGN_IDENTITY="Developer ID Application: … (TEAMID)"` | Real signing with hardened runtime instead of ad-hoc |
| `NOTARY_PROFILE=<keychain profile>` | Notarize and staple the DMG (`xcrun notarytool store-credentials` first) |
| `NO_DMG=1` | Skip the disk image |

## Working in Xcode

`File ▸ Open…` → select `Package.swift`. Choose the *PhotoFlow* scheme and *My Mac*. Running from Xcode starts the app without the bundled Info.plist/localizations (strings appear in English, the Dock icon is generic); use `Scripts/build_app.sh` for the real bundle.

## Tests

The test harness is part of the app binary, so it exercises exactly the shipping code:

```bash
APP=build/PhotoFlow.app/Contents/MacOS/PhotoFlow
$APP --qa info                                   # hardware, formats, Vision revision
$APP --qa selftest                               # deterministic checks (geometry, WB mapping, tone curve, export safety, Trash/restore)
$APP --qa gen ~/Pictures/Seeds /tmp/pf-dataset 40   # labelled dataset from your own photos
$APP --qa eval-dup /tmp/pf-dataset/dup
$APP --qa eval-straighten /tmp/pf-dataset/tilt
$APP --qa eval-wb /tmp/pf-dataset/wb
$APP --qa eval-perspective /tmp/pf-dataset/persp
$APP --qa batch /tmp/pf-dataset/dup 1000 [concurrency]   # throughput, peak memory, original protection
$APP --qa enhance photo.jpg /tmp/enhanced.jpg            # one photo, prints every decision
```

To test the Intel slice on Apple Silicon: `arch -x86_64 build/PhotoFlow.app/Contents/MacOS/PhotoFlow --qa selftest` (runs under Rosetta).

## Localization check

```bash
python3 Scripts/extract_strings.py            # verifies every UI string has a German translation
python3 Scripts/extract_strings.py --write-en # regenerates Resources/en.lproj/Localizable.strings
```

## If no DMG can be created

`build/PhotoFlow.app` is complete on its own: copy it to `/Applications`. `make_dmg.sh` needs `hdiutil` (always present on macOS); the Finder window layout step needs a logged-in GUI session and is skipped gracefully otherwise.
