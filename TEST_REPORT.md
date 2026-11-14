# Test report

This report only states results that were actually measured. Untested areas are listed explicitly at the end.

## 1. Algorithm validation (numerical prototypes, before porting to Swift)

The core computer-vision algorithms were first implemented in Python/NumPy with identical maths and validated on synthetic images with known ground truth. The Swift implementation mirrors these prototypes.

### Straightening (tilt estimation)
Synthetic scenes (horizon + vertical posts + random texture blobs, anti-aliased by 4× supersampling), rotated by known angles and cropped; 6 scenes × 9 angles (−8° … +7°).

| Method | Mean abs. error | Max error |
|---|---|---|
| Per-pixel orientation histogram (first approach) | 0.73° | 1.54° (systematic under-estimate at 6–8°) |
| + Gaussian pre-smoothing, weighted median | 0.42° | 1.11° |
| **Projection profile (shipping method), 512 px** | **0.038°** | **0.15°** |
| **Projection profile, 768 px (shipping size)** | **0.013°** | **0.05°** |

Texture-only image without lines: confidence 0.06 (threshold for auto-apply: 0.30); real scenes ≥ 0.59.
Finding that changed the design: gradient-orientation methods are biased toward 0° on sharp edges (an analytic 7° step edge measured 5.96° per-pixel median); position-based projection profiles are not.

### Perspective (vertical keystone)
Synthetic facades (9 vertical, 9 horizontal lines) with known top convergence.

| Convergence | Expected `cv` | Measured `cv` | Confidence |
|---|---|---|---|
| 0 % | 0.0000 | 0.0000 | 0.74 |
| 5 % | 0.0513 | 0.0500 | 0.73 |
| 10 % | 0.1053 | 0.1080 | 0.73 |
| 20 % | 0.2222 | 0.2220 | 0.72 |
| −10 % | −0.0952 | −0.0960 | 0.74 |

### White balance
200 random multi-patch ("Mondrian") scenes with shading and random illuminant casts (±0.45 log units per channel).

| Estimator | Median angular error | p90 |
|---|---|---|
| No correction | 10.64° | 16.82° |
| Gray-world | 4.07° | 7.78° |
| Gray-edge | 3.16° | 7.40° |
| White-patch | 10.11° | 26.08° (rejected) |
| **Adaptive combination (shipping)** — no neutral surfaces / 10 % / 30 % | **2.46° / 2.04° / 1.41°** | 5.90° / 5.81° / 4.57° |

## 2. Build & tests on macOS (GitHub Actions, build 7)

Environment: GitHub-hosted macOS runner, macOS 15.8.2 (virtual Mac, Apple Silicon, 5 cores, 14 GB, paravirtual Metal GPU), **Xcode 26.3 / Swift 6.2.4, macOS 26.2 SDK** (Liquid Glass compiled in). Workflow: `.github/workflows/build.yml`; full logs are in the `dist` branch.

### Build
| Check | Result |
|---|---|
| Compile arm64 + x86_64 (release) | ✅ both succeed |
| Universal Binary | ✅ `lipo -archs` → `x86_64 arm64` (Mach-O universal, 2 architectures) |
| Signature | ✅ ad-hoc, `codesign --verify --strict` passes (no Developer ID → not notarized) |
| DMG | ✅ `PhotoFlow.dmg` (3.6 MB), Finder layout applied, `hdiutil verify` passes |

### Self-test (`--qa selftest`) — 21/21 PASS on arm64 **and** on the x86_64 slice (Rosetta)
Inscribed-crop geometry (4 angles + perspective), white-balance slider mapping (3), tone-curve monotonicity (2), pHash stable under 50 % resize (distance 2), tilt detection on a synthetic scene (−4.00°, +2.50°, +6.00° detected exactly), library insert, recipe round-trip, export never overwrites ("Sample (2).jpg"), original byte-identical after export, export into the original's folder keeps the original, Move to Trash, restore from Trash (byte-identical).

