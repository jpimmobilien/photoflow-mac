import Foundation
import CoreGraphics
import Vision
import simd

/// Verifies that two images show the same original even if one is a crop or a resized/reframed version:
/// Vision's on-device homographic image registration aligns them, then normalized cross-correlation over
/// the overlapping area confirms (or rejects) the match. Used only for borderline candidate pairs.
enum CropVerifier {
    struct Match: Sendable {
        var correlation: Double   // NCC over the overlap, −1…1
        var overlap: Double       // overlap as fraction of the smaller image
    }

    static let workingSize = 192

    static func verify(_ a: CGImage, _ b: CGImage) -> Match? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: b, options: [:])
        let handler = VNImageRequestHandler(cgImage: a, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        let H = obs.warpTransform
        guard let ga = PerceptualHash.grayscale(a, a.width, a.height),
              let gb = PerceptualHash.grayscale(b, b.width, b.height) else { return nil }
        // The direction and y-origin conventions of the warp are tried explicitly; a wrong convention
        // simply produces a low correlation, so this is robust.
        var best: Match?
        for matrix in [H, H.inverse] {
            for flip in [false, true] {
                if let m = correlate(ga, a.width, a.height, gb, b.width, b.height, matrix, flipY: flip),
                   m.correlation > (best?.correlation ?? -2) {
                    best = m
                }
            }
        }
        return best
    }

    /// Samples a grid on image A, maps points into B and correlates the intensities.
    private static func correlate(_ ga: [Float], _ wa: Int, _ ha: Int, _ gb: [Float], _ wb: Int, _ hb: Int,
                                  _ H: simd_float3x3, flipY: Bool) -> Match? {
        var xs: [Float] = [], ys: [Float] = []
        let steps = 40
        var total = 0
        for j in 0 ..< steps {
            for i in 0 ..< steps {
                total += 1
                let x = (Float(i) + 0.5) / Float(steps) * Float(wa)
                let yTop = (Float(j) + 0.5) / Float(steps) * Float(ha)
                let y = flipY ? Float(ha) - yTop : yTop
                let p = H * SIMD3<Float>(x, y, 1)
                guard abs(p.z) > 1e-6 else { continue }
                let bx = p.x / p.z
                var by = p.y / p.z
                if flipY { by = Float(hb) - by }
                guard bx >= 0, by >= 0, bx < Float(wb - 1), by < Float(hb - 1) else { continue }
                xs.append(sample(ga, wa, x, yTop))
                ys.append(sample(gb, wb, bx, by))
            }
        }
        guard xs.count >= total / 6 else { return nil }
        let n = Float(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for k in 0 ..< xs.count {
            let dx = xs[k] - mx, dy = ys[k] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 1e-6, syy > 1e-6 else { return nil }
        let ncc = Double(sxy / sqrt(sxx * syy))
        // Overlap relative to the smaller image area (approximated via sample coverage of A, scaled by areas).
        let coverA = Double(xs.count) / Double(total)
        let areaRatio = Double(wa * ha) / Double(max(1, wb * hb))
        let overlap = min(1, coverA * max(1, areaRatio))
        return Match(correlation: ncc, overlap: overlap)
    }

    @inline(__always)
    private static func sample(_ g: [Float], _ w: Int, _ x: Float, _ y: Float) -> Float {
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let h = g.count / w
        let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let a = g[y0 * w + x0], b = g[y0 * w + x1], c = g[y1 * w + x0], d = g[y1 * w + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}
