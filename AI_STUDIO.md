# AI Studio – local image generation and AI editing

AI Studio is the generative part of PhotoFlow. **Every model runs on the Mac** through Apple's Core ML. There is
no cloud API (no OpenAI, Firefly, Gemini, Midjourney or Stability API), no account, no telemetry, and prompts or
images are never uploaded. The internet is used for exactly one thing: downloading a model the user chose,
from its official source. Afterwards everything works offline (verified in CI with networking blocked, see below).

## Sections

| Section | What it does | Technique |
|---|---|---|
| Generate Image | Text to image, 6 formats, 4 quality levels, 1/2/4 variants, 12 photographic styles, seed / steps / guidance / negative prompt | Stable Diffusion (Core ML), DPM-Solver++ scheduler |
| Edit Image | Image to image with strength, style, before/after slider | SD with VAE-encoded starting image |
| Generative Fill | Brush, eraser, rectangle, ellipse, refine (grow/shrink), invert, clear, soft edge; three modes: fill with prompt, remove object, replace background | masked-latent inpainting; LaMa; Vision subject mask |
| Expand Image | Drag the four edges or use presets (16:9, 1:1, 9:16, 4:3, +25 %) | outpainting with the same inpainting path |
| Enhance Image | Restore detail, remove noise & artefacts, background blur, Auto Enhance; "Portrait retouch" is shown as not available | Real-ESRGAN, Vision + Core Image, PhotoFlow's analysis engine |
| AI Upscaling | 2×, 4×, 8× with result size and file-size estimate | tiled Real-ESRGAN |
| My AI Creations | Persistent gallery with search, filter, sort; prompt/model/seed/settings; regenerate, variants, edit, export, save to library, delete | JSON + PNG in Application Support |
| Model Management | Hardware profile, performance profile, every model with licence, size, memory, requirements, status, version; download / pause / resume / cancel / update / remove / set default | URLSession + SHA-256 |

## Models

The catalog (`Sources/PhotoFlow/AI/AIModelCatalog.swift`, files in `AIModelCatalogData.swift`) pins every file to
an exact revision with size and SHA-256:

| Model | Download | Native size | Runs on | Min. macOS | Hardware | Licence |
|---|---|---|---|---|---|---|
| Stable Diffusion 2.1 · Neural Engine (6-bit) | 1.1 GB | 512 px | Neural Engine | 14 | Apple Silicon, 6 GB+ | CreativeML Open RAIL++-M |
| Stable Diffusion 1.5 · Neural Engine (6-bit) | 0.96 GB | 512 px | Neural Engine | 14 | Apple Silicon, 6 GB+ | CreativeML Open RAIL-M |
| Stable Diffusion 2.1 (float16) | 2.6 GB | 512 px | GPU | 13.1 | Apple Silicon, Intel (8 GB+) | CreativeML Open RAIL++-M |
| Stable Diffusion 1.5 (float16) | 2.1 GB | 512 px | GPU | 13.1 | Apple Silicon, Intel (8 GB+) | CreativeML Open RAIL-M |
| Stable Diffusion 2.1 Compact (6-bit) | 1.1 GB | 512 px | GPU | 14 | Apple Silicon (8 GB+) | CreativeML Open RAIL++-M |
| Stable Diffusion XL (4.5-bit mixed) | 3.4 GB | 1024 px | GPU | 14 | Apple Silicon, 16 GB+ | CreativeML Open RAIL++-M |
| Stable Diffusion XL (float16) | 7.0 GB | 1024 px | GPU | 14 | Apple Silicon, 24 GB+ (32 GB recommended) | CreativeML Open RAIL++-M |
| Precise image decoder (VAE, float32) | 311 MB | 512 px | GPU / CPU | 13 | all – installed automatically with SD 1.5/2.1 | MIT |
| Real-ESRGAN x4plus / x2plus | 31 MB each | 256 px tiles | all | 13 | all | BSD 3-Clause |
| Real-ESRGAN General x4v3 | 2 MB | 256 px tiles | all | 13 | all | BSD 3-Clause |
| LaMa (Big-LaMa) | 190 MB | 800 px | all | 13 | all | Apache 2.0 |

