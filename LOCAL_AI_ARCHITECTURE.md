# Local AI architecture

PhotoFlow's "intelligence" runs **only on the Mac**. Nothing is uploaded, no cloud service is contacted, no model is downloaded. The app works fully offline.

This document is deliberately precise about which parts are **machine learning** and which are **classic computer vision / image statistics** — the prompt for this product asked not to label ordinary filters as AI, and PhotoFlow's UI says "on-device analysis", not "AI magic".

## 1. Machine-learning components (Apple's on-device models)

All ML models are part of macOS itself and are accessed through the Vision framework. PhotoFlow bundles **no model files** (0 MB), so there is nothing to install, download or license. Vision chooses the Neural Engine, GPU or CPU automatically; every request works on Intel Macs (CPU/GPU) as well as Apple Silicon (Neural Engine).

| Purpose | Vision request | Min. macOS | Used for |
|---|---|---|---|
| Scene classification | `VNClassifyImageRequest` | 10.15 | Scene-aware targets (night, snow, sunset, landscape, architecture, document, food, underwater) |
| Faces | `VNDetectFaceRectanglesRequest` | 10.13 | Face-weighted exposure, skin-tone guard for white balance, limits on contrast/saturation for portraits |
| Horizon | `VNDetectHorizonRequest` | 10.13 | Second opinion for straightening |
| Saliency | `VNGenerateAttentionBasedSaliencyImageRequest` | 10.15 | Placing aspect-ratio crops |
| Image embedding | `VNGenerateImageFeaturePrintRequest` | 10.15 | Visual similarity (duplicates, bursts, edited versions) |
| Image registration | `VNHomographicImageRegistrationRequest` | 10.13 | Verifying crops / reframed versions of the same photo |
| Rectangles | `VNDetectRectanglesRequest` | 10.13 | Document perspective mode |
| Aesthetics | `VNCalculateImageAestheticsScoresRequest` | **15** | Optional factor in "best version to keep" (skipped on 13–14) |

Feature prints are L2-normalised and compared by cosine similarity. The model revision is stored with each cached vector; when a macOS update changes the revision, vectors are recomputed automatically.

## 2. Classic computer vision & image statistics (PhotoFlow's own algorithms)

All of these run on a ~768 px analysis copy (decoded directly at that size by ImageIO) and take a few tens of milliseconds.