### Real-photo dataset
54 real photographs: the 24 images of the Kodak Lossless True Color Image Suite and 30 Unsplash photos (picsum.photos, fixed IDs, 2400×1600). `--qa gen` derived 540 labelled duplicate variants, 108 tilt images (54 originals + 54 rotated by −6 … +4.5°), 54 colour-cast images and 54 keystoned images. Photos are used for testing only and are not shipped.

### Duplicate & similarity detection (540 photos)
| Variant of the original | ≥ 95 (Duplicate Finder default) | ≥ 85 | ≥ 70 |
|---|---|---|---|
| exact byte copy | 53/54 | 54/54 | 54/54 |
| recompressed (JPEG q 0.45) | 53/54 | 54/54 | 54/54 |
| resized to 50 % | 50/54 | 51/54 | 52/54 |
| PNG version | 51/54 | 54/54 | 54/54 |
| +0.6 EV brighter | 51/54 | 54/54 | 54/54 |
| colour-temperature shift | 53/54 | 54/54 | 54/54 |
| black & white | 51/54 | 50/54 | 50/54 |
| crop to 80 % | 9/54 | 44/54 | 52/54 |
| crop to 65 % (corner) | 0/54 | 9/54 | 37/54 |
| **overall recall** | **76.3 %** | **87.2 %** | **94.9 %** |
| **photos wrongly grouped with a different photo** | **0** | **0** | **17** |

Feature-print cosine: same source median 0.953 (p05 0.776); different photos median 0.383, p99 0.695, p99.9 0.802, max 0.900 (143,100 pairs). Scan time for 540 photos: 156 s on first run (analysis), **18 s on the second run** (all 540 from cache).
Interpretation: renditions (resized, recompressed, converted, brightened, colour-shifted) are reliably "very similar"; crops are "similar"/"possibly similar". The "Possibly similar" range (≥ 70) can contain different photos with similar content – which is why PhotoFlow never deletes automatically.

### Straightening (108 images)
Development history on the same dataset:
| Version | Straight originals rotated without need | Tilted photos auto-corrected |
|---|---|---|
| build 5 (first real test) | 15/62 (24 %) – **not acceptable** | many, partly in the wrong direction |
| build 7 (shipping) | **2/54 (4 %)** | 12/46, of which 8 within ±0.5° of the expected angle |

Root causes found and fixed: (1) Apple Vision reports the horizon *correction* angle (opposite sign) – fusion was inverted; (2) integer pixel positions created an artificial optimum at 0° (fixed with sub-pixel jitter); (3) a single dominant slanted line (hillside, roof) was trusted – automatic correction now requires agreement of two independent measurements. Several originals turned out to be tilted themselves (e.g. one original measured −9.7° by both the edge analysis and Vision), so "errors" against the nominal angle partly reflect real tilts.
The automatic straightening is now **deliberately conservative** (prefers doing nothing over a wrong rotation). When the user clicks *Auto Straighten* in the editor, the best estimate is applied with a note to check the result.

### Perspective (54 keystoned images, mostly landscapes)
Automatic correction applied to **1/54** images (direction correct, under-corrected: −0.048 vs −0.10); no wrong correction. On these landscape photos the measurement itself is unreliable (MAE 0.27 in `cv`), so the gate keeps auto-perspective off unless the scene is recognised as architecture with strong straight verticals. Synthetic facades are measured within ±0.003 (section 1). A dedicated architecture dataset has **not** been tested; manual Vertical/Horizontal sliders and Document mode are the primary tools.

### White balance (54 images with known added casts)
Mean angular deviation 7.0° → 5.8° (median 8.8° → 5.8°). The metric is approximate because the original photos' own colour balance is unknown. Real-photo testing revealed that foliage-rich landscapes were read as a green cast (tint over-corrected toward magenta); this was fixed (reduced green correction for colourful/landscape scenes, tint capped at ±12 without neutral surfaces).

