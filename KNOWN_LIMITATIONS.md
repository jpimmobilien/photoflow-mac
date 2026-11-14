# Known limitations

## Distribution
- **No Developer ID signature / notarization.** No Apple Developer credentials were available, so the app is **ad-hoc signed** (required for Apple Silicon) and **not notarized**. On first launch macOS shows a warning: right-click the app ▸ *Open* ▸ *Open*, or System Settings ▸ Privacy & Security ▸ *Open Anyway*. `Scripts/build_app.sh` signs with hardened runtime and notarizes automatically when `SIGN_IDENTITY` and `NOTARY_PROFILE` are provided.
- The app is **not sandboxed** (like the earlier AndroidBridge / Music Library builds). This lets it reference originals anywhere without copying them. Sandbox-ready code paths (security-scoped bookmarks) exist but an App Store build would need entitlements and a sandbox review.

## "AI" scope
- The library, Auto Enhance, duplicates and batch features use Apple's built-in on-device models via Vision plus PhotoFlow's own computer-vision algorithms (no download needed).
- `VNCalculateImageAestheticsScoresRequest` exists only on macOS 15+; on 13–14 the keep recommendation uses technical quality factors only.
- Scene classification labels are Apple's taxonomy; unusual scenes may get no or generic labels, which simply means neutral default targets.

## AI Studio
- **Models are optional downloads** (1.1–7 GB for image generation, 2–190 MB for upscaling / removal); nothing generative is bundled in the DMG.
- **Fixed model sizes:** the Core ML diffusion models generate 512 × 512 (SD 2.1) or 1024 × 1024 (SDXL) squares. Other formats are cropped from the square; free resolutions are not offered. Larger output comes from Real-ESRGAN upscaling.
- **Inpainting / outpainting use the standard text-to-image UNets with masked latent blending**, not dedicated inpainting UNets (no Core ML inpainting model with a suitable licence and current Apple conversion exists). Results are good for textures, backgrounds and objects; very large masks over complex structures can look less coherent than a dedicated inpainting model. Outpainting works tile by tile at model resolution with real photo context; on large photos the new areas are still softer than the original, and very wide extensions can repeat motifs.
- **Intel Macs:** generation runs on the CPU/GPU without a Neural Engine and takes minutes per image; SDXL is not offered on Intel. Upscaling, object removal and enhancement run well.
- **Prompt understanding:** the CLIP text encoders understand English best. The prompt assistant can translate when Apple Intelligence is available (macOS 26 + Apple Silicon); otherwise it uses rule-based English templates.
- **Portrait retouch / face restoration is not available** – no face-restoration model with a licence that permits use in PhotoFlow was found.
- **Background replacement** relies on Vision's subject mask (any subject on macOS 14+, people only on macOS 13); fine hair or transparent objects may need manual correction. The shadow is a simple contact shadow, not physically based relighting.
- **ETA** is shown only after the step time has been measured on this Mac (no estimate is invented before).
- **Image generation needs a Metal GPU or the Neural Engine.** Apple's float16 VAE is computed wrongly by Core ML on the CPU and the float16 UNet does not run on an x86 CPU (measured, `AI_FEHLERANALYSE.md`). PhotoFlow therefore uses its own float32 VAE (installed automatically) and never silently runs the UNet on the CPU. Every image is checked before it is shown; invalid results are rejected, the model is marked as not working on this Mac, and an installed model of the other compute path is used instead.
- **Verification on real hardware is outstanding.** GitHub's virtual Macs have no Core ML-usable GPU and no Neural Engine. On them the complete pipeline was verified on the Apple-Silicon CPU and on the Intel VM (with the float32 VAE: all tests passed, no GPU hang). Whether GPU and Neural-Engine execution produce valid images on a real Mac is **not yet confirmed**; the hardware acceptance test (Model Management ▸ Hardware test) measures exactly this and writes a report. Until a report exists, these paths count as untested – see `TEST_REPORT.md` §4.
- **SDXL** could not be run in CI at all (the runners have 7 GB of memory).

## Image processing
- Auto Enhance is rule-based and conservative by design; strongly stylised photos (e.g. deliberate high-key or low-key looks not recognised as such) may be nudged toward neutral. Use *Subtle* or adjust afterwards.
- White balance cannot know the "true" scene colour; images without neutral surfaces (e.g. a green forest, a red wall) are corrected with reduced confidence.
- Auto Straighten only corrects tilts between 0.15° and 10° with sufficient confidence; larger tilts are treated as intentional. Photos without straight lines or a horizon (portraits, close-ups, foliage) are left unchanged.
- Auto Perspective corrects vertical convergence automatically; horizontal keystone only for frontal facades/documents. Two-point perspective of buildings photographed at an angle is not "flattened". Freehand quad (four-corner) editing is not offered; Document mode uses Vision's rectangle detector.
- There is no free-form (drag-handle) crop tool. The editor's *Crop* group offers subject-aware aspect-ratio crops (1:1, 4:5, 3:2, 4:3, 16:9), *Remove borders* and *Remove Crop*; straighten/perspective crop automatically.
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

## PhotoFlow 2.0 design – what could and could not be verified
- All screens were reviewed from real screenshots of the running app on GitHub-hosted Macs (virtual machines):
  macOS 15 (material fallback) and macOS 26 (native Liquid Glass), light/dark, English/German, empty/with photos,
  1280×800, 1440×900, 1920×1080. These VMs render without a physical GPU and their display is 1024×768; larger
  window sizes are captured off-screen. Rendering on a real Mac (Retina, ProMotion, real GPU) was not observed
  by the developer – subtle differences in blur strength and animation smoothness are possible.
- Real input was tested with synthesized mouse/keyboard events (click, double-click, ⌘-click, Space, ←, Esc,
  ⌘Z, ⇧⌘Z). **Drag and drop, context menus, slider dragging, hover effects and tooltips were not automated** –
  their code paths are standard SwiftUI/AppKit but they were checked only visually/structurally.
- Animations were reviewed as still frames; their timing and smoothness can only be judged on a real Mac.
- The size estimate in the export dialog is an approximation (a 1024 px sample of the first photo is encoded
  and scaled to all photos); photos with very different content compress differently.
- The sidebar starts hidden (layout of the reference); show it with the button top-left or ⌃⌘S.
