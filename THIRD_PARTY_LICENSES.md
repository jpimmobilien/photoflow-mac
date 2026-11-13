# Third-party licenses

## Code included in PhotoFlow

| Component | Source | Licence | Where |
|---|---|---|---|
| Core ML Stable Diffusion (Swift pipeline, tokenizer, schedulers) | [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion), revision in `Sources/StableDiffusion/UPSTREAM_REVISION` | MIT (`Sources/StableDiffusion/LICENSE.md`) | `Sources/StableDiffusion/` – vendored; PhotoFlow added masked-latent inpainting (`LatentInpainting.swift`) and removed the unused SD3 files |

Build-time only (not part of the app): `Scripts/ai/lama/CoreMLaMa.py` and `convert_lama.py` from
[mallman/CoreMLaMa](https://github.com/mallman/CoreMLaMa) (Apache 2.0, `Scripts/ai/lama/LICENSE.txt`) are used by the
public GitHub workflow that converts LaMa to Core ML. The Real-ESRGAN network definitions in
`Scripts/ai/convert_realesrgan.py` follow [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) / BasicSR (BSD 3-Clause / Apache 2.0).

## Machine-learning models (optional downloads – never bundled)

The DMG contains **no model weights**. Users choose in *AI Studio ▸ Model Management* which models to download.
Every file is pinned to an exact revision and verified with SHA-256 (`Sources/PhotoFlow/AI/AIModelCatalogData.swift`).

| Model | Publisher / source | Licence | Private use | Commercial use | Notes |
|---|---|---|---|---|---|
| Stable Diffusion 2.1 base (Core ML, float16 and 6-bit palettized) | Stability AI; Core ML conversion by Apple – [apple/coreml-stable-diffusion-2-1-base](https://huggingface.co/apple/coreml-stable-diffusion-2-1-base), [-palettized](https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized) | CreativeML Open RAIL++-M | ✓ | ✓ | Use-based restrictions (Attachment A of the licence); generated images belong to the user; redistribution of the weights must carry the same licence |
| Stable Diffusion XL 1.0 base (Core ML, 4.5-bit mixed palettization and float16) | Stability AI; Core ML conversion by Apple – [apple/coreml-stable-diffusion-mixed-bit-palettization](https://huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization), [apple/coreml-stable-diffusion-xl-base](https://huggingface.co/apple/coreml-stable-diffusion-xl-base) | CreativeML Open RAIL++-M | ✓ | ✓ | as above |
| Real-ESRGAN x4plus, x2plus, General x4v3 | Xintao Wang et al. – [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN); Core ML conversion by PhotoFlow's public workflow (`.github/workflows/ai-models.yml`), release `ai-models-v1` | BSD 3-Clause | ✓ | ✓ | Original `.pth` weights' SHA-256 recorded in the release manifest |
| Big-LaMa | Samsung AI Center – [advimman/lama](https://github.com/advimman/lama); TorchScript export used by IOPaint; Core ML conversion via CoreMLaMa by PhotoFlow's public workflow, release `ai-models-v1` | Apache 2.0 | ✓ | ✓ | |

Models considered and **not** offered: FLUX.1 schnell (Apache 2.0, but gated download, ~24 GB and no Core ML version;
MLX ports need Apple Silicon only), SDXL-Turbo / SD-Turbo (non-commercial licence), Stable Diffusion 1.5 (licence
listed as "other" by the current host), GFPGAN / CodeFormer face restoration (dependencies or weights under
non-commercial licences) – therefore "Portrait retouch" is shown as unavailable.

## Components of macOS

| Component | Provider | Notes |
|---|---|---|
| SwiftUI, AppKit, Foundation, Core Image, Core Graphics, ImageIO, Vision, Metal, Core ML, Accelerate, CryptoKit, QuickLook, UniformTypeIdentifiers, NaturalLanguage | Apple (macOS SDK) | System frameworks |
| FoundationModels (Apple Intelligence on-device language model, macOS 26+) | Apple | Optional prompt assistant; weak-linked, used only when available |
| On-device Vision models (classification, faces, horizon, saliency, feature prints, registration, aesthetics, subject / person segmentation) | Apple, part of macOS | Not bundled and not downloaded by PhotoFlow |
| SQLite (`libsqlite3`) | System library | Public domain |
| SF Symbols | Apple | Used through the system |

The app icon and the DMG background were created for PhotoFlow (`Scripts/make_icon.py`).