The diffusion models come straight from Apple's Hugging Face repositories (Core ML conversions of Stability AI's
weights). The float32 VAE (stabilityai/sd-vae-ft-mse), Real-ESRGAN and LaMa have no official Core ML release; they are
converted from the original weights by a public workflow in this repository (`.github/workflows/ai-models.yml`,
`Scripts/ai/convert_vae.py`), published as release `ai-models-v1`, and the original weight checksums are recorded in
the release manifests. Downloads are only accepted over HTTPS from `huggingface.co` / `hf.co` / `github.com` /
`githubusercontent.com` (redirects included). Archives are rejected if they contain links; models contain no
executable code.

**Why a separate float32 VAE?** Apple's float16 VAE is computed wrongly by Core ML on the CPU (measured on x86 and ARM,
see `AI_FEHLERANALYSE.md` §2.3), which produced the "empty" grey images. PhotoFlow's float32 VAE has the same interface
and is correct on every compute unit; it replaces Apple's VAE for SD 1.5 / 2.1 automatically.

**Why two compute paths (GPU and Neural Engine)?** They are independent implementations inside Core ML. If a model
produces invalid images on a Mac, PhotoFlow marks it as failed on that Mac and switches to an installed model of the
other path (same resolution) – and says so.

**Why not FLUX, SDXL-Turbo, SD 3.5 …?** see `AI_FEHLERANALYSE.md` §4 and `THIRD_PARTY_LICENSES.md` (licence, access
or hardware reasons).

## Hardware

`AIHardware` reads architecture, chip (e.g. "Apple M2 Pro"), Apple Silicon generation, Neural Engine, Metal GPU
family, memory, free disk space and macOS version, and recommends a model (models that already failed on this Mac are
skipped):

| Mac | Recommended model (in order) | Compute units (diffusion) |
|---|---|---|
| Apple Silicon < 16 GB, macOS 14+ | SD 2.1 · Neural Engine → SD 1.5 · Neural Engine → SD 2.1 Compact | CPU + Neural Engine (GPU models: CPU + GPU) |
| Apple Silicon ≥ 16 GB, macOS 14+ | SDXL (4.5-bit) → SD 2.1 · Neural Engine → SD 2.1 Compact | CPU + GPU (Neural Engine models: CPU + NE) |
| Apple Silicon, macOS 13 | SD 1.5 → SD 2.1 (float16) | CPU + GPU |
| Intel with Metal GPU | SD 1.5 → SD 2.1 (float16) | text encoder on the CPU, UNet on the GPU, float32 VAE on the CPU |
| No usable Metal GPU | Neural Engine models only (Apple Silicon); otherwise no image generation | – |

### Compatibility matrix

Status legend: **supported** = expected to work fully; **limited** = works with restrictions; **not supported** =
not offered. The column *Verified* says what was actually measured – nothing else is claimed.

| Function | Apple Silicon (M1–M4) | Intel Mac with Metal GPU | Verified |
|---|---|---|---|
| Text to image, SD 1.5 / 2.1 (GPU) | supported | limited (minutes per image) | ✓ full pipeline on Apple-Silicon **CPU** (GitHub M1 VM) and Intel VM; **real Mac GPU: pending hardware test** |
| Text to image, SD 1.5 / 2.1 (Neural Engine) | supported (macOS 14+) | not supported | **pending hardware test** (VMs have no Neural Engine) |
| Text to image, SDXL | supported with ≥ 16 GB | not supported | **pending hardware test** (runners have 7 GB) |
| Image to image, generative fill, expand, background replacement | supported | limited (slow) | ✓ Apple-Silicon CPU (VM), Intel VM; real GPU / NE: pending |
| Object removal (LaMa) | supported | supported | ✓ Intel VM, Apple-Silicon VM |
| Upscaling (Real-ESRGAN), enhance | supported | supported | ✓ Intel VM |
| Offline operation | supported | supported | ✓ network blocked by sandbox during generation |

"Pending hardware test" means: run *Model Management ▸ Hardware test ▸ Full test* (or
`/Applications/PhotoFlow.app/Contents/Resources/ai_hardware_test.sh full`) on the Mac. The report (`report.md`,
`report.json`, `index.html` and all images) is written to `~/Pictures/PhotoFlow KI-Hardwaretest/<date>/`; results go
into `TEST_REPORT.md` §4.

Every generated image is checked before it is shown (`AIImageValidator`: brightness spread, noise measure, share of
black/white pixels, calibrated on real outputs). An invalid image is never shown: the model is reloaded once; if the
result is still invalid, the model is marked as not working on this Mac and the other compute path is used if
installed. Real-ESRGAN and LaMa run on the CPU, GPU or Neural Engine.

