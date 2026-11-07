import Foundation

/// Structure-tensor edge analysis shared by straightening and perspective correction.
///
/// For every pixel we compute the gradient (Sobel after Gaussian pre-smoothing σ = 1) and the smoothed
/// structure tensor (σ = 1.5). From it we derive the local line orientation and its *coherence*
/// (1 = a clean straight edge, 0 = texture/noise). Only strong, coherent edge pixels are kept, as centred
/// coordinates with y pointing **up** and a weight = edge energy × coherence.
struct EdgeField: Sendable {
    struct EdgePoint: Sendable {
        var x: Float          // centred, y up
        var y: Float
        var angle: Float      // line direction, degrees, visual CCW, in [−90, 90)
        var weight: Float
    }

    let width: Int
    let height: Int
    let points: [EdgePoint]

    init(luma src: [Float], width w: Int, height h: Int) {
        width = w; height = h
        guard w >= 8, h >= 8 else { points = []; return }
        let g = EdgeField.gaussian(src, w, h, sigma: 1.0)
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        g.withUnsafeBufferPointer { p in
            for y in 1 ..< h - 1 {
                for x in 1 ..< w - 1 {
                    let i = y * w + x
                    let right: Float = p[i - w + 1] + 2 * p[i + 1] + p[i + w + 1]
                    let left: Float = p[i - w - 1] + 2 * p[i - 1] + p[i + w - 1]
                    let below: Float = p[i + w - 1] + 2 * p[i + w] + p[i + w + 1]
                    let above: Float = p[i - w - 1] + 2 * p[i - w] + p[i - w + 1]
                    gx[i] = right - left
                    gy[i] = below - above
                }
            }
        }
        var jxx = [Float](repeating: 0, count: w * h), jyy = jxx, jxy = jxx
        for i in 0 ..< w * h { jxx[i] = gx[i] * gx[i]; jyy[i] = gy[i] * gy[i]; jxy[i] = gx[i] * gy[i] }
        jxx = EdgeField.gaussian(jxx, w, h, sigma: 1.5)
        jyy = EdgeField.gaussian(jyy, w, h, sigma: 1.5)
        jxy = EdgeField.gaussian(jxy, w, h, sigma: 1.5)

        var energy = [Float](repeating: 0, count: w * h)
        var coherence = energy
        for i in 0 ..< w * h {
            let tr = jxx[i] + jyy[i]
            energy[i] = sqrt(tr)
            if tr > 1e-12 {
                let d = sqrt((jxx[i] - jyy[i]) * (jxx[i] - jyy[i]) + 4 * jxy[i] * jxy[i])
                coherence[i] = d / tr
            }
        }
        // Energy threshold = 85th percentile (sampled)
        var sample: [Float] = []
        sample.reserveCapacity(w * h / 7 + 1)
        var i = 0
        while i < w * h { sample.append(energy[i]); i += 7 }
        sample.sort()
        let threshold = max(sample.isEmpty ? 0 : sample[Int(Double(sample.count - 1) * 0.85)], 1e-3)

        var pts: [EdgePoint] = []
        pts.reserveCapacity(w * h / 6)
        let cx = Float(w) / 2, cy = Float(h) / 2
        let margin = 3
        for y in margin ..< h - margin {
            for x in margin ..< w - margin {
                let k = y * w + x
                guard energy[k] > threshold, coherence[k] > 0.5 else { continue }
                // Gradient orientation (y down) → line direction → visual CCW angle
                let theta = 0.5 * atan2(2 * jxy[k], jxx[k] - jyy[k])
                var vis = -(theta + .pi / 2)
                vis = fmodf(vis + .pi / 2, .pi); if vis < 0 { vis += .pi }; vis -= .pi / 2
                // Deterministic sub-pixel jitter (±0.5 px) breaks the pixel-lattice alignment: without it,
                // integer pixel positions make "no rotation / no keystone" look artificially perfect.
                let jx = EdgeField.jitter(UInt32(truncatingIfNeeded: k) &* 2), jy = EdgeField.jitter(UInt32(truncatingIfNeeded: k) &* 2 &+ 1)
                pts.append(EdgePoint(x: Float(x) - cx + jx, y: cy - Float(y) + jy, angle: vis * 180 / .pi,
                                     weight: energy[k] * coherence[k]))
            }
        }
        points = pts
    }

    /// Hash-based uniform value in [−0.5, 0.5) (reproducible across runs).
    @inline(__always) static func jitter(_ n: UInt32) -> Float {
        var h = n &* 0x9E3779B1
        h ^= h >> 15; h = h &* 0x85EBCA77; h ^= h >> 13; h = h &* 0xC2B2AE3D; h ^= h >> 16
        return Float(h & 0xFFFF) / 65536 - 0.5
    }

    /// Separable Gaussian blur with edge clamping.
    static func gaussian(_ src: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
        let r = max(1, Int(ceil(3 * sigma)))
        var k = (-r ... r).map { expf(-0.5 * Float($0 * $0) / (sigma * sigma)) }
        let s = k.reduce(0, +); k = k.map { $0 / s }
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        src.withUnsafeBufferPointer { p in
            for y in 0 ..< h {
                let row = y * w
                for x in 0 ..< w {
                    var acc: Float = 0
                    for j in -r ... r { acc += k[j + r] * p[row + min(w - 1, max(0, x + j))] }
                    tmp[row + x] = acc
                }
            }
        }
        tmp.withUnsafeBufferPointer { p in
            for y in 0 ..< h {
                for x in 0 ..< w {
                    var acc: Float = 0
                    for j in -r ... r { acc += k[j + r] * p[min(h - 1, max(0, y + j)) * w + x] }
                    out[y * w + x] = acc
                }
            }
        }
        return out
    }
}
