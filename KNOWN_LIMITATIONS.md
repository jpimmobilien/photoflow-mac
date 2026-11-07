# Known limitations

## Distribution
- **No Developer ID signature / notarization.** No Apple Developer credentials were available, so the app is **ad-hoc signed** (required for Apple Silicon) and **not notarized**. On first launch macOS shows a warning: right-click the app ▸ *Open* ▸ *Open*, or System Settings ▸ Privacy & Security ▸ *Open Anyway*. `Scripts/build_app.sh` signs with hardened runtime and notarizes automatically when `SIGN_IDENTITY` and `NOTARY_PROFILE` are provided.
- The app is **not sandboxed** (like the earlier AndroidBridge / Music Library builds). This lets it reference originals anywhere without copying them. Sandbox-ready code paths (security-scoped bookmarks) exist but an App Store build would need entitlements and a sandbox review.

## "AI" scope
- PhotoFlow uses Apple's built-in on-device models via Vision plus its own computer-vision algorithms. It does **not** bundle a generative or learned enhancement model (no "neural" retouching, relighting, denoising or upscaling). This keeps it offline, small (no model download) and Intel-compatible.
- `VNCalculateImageAestheticsScoresRequest` exists only on macOS 15+; on 13–14 the keep recommendation uses technical quality factors only.
- Scene classification labels are Apple's taxonomy; unusual scenes may get no or generic labels, which simply means neutral default targets.

## Image processing
- Auto Enhance is rule-based and conservative by design; strongly stylised photos (e.g. deliberate high-key or low-key looks not recognised as such) may be nudged toward neutral. Use *Subtle* or adjust afterwards.
- White balance cannot know the "true" scene colour; images without neutral surfaces (e.g. a green forest, a red wall) are corrected with reduced confidence.
- Auto Straighten only corrects tilts between 0.15° and 10° with sufficient confidence; larger tilts are treated as intentional. Photos without straight lines or a horizon (portraits, close-ups, foliage) are left unchanged.
- Auto Perspective corrects vertical convergence automatically; horizontal keystone only for frontal facades/documents. Two-point perspective of buildings photographed at an angle is not "flattened". Freehand quad (four-corner) editing is not offered; Document mode uses Vision's rectangle detector.
- There is no free-form crop tool in the editor (automatic inscribed crop after straighten/perspective, and aspect-ratio/border crops in batch workflows).
- RAW files are developed with Core Image's default RAW settings; there are no RAW-specific controls (lens profiles, highlight reconstruction settings). RAW export produces a rendered JPEG/HEIC/TIFF/PNG — writing RAW/DNG is not supported.
- WebP and HEIC export depend on what ImageIO on the running Mac can encode; unavailable formats are hidden.
- The 1:1 zoom view is capped at 6,000 px on the long side to stay usable on 8 GB Intel Macs.

## Duplicates
- Similarity scores are calibrated heuristics, not guarantees. Two different photos of the same subject (e.g. two portraits of the same person in the same place) can score as "Similar"; always review before deleting.
- Rotated duplicates (90°) are found through the feature print only; heavy crops (< ~40 % of the original) may be missed.
- Analysis caches are invalidated by file size/date changes, not by content changes that keep both identical (extremely rare).

## Library
- Single library per macOS user, stored in `~/Library/Application Support/PhotoFlow`. No iCloud sync and no Apple Photos library integration (Photos libraries are packages and are skipped during folder import).
- Files moved to a different volume while PhotoFlow is closed are shown as missing (bookmarks only follow moves on the same volume) — use "Locate Original…".
- Restoring from Trash requires the file to still be in the macOS Trash.

## Platform
- macOS 13 Ventura or newer. Liquid Glass appears on macOS 26 only when the app is built with the macOS 26 SDK (Xcode 26); older SDK builds and older macOS versions use the material-based design.
- Running from Xcode (Package.swift) does not include the bundle's Info.plist, icon and localizations — use `Scripts/build_app.sh`.
