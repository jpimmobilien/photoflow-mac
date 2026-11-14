import Foundation
import CoreGraphics
import Vision

/// Decides whether a generated image has plausible photographic content.
///
/// Calibrated on real outputs (see TEST_REPORT.md §3): natural images have a luma spread of 0.15–0.20 and a
/// Laplacian/spread ratio of 0.13–0.19; the broken outputs seen on virtual GPUs were either uniform
/// (spread < 0.01) or fine-grained noise textures (ratio ≈ 3). Random noise has a ratio of ≈ 2.7.
enum AIImageValidator {
    struct Metrics: Codable, Equatable {
        var mean: Double
        var spread: Double          // standard deviation of luma (0…1)
        var detailRatio: Double     // mean |Laplacian| / spread – high for noise
        var extremeFraction: Double // share of near-black or near-white pixels
    }

    struct Verdict {
        var valid: Bool
        var reason: String?
        var metrics: Metrics
    }

    static func metrics(_ image: CGImage) -> Metrics {
        let side = 256
        guard let pb = PixelBuffer(cgImage: image, maxSide: side) else { return Metrics(mean: 0, spread: 0, detailRatio: 0, extremeFraction: 1) }
        let l = pb.luma()
        let w = pb.width, h = pb.height
        let n = Double(l.count)
        let mean = l.reduce(0.0) { $0 + Double($1) } / max(1, n)
        let variance = l.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / max(1, n)
        let spread = sqrt(variance)
        var lap = 0.0, count = 0.0
        if w > 2 && h > 2 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let c = Double(l[y * w + x])
                    let v = 4 * c - Double(l[(y - 1) * w + x]) - Double(l[(y + 1) * w + x]) - Double(l[y * w + x - 1]) - Double(l[y * w + x + 1])
                    lap += abs(v); count += 1
                }
            }
        }
        let extreme = Double(l.filter { $0 < 0.02 || $0 > 0.98 }.count) / max(1, n)
        return Metrics(mean: mean, spread: spread, detailRatio: spread > 1e-6 ? (lap / max(1, count)) / spread : 0, extremeFraction: extreme)
    }

    static func check(_ image: CGImage) -> Verdict {
        let m = metrics(image)
        if m.spread < 0.03 {
            return Verdict(valid: false, reason: String(localized: "The image is (almost) uniform."), metrics: m)
        }
        if m.detailRatio > 0.9 {
            return Verdict(valid: false, reason: String(localized: "The image consists of noise instead of picture content."), metrics: m)
        }
        if m.extremeFraction > 0.9 {
            return Verdict(valid: false, reason: String(localized: "The image is almost entirely black or white."), metrics: m)
        }
        return Verdict(valid: true, reason: nil, metrics: m)
    }

    /// Apple's on-device scene classifier: the top labels with their confidence (used by the acceptance test to
    /// confirm that "a cat on a sofa" actually shows a cat).
    static func labels(_ image: CGImage, limit: Int = 5) -> [(String, Double)] {
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return [] }
        return obs.sorted { $0.confidence > $1.confidence }.prefix(limit).map { ($0.identifier, Double($0.confidence)) }
    }
}