### Batch processing ("Auto Improve Everything" + JPEG export, 2 parallel workers)
| Photos | Architecture | Failed | Wall time | Per photo | CPU | Peak memory | Originals unchanged |
|---|---|---|---|---|---|---|---|
| 100 | arm64 | 0 | 20.2 s | 0.20 s | 223 % | 1,090 MB | ✅ |
| 500 | arm64 | 0 | 92.5 s | 0.19 s | 238 % | 1,123 MB | ✅ |
| 1,000 | arm64 | 0 | 186.4 s | 0.19 s | 238 % | 1,127 MB | ✅ (SHA-256 of all sources identical before/after) |
| 100 | x86_64 (Rosetta) | 0 | 31.6 s | 0.32 s | 262 % | 1,215 MB | ✅ |

Memory stays flat from 100 to 1,000 photos (no growth/leak). Source photos 2400×1600 / 768×512.

### Not yet tested
- **GUI interaction by a person**: not yet. The UI *is* reviewed automatically: `PhotoFlow --ui-tour` (workflow `ui.yml`) launches the real app on a macOS runner with 45 real photos, walks through 23 states (empty library, overview, grid, inspector, multi-selection, list, editor original/enhanced/slider/side-by-side, batch setup/running/results, duplicate scan/results/marking, similar photos, export history, trash, export sheet) in light mode, dark mode and German, and saves screenshots (branch `shots`). Three design-review iterations fixed: thumbnails overflowing grid cells, collapsed header text at narrow widths, a background glow covering the photo grid and pushing the editor panel off-screen, clipped export sheet, slider tick clutter, missing live feedback during batches, and a plural error. Mouse/keyboard interaction (drag & drop, context menus, Quick Look) is not covered by the tour.
- **Native Intel hardware** (e.g. MacBook Pro 2017): the x86_64 slice was tested under Rosetta on Apple Silicon only.
- **Metadata preservation with real EXIF**: the test photos carry no EXIF capture dates, so this check was not meaningful (code path exists; selftest covers export safety only).
- **HEIC / RAW / TIFF sources**: the dataset contains JPEG and PNG only.
- **macOS 13/14 and macOS 26**: tested on macOS 15.8 only.
- WebP export is not available on the runner's macOS (ImageIO cannot encode WebP there); the option is hidden automatically.

## 3. AI Studio on GitHub's virtual Macs (`ai-test.yml`, real downloads and real inference)

Runners: `macos-15-intel` (Intel Core i7-8700B VM, 14 GB, "Apple Paravirtual" GPU) and `macos-15` (Apple M1 VM, 7 GB,
no Neural Engine, paravirtual GPU). Model: SD 2.1 (float16) + PhotoFlow's float32 VAE. These VMs are suitable for
build, download, pipeline and UI tests – **not** for the final GPU / Neural Engine acceptance (see §4).

**Where Core ML actually computes (`MLComputePlan`):** on both VMs "UNet: GPU 0 %, Neural Engine 0 %, CPU 100 % of
1841 ops". So the results below verify the complete pipeline on the **CPU** of Apple Silicon and Intel – they do not
verify the GPU or the Neural Engine of a real Mac.

### 3.1 Before the fix (Apple's float16 VAE)

| Symptom | Intel VM | Apple Silicon VM |
|---|---|---|
| Text to image | first image correct, then `GPU Hang` in the VAE decoder | uniform grey/brown images |
| Cause (measured with `ai-diag`, details in `AI_FEHLERANALYSE.md`) | VAE kernels of 45–56 s on the slow VM GPU | float16 VAE computed wrongly by Core ML on the CPU (decoder std 0.070 instead of 0.094, encoder 4.70 instead of 7.25) |

### 3.2 After the fix (float32 VAE), runs 43571996554 / 43571998685 / 43574989144

