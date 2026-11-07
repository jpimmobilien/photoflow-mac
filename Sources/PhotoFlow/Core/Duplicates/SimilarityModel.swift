import Foundation

enum SimilarityCategory: Int, Comparable, CaseIterable, Sendable {
    case possiblySimilar = 0, similar, verySimilar, exact

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var displayName: String {
        switch self {
        case .exact: return String(localized: "Exact Duplicate")
        case .verySimilar: return String(localized: "Very Similar")
        case .similar: return String(localized: "Similar")
        case .possiblySimilar: return String(localized: "Possibly Similar")
        }
    }

    var symbol: String {
        switch self {
        case .exact: return "equal.circle.fill"
        case .verySimilar: return "square.on.square.fill"
        case .similar: return "square.on.square"
        case .possiblySimilar: return "questionmark.square.dashed"
        }
    }
}

/// UI categories – configurable starting points, *not* mathematical guarantees (see DUPLICATE_DETECTION.md).
struct SimilarityThresholds: Sendable, Equatable {
    var verySimilar: Double = 95
    var similar: Double = 85
    var possibly: Double = 70

    func category(for score: Double, exact: Bool) -> SimilarityCategory? {
        if exact { return .exact }
        if score >= verySimilar { return .verySimilar }
        if score >= similar { return .similar }
        if score >= possibly { return .possiblySimilar }
        return nil
    }
}

/// Converts raw evidence (hash distances, feature-print cosine, registration) into a 0…100 similarity score.
/// The mapping table is calibrated with the QA harness (`PhotoFlow --qa calibrate`) on real photographs.
enum SimilarityScorer {
    /// (cosine, score) knots – piecewise linear. Feature prints are L2-normalised before comparison.
    static var featureKnots: [(Float, Double)] = [
        (0.00, 0), (0.50, 30), (0.70, 55), (0.80, 70), (0.86, 78), (0.90, 85), (0.94, 91), (0.97, 95), (0.99, 98), (1.00, 99)
    ]

    static func featureScore(_ cosine: Float) -> Double {
        let k = featureKnots
        if cosine <= k[0].0 { return k[0].1 }
        for i in 1 ..< k.count where cosine <= k[i].0 {
            let (x0, y0) = k[i - 1], (x1, y1) = k[i]
            let t = Double((cosine - x0) / max(x1 - x0, 1e-6))
            return y0 + t * (y1 - y0)
        }
        return k[k.count - 1].1
    }

    /// Perceptual-hash evidence: near-identical renditions (resized / recompressed / slightly adjusted).
    static func hashScore(_ a: PerceptualHash.Hashes, _ b: PerceptualHash.Hashes) -> Double? {
        let dp = PerceptualHash.distance(a.p, b.p)
        let dd = PerceptualHash.distance(a.d, b.d)
        let da = PerceptualHash.distance(a.a, b.a)
        guard dp <= 10 else { return nil }
        // 0 bits → 99, 10 bits → ~90; dHash/aHash refine.
        let s = 99.0 - Double(dp) * 0.7 - Double(dd) * 0.15 - Double(da) * 0.1
        return max(80, min(99, s))
    }

    /// Final pair score. Hash evidence is only trusted when the semantic embedding does not contradict it
    /// (simple images – sky, walls – can share hashes while being different photos).
    static func combined(hash: Double?, cosine: Float?, registration: Double?) -> Double {
        var score = 0.0
        if let c = cosine { score = featureScore(c) }
        if let h = hash {
            if let c = cosine {
                if c >= 0.80 { score = max(score, h) }
            } else {
                score = max(score, h)
            }
        }
        if let r = registration { score = max(score, r) }
        return score
    }
}
