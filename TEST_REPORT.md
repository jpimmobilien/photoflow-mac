# Test report

This report only states results that were actually measured. Sections marked **PENDING** have not been run yet.

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

## 2. On-Mac tests — **PENDING**

The Swift project has to be compiled and tested on a Mac. The following runs are prepared in the built-in harness (`PhotoFlow --qa …`, see BUILD_INSTRUCTIONS.md) and will be filled in with measured numbers:

| Test | Command | Status |
|---|---|---|
| Universal binary contains x86_64 + arm64 | `lipo -archs` (also enforced by `build_app.sh`) | PENDING |
| Deterministic self-test (geometry, WB mapping, tone curve, hashes, tilt, export never overwrites, original untouched, Trash + restore) | `--qa selftest` (native and `arch -x86_64`) | PENDING |
| Duplicate detection recall per variant (exact copy, resized, recompressed, brighter, colour shift, crop 80 %/65 %, mono, PNG) and false positives | `--qa eval-dup` | PENDING |
| Straightening on real photos | `--qa eval-straighten` | PENDING |
| White balance on real photos | `--qa eval-wb` | PENDING |
| Perspective on real photos | `--qa eval-perspective` | PENDING |
| Batch 100 / 500 / 1,000 photos: time, CPU, peak memory, failures, originals unchanged, metadata preserved | `--qa batch` | PENDING |
| GUI smoke test (launch, import, grid, editor, compare, batch, duplicates, trash/restore, export, settings, DE localization) | manual | PENDING |
| DMG creation and verification | `make_dmg.sh` (`hdiutil verify`) | PENDING |
