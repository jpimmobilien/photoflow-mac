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

| Model | Download | Native size | Min. macOS | Hardware | Licence |
|---|---|---|---|---|---|
| Stable Diffusion 2.1 (float16) | 2.6 GB | 512 px | 13.1 | Apple Silicon, Intel | CreativeML Open RAIL++-M |
| Stable Diffusion 2.1 Compact (6-bit) | 1.1 GB | 512 px | 14 | Apple Silicon (8 GB+), Intel | CreativeML Open RAIL++-M |
| Stable Diffusion XL (4.5-bit mixed) | 3.4 GB | 1024 px | 14 | Apple Silicon, 16 GB+ | CreativeML Open RAIL++-M |
| Stable Diffusion XL (float16) | 7.0 GB | 1024 px | 14 | Apple Silicon, 32 GB recommended | CreativeML Open RAIL++-M |
| Real-ESRGAN x4plus / x2plus | 31 MB each | 256 px tiles | 13 | all | BSD 3-Clause |
| Real-ESRGAN General x4v3 | 2 MB | 256 px tiles | 13 | all | BSD 3-Clause |
| LaMa (Big-LaMa) | 190 MB | 800 px | 13 | all | Apache 2.0 |

The diffusion models come straight from Apple's Hugging Face repositories (Core ML conversions of Stability AI's
weights). Real-ESRGAN and LaMa have no official Core ML release; they are converted from the original weights by a
public workflow in this repository (`.github/workflows/ai-models.yml`), published as release `ai-models-v1`, and the
original weight checksums are recorded in the release manifests. Downloads are only accepted over HTTPS from
`huggingface.co` / `hf.co` / `github.com` / `githubusercontent.com` (redirects included). Archives are rejected if they
contain links; models contain no executable code.

**Why not FLUX, SDXL-Turbo, …?** see `THIRD_PARTY_LICENSES.md` (licence or hardware reasons).

## Hardware

`AIHardware` reads architecture, chip (e.g. "Apple M2 Pro"), Apple Silicon generation, Neural Engine, Metal GPU
family, memory, free disk space and macOS version, and assigns a tier:

| Tier | Recommended model | Variants per run | Compute units (diffusion) |
|---|---|---|---|
| Intel | SD 2.1 (float16) | up to 2 | text encoder on the CPU, UNet + VAE on the GPU |
| Apple Silicon < 16 GB | SD 2.1 Compact | up to 2 | CPU + GPU |
| Apple Silicon ≥ 16 GB | SDXL (4.5-bit) | up to 4 | CPU + GPU |

Image generation needs a Metal GPU: measured on macOS 15 (`--qa ai-diag`), Core ML's CPU-only path cannot run these
float16 models correctly (on x86 the UNet does not run at all and the VAE returns wrong values). PhotoFlow therefore
never silently falls back to the CPU for diffusion; a GPU error triggers one clean reload, and a result that is
empty/uniform is rejected with an explanation instead of being shown. Real-ESRGAN and LaMa run on the CPU, GPU or
Neural Engine. MLX is not used (it is Apple-Silicon-only); Core ML runs on both architectures. Models that cannot run
(macOS too old, Intel for SDXL, too little memory, no Metal GPU) cannot be downloaded and say why; models that run
slowly show a warning.

**Performance profiles:** Energy saving (×0.75 steps, low-memory loading, models released after 1 min), Balanced,
Maximum quality (×1.25 steps), Maximum speed (×0.7 steps, models kept loaded for 15 min). Low-memory mode
(`reduceMemory`) is used automatically when the Mac has less than 1.5× the recommended memory.

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
- **Outpainting:** the canvas is enlarged, new areas are pre-filled with stretched, blurred edges, and the new areas
  plus a narrow seam band are regenerated with the same inpainting path. Original pixels stay unchanged.
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
whole suite on GitHub's Intel and Apple Silicon runners. Results: see `TEST_REPORT.md` (AI Studio section).
