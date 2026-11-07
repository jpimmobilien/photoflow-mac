# Duplicate & similar-photo detection

PhotoFlow finds two kinds of duplicates and **never deletes anything automatically** — it groups, scores, recommends, and the user decides.

## Pipeline

```
photos ──► cache lookup (signature = size + mtime; Vision revision)
       ├─► EXACT: files with equal byte size → streaming SHA-256 → identical hashes
       └─► VISUAL: 512 px thumbnail (ImageIO, embedded preview when large enough)
              ├─ aHash / dHash / pHash (64 bit each)
              ├─ Vision feature print (L2-normalised vector)
              ├─ sharpness, exposure quality, aesthetics (macOS 15+)
              ▼
         candidate pairs
              ├─ feature vectors: blocked matrix product A·Aᵀ (BLAS sgemm) → cosine ≥ floor
              └─ pHash Hamming distance ≤ 10
              ▼
         pair score 0–100 (SimilarityScorer)
              └─ borderline pairs with different framing → Vision homographic registration
                 + normalized cross-correlation (crop / reframe verification)
              ▼
         union-find grouping → anchor = recommended photo → members must match the anchor
              ▼
         groups with category, similarity, recommendation and reasons
```

### Exact duplicates
SHA-256 (CryptoKit, 1 MB streaming) — computed only for files whose byte size collides with another file, so a 10,000-photo library typically hashes a handful of files. File names and locations are irrelevant.

### Visual duplicates
| Evidence | Robust to | Weak at |
|---|---|---|
| pHash (DCT) | resizing, recompression, mild colour/brightness changes | crops, rotations |
| dHash / aHash | resizing, compression | brightness shifts (aHash) |
| Vision feature print | crops, reframing, colour edits, B&W, bursts | — (semantic: may rate *different* photos of the same subject as similar) |
| Registration + NCC | crops / different framing of the same original | only run on candidates |

Hash evidence is only trusted when the feature print does not contradict it (cosine ≥ 0.80): simple images such as skies or walls can share hashes while being different photos.

### Score → category
Default UI categories (configurable in Settings ▸ Duplicates):

| Category | Score |
|---|---|
| Exact duplicate | identical SHA-256 |
| Very similar | ≥ 95 |
| Similar | 85 – 95 |
| Possibly similar | 70 – 85 |

These are **practical starting points, not mathematical guarantees**. The feature-print → score mapping is a piecewise-linear table (`SimilarityScorer.featureKnots`) calibrated with `PhotoFlow --qa eval-dup`, which prints recall per variant type and the cosine distributions for same-source and different-source pairs (see TEST_REPORT.md).

Sensitivity: the Duplicate Finder defaults to ≥ 95 (exact + very similar), Similar Photos to ≥ 80. Both sliders are adjustable per scan.

### Grouping without chains
Plain connected components can chain A~B~C~D into one group although A and D differ. PhotoFlow therefore requires every member to reach the threshold **against the group's recommended photo**; the rest are re-grouped separately.

## Best version to keep

Each member gets a weighted, group-normalised score:

| Factor | Weight |
|---|---|
| Resolution | 0.28 |
| Sharpness (variance of Laplacian) | 0.20 |
| Exposure quality (clipping, mid-tones, range) | 0.12 |
| Original format (RAW > TIFF/PNG > HEIC > JPEG > WebP) | 0.10 |
| Bytes per pixel (less compression) | 0.08 |
| Metadata completeness (date, camera, lens, exposure) | 0.08 |
| Original-looking file name (not "copy", "Kopie", "(1)", "-edited" …) | 0.06 |
| Apple aesthetics score (macOS 15+), otherwise exposure again | 0.08 |
| Already edited in PhotoFlow | +0.04 |

The UI shows the reasons ("Highest resolution", "Sharpest image", "Original RAW file", …).

## Review & deletion
Keep / Select for deletion per photo, "Keep this photo only", "Select all except recommended" (per group or globally), "Keep all", side-by-side comparison, Quick Look, Reveal in Finder. Deleting moves files to the **macOS Trash** after a confirmation that states the number of files and bytes; if every photo of a group is selected, the recommended one is kept automatically. Trashed photos can be restored from PhotoFlow's Trash view (with edits, favourites and albums).

## Performance
- Thumbnail decode instead of full images; parallel analysis (2–8 workers by hardware).
- Persistent cache in the library database; unchanged files are never re-analysed.
- All-pairs similarity via BLAS: 10,000 photos ≈ 50 M comparisons as a few large matrix products.
- Progress reporting per phase and cancellation at every stage.