| Test | Intel VM | Apple Silicon VM (CPU) |
|---|---|---|
| Catalog, hardware detection | ✓ tier Intel, SDXL / Neural Engine models refused | ✓ "Apple M1 (Virtual)" |
| Download + SHA-256 of all files, pause → resume | ✓ SD 2.1: 22 files / 2.58 GB in 76 s | ✓ 47 s |
| float32 VAE download + Core ML compile | ✓ 5 s | ✓ 6 s |
| Sampling (`PipelineDiagnostics`) | ✓ latent std 1.001 → 0.883, all finite | ✓ latent std 1.000 → 0.922, all finite |
| Text to image, **network blocked** | ✓ valid 512×512 image, std 0.202; 50 s/step, 709 s incl. load (12 steps) | ✓ valid, std 0.188; 13.4 s/step, 235 s incl. load (15 steps) |
| Image to image | ✓ std 0.180, 34 s/step | ✓ std 0.187, 16 s/step |
| Generative fill | ✓ outside the mask unchanged (diff 0.00000), filled area valid | ✓ outside unchanged (0.00000), filled area valid |
| Expand image | ✓ new area valid, original unchanged | ✓ |
| Cancel → next generation | ✓ stops at the next step, next image valid | ✓ |
| Memory, 3 runs | ✓ peak 5.97 / 6.03 / 6.00 GB, no growth, 58 MB after unload | ✓ no growth (+5 MB between run 2 and 3)¹ |
| GPU hang | **none** (VAE now on the CPU in float32) | – |
| LaMa, Real-ESRGAN 2×/4×, denoise, Vision mask, AI metadata | ✓ | ✓ (LaMa, Vision via UI tour) |

¹ On the Apple-Silicon VM the process footprint stayed at 20–34 MB; Core ML's model memory is not included in this
measure there, so it only shows that the app itself does not grow.

Images were also inspected visually (`ai-results` branch): the text-to-image cabin/lake image and the inpainted plant
are clean and plausible. The first tiled outpainting was technically valid but visually poor (tiles invented
unrelated scenes); it was reworked (mirrored prefill, strength 0.82, Vision description of the photo as prompt, soft
tile seams) – see §3.3.

### 3.3 Outpainting rework

Run 43580467708 (Apple Silicon VM, CPU, SD 2.1 + float32 VAE, 15 steps), all 14 tests passed. Expanding the
macaw photo by 192 px on both sides: original area unchanged (diff 0.00000), new area valid (std 0.156); visually the
scene continues naturally (foliage, bokeh and further macaws in the same light) without hard seams. Remaining
weakness: on very wide extensions slight repetitions of the blurred mirror pre-fill can be visible in out-of-focus
areas. Other results of the same run: text to image std 0.188, image to image std 0.187 (with an empty prompt the
model reinterprets the birds noticeably – a prompt is recommended), generative fill (plant pot between the birds)
clean with untouched surroundings, cancel → next image valid, no memory growth.

## 4. Real Apple Silicon hardware (hardware acceptance test)

**Status: pending.** No real Mac was available to this build environment. Per the acceptance requirement, the GPU and
Neural-Engine paths are therefore **not** declared as successfully tested.

The test is reproducible on any Mac:

1. Install PhotoFlow from the DMG and open it.
2. *AI Studio ▸ Model Management ▸ Hardware test ▸ Full test* (downloads the recommended model, Real-ESRGAN 2× and
   LaMa if missing). Alternatively in Terminal:
   `/Applications/PhotoFlow.app/Contents/Resources/ai_hardware_test.sh full`
3. Quit and reopen PhotoFlow, then *Hardware test ▸ Test after restart*.
4. The report is in `~/Pictures/PhotoFlow KI-Hardwaretest/<date>/` (`report.md`, `report.json`, `index.html`, every
   generated image).

What the full test covers: Core ML op placement and VAE in use; 3 load/unload cycles; 20 consecutive generations over
5 prompts with content check (PNG written, reopened, validated, Vision labels compared with the prompt), interim
results after 10 and 20 incl. memory growth; reproducibility (same seed → same image); 4 variants; 16:9 / 9:16 and 2×
high resolution; cancel at step 3 followed by a generation; model switch (if two models are installed); image to
image, generative fill (area outside the mask must be unchanged), object removal, expand (original preserved) and
background replacement; final memory; one generation after an app restart. Runtimes, s/step, memory and error rate
are written to the report.

| Mac | Model | Result | s/step | Memory | Errors |
|---|---|---|---|---|---|
| – | – | pending | – | – | – |
