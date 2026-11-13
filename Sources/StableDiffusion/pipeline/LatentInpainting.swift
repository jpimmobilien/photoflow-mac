// PhotoFlow addition (not part of apple/ml-stable-diffusion).
// Masked-latent inpainting for standard (4-channel) Stable Diffusion UNets.
//
// After every scheduler step the region that must be preserved is replaced by the
// encoded original, re-noised to the timestep the sampler will process next. The region
// inside the mask is generated freely by the model, conditioned on its surroundings.
// The last step blends with the clean original latent; the caller then composites the
// decoded image over the source with a feathered pixel mask so unmasked pixels stay exact.

import Foundation
import CoreML
import CoreGraphics

/// Inpainting request for `generateImages(configuration:inpainting:progressHandler:)`.
@available(iOS 16.2, macOS 13.1, *)
public struct LatentInpainting {
    /// Source image, already scaled to exactly the model's input size.
    public var image: CGImage
    /// Mask at latent resolution (row-major, height × width of the latent), 1 = regenerate, 0 = keep.
    public var latentMask: [Float]

    public init(image: CGImage, latentMask: [Float]) {
        self.image = image
        self.latentMask = latentMask
    }
}

@available(iOS 16.2, macOS 13.1, *)
public enum LatentInpaintingError: Error, LocalizedError {
    case missingEncoder
    case maskSizeMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .missingEncoder: return "The model has no VAE encoder, so it cannot edit existing images."
        case .maskSizeMismatch(let e, let g): return "Mask has \(g) values, the model expects \(e)."
        }
    }
}

@available(iOS 16.2, macOS 13.1, *)
struct InpaintState {
    let original: MLShapedArray<Float32>       // clean latent [1, C, H, W]
    let noise: [MLShapedArray<Float32>]        // fixed noise per image
    let mask: [Float32]                        // H*W
    let channels: Int
    let plane: Int

    /// Prepares the starting latents and the state used for blending.
    static func prepare(_ request: LatentInpainting,
                        configuration config: PipelineConfiguration,
                        sampleShape unetShape: [Int],
                        encoder: Encoder?,
                        scheduler: Scheduler,
                        random: inout RandomSource) throws -> ([MLShapedArray<Float32>], InpaintState) {
        guard let encoder else { throw LatentInpaintingError.missingEncoder }
        var shape = unetShape
        shape[0] = 1
        let channels = shape[1]
        let plane = shape[2] * shape[3]
        guard request.latentMask.count == plane else {
            throw LatentInpaintingError.maskSizeMismatch(expected: plane, got: request.latentMask.count)
        }
        let stdev = scheduler.initNoiseSigma
        let noise = (0..<config.imageCount).map { _ in
            MLShapedArray<Float32>(converting: random.normalShapedArray(shape, mean: 0.0, stdev: Double(stdev)))
        }
        let original = try encoder.encode(request.image, scaleFactor: config.encoderScaleFactor, random: &random)
        let start: [MLShapedArray<Float32>]
        if config.strength < 1.0 {
            start = scheduler.addNoise(originalSample: original, noise: noise, strength: config.strength)
        } else {
            start = noise
        }
        let state = InpaintState(original: original, noise: noise,
                                 mask: request.latentMask.map { Float32(min(max($0, 0), 1)) },
                                 channels: channels, plane: plane)
        return (start, state)
    }

    /// Replaces the preserved region of `latents` with the original at `timeStep`
    /// (or the clean original when `timeStep` is nil).
    func blend(_ latents: inout [MLShapedArray<Float32>], timeStep: Int?, scheduler: Scheduler) {
        let a: Float32
        let b: Float32
        if let t = timeStep, t < scheduler.alphasCumProd.count {
            let acp = scheduler.alphasCumProd[t]
            a = sqrt(acp)
            b = sqrt(1 - acp)
        } else {
            a = 1
            b = 0
        }
        let orig = original.scalars
        for i in latents.indices {
            var out = latents[i].scalars
            guard out.count == orig.count else { continue }
            let nz = noise[min(i, noise.count - 1)].scalars
            for c in 0..<channels {
                let base = c * plane
                for p in 0..<plane {
                    let m = mask[p]
                    if m >= 1 { continue }
                    let k = base + p
                    let known = a * orig[k] + b * nz[k]
                    out[k] = m * out[k] + (1 - m) * known
                }
            }
            latents[i] = MLShapedArray(scalars: out, shape: latents[i].shape)
        }
    }
}
