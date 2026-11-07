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
        /// True when independent evidence agrees – safe for automatic (batch) correction.
        var shouldApply: Bool
        /// A plausible estimate exists (used when the user explicitly clicks "Auto Straighten").
        var hasSuggestion: Bool
        // Diagnostics
        var horizontal: (angle: Double, confidence: Double) = (0, 0)
        var vertical: (angle: Double, confidence: Double) = (0, 0)
        var combined: (angle: Double, confidence: Double) = (0, 0)
        var vision: Double?
        var correction: Double { -tilt }
    }

    static let maxAutoAngle = 10.0
    static let minAutoAngle = 0.15

    /// Decision rule (tuned on real photographs, see TEST_REPORT.md): a photo is only straightened
    /// automatically when two independent measurements agree – the horizontal and vertical line families,
    /// or the edge analysis and Apple Vision's horizon detector. A single dominant line (a hillside, a roof,
    /// a diagonal) is never enough on its own, because it is often not meant to be level.
    static func detect(edges: EdgeField, vision: VisionAnalyzer.SceneResult?) -> Result {
        let maxDeg: Float = 12
        let horizontal = edges.points.filter { abs($0.angle) < 45 && abs($0.angle) <= maxDeg + 2 }
        let vertical = edges.points.filter { abs($0.angle) >= 45 && abs(abs($0.angle) - 90) <= maxDeg + 2 }
        let nb = Int(2 * hypot(Double(edges.width), Double(edges.height))) + 8

        let h = bestAngle(horizontal, family: .horizontal, bins: nb, maxDeg: Double(maxDeg))
        let v = bestAngle(vertical, family: .vertical, bins: nb, maxDeg: Double(maxDeg))
        let both = bestAngle(horizontal + vertical, family: .mixed(horizontalCount: horizontal.count), bins: nb, maxDeg: Double(maxDeg))
        var visionAngle: Double?
        if let va = vision?.horizonAngle, abs(va) <= Double(maxDeg) { visionAngle = va }

        var tilt = both.angle
        var confidence = both.confidence
        var source = "edges"
        var agreed = false

        // 1. Horizontal and vertical structures agree
        if h.confidence >= 0.25 && v.confidence >= 0.25 && abs(h.angle - v.angle) <= 0.75 {
            tilt = both.angle
            confidence = min(1, max(h.confidence, v.confidence) + 0.15)
            source = "lines(h+v)"
            agreed = true
        }
        // 2. Edge analysis agrees with Vision's horizon
        if let va = visionAngle {
            let candidates: [(Double, Double)] = [(both.angle, both.confidence), (h.angle, h.confidence), (v.angle, v.confidence)]
            if let match = candidates.filter({ $0.1 >= 0.2 && abs($0.0 - va) <= 1.0 }).max(by: { $0.1 < $1.1 }) {
                if !agreed || abs(tilt - va) <= 1.0 {
                    tilt = (match.0 * 2 + va) / 3
                    confidence = min(1, max(confidence, match.1) + 0.2)
                    source = agreed ? "lines(h+v)+vision" : "edges+vision"
                    agreed = true
                }
            }
        }
        // 3. A single, very clean line family (e.g. a sea horizon) – only for small angles
        if !agreed {
            let single = h.confidence >= v.confidence ? h : v
            if single.confidence >= 0.75 && abs(single.angle) <= 3 {
                tilt = single.angle
                confidence = single.confidence
                source = h.confidence >= v.confidence ? "horizon-line" : "vertical-lines"
                agreed = true
            }
        }

        let inRange = abs(tilt) >= minAutoAngle && abs(tilt) <= maxAutoAngle
        let apply = agreed && confidence >= 0.3 && inRange
        // Suggestion for an explicit user click: the best available single estimate
        var suggestion = agreed
        if !agreed {
            if both.confidence >= 0.3 { tilt = both.angle; confidence = both.confidence; source = "edges(single)"; suggestion = true }
            else if let va = visionAngle { tilt = va; confidence = 0.3; source = "vision(single)"; suggestion = true }
        }
        var r = Result(tilt: tilt, confidence: confidence, source: source, shouldApply: apply,
                       hasSuggestion: suggestion && abs(tilt) <= maxAutoAngle)
        r.horizontal = (h.angle, h.confidence)
        r.vertical = (v.angle, v.confidence)
        r.combined = (both.angle, both.confidence)
        r.vision = visionAngle
        return r
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
