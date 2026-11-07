import Foundation
import ImageIO
import CoreImage
import CoreGraphics

/// Efficient image decoding. Never decodes more pixels than needed:
/// thumbnails and previews use ImageIO's downsampling decoder; only exports decode full resolution.
enum ImageLoader {
    enum LoadError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return String(localized: "The file “\(name)” could not be read as an image.")
            }
        }
    }

    /// Decodes a downsampled, correctly oriented CGImage with the given maximum long side.
    static func thumbnail(url: URL, maxPixel: Int, preferEmbedded: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        func make(_ always: Bool) -> CGImage? {
            var opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if always {
                opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
            } else {
                opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if preferEmbedded, let t = make(false), max(t.width, t.height) >= maxPixel / 2 { return t }
        return make(true)
    }

    /// Preview-quality CIImage (oriented) limited to `maxPixel` on the long side.
    static func preview(url: URL, maxPixel: Int) -> CIImage? {
        guard let cg = thumbnail(url: url, maxPixel: maxPixel) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Full-resolution CIImage (lazy – Core Image decodes tiles on demand). RAW files go through CIRAWFilter.
    static func full(url: URL, uti: String? = nil) throws -> CIImage {
        let isRaw = uti.map(PhotoFormat.isRAW) ?? PhotoFormat.isRAW(typeIdentifier(of: url) ?? "")
        if isRaw, let raw = CIRAWFilter(imageURL: url), let out = raw.outputImage {
            return out
        }
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        return img
    }

    static func typeIdentifier(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(src) as String?
    }

    /// Pixel dimensions after orientation.
    static func orientedSize(url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let o = p[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { return CGSize(width: h, height: w) }
        return CGSize(width: w, height: h)
    }
}

/// 8-bit sRGB RGBA pixel buffer used by the analysis algorithms (row 0 = top of the image).
struct PixelBuffer: @unchecked Sendable {
    let width: Int
    let height: Int
    var data: [UInt8]   // RGBA, premultiplied-last with opaque alpha

    init?(cgImage: CGImage, maxSide: Int) {
        let scale = min(1.0, Double(maxSide) / Double(max(cgImage.width, cgImage.height)))
        let w = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let h = max(1, Int((Double(cgImage.height) * scale).rounded()))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CIContextProvider.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; data = buf
    }

    init?(ciImage: CIImage, maxSide: Int, context: CIContext = CIContextProvider.shared) {
        let ext = ciImage.extent
        guard ext.width > 0, ext.height > 0, ext.width.isFinite else { return nil }
        let s = min(1.0, Double(maxSide) / Double(max(ext.width, ext.height)))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8,
                                             colorSpace: CIContextProvider.sRGB) else { return nil }
        self.init(cgImage: cg, maxSide: maxSide)
    }

    /// Rec.709 luma of the gamma-encoded values (0…1), row-major.
    func luma() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        data.withUnsafeBufferPointer { p in
            for i in 0 ..< width * height {
                let r = Float(p[i * 4]), g = Float(p[i * 4 + 1]), b = Float(p[i * 4 + 2])
                out[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            }
        }
        return out
    }
}

/// sRGB transfer function helpers.
enum ColorMath {
    static let toLinearLUT: [Float] = (0 ..< 256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func toGamma(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
    }
}