**Performance profiles:** Energy saving (×0.75 steps, low-memory loading, models released after 1 min), Balanced,
Maximum quality (×1.25 steps), Maximum speed (×0.7 steps, models kept loaded for 15 min). Low-memory mode
(`reduceMemory`) is used automatically when the Mac has less than 1.5× the recommended memory (Neural Engine models:
below 7.5 GB).

## How the editing operations work

- **Formats:** the Core ML UNets have a fixed square latent shape, so other formats are cropped from the generated
  square (the UI says so). *Free resolution* is therefore not offered. *High* / *Maximum* quality add 2× / 4×
  Real-ESRGAN upscaling when it is installed.
- **Inpainting (Generative Fill):** a context region around the mask (mask bounds + 45 % margin, at least the model
  size) is cut out and letterboxed into the model square. Generation starts from the VAE-encoded region; after every
  scheduler step the region outside the mask is replaced by the original latent re-noised to the next timestep
  (`Sources/StableDiffusion/pipeline/LatentInpainting.swift`), and the last step uses the clean original. The result is
  scaled back (Real-ESRGAN when it helps) and blended through the feathered mask, so pixels outside the mask are
  exactly the original ones and the rest of the photo keeps its full resolution.
- **Outpainting:** the canvas is enlarged and the new areas are pre-filled with a blurred mirror of the photo. Each new
  strip is then regenerated tile by tile at model resolution; every tile contains real photo content next to the new
  area, so the model continues the existing scene. Tiles overlap with soft, feathered seams, the prompt defaults to an
  on-device (Vision) description of the photo, and the original pixels are restored exactly at the end.
- **Object removal:** LaMa on a square context crop (800 px model input) with a slightly grown mask; without LaMa,
  Stable Diffusion inpainting is used and the result is labelled accordingly.
- **Background replacement:** Vision's foreground instance mask (macOS 14+, person segmentation on 13), correctable
  with brush/eraser; the background is regenerated, the original subject composited on top, plus a soft contact shadow.
- **Upscaling:** 256 px tiles with 16 px overlap; only tile centres are kept, so there are no seams. 8× = 4× then 2×.
  Output is limited to 20,000 px per side / 240 MP.
- **Prompt assistant:** Apple's on-device language model (FoundationModels, macOS 26 with Apple Intelligence) when
  available; otherwise transparent rule-based templates labelled "no AI". Generation never depends on it.

## Library integration and provenance

Results are saved as PNG in *My AI Creations*. "Save to Library" writes a copy to `~/Pictures/PhotoFlow AI/` and
imports it (optionally into an album or a new album, or opens it in the editor). Every file carries XMP metadata:
IPTC **Digital Source Type** `trainedAlgorithmicMedia` (generated) or `compositeWithTrainedAlgorithmicMedia` (AI edits),
`dc:description`, `xmp:CreatorTool` and PhotoFlow fields (operation, model, prompt, negative prompt, style, seed,
settings, source). AI edits never overwrite an original – each is a new file (a new version).

## Stability

- One heavy AI job at a time on a dedicated queue; the UI stays responsive (generation off the main thread).
- Cancel at any step (checked every scheduler step and every upscaling tile).
- Models are released after an idle time and on macOS memory-pressure warnings.
- Disk space is checked before downloads (download + room for extraction + 500 MB).
- Downloads resume after pause or interruption (URLSession resume data, otherwise per verified file).
- Clear error messages with a way forward (no internet, no model, not enough memory/disk, damaged file, …).

## Data and privacy

| What | Where |
|---|---|
| Models | `~/Library/Application Support/PhotoFlow/Models/<id>/` |
| Creations (PNG + `creations.json`) | `~/Library/Application Support/PhotoFlow/AI Studio/` |
| Images saved to the library | `~/Pictures/PhotoFlow AI/` |

Nothing else is stored or sent anywhere.

## Tests

`PhotoFlow --qa ai-*` runs real downloads and real inference (no mocks); `.github/workflows/ai-test.yml` runs the
whole suite on GitHub's Intel and Apple Silicon runners. The hardware acceptance test (`--qa ai-acceptance`, also in
Model Management) runs 10/20 consecutive generations with several prompts, seeds, variants and formats, cancel, model
switching, load/unload cycles, all editing operations and a check after an app restart, and validates every PNG after
reading it back. Results: `TEST_REPORT.md` §3–4; root-cause analysis: `AI_FEHLERANALYSE.md`.
