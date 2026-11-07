import Foundation
import CoreGraphics

/// Automatic perspective (keystone) correction – separate from straightening.
///
/// Converging verticals all pass through a vanishing point. For a candidate projective coefficient `c`
/// (see `GeometryModel`) every near-vertical edge pixel is mapped through the correcting homography;
/// when `c` is right, all pixels of each building edge collapse onto one column and the column profile's
/// energy peaks. Search: coarse (step 0.02) then fine (0.002). Synthetic validation: error ≤ 0.003.
///
/// Corrections are only applied automatically when the evidence is strong (confidence, amount of straight
/// vertical structure, plausible magnitude, scene type); otherwise the manual sliders are offered.
enum PerspectiveEngine {
    struct Result: Sendable {
        var vertical: Double          // projective coefficient cv
        var verticalConfidence: Double
        var horizontal: Double        // projective coefficient ch
        var horizontalConfidence: Double
        var structureFraction: Double // share of edge pixels belonging to near-vertical structures
        var applyVertical: Bool
        var applyHorizontal: Bool

        /// Slider values (−100…100) for the recipe.
        var verticalSlider: Double { max(-100, min(100, vertical / GeometryModel.perspectiveRange * 100)) }
        var horizontalSlider: Double { max(-100, min(100, horizontal / GeometryModel.perspectiveRange * 100)) }
    }

    /// Share of the measured correction that is applied automatically. A tiny amount of residual
    /// convergence looks more natural than a mathematically perfect (often "top-heavy") result.
    static let naturalStrength = 0.85

    static func detect(edges: EdgeField, rotationCorrection: Double, scene: VisionAnalyzer.SceneResult?) -> Result {
        let t = rotationCorrection * .pi / 180
        let c = Float(cos(t)), s = Float(sin(t))
        let W = Float(edges.width), H = Float(edges.height)
        // Rotate points by the straightening correction first (model order: P ∘ R).
        let rotated = edges.points.map { p -> EdgeField.EdgePoint in
            var q = p
            q.x = p.x * c - p.y * s
            q.y = p.x * s + p.y * c
            q.angle = p.angle + Float(rotationCorrection)
            return q
        }
        let verticals = rotated.filter { abs(abs($0.angle) - 90) <= 25 }
        let horizontals = rotated.filter { abs($0.angle) <= 25 }

        let v = search(verticals, along: .vertical, W: W, H: H)
        let h = search(horizontals, along: .horizontal, W: W, H: H)
        let structure = Double(verticals.count) / Double(max(1, edges.points.count))

        let builtScene = scene?.has(VisionAnalyzer.architectureLabels, minConfidence: 0.2) ?? false
        let documentScene = scene?.has(VisionAnalyzer.documentLabels, minConfidence: 0.3) ?? false
        let naturalScene = scene?.has(VisionAnalyzer.landscapeLabels, minConfidence: 0.4) ?? false

        var applyV = v.confidence >= 0.35 && abs(v.value) >= 0.02 && abs(v.value) <= 0.6 && structure >= 0.12
        if naturalScene && !builtScene { applyV = applyV && v.confidence >= 0.6 && structure >= 0.25 }
        // Horizontal keystone is usually intentional (two-point perspective) – only for frontal facades/documents.
        let applyH = (builtScene || documentScene) && h.confidence >= 0.5 && abs(h.value) >= 0.02 && abs(h.value) <= 0.25

        var vertical = v.value * naturalStrength
        var horizontal = h.value * naturalStrength
        // Never auto-crop away more than 35 % of the picture.
        if applyV || applyH {
            var model = GeometryModel(rotationDegrees: rotationCorrection, cv: applyV ? vertical : 0, ch: applyH ? horizontal : 0)
            var retained = model.retainedArea(size: CGSize(width: Double(W), height: Double(H)))
            var guardSteps = 0
            while retained < 0.65 && guardSteps < 10 {
                vertical *= 0.85; horizontal *= 0.85
                model = GeometryModel(rotationDegrees: rotationCorrection, cv: applyV ? vertical : 0, ch: applyH ? horizontal : 0)
                retained = model.retainedArea(size: CGSize(width: Double(W), height: Double(H)))
                guardSteps += 1
            }
        }
        return Result(vertical: vertical, verticalConfidence: v.confidence, horizontal: horizontal,
                      horizontalConfidence: h.confidence, structureFraction: structure,
                      applyVertical: applyV, applyHorizontal: applyH)
    }

    private enum Axis { case vertical, horizontal }

    private static func search(_ pts: [EdgeField.EdgePoint], along axis: Axis, W: Float, H: Float) -> (value: Double, confidence: Double) {
        guard pts.count >= 60 else { return (0, 0) }
        let nb = Int(3 * max(W, H)) + 8
        var hist = [Float](repeating: 0, count: nb)
        var base: Float = 0
        for p in pts { base += p.weight * p.weight }
        let scale: Float = 1   // 1-px bins (points carry sub-pixel jitter, see EdgeField)

        func score(_ k: Double) -> Float {
            let kf = Float(k)
            for i in 0 ..< nb { hist[i] = 0 }
            for p in pts {
                let rho: Float
                switch axis {
                case .vertical:
                    let w = 1 - kf * p.y / H
                    guard w > 0.05 else { continue }
                    rho = p.x / w
                case .horizontal:
                    let w = 1 + kf * p.x / W
                    guard w > 0.05 else { continue }
                    rho = p.y / w
                }
                let b = Int(rho * scale) + nb / 2
                if b >= 0 && b < nb { hist[b] += p.weight }
            }
            var e: Float = 0
            for v in hist { e += v * v }
            return e / max(base, 1e-9)
        }

        var coarse: [(Double, Float)] = []
        var k = -0.8
        while k <= 0.8 + 1e-9 { coarse.append((k, score(k))); k += 0.02 }
        guard let best = coarse.max(by: { $0.1 < $1.1 }) else { return (0, 0) }
        var fine = best
        var f = best.0 - 0.03
        while f <= best.0 + 0.03 + 1e-9 {
            let sc = score(f)
            if sc > fine.1 { fine = (f, sc) }
            f += 0.002
        }
        let sorted = coarse.map(\.1).sorted()
        let median = sorted[sorted.count / 2]
        let conf = Double((fine.1 - median) / max(fine.1, 1e-9))
        return (fine.0, max(0, min(1, conf)))
    }

    /// Document mode: rectangle found by Vision, returned as normalized corners for `EditRecipe.documentCorners`.
    static func documentCorners(in image: CGImage) -> [Double]? {
        guard let q = VisionAnalyzer.documentQuad(image) else { return nil }
        return q.flatMap { [Double($0.x), Double($0.y)] }
    }
}
