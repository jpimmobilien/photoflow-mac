# PhotoFlow – Intelligent Photo Studio

A native macOS app (SwiftUI + AppKit) that makes large photo collections look better with a few clicks — **entirely on your Mac**.

**Import → Analyze → Optimize → Organize → Export**

| | |
|---|---|
| **Auto Enhance** | Analyzes every photo individually (exposure, tonal range, colour cast, noise, scene type, faces) and applies natural, explainable corrections. Subtle / Balanced / Strong. |
| **White balance** | Colour-constancy estimation (gray-world, gray-edge, neutral surfaces) that keeps intentional moods such as sunsets. |
| **Straighten** | Horizon/tilt detection by projection-profile analysis, fused with Apple Vision's horizon detector; crops to the largest possible rectangle. |
| **Perspective** | Vanishing-point keystone correction for buildings and interiors, a document mode, and manual sliders. |
| **Batch processing** | 1,000+ photos with controlled concurrency, progress, ETA, pause/resume, cancel, retry, and seven predefined workflows. |
| **Duplicates & similar photos** | SHA-256 for exact copies; perceptual hashes + Apple Vision feature prints + registration-based crop verification for visual duplicates; grouped review with a "Best version to keep" recommendation. Never deletes automatically. |
| **Library** | Albums, favourites, search, sorting, filters, grid/list, drag & drop, native context menu, Quick Look, safe deletion via the macOS Trash, restore. |
| **AI Studio** | Local image generation (Stable Diffusion 2.1 / XL via Core ML), image-to-image, generative fill, object removal (LaMa), background replacement, outpainting, Real-ESRGAN upscaling and restoration, prompt assistant, persistent creations gallery and model management with licence information. Models are optional downloads, verified by SHA-256; everything runs on the Mac. See `AI_STUDIO.md`. |
| **Non-destructive** | Originals are never modified; edits are stored as recipes and exported as new files ("Processed Photos"). |

- **100 % local:** no uploads, no cloud AI, no account, no analytics, works offline (AI models are downloaded once, on request).
- **Universal:** Intel (x86_64) and Apple Silicon (arm64), macOS 13 Ventura or newer.
- **Design (PhotoFlow 2.0):** a complete redesign around the new app icon – warm light grey / deep anthracite,
  sky-blue / iris / cyan accents from the icon, four glass material levels (native Liquid Glass on macOS 26,
  matching fallback on 13–15), floating glass tab bar, photo mosaic, photo dock, full-size viewer, and a motion
  system that respects Reduce Motion. See `DESIGN_SYSTEM.md` and `REDESIGN.md`.
- **Languages:** English, German.

## Install

Open `PhotoFlow.dmg` and drag PhotoFlow to Applications. The app is ad-hoc signed (no Developer ID), so the first launch needs **right-click ▸ Open ▸ Open** (or System Settings ▸ Privacy & Security ▸ "Open Anyway").

## Documentation

- [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) – build the app and DMG
- [FEATURES.md](FEATURES.md) – complete feature list and where it lives in the code
- [AI_STUDIO.md](AI_STUDIO.md) – local generative AI: models, licences, hardware profiles, how inpainting/outpainting work, privacy
- [LOCAL_AI_ARCHITECTURE.md](LOCAL_AI_ARCHITECTURE.md) – what is machine learning, what is classic computer vision, and how each decision is made
- [DUPLICATE_DETECTION.md](DUPLICATE_DETECTION.md) – the duplicate/similarity pipeline and its calibration
- [TEST_REPORT.md](TEST_REPORT.md) – what was tested and the measured results
- [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
- [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
- [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) – visual concept, tokens, glass levels, motion

## Project layout

```
Package.swift                 SwiftPM manifest (open in Xcode)
Sources/PhotoFlow/
  App/                        App entry, AppModel (state), Batch/Duplicates view models
  Core/Models                 PhotoRecord, EditRecipe, Album …
  Core/Storage                SQLite wrapper + library schema
  Core/Import                 Import, metadata, moved/missing file detection
  Core/Thumbnails             Two-level thumbnail cache
  Core/Imaging                Decoding, render pipeline (Core Image), geometry model
  Core/Analysis               Statistics, Vision wrapper, edge field, PhotoAnalyzer
  Core/Enhancement            Auto Enhance engine, auto crop
  Core/WhiteBalance           Illuminant estimation
  Core/Straighten             Tilt detection
  Core/Perspective            Keystone detection
  Core/Batch                  Batch workflows and runner
  Core/Duplicates             Hashes, fingerprints, scorer, grouping, keep recommendation
  Core/Export                 Export engine, watermark
  Core/Files                  Trash/restore/rename/move with clear error messages
  Core/Presets, Settings, Hardware
  UI/…                        SwiftUI views (Liquid Glass design system in UI/Design)
  QA/QARunner.swift           Headless test harness (`PhotoFlow --qa …`)
Resources/{en,de}.lproj       Localizations
Packaging/                    Info.plist, icon, DMG background
Scripts/                      build_app.sh, make_dmg.sh, make_icon.py, extract_strings.py
```
