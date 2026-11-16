import Foundation
import CoreGraphics

/// Automatic crop: removes uniform borders (scans, screenshots, letterboxing) or crops to a target aspect ratio
/// around the most salient region (Vision attention saliency).
enum AutoCrop {
    enum Mode: Codable, Hashable, Sendable {
        case none
        case trimBorders
        /// Composition-aware crop to a fixed ratio (decided per photo by `SmartCrop`).
        case aspect(width: Double, height: Double)
        /// Improve the composition but keep the photo's own aspect ratio; only crops when it clearly helps.
        case smartOriginal
        /// Picks the best ratio per photo (original, 3:2, 4:3, 16:9, 1:1, 4:5, 9:16).
        case smartFree

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .trimBorders: return String(localized: "Remove borders")
            case .aspect(let w, let h): return "\(Int(w)):\(Int(h))"
            case .smartOriginal: return String(localized: "Optimise original format")
            case .smartFree: return String(localized: "Free (best per photo)")
            }
        }

        static let choices: [Mode] = [.none, .trimBorders, .smartOriginal, .smartFree, .aspect(width: 16, height: 9), .aspect(width: 4, height: 3),
                                      .aspect(width: 3, height: 2), .aspect(width: 1, height: 1), .aspect(width: 4, height: 5),
                                      .aspect(width: 9, height: 16)]
    }

    /// Smart crop for a mode using the photo's analysis image. Returns nil when the photo should stay uncropped.
    static func smart(_ mode: Mode, analysisImage: CGImage) -> (NormalizedRect, String)? {
        guard let content = SmartCrop.content(of: analysisImage) else { return nil }
        switch mode {
        case .aspect(let w, let h):
            let r = SmartCrop.best(content, ratio: w / h)
            return (r.rect, ([String(localized: "Cropped to \(Int(w)):\(Int(h))")] + r.reasons).joined(separator: " · "))
        case .smartOriginal:
            let r = SmartCrop.best(content, ratio: nil)
            guard r.score - r.baseline > 0.06, r.rect.width * r.rect.height < 0.97 else { return nil }
            return (r.rect, ([String(localized: "Composition improved")] + r.reasons).joined(separator: " · "))
        case .smartFree:
            let ratios: [(Double?, String)] = [(nil, String(localized: "original format")), (3.0 / 2, "3:2"), (4.0 / 3, "4:3"), (16.0 / 9, "16:9"),
                                               (1, "1:1"), (4.0 / 5, "4:5"), (9.0 / 16, "9:16")]
            var best: (SmartCrop.Result, String)?
            for (ratio, name) in ratios {
                var r = SmartCrop.best(content, ratio: ratio)
                if ratio != nil { r.score -= 0.05 }    // a different format must earn its place
                if best == nil || r.score > best!.0.score { best = (r, name) }
            }
            guard let (r, name) = best else { return nil }
            if r.rect.width * r.rect.height > 0.97 { return nil }
            return (r.rect, ([String(localized: "Best format: \(name)")] + r.reasons).joined(separator: " · "))
        default:
            return nil
        }
    }

    /// Detects uniform dark or bright borders. Returns nil when there is nothing (sensible) to trim.
    static func trimBorders(_ px: PixelBuffer) -> NormalizedRect? {
        let w = px.width, h = px.height
        guard w > 32, h > 32 else { return nil }
        let luma = px.luma()

        func lineStats(_ values: [Float]) -> (mean: Float, std: Float) {
            let n = Float(values.count)
            let m = values.reduce(0, +) / n
            let v = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n
            return (m, sqrt(v))
        }
        func row(_ y: Int) -> [Float] { Array(luma[(y * w) ..< (y * w + w)]) }
        func col(_ x: Int) -> [Float] { (0 ..< h).map { luma[$0 * w + x] } }
        func isBorder(_ s: (mean: Float, std: Float), ref: Float) -> Bool {
            s.std < 0.025 && (s.mean < 0.12 || s.mean > 0.92) && abs(s.mean - ref) < 0.06
        }
        func scan(count: Int, line: (Int) -> [Float], reversed: Bool) -> Int {
            let first = lineStats(line(reversed ? count - 1 : 0))
            guard first.std < 0.025, first.mean < 0.12 || first.mean > 0.92 else { return 0 }
            var n = 0
            while n < count / 4 {
                let idx = reversed ? count - 1 - n : n
                if !isBorder(lineStats(line(idx)), ref: first.mean) { break }
                n += 1
            }
            return n
        }
        let top = scan(count: h, line: row, reversed: false)
        let bottom = scan(count: h, line: row, reversed: true)
        let left = scan(count: w, line: col, reversed: false)
        let right = scan(count: w, line: col, reversed: true)
        let total = top + bottom + left + right
        guard total >= 2 else { return nil }
        // Small safety inset so no border line survives due to anti-aliasing
        let inset = 1
        let x = Double(left > 0 ? left + inset : 0) / Double(w)
        let y = Double(top > 0 ? top + inset : 0) / Double(h)
        let x2 = Double(w - (right > 0 ? right + inset : 0)) / Double(w)
        let y2 = Double(h - (bottom > 0 ? bottom + inset : 0)) / Double(h)
        guard x2 - x > 0.4, y2 - y > 0.4 else { return nil }
        return NormalizedRect(x: x, y: y, width: x2 - x, height: y2 - y)
    }

    /// Largest crop with the requested aspect ratio, centred on the salient region (or the image centre).
    static func aspectCrop(imageSize: CGSize, ratio: Double, salient: CGRect?) -> NormalizedRect {
        let imgRatio = Double(imageSize.width / imageSize.height)
        var w = 1.0, h = 1.0
        if ratio > imgRatio { h = imgRatio / ratio } else { w = ratio / imgRatio }
        let center = salient.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 0.5, y: 0.5)
        let x = min(max(0, Double(center.x) - w / 2), 1 - w)
        let y = min(max(0, Double(center.y) - h / 2), 1 - h)
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }
}