### Tonal analysis (`ImageStatistics`)
256-bin luma histogram, percentiles (0.5 … 99.5 %), mean/std, clipped highlight/shadow fractions, HSV saturation and Hasler–Süsstrunk colourfulness, noise sigma (Immerkær's Laplacian-difference estimator restricted to flat regions), sharpness (variance of the Laplacian).

### White balance (`WhiteBalanceEstimator`)
Three colour-constancy estimators in linear light: **gray-world**, **gray-edge** (van de Weijer et al., p = 2), and an iterative **near-neutral-pixel** estimate. The neutral estimate is weighted up when it agrees with gray-edge and down when it does not; the agreement plus the share of neutral surfaces gives a confidence value.
*Validation (synthetic multi-patch scenes, 200 random casts):* median angular error 10.6° uncorrected → 2.9° combined; 2.0–2.5° with the adaptive weighting; ≈1.4° when neutral surfaces exist.

**Preserving atmosphere:** warm casts are only partly removed (60 %), and only 25 % in sunset / candle-light / night scenes (scene classifier). Cool casts 80 %, green/magenta tints 70–85 %. Casts below 1.5° are ignored. With faces present, the correction is reduced until skin keeps a plausible R > G > B ordering.

### Edge field (`EdgeField`)
Gaussian pre-smoothing (σ = 1) → Sobel gradients → structure tensor (σ = 1.5) → orientation + coherence. Only the strongest 15 % of edges with coherence > 0.5 (clean straight structures, not foliage/texture) are kept.

### Straightening (`StraightenEngine`) — projection profiles
Edge pixels are split into near-horizontal and near-vertical families. For each candidate angle (±12°, coarse 0.5°, fine 0.05°) they are projected onto the line normal and binned; the energy Σh² peaks when straight lines collapse into single bins. Because the method fits **positions**, not per-pixel orientations, it is immune to the orientation bias of gradient operators on sharp, aliased edges (measured during development: per-pixel orientation histograms under-estimated a 7° tilt by ~1°; projection profiles: 0.04° mean error at 512 px, 0.013° at 768 px).
Confidence = (peak − median score) / peak. Texture-only images score ≈ 0.06, scenes with real lines ≥ 0.6; auto-straighten requires ≥ 0.3, |angle| between 0.15° and 10° (larger tilts are treated as intentional). Disagreeing horizontal/vertical families (e.g. converging verticals) fall back to the horizontal family. Vision's horizon detector is fused when it agrees within 1°, or used alone when edges are inconclusive.

### Perspective (`PerspectiveEngine`) — vanishing-point search
Converging verticals meet in a vanishing point. PhotoFlow models the correction as a homography `[x, y, 1] → [x, y, 1 − cv·y/H + ch·x/W]` (applied after the rotation). For each candidate `cv` all near-vertical edge pixels are mapped through it; when `cv` is right every building edge becomes a single column and the column profile's energy peaks (coarse step 0.02, fine 0.002). *Synthetic validation:* error ≤ 0.003 in `cv` for convergences of 5–20 %, exactly 0 for a frontal facade.
Auto-apply requires confidence ≥ 0.35, enough straight vertical structure (≥ 12 % of edges), plausible magnitude, and — for landscapes — much stronger evidence. Horizontal keystone is only corrected automatically for frontal facades/documents. 85 % of the measured correction is applied (fully corrected verticals tend to look top-heavy), and corrections are reduced until at least 65 % of the image area survives the crop. Otherwise the manual sliders are offered with an explanation.

### Geometry & crop (`GeometryModel`)
One model drives detection, rendering (single `CIPerspectiveTransform`), and the crop: the largest axis-aligned rectangle of the original aspect ratio inside the transformed quadrilateral (binary search over a small grid of centre offsets; matches the analytic formula for pure rotation).

## 3. Decision engine (`AutoEnhanceEngine`)

Deterministic, explainable rules on top of the measurements — every decision is shown to the user ("Brightened by 0.4 EV", "Removed a cool/blue colour cast", "Recognized: landscape").

- **Exposure:** target mid-tone 0.46 (night 0.30, snow/high-key 0.62, documents 0.62; faces weighted 60 %), 70 % of the full correction, limited by highlight headroom.
- **Highlights / shadows / whites / blacks / contrast:** from clipping, bright/dark fractions, projected percentiles and luma spread; portraits get gentler contrast.
- **Vibrance:** only for dull images; capped with faces; reduced for already saturated images.
- **Detail:** noise reduction when the noise estimate or ISO is high; sharpening and clarity by scene type.
- **Strength:** Subtle × 0.55, Balanced × 1.0, Strong × 1.4.
- **Self-check:** the recipe is rendered on the analysis image and re-measured; if clipping or saturation grew too much, exposure/highlights/vibrance are pulled back (up to two iterations).

## 4. Rendering

Built-in Core Image filters only (exposure, colour matrix, highlight/shadow, a 5-point tone curve in gamma space, vibrance, saturation, unsharp-mask clarity, perspective transform, noise reduction, luminance sharpening). Working space: extended linear sRGB, half-float. GPU via Metal when available, otherwise Core Image's CPU renderer (setting "Use CPU rendering"). All spatial parameters scale with image size, so previews and exports match.

## 5. Hardware adaptation (`HardwareProfile`)

| | Apple Silicon | Intel |
|---|---|---|
| Batch workers | cores/2, 2–6 | cores/3, 1–3 |
| Analysis workers | cores−2, 2–8 | cores/2, 2–4 |
| Memory cap | ≤ 1 worker per 4 GB RAM | same |

Rosetta is detected (`sysctl.proc_translated`). Exports and 1:1 zoom are the only full-resolution decodes; everything else uses ImageIO's downsampling decoder.
