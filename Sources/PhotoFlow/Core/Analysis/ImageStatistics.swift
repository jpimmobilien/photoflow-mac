import Foundation
import Accelerate

/// Measured properties of an image (computed on a ~768 px analysis copy in sRGB).
/// All tonal values are gamma-encoded luma in 0…1 unless noted.
struct ImageStatistics: Sendable {
    var width: Int
    var height: Int
    var histogram: [Double]          // 256 bins, normalized to sum 1
    var p005: Double, p01: Double, p05: Double, p25: Double, p50: Double, p75: Double, p95: Double, p99: Double, p995: Double
    var meanLuma: Double
    var stdLuma: Double
    var clippedHighlights: Double    // fraction of pixels with any channel ≥ 254
    var clippedShadows: Double       // fraction of pixels with all channels ≤ 2
    var brightFraction: Double       // luma > 0.85
    var darkFraction: Double         // luma < 0.12
    var meanSaturation: Double       // HSV saturation, 0…1
    var p95Saturation: Double
    var colorfulness: Double         // Hasler–Süsstrunk metric (0…~1.5)
    var meanLinearRGB: (r: Double, g: Double, b: Double)
    var noiseSigma: Double           // estimated noise std-dev (0…1 scale), Immerkær method
    var sharpness: Double            // variance of Laplacian on normalized luma
    var dynamicRange: Double         // p99.5 − p0.5

    static func compute(_ px: PixelBuffer) -> ImageStatistics {
        let n = px.width * px.height
        var hist = [Double](repeating: 0, count: 256)
        var clipHi = 0, clipLo = 0, bright = 0, dark = 0
        var satSum = 0.0
        var satHist = [Int](repeating: 0, count: 101)
        var rgSum = 0.0, ybSum = 0.0, rg2 = 0.0, yb2 = 0.0
        var lr = 0.0, lg = 0.0, lb = 0.0
        var lumaSum = 0.0, luma2 = 0.0
        let lut = ColorMath.toLinearLUT
        px.data.withUnsafeBufferPointer { p in
            for i in 0 ..< n {
                let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
                let y = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
                hist[min(255, Int(y * 255 + 0.5))] += 1
                lumaSum += y; luma2 += y * y
                let mx = max(r, g, b), mn = min(r, g, b)
                if mx >= 254 { clipHi += 1 }
                if mx <= 2 { clipLo += 1 }
                if y > 0.85 { bright += 1 }
                if y < 0.12 { dark += 1 }
                let s = mx > 0 ? Double(mx - mn) / Double(mx) : 0
                satSum += s
                satHist[Int(s * 100)] += 1
                let rg = Double(r - g), yb = 0.5 * Double(r + g) - Double(b)
                rgSum += rg; ybSum += yb; rg2 += rg * rg; yb2 += yb * yb
                lr += Double(lut[r]); lg += Double(lut[g]); lb += Double(lut[b])
            }
        }
        let N = Double(max(n, 1))
        for i in 0 ..< 256 { hist[i] /= N }
        func pct(_ q: Double) -> Double {
            var acc = 0.0
            for i in 0 ..< 256 { acc += hist[i]; if acc >= q { return Double(i) / 255 } }
            return 1
        }
        var accS = 0, p95s = 1.0
        for i in 0 ... 100 { accS += satHist[i]; if Double(accS) >= 0.95 * N { p95s = Double(i) / 100; break } }
        let mean = lumaSum / N
        let std = sqrt(max(0, luma2 / N - mean * mean))
        let rgMean = rgSum / N, ybMean = ybSum / N
        let rgStd = sqrt(max(0, rg2 / N - rgMean * rgMean)), ybStd = sqrt(max(0, yb2 / N - ybMean * ybMean))
        let colorfulness = (sqrt(rgStd * rgStd + ybStd * ybStd) + 0.3 * sqrt(rgMean * rgMean + ybMean * ybMean)) / 255

        let luma = px.luma()
        let (noise, sharp) = noiseAndSharpness(luma, width: px.width, height: px.height)

        return ImageStatistics(
            width: px.width, height: px.height, histogram: hist,
            p005: pct(0.005), p01: pct(0.01), p05: pct(0.05), p25: pct(0.25), p50: pct(0.5), p75: pct(0.75),
            p95: pct(0.95), p99: pct(0.99), p995: pct(0.995),
            meanLuma: mean, stdLuma: std,
            clippedHighlights: Double(clipHi) / N, clippedShadows: Double(clipLo) / N,
            brightFraction: Double(bright) / N, darkFraction: Double(dark) / N,
            meanSaturation: satSum / N, p95Saturation: p95s, colorfulness: colorfulness,
            meanLinearRGB: (lr / N, lg / N, lb / N), noiseSigma: noise, sharpness: sharp,
            dynamicRange: pct(0.995) - pct(0.005))
    }

    /// Noise: Immerkær's fast estimator (Laplacian-difference mask) restricted to non-edge pixels.
    /// Sharpness: variance of the 4-neighbour Laplacian of the contrast-normalized image.
    static func noiseAndSharpness(_ l: [Float], width w: Int, height h: Int) -> (Double, Double) {
        guard w > 4, h > 4 else { return (0, 0) }
        var minV: Float = 1, maxV: Float = 0
        vDSP_minv(l, 1, &minV, vDSP_Length(l.count))
        vDSP_maxv(l, 1, &maxV, vDSP_Length(l.count))
        let range = max(0.05, maxV - minV)
        var noiseAcc = 0.0, noiseN = 0
        var lapSum = 0.0, lap2 = 0.0, lapN = 0
        l.withUnsafeBufferPointer { p in
            for y in 1 ..< h - 1 {
                for x in 1 ..< w - 1 {
                    let i = y * w + x
                    let c = p[i]
                    let lap4 = p[i - 1] + p[i + 1] + p[i - w] + p[i + w] - 4 * c
                    let ln = Double(lap4 / range)
                    lapSum += ln; lap2 += ln * ln; lapN += 1
                    // Immerkær mask: [1 -2 1; -2 4 -2; 1 -2 1]
                    let corners: Float = p[i - w - 1] + p[i - w + 1] + p[i + w - 1] + p[i + w + 1]
                    let edges: Float = p[i - w] + p[i - 1] + p[i + 1] + p[i + w]
                    let m: Float = corners - 2 * edges + 4 * c
                    let gx = abs(p[i + 1] - p[i - 1]), gy = abs(p[i + w] - p[i - w])
                    if gx + gy < 0.04 {   // flat region only – edges are not noise
                        noiseAcc += Double(abs(m)); noiseN += 1
                    }
                }
            }
        }
        let sigma = noiseN > 100 ? sqrt(Double.pi / 2) * noiseAcc / (6 * Double(noiseN)) : 0
        let mean = lapSum / Double(max(lapN, 1))
        let variance = lap2 / Double(max(lapN, 1)) - mean * mean
        return (sigma, variance)
    }

    /// Simple 0…1 "technical exposure quality" used when ranking duplicates.
    var exposureQuality: Double {
        let midBalance = 1 - min(1, abs(p50 - 0.45) / 0.45)
        let clipPenalty = min(1, clippedHighlights * 8 + clippedShadows * 6)
        let rangeScore = min(1, dynamicRange / 0.8)
        return max(0, 0.45 * midBalance + 0.35 * rangeScore + 0.2 - 0.5 * clipPenalty)
    }
}
