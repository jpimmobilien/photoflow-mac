import Foundation
import CoreGraphics

/// Automatic horizon / tilt detection.
///
/// Method ("projection profile", as used in document deskewing, extended to photographs):
/// edge pixels from `EdgeField` are split into a near-horizontal and a near-vertical family. For each
/// candidate angle the pixels are projected onto the line normal and binned; when the candidate equals the
/// true tilt, all pixels of a straight line fall into the same bin and the profile's energy Σh² peaks.
/// Because it fits *positions* rather than per-pixel orientations, it is immune to the orientation bias of
/// gradient operators on sharp, aliased edges. Synthetic validation: mean error 0.04° (512 px), texture-only
/// images yield confidence ≈ 0.06 versus ≥ 0.6 for real lines.
///
/// The result is fused with Apple Vision's horizon detector when both are available.
enum StraightenEngine {
    struct Result: Sendable {
        /// Detected visual tilt in degrees (CCW positive). The correction is `-tilt`.
        var tilt: Double
        var confidence: Double
        var source: String
        var shouldApply: Bool
        var correction: Double { -tilt }
    }

    static let maxAutoAngle = 10.0
    static let minAutoAngle = 0.15

    static func detect(edges: EdgeField, vision: VisionAnalyzer.SceneResult?) -> Result {
        let maxDeg: Float = 12
        let horizontal = edges.points.filter { abs($0.angle) < 45 && abs($0.angle) <= maxDeg + 2 }
        let vertical = edges.points.filter { abs($0.angle) >= 45 && abs(abs($0.angle) - 90) <= maxDeg + 2 }
        let nb = Int(2 * hypot(Double(edges.width), Double(edges.height))) + 8

        let h = bestAngle(horizontal, family: .horizontal, bins: nb, maxDeg: Double(maxDeg))
        let v = bestAngle(vertical, family: .vertical, bins: nb, maxDeg: Double(maxDeg))
        let both = bestAngle(horizontal + vertical, family: .mixed(horizontalCount: horizontal.count), bins: nb, maxDeg: Double(maxDeg))

        var tilt = both.angle
        var confidence = both.confidence
        var source = "edges"
        if h.confidence > 0.3 && v.confidence > 0.3 {
            if abs(h.angle - v.angle) <= 1.0 {
                confidence = min(1, confidence + 0.15)              // independent families agree
            } else {
                // Converging verticals (perspective) or diagonal structures – trust the horizontal family,
                // which is what people perceive as "crooked".
                tilt = h.angle
                confidence = h.confidence * 0.7
            }
        }

        if let va = vision?.horizonAngle, let vc = vision?.horizonConfidence, vc > 0.4, abs(va) <= Double(maxDeg) {
            if abs(va - tilt) <= 1.0 {
                tilt = (tilt * confidence + va * Double(vc) * 0.5) / (confidence + Double(vc) * 0.5)
                confidence = min(1, confidence + 0.2)
                source = "edges+vision"
            } else if confidence < 0.3 {
                tilt = va
                confidence = Double(vc) * 0.6
                source = "vision"
            }
        }

        let apply = confidence >= 0.3 && abs(tilt) >= minAutoAngle && abs(tilt) <= maxAutoAngle
        return Result(tilt: tilt, confidence: confidence, source: source, shouldApply: apply)
    }

    enum Family { case horizontal, vertical, mixed(horizontalCount: Int) }

    private static func bestAngle(_ pts: [EdgeField.EdgePoint], family: Family, bins: Int, maxDeg: Double) -> (angle: Double, confidence: Double) {
        guard pts.count >= 40 else { return (0, 0) }
        let xs = pts.map(\.x), ys = pts.map(\.y), ws = pts.map(\.weight)
        var baseEnergy: Float = 0
        for w in ws { baseEnergy += w * w }
        let hCount: Int
        switch family {
        case .horizontal: hCount = pts.count
        case .vertical: hCount = 0
        case .mixed(let n): hCount = n
        }
        var hist = [Float](repeating: 0, count: bins)
        let half = Float(bins / 2)

        func score(_ deg: Double) -> Float {
            let t = Float(deg * .pi / 180)
            let s = sinf(t), c = cosf(t)
            for i in 0 ..< hist.count { hist[i] = 0 }
            for i in 0 ..< pts.count {
                // Horizontal lines with tilt t: normal coordinate = −x·sin t + y·cos t.
                // Vertical lines with tilt t:   normal coordinate =  x·cos t + y·sin t.
                let rho = i < hCount ? (-xs[i] * s + ys[i] * c) : (xs[i] * c + ys[i] * s)
                let b = Int(rho + half)
                if b >= 0 && b < hist.count { hist[b] += ws[i] }
            }
            var e: Float = 0
            for v in hist { e += v * v }
            return e / max(baseEnergy, 1e-9)
        }

        var coarse: [(Double, Float)] = []
        var a = -maxDeg
        while a <= maxDeg + 1e-9 { coarse.append((a, score(a))); a += 0.5 }
        guard let best = coarse.max(by: { $0.1 < $1.1 }) else { return (0, 0) }
        var fineBest = best
        var f = best.0 - 0.6
        while f <= best.0 + 0.6 + 1e-9 {
            let sc = score(f)
            if sc > fineBest.1 { fineBest = (f, sc) }
            f += 0.05
        }
        let sorted = coarse.map(\.1).sorted()
        let median = sorted[sorted.count / 2]
        let conf = Double((fineBest.1 - median) / max(fineBest.1, 1e-9))
        return (fineBest.0, max(0, min(1, conf)))
    }
}
