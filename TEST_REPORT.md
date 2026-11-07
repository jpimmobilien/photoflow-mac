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
- **GUI**: no interactive test of the user interface has been performed (CI runners have no screen session for UI testing). All engine code paths used by the UI are covered by the tests above, but window layout, interaction and localisation display have not been verified by a person.
- **Native Intel hardware** (e.g. MacBook Pro 2017): the x86_64 slice was tested under Rosetta on Apple Silicon only.
- **Metadata preservation with real EXIF**: the test photos carry no EXIF capture dates, so this check was not meaningful (code path exists; selftest covers export safety only).
- **HEIC / RAW / TIFF sources**: the dataset contains JPEG and PNG only.
- **macOS 13/14 and macOS 26**: tested on macOS 15.8 only.
- WebP export is not available on the runner's macOS (ImageIO cannot encode WebP there); the option is hidden automatically.
