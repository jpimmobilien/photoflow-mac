import Foundation
import CoreGraphics
import AppKit

/// `--qa eval-photo-batch <folder> <out> [count]` – checks the Foto-KI batch optimisation on real photos:
///  • every photo gets its own adjustments (spread of exposure / contrast / temperature / saturation across the set),
///  • smart crop keeps faces inside, picks different formats for different photos (free mode),
///  • contact sheet with the crop frames for a visual check (red 16:9, green 1:1, blue 9:16, yellow free).
enum PhotoBatchQA {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func run(folder: String, out: String, count: Int) throws {
        let urls = Array(ImportService.collectImageURLs(from: [URL(fileURLWithPath: folder)]).prefix(count))
        guard urls.count >= 5 else { throw Failure(description: "need at least 5 photos, found \(urls.count)") }
        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var exposure: [Double] = [], contrast: [Double] = [], temperature: [Double] = [], saturation: [Double] = []
        var signatures = Set<String>()
        var facePhotos = 0, faceKept = 0
        var freeFormats: [String: Int] = [:]
        var cropped = 0
        var tiles: [CGImage] = []
        let modes: [(AutoCrop.Mode, NSColor)] = [(.aspect(width: 16, height: 9), .systemRed), (.aspect(width: 1, height: 1), .systemGreen),
                                                 (.aspect(width: 9, height: 16), .systemBlue), (.smartFree, .systemYellow)]
        let t0 = Date()
        for url in urls {
            guard let a = PhotoAnalyzer.analyze(url: url) else { continue }
            let r = AutoEnhanceEngine.enhance(a, strength: .balanced, options: .everything).recipe
            exposure.append(r.exposure); contrast.append(r.contrast); temperature.append(r.temperature); saturation.append(r.saturation)
            signatures.insert(String(format: "%.2f/%.2f/%.0f/%.2f", r.exposure, r.contrast, r.temperature, r.saturation))

            guard let thumb = ImageLoader.thumbnail(url: url, maxPixel: 768), let content = SmartCrop.content(of: thumb) else { continue }
            var rects: [(NormalizedRect, NSColor)] = []
            for (mode, color) in modes {
                guard let (rect, note) = AutoCrop.smart(mode, analysisImage: thumb) else { continue }
                rects.append((rect, color))
                if case .smartFree = mode {
                    cropped += 1
                    let name = note.components(separatedBy: " · ").first ?? note
                    freeFormats[name, default: 0] += 1
                }
                if !content.faces.isEmpty, case .aspect(let w, _) = mode, w == 16 {
                    // faces: normalized, origin top-left – same convention as the crop rect. Only faces that are not
                    // tiny next to the main face count (same rule as SmartCrop), and only if they fit into the crop at all.
                    let mainArea = content.faces.map { $0.rect.width * $0.rect.height }.max() ?? 0
                    let significant = content.faces.map(\.rect).filter { $0.width * $0.height > 0.2 * mainArea }
                    let union = significant.dropFirst().reduce(significant[0]) { $0.union($1) }
                    if union.width <= rect.width && union.height <= rect.height {
                        facePhotos += 1
                        let inside = significant.allSatisfy { f in
                            f.minX >= rect.x - 0.01 && f.maxX <= rect.x + rect.width + 0.01 &&
                            f.minY >= rect.y - 0.01 && f.maxY <= rect.y + rect.height + 0.01
                        }
                        if inside { faceKept += 1 } else { print("  face cut: \(url.lastPathComponent)") }
                    }
                }
            }
            if tiles.count < 24, let tile = drawTile(thumb, rects) { tiles.append(tile) }
            print(String(format: "%@  exp %+.2f  con %+.2f  temp %+.0f  sat %+.2f  faces %d  crops %d", url.lastPathComponent,
                         r.exposure, r.contrast, r.temperature, r.saturation, content.faces.count, rects.count))
        }
        func spread(_ v: [Double]) -> (Double, Double, Double) {
            let m = v.reduce(0, +) / Double(max(1, v.count))
            let sd = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(1, v.count))).squareRoot()
            return (v.min() ?? 0, v.max() ?? 0, sd)
        }
        let n = exposure.count
        let e = spread(exposure), c = spread(contrast), t = spread(temperature), s = spread(saturation)
        print(String(format: "photos %d in %.1f s", n, Date().timeIntervalSince(t0)))
        print(String(format: "exposure   min %+.2f max %+.2f sd %.3f", e.0, e.1, e.2))
        print(String(format: "contrast   min %+.2f max %+.2f sd %.3f", c.0, c.1, c.2))
        print(String(format: "temperature min %+.0f max %+.0f sd %.1f", t.0, t.1, t.2))
        print(String(format: "saturation min %+.2f max %+.2f sd %.3f", s.0, s.1, s.2))
        print("distinct adjustment sets: \(signatures.count) of \(n)")
        print("free crop formats: \(freeFormats.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) (cropped \(cropped) of \(n))")
        print("faces kept inside 16:9 crop: \(faceKept) of \(facePhotos)")
        if let sheet = contactSheet(tiles) {
            try VideoIO.writePNG(sheet, to: outDir.appendingPathComponent("smartcrop_sheet.png"))
        }
        guard signatures.count >= max(3, n * 6 / 10) else { throw Failure(description: "adjustments are too uniform (\(signatures.count) of \(n))") }
        guard facePhotos == 0 || Double(faceKept) / Double(facePhotos) >= 0.9 else { throw Failure(description: "faces cut off by the crop") }
        print("PASS photo batch")
    }

    private static func drawTile(_ img: CGImage, _ rects: [(NormalizedRect, NSColor)]) -> CGImage? {
        let w = 360, h = Int(Double(img.height) / Double(img.width) * 360)
        guard let ctx = CGContext(data: nil, width: w, height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineWidth(3)
        for (r, color) in rects {
            ctx.setStrokeColor(color.cgColor)
            // top-left origin → Core Graphics bottom-left origin
            ctx.stroke(CGRect(x: r.x * Double(w), y: (1 - r.y - r.height) * Double(h), width: r.width * Double(w), height: r.height * Double(h)).insetBy(dx: 1.5, dy: 1.5))
        }
        return ctx.makeImage()
    }

    private static func contactSheet(_ tiles: [CGImage]) -> CGImage? {
        guard !tiles.isEmpty else { return nil }
        let cols = 4, cell = 370
        let rows = (tiles.count + cols - 1) / cols
        let rowH = 290
        guard let ctx = CGContext(data: nil, width: cols * cell, height: rows * rowH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cols * cell, height: rows * rowH))
        for (i, t) in tiles.enumerated() {
            let col = i % cols, row = i / cols
            let scale = min(1, Double(rowH - 10) / Double(t.height))
            let tw = Double(t.width) * scale, th = Double(t.height) * scale
            ctx.draw(t, in: CGRect(x: Double(col * cell + 5), y: Double((rows - 1 - row) * rowH + 5), width: tw, height: th))
        }
        return ctx.makeImage()
    }
}
