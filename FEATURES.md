# Features

Status legend: ✅ implemented in code · 🧪 verified by an automated test (see TEST_REPORT.md)

## Library & import
| Feature | Where |
|---|---|
| Import files and folders (recursive, hidden files/packages skipped), drag & drop onto the window, the Dock icon or an album | `ImportService`, `ContentView`, `SidebarView`, `AppDelegate` |
| JPEG, HEIC/HEIF, PNG, TIFF, WebP, GIF, BMP, DNG and camera RAW (CR2/CR3, NEF, ARW, RAF, ORF, RW2, PEF, …) | `PhotoFormat`, `ImageLoader` (RAW via `CIRAWFilter`) |
| Originals are referenced, never copied or modified; bookmarks find moved/renamed files; missing files are flagged with "Locate Original…" | `LibraryValidator`, `MetadataReader.bookmark` |
| Already-imported paths are skipped | `ImportService` |
| Sidebar: Overview, All Photos, Recent Imports, Favorites, Recently Edited, Albums, Batch Processing, Duplicate Finder, Similar Photos, Export History, Trash | `SidebarView` |
| Albums: create, rename, delete, add, move between albums, remove, export album | `AppModel`, `SidebarView`, `PhotoContextMenu` |
| Grid (adjustable size) and list (sortable table) views, multi-selection (⌘/⇧-click, ⌥⌘A), arrow-key navigation, Delete key | `LibraryView` |
| Sort by date taken, date imported, name, size, resolution; filter by format and editing status; search by file name/camera | `AppModel.refreshVisible`, `LibraryHeader` |
| Inspector: preview, file name, dimensions, size, format, dates, camera/lens/exposure, editing status, Auto Enhance, "What Auto Enhance did" | `InspectorView` |
| Context menu: Open, Quick Look, Auto Enhance (+ strength), Edit, Compare, Restore Original, Copy/Paste Adjustments, Favorites, Move to Album, Rename, Reveal in Finder, Copy/Move to Folder, Remove from Library, Export, Move to Trash, Get Information | `PhotoContextMenu` |

## Automatic enhancement
| Feature | Where |
|---|---|
| One-click Auto Enhance per photo or for any selection/collection, Subtle/Balanced/Strong (Balanced default) | `AutoEnhanceEngine`, toolbar, inspector, editor |
| Individual analysis of every photo: histogram & percentiles, clipping, dynamic range, saturation, colourfulness, noise, sharpness, colour cast; Vision scene classification, faces, horizon, saliency | `PhotoAnalyzer`, `ImageStatistics`, `VisionAnalyzer` |
| Scene-aware targets (night, snow, sunset, documents, portraits, landscapes, architecture, food, underwater) | `PhotoAnalysis`, `AutoEnhanceEngine` |
| Self-check render to prevent new clipping/oversaturation | `AutoEnhanceEngine.selfCheck` |
| Plain-language explanation of every decision | `AutoEnhanceInfo.notes` |

## White balance, straightening, perspective
| Feature | Where |
|---|---|
| Automatic white balance (warm/cool casts, green/magenta tints) with atmosphere preservation and skin-tone guard; manual temperature/tint afterwards | `WhiteBalanceEstimator`, `WhiteBalanceModel` |
| Auto Straighten (projection profiles + Vision horizon), manual angle slider (±45°, 0.1° steps) with grid overlay, 90° rotation, inscribed crop showing retained area | `StraightenEngine`, `GeometryModel`, `EditorView` |
| Auto Perspective (vanishing-point search), Document mode (Vision rectangles), Vertical/Horizontal sliders, clear message when no confident correction is possible | `PerspectiveEngine`, `EditorModel.autoPerspective` |

