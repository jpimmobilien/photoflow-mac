// PhotoFlow addition (not part of apple/ml-stable-diffusion).
// Per-step numerical statistics of the sampling loop, used to find where a run goes wrong
// (non-finite values, exploding or collapsing latents) instead of guessing from the final image.

import Foundation
import CoreML

public struct PipelineStepStats: Sendable, Codable {
    public var step: Int
    public var noiseStd: Float
    public var latentStd: Float
    public var nonFinite: Int
}

public enum PipelineDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [PipelineStepStats] = []
    nonisolated(unsafe) private static var decoded: (mean: Float, std: Float, nonFinite: Int)?

    public static func reset() { lock.lock(); steps = []; decoded = nil; lock.unlock() }

    public static var lastRun: [PipelineStepStats] { lock.lock(); defer { lock.unlock() }; return steps }

    /// Short human-readable summary, e.g. "steps 1–20: latent std 1.00 → 0.98, non-finite 0".
    public static var summary: String {
        lock.lock(); defer { lock.unlock() }
        guard let first = steps.first, let last = steps.last else { return "no steps" }
        let bad = steps.first { $0.nonFinite > 0 }
        var s = String(format: "steps %d–%d: latent std %.3f → %.3f, noise std %.3f → %.3f", first.step, last.step,
                       first.latentStd, last.latentStd, first.noiseStd, last.noiseStd)
        if let bad { s += ", first non-finite values at step \(bad.step) (\(bad.nonFinite))" } else { s += ", all values finite" }
        return s
    }

    static func stats(_ a: MLShapedArray<Float32>) -> (std: Float, nonFinite: Int) {
        var sum: Double = 0, sq: Double = 0, n = 0, bad = 0
        a.withUnsafeShapedBufferPointer { p, _, _ in
            for v in p {
                if v.isFinite { sum += Double(v); sq += Double(v) * Double(v); n += 1 } else { bad += 1 }
            }
        }
        let mean = n > 0 ? sum / Double(n) : 0
        let variance = n > 0 ? max(0, sq / Double(n) - mean * mean) : 0
        return (Float(variance.squareRoot()), bad)
    }

    static func record(step: Int, noise: [MLShapedArray<Float32>], latents: [MLShapedArray<Float32>]) {
        guard let n = noise.first, let l = latents.first else { return }
        let ns = stats(n), ls = stats(l)
        lock.lock()
        steps.append(PipelineStepStats(step: step + 1, noiseStd: ns.std, latentStd: ls.std, nonFinite: ns.nonFinite + ls.nonFinite))
        lock.unlock()
    }
}
