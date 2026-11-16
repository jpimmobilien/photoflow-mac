import Foundation
import Vision
import CoreGraphics

/// Composition-aware crop, decided per photo from its content:
/// – where the eye goes (Apple Vision attention saliency map, 68 × 68),
/// – faces and the direction they look (yaw) – lead room and head room,
/// – rule of thirds / centre for symmetric subjects, visual balance,
/// – no cuts through subjects or faces, and as much of the photo as possible.
/// Candidates over position and scale are scored; for "optimise original format" a crop is only proposed when it
/// clearly improves the composition.
enum SmartCrop {
    struct Content {
        var saliency: [Float]           // row-major, origin top-left, normalized so the sum is 1
        var cols: Int
        var rows: Int
        var faces: [(rect: CGRect, gaze: Double)]  // normalized, origin top-left; gaze < 0 looks to the image's left, > 0 to the right
        var imageAspect: Double         // width / height
    }

    struct Result {
        var rect: NormalizedRect
        var score: Double
        var baseline: Double            // score of the uncropped photo (same aspect handling)
        var reasons: [String]
    }

    static func content(of image: CGImage) -> Content? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let sal = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceLandmarksRequest()
        try? handler.perform([sal, faces])
        guard let obs = sal.results?.first else { return nil }
        let pb = obs.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var map = [Float](repeating: 0, count: w * h)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<w {
                let v: Float = fmt == kCVPixelFormatType_OneComponent32Float
                    ? row.assumingMemoryBound(to: Float.self)[x]
                    : Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                map[y * w + x] = max(0, v)
            }
        }
        // Vision's saliency buffer has its origin at the top-left already (image orientation).
        let sum = map.reduce(0, +)
        if sum > 0 { map = map.map { $0 / sum } }
        // Direction of view from the nose position inside the face box (unambiguous in image coordinates):
        // a nose left of the box centre means the face is turned towards the image's left.
        let f: [(CGRect, Double)] = (faces.results ?? []).map { o in
            let b = o.boundingBox
            var gaze = 0.0
            if let nose = o.landmarks?.nose?.normalizedPoints, !nose.isEmpty {
                let nx = nose.map { Double($0.x) }.reduce(0, +) / Double(nose.count)
                gaze = max(-1, min(1, (nx - 0.5) / 0.15))
            }
            return (CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), gaze)
        }
        return Content(saliency: map, cols: w, rows: h, faces: f, imageAspect: Double(image.width) / Double(max(1, image.height)))
    }

    /// Best crop for `ratio` (width/height of the crop in pixels); nil = keep the photo's own aspect ratio.
    static func best(_ c: Content, ratio: Double?, minArea: Double = 0.45) -> Result {
        let target = ratio ?? c.imageAspect
        // Largest crop of this ratio, as normalized width/height
        var w0 = 1.0, h0 = 1.0
        if target > c.imageAspect { h0 = c.imageAspect / target } else { w0 = target / c.imageAspect }
        let full = NormalizedRect(x: (1 - w0) / 2, y: (1 - h0) / 2, width: w0, height: h0)
        let baseline = score(c, full).0
        var bestRect = full
        var best = score(c, full)
        // Never above 1: when even the largest crop of this ratio is smaller than `minArea` (portrait → 16:9, landscape → 9:16)
        // the largest size must still be searched across all positions instead of falling back to the centre.
        let minScale = ratio == nil ? 0.72 : min(1.0, max(0.55, (minArea / (w0 * h0)).squareRoot()))
        var s = 1.0
        while s >= minScale - 1e-9 {
            let w = w0 * s, h = h0 * s
            let steps = 14
            for iy in 0...steps {
                for ix in 0...steps {
                    let x = (1 - w) * Double(ix) / Double(steps)
                    let y = (1 - h) * Double(iy) / Double(steps)
                    let r = NormalizedRect(x: x, y: y, width: w, height: h)
                    let sc = score(c, r)
                    if sc.0 > best.0 { best = sc; bestRect = r }
                }
            }
            s -= 0.04
        }
        return Result(rect: bestRect, score: best.0, baseline: baseline, reasons: best.1)
    }

    /// Composition score of a crop (higher is better) and the main reasons.
    static func score(_ c: Content, _ r: NormalizedRect) -> (Double, [String]) {
        var inside = 0.0, border = 0.0, cx = 0.0, cy = 0.0
        let bw = 0.035 // border strip, fraction of the image
        for row in 0..<c.rows {
            let y = (Double(row) + 0.5) / Double(c.rows)
            for col in 0..<c.cols {
                let v = Double(c.saliency[row * c.cols + col])
                if v == 0 { continue }
                let x = (Double(col) + 0.5) / Double(c.cols)
                let inX = x >= r.x && x <= r.x + r.width, inY = y >= r.y && y <= r.y + r.height
                if inX && inY {
                    inside += v; cx += v * x; cy += v * y
                    let edge = min(x - r.x, r.x + r.width - x, y - r.y, r.y + r.height - y)
                    if edge < bw { border += v * (1 - edge / bw) }
                }
            }
        }
        var reasons: [String] = []
        var score = 1.4 * inside - 3.0 * border
        let area = r.width * r.height
        score -= 0.35 * (1 - area)
        // Subject position: saliency centroid or the main face (eyes ~ upper part of the face box)
        var px = inside > 0 ? cx / inside : 0.5, py = inside > 0 ? cy / inside : 0.5
        var faceInside = false
        // Every other face that is not tiny compared with the main face must stay whole as well (group photos).
        if let mainArea = c.faces.map({ $0.rect.width * $0.rect.height }).max(), c.faces.count > 1 {
            for face in c.faces {
                let f = face.rect
                let rel = f.width * f.height / max(mainArea, 1e-6)
                guard rel < 0.999, rel > 0.2 else { continue }
                let cut = f.minX < r.x || f.maxX > r.x + r.width || f.minY < r.y || f.maxY > r.y + r.height
                if cut { score -= 0.6 + 0.6 * rel }
            }
        }
        if let face = c.faces.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            let f = face.rect
            let cut = f.minX < r.x || f.maxX > r.x + r.width || f.minY < r.y || f.maxY > r.y + r.height
            if cut { score -= 1.5 } else {
                faceInside = true
                px = f.midX; py = f.minY + f.height * 0.38
                // head room: face top at least 6 % of the crop below the top edge
                let head = (f.minY - r.y) / r.height
                if head < 0.06 { score -= 0.6 * (0.06 - head) / 0.06 }
                // lead room: more space in the direction the face looks
                if abs(face.gaze) > 0.4 {
                    let pos = (f.midX - r.x) / r.width          // 0 = left edge
                    let looksLeft = face.gaze < 0
                    let lead = looksLeft ? pos : 1 - pos
                    if lead < 0.5 { score -= 0.5 * (0.5 - lead) } else { reasons.append(String(localized: "space in the direction of view")) }
                }
            }
        }
        // Thirds or centre (symmetric subjects may sit in the middle)
        let u = (px - r.x) / r.width, v = (py - r.y) / r.height
        let thirds = [(1.0 / 3, 1.0 / 3), (2.0 / 3, 1.0 / 3), (1.0 / 3, 2.0 / 3), (2.0 / 3, 2.0 / 3)]
        let dThird = thirds.map { hypot(u - $0.0, v - $0.1) }.min() ?? 1
        let dCenter = hypot(u - 0.5, v - 0.5)
        let dPos = min(dThird, dCenter * 1.25)
        score -= 0.55 * dPos
        if dThird < 0.08 { reasons.append(faceInside ? String(localized: "face on a third") : String(localized: "subject on a third")) }
        else if dCenter < 0.08 { reasons.append(String(localized: "subject centred")) }
        if border < 0.004 { reasons.append(String(localized: "no subject cut at the edge")) }
        return (score, reasons)
    }
}
