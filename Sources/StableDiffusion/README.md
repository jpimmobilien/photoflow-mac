# StableDiffusion (vendored)

Swift Core ML pipeline from [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion), MIT licence
(see LICENSE.md), upstream revision in UPSTREAM_REVISION.

Changes for PhotoFlow:
- Stable Diffusion 3 files removed (they need the swift-transformers dependency and are not used).
- `pipeline/LatentInpainting.swift` (new) plus an optional `inpainting:` parameter on `generateImages` of both
  pipelines (and the protocol): masked-latent inpainting / outpainting with the standard UNets. After every
  scheduler step the preserved region is replaced with the encoded original re-noised to the next timestep.