## Manual editing & presets
| Feature | Where |
|---|---|
| Exposure, Brightness, Contrast, Highlights, Shadows, Whites, Blacks (advanced), Temperature, Tint, Vibrance, Saturation, Black & White, Sharpness, Noise Reduction, Clarity | `EditorView`, `RenderPipeline` |
| Undo / Redo (Edit menu, ⌘Z/⇧⌘Z, toolbar), reset single slider (button or double-click), Reset All, Reset Geometry | `EditorModel` |
| Presets: Natural, Bright, Warm, Cool, Vivid, Landscape, Portrait, Black and White, Professional Clean, Soft Contrast — adaptive (analysis first, then style); custom presets; usable in batches | `Preset` |
| Copy/paste adjustments between photos | `AppModel.copyAdjustments` |

## Before / after
| Feature | Where |
|---|---|
| Edited / Original toggle, interactive split slider, side by side, 100 % zoom (up to 6,000 px), batch result comparison (switch all thumbnails), two-photo comparison | `CompareCanvas`, `SplitCompare`, `ZoomedView`, `BatchView`, `ComparePhotosSheet` |

## Non-destructive editing
Edits are stored as JSON recipes in the library database; thumbnails and exports apply them on the fly; "Restore Original" deletes the recipe. Original files are only read. (`EditRecipe`, `LibraryStore.saveRecipe`)

## Batch processing
| Feature | Where |
|---|---|
| Workflows: Auto Improve Everything, Natural Colors, Bright and Clean, Landscape Optimization, Portrait Optimization, Straighten and Enhance, Web Export | `BatchWorkflow.predefined` |
| Sources: selection, all photos, album, folder (auto-imported) | `BatchModel.Source` |
| Operations: enhancement (tone/colour/white balance/detail), straightening, perspective, automatic crop (remove borders or aspect ratio around the salient subject), preset, resize, format conversion, watermark, metadata preservation, save to library and/or export | `BatchRunner`, `AutoCrop`, `ExportEngine` |
| Queue with hardware-adapted parallelism, live per-photo status, progress, ETA, pause/resume, cancel, error messages, retry failed, summary | `BatchRunner`, `PauseGate`, `BatchView` |

## Duplicates & similar photos
See DUPLICATE_DETECTION.md. Exact (SHA-256) and visual (hashes + feature prints + registration) detection, adjustable sensitivity, category filter, grouped review with thumbnails, similarity, resolution, size, date, location, "Best Version to Keep" with reasons, compare sheet, Keep/Delete per photo, select recommended, cached analysis, cancellable scans.

## File management & safety
| Feature | Where |
|---|---|
| Move to Trash (single, multiple, duplicate groups) via `FileManager.trashItem` — never permanent | `FileOperations.moveToTrash` |
| Confirmation with file count and size (configurable: always / only for many / never) | `ContentView`, Settings |
| App-managed Trash list with restore (incl. edits, favourites, albums) | `TrashView`, `AppModel.restore` |
| Rename, move/copy to folder, Reveal in Finder; never overwrites (unique names) | `FileOperations` |
| Clear explanations for permission, read-only volume, missing file, full disk, unsupported Trash errors | `FileOperations.explain` |
| Security-scoped bookmarks when sandboxed; plain bookmarks otherwise | `MetadataReader.bookmark` |

## Export
JPEG, PNG, TIFF (16-bit), HEIC and WebP (when the Mac's ImageIO can write them), "same as original" (lossless copy when unedited); quality, size (long side), sRGB/Display P3, file-name pattern (`{name} {date} {counter} {width} {height}`), destination (default `~/Pictures/Processed Photos`), metadata preservation with optional location removal, text watermark; presets Original Quality, High Quality, Web Optimized, Small File Size, Social Media; export history. RAW files are exported as rendered images. (`ExportEngine`, `ExportViews`)

## Settings
Appearance, language (EN/DE), default enhancement strength, deletion confirmation, launch validation, default export format/quality/destination, parallel processing (automatic/manual), CPU rendering, thumbnail quality, duplicate sensitivities and category thresholds, cache sizes and clearing, privacy statement. (`SettingsView`)

## Design
Liquid Glass (`glassEffect`, `.glass`/`.glassProminent`) on macOS 26; material-based glass fallback on macOS 13–15; Light/Dark/automatic; SF Symbols; unified toolbar; toasts; empty states. (`UI/Design`)
