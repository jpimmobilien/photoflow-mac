import Foundation

/// Estimates the colour of the scene illuminant from image statistics (no ML needed – classic colour constancy).
///
/// Three complementary estimators are combined:
/// 1. **Gray-world** – the average scene reflectance is assumed achromatic.
/// 2. **Gray-edge** (van de Weijer et al.) – the average *edge* difference is achromatic; robust to large
///    coloured areas.
/// 3. **Near-neutral pixels** – iteratively finds the least chromatic pixels (likely white/grey surfaces)
///    under the current estimate and averages them.
/// The neutral-pixel estimate is trusted more when it agrees with gray-edge. Validated on synthetic scenes
/// with random casts (median angular error 11° → ~2°, see LOCAL_AI_ARCHITECTURE.md).
enum WhiteBalanceEstimator {
    struct Estimate: Sendable {
        /// Illuminant chromaticity as log ratios relative to green.
        var logRG: Double
        var logBG: Double
        /// 0…1 – agreement between estimators and availability of neutral surfaces.
        var confidence: Double
        /// Fraction of pixels considered near-neutral after correction.
        var neutralFraction: Double

        /// Angular cast strength in degrees (0 = neutral).
        var castDegrees: Double {
            let v = (exp(logRG), 1.0, exp(logBG))
            let dot = (v.0 + v.1 + v.2) / (sqrt(3) * sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2))
            return acos(min(1, max(-1, dot))) * 180 / .pi
        }

        /// Positive = warm (amber) cast, negative = cool (blue) cast, in log units.
        var warmth: Double { (logRG - logBG) / 2 }
        /// Positive = green cast, negative = magenta cast, in log units.
        var greenness: Double { -(logRG + logBG) / 2 }

        /// Linear channel gains that would fully neutralise the cast.
        var correctionGains: (r: Double, g: Double, b: Double) { (exp(-logRG), 1, exp(-logBG)) }
    }

    static func estimate(_ px: PixelBuffer) -> Estimate {
        let w = px.width, h = px.height, n = w * h
        let lut = ColorMath.toLinearLUT
        var lin = [Float](repeating: 0, count: n * 3)
        var valid = [Bool](repeating: false, count: n)
        var gw = (0.0, 0.0, 0.0); var gwN = 0
        px.data.withUnsafeBufferPointer { p in
            for i in 0 ..< n {
                let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2]
                let lr = lut[Int(r)], lg = lut[Int(g)], lb = lut[Int(b)]
                lin[i * 3] = lr; lin[i * 3 + 1] = lg; lin[i * 3 + 2] = lb
                let mx = max(r, g, b)
                let luma = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
                // Exclude clipped pixels (their colour is wrong) and near-black pixels (noise dominated).
                if mx < 250 && luma > 0.015 {
                    valid[i] = true
                    gw.0 += Double(lr); gw.1 += Double(lg); gw.2 += Double(lb); gwN += 1
                }
            }
        }
        guard gwN > n / 20, gw.1 > 0 else {
            return Estimate(logRG: 0, logBG: 0, confidence: 0, neutralFraction: 0)
        }
        let grayWorld = (log(gw.0 / gw.1), log(gw.2 / gw.1))

        // Gray-edge (Minkowski p = 2 on first-order differences)
        var ge = (0.0, 0.0, 0.0)
        lin.withUnsafeBufferPointer { p in
            for y in 0 ..< h - 1 {
                for x in 0 ..< w - 1 {
                    let i = y * w + x
                    guard valid[i], valid[i + 1], valid[i + w] else { continue }
                    for c in 0 ..< 3 {
                        let dx = Double(p[(i + 1) * 3 + c] - p[i * 3 + c])
                        let dy = Double(p[(i + w) * 3 + c] - p[i * 3 + c])
                        let m = dx * dx + dy * dy
                        if c == 0 { ge.0 += m } else if c == 1 { ge.1 += m } else { ge.2 += m }
                    }
                }
            }
        }
        let grayEdge: (Double, Double) = ge.1 > 1e-9 ? (0.5 * log(ge.0 / ge.1), 0.5 * log(ge.2 / ge.1)) : grayWorld

        // Near-neutral pixel iteration (start from gray-edge)
        var est = grayEdge
        var neutralFraction = 0.0
        var chroma = [Float](repeating: 0, count: n)
        for _ in 0 ..< 3 {
            let cr = Float(exp(-est.0)), cb = Float(exp(-est.1))
            var count = 0
            for i in 0 ..< n where valid[i] {
                let r = max(lin[i * 3] * cr, 1e-4), g = max(lin[i * 3 + 1], 1e-4), b = max(lin[i * 3 + 2] * cb, 1e-4)
                chroma[i] = abs(logf(r / g)) + abs(logf(b / g))
                count += 1
            }
            // 10th percentile of chroma among valid pixels
            var sample: [Float] = []
            sample.reserveCapacity(count / 4 + 1)
            var k = 0
            for i in 0 ..< n where valid[i] { if k % 4 == 0 { sample.append(chroma[i]) }; k += 1 }
            sample.sort()
            let threshold = sample.isEmpty ? 0 : sample[min(sample.count - 1, sample.count / 10)]
            var acc = (0.0, 0.0, 0.0); var m = 0
            for i in 0 ..< n where valid[i] && chroma[i] <= threshold {
                acc.0 += Double(lin[i * 3]); acc.1 += Double(lin[i * 3 + 1]); acc.2 += Double(lin[i * 3 + 2]); m += 1
            }
            guard m > 20, acc.1 > 0 else { break }
            est = (log(acc.0 / acc.1), log(acc.2 / acc.1))
            // How many pixels are genuinely neutral (chroma < 0.08) after this correction?
            var neutral = 0
            for i in 0 ..< n where valid[i] && chroma[i] < 0.08 { neutral += 1 }
            neutralFraction = Double(neutral) / Double(max(count, 1))
        }

        // Adaptive combination: trust the neutral estimate when it agrees with gray-edge.
        let d = hypot(est.0 - grayEdge.0, est.1 - grayEdge.1)
        var wN = 0.4
        if d > 0.25 { wN = 0.15 }
        if d < 0.12 { wN = 0.6 }
        let wGE = 0.4, wGW = 0.2
        let sum = wN + wGE + wGW
        let logRG = (wN * est.0 + wGE * grayEdge.0 + wGW * grayWorld.0) / sum
        let logBG = (wN * est.1 + wGE * grayEdge.1 + wGW * grayWorld.1) / sum

        // Confidence: estimators agree + neutral surfaces exist.
        let spread = (hypot(est.0 - logRG, est.1 - logBG) + hypot(grayEdge.0 - logRG, grayEdge.1 - logBG)
                      + hypot(grayWorld.0 - logRG, grayWorld.1 - logBG)) / 3
        let agreement = max(0, 1 - spread / 0.25)
        let confidence = min(1, 0.65 * agreement + 0.35 * min(1, neutralFraction * 6))
        return Estimate(logRG: logRG, logBG: logBG, confidence: confidence, neutralFraction: neutralFraction)
    }
}
