# PhotoFlow 2.0 – Redesign: what changed

This document lists every change of the visual transformation. Functions, image processing, batch engine,
import/export logic and the non-destructive data model were kept; where code was touched outside the UI,
it is listed explicitly under "Engine changes".

## Identity
- **New app icon** (supplied artwork, unchanged): cut out with a superellipse mask fitted to the artwork's
  own rim (n ≈ 4.1), placed on the macOS icon grid (824 px body, 100 px margin, soft shadow);
  `AppIcon.icns` with all sizes 16–1024 incl. @2x (`Scripts/make_icon.py`, source in `Packaging/icon/`).
- `BrandMark.png` (icon body) is bundled and used for the welcome screen, empty states, drop overlay,
  sidebar, Settings header; the native About panel (PhotoFlow ▸ About) shows the new icon.
- New DMG window background in the new palette with the brand mark (`Scripts/make_dmg_background.py`).
- CI verifies by SHA-256 that the icon in `PhotoFlow.app` and inside `PhotoFlow.dmg` is the new icon and
  that `CFBundleIconFile` points to it (`icon-check.log` on the `dist` branch).

## Design system
- New `DESIGN_SYSTEM.md`: palette (warm light grey / anthracite, accents from the icon), semantic colours,
  four material levels, type ramp, spacing and radius scales, motion tokens, the 15 effects, components.
- All screens use the tokens; legacy names (`indigo`, `cyan`, `pink`, …) now map onto the new palette.

## Window & navigation
- Hidden title bar; window is dragged by the top strip; content scrolls under a transparent floating top bar
  with a soft fade mask.
- **New sidebar** (custom, Background Glass): brand row, groups *Library* (Overview, All Photos, Recent Imports,
  Favorites, Recently Edited), *Albums* (My Albums, each album, New Album…), *Tools* (Batch Processing,
  Duplicate Finder, Similar Photos, Export History, Trash). Glass selection pill glides between rows, hover
  light, filled symbols when active, live counts, busy indicators, album drag & drop and context menus kept.
  Hide/show with the button, ⌃⌘S or View menu; animated.
- Page changes unfold (fade + rise + scale) instead of switching abruptly.
- Floating **Inspector** panel (⌥⌘I), floating **Selection bar** (fanned thumbnails, count, size, favourite,
  edit, compare, album, export, trash, Auto Enhance, deselect) with a compact variant for narrow windows.
- Contextual glass tooltips with keyboard shortcuts.

## Screens
- **Overview**: large title + count line, dynamic bento mosaic (1 large + up to 6 small, adapts to width,
  reveal animation, hover zoom/reflection, click selects, double-click opens the viewer), glass hero caption
  with *Improve All* (premium) and *Find Duplicates*, statistic cards (progress ring, storage bar, duplicates,
  favourites), workflow cards with animated real previews, recently-imported strip.
- **Welcome / empty library**: the icon floating above two photo cards, title, subtitle, premium import
  button (⇧⌘I), drag-and-drop zone with hover reaction, feature hints.
- **Library pages** (All Photos, Recent Imports, Favorites, Recently Edited, albums): glass search field,
  control capsule (Mosaic / Grid / List with gliding indicator, sort, filter, size), month sections
  (Recent Imports: grouped by import session with date and count; Recently Edited: by day),
  **justified mosaic** layout keeping every aspect ratio, new photo tiles (hover zoom, light reflection,
  info fade-in, heart with bounce, edited badge, animated selection ring), staggered reveal for new imports,
  list view restyled.
- **Photo viewer (new)**: double-click / Space; zooms out of the tile's real position, dims and blurs the
  interface, inspector slides in, ←/→ browse with cross-fade, Esc/Space returns to the grid position.
- **My Albums (new page)**: cover cards stacked from the album's own photos, new-album card, empty state.
- **Editor**: dimmed stage lit by the photo, floating top bar (back, file name with "Saved" confirmation,
  compare modes as segmented glass control, undo/redo, 100 % zoom, grid, export), floating tool panel with
  animated real histogram, Auto Enhance (premium), and tool groups **Light · Color · Detail · Geometry ·
  Crop · Effects** with a gliding indicator. New *Crop* group (aspect ratios incl. subject-aware crop,
  trim borders, remove crop). Fluid sliders with animated values; glowing split-compare divider.
- **Batch processing** (complete redesign): seven workflow cards, each with its own imagery
  (Auto: animated before/after + light accent; Natural: cast → neutral cross-fade; Bright & Clean: exposure
  change with light; Landscape: animated horizon line; Portrait: soft face highlight; Straighten: tilted
  photo settling level with a glowing line; Web export: resolution/format chips). With an empty library
  the cards use built-in sample scenes (drawn in the icon's style) with real before/after looks; with photos
  they show the **real planned result** of each workflow on a library photo.
  **Live preview** with a draggable before/after slider computed by the same planner the batch uses; changes
  update only the preview image. Settings panel: source menu, enhancement switch, strength, option chips,
  preset and auto-crop menus, keep-edits, outputs, export options. Start button → "Preparing…" transition →
  processing panel (ring with glowing tip, percentage, count, current photo with shimmer, settings summary,
  pause/resume/cancel) → completion (checkmark animation, done/skipped/failed/duration/exported, *View
  Results*, *Show Exports*, *Retry Failed*, *New Batch*) and a results grid with Edited/Original toggle.
- **Duplicate Finder / Similar Photos**: control capsule (scope, sensitivity slider, category filter), scan
  progress ring, statistic tiles, group cards with similarity meter, best version first, highlighted
  differences (resolution up/down arrows), Keep/Delete as segmented control per photo, compare sheet with
  side-by-side **and** overlay slider, floating deletion bar.
- **Export dialog**: stacked preview, export presets as tiles, menus, quality slider, colour-space segments,
  glass text fields, switches, watermark panel and a **size estimate measured by encoding a 1024 px sample
  with the chosen format/quality** (shown as "≈").
- **Export history**: summary tiles and a timeline of export jobs with format, count, size, status and
  folder button.
- **Trash**: thumbnail cards from the files in the macOS Trash, hover restore, multi-select, restore all/
  selected, gentle notice for files no longer in the Trash, own empty state.
- **Settings**: brand header, accent tint (native settings window kept on purpose).
- Info, rename, new-album and compare sheets restyled.

## Motion
All 15 effects of the brief are implemented (see DESIGN_SYSTEM.md › Motion). Reduce Motion is respected.
Looping animations are scoped to their own view (fix for labels that pulsed/disappeared).

## Engine changes (behaviour-preserving)
- `BatchPlanner.recipe(…)` extracted from `BatchRunner.process` so the live preview and the batch share one
  function (identical results by construction). Covered by the existing batch QA runs.
- `EditorModel.applyCrop(_:)` added for the new Crop tool group (uses the existing `AutoCrop` functions).
- `AppModel`: viewer state, sidebar/inspector visibility, `highlightPhotos`, `ambientPhoto`,
  `freshlyImported`; default page is now the Overview; importing no longer jumps to Recent Imports.

## Quality assurance
- `UITour` walks through ~40 states per run, in light/dark × English/German, plus reduced runs at
  1280×800 and 1920×1080; it posts **real NSEvents** (mouse clicks, double-click, ⌘-click, Space, ←, Esc,
  ⌘Z, ⇧⌘Z) and reports PASS/FAIL per interaction (`interaction-checks.txt` on the `shots` branch).
