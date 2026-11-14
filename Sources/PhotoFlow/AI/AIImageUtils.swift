import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Pixel helpers shared by the AI engines. All images are 8-bit sRGB.
enum AIImage {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Loading

    /// Loads an image file (orientation applied), optionally with PhotoFlow's edit recipe, limited to `maxPixel`.
    static func load(url: URL, recipe: EditRecipe? = nil, maxPixel: Int = 4096) throws -> CGImage {
        var ci = try ImageLoader.full(url: url)
        if let recipe { ci = RenderPipeline.apply(recipe, to: ci) }
        let ext = ci.extent
        let longSide = max(ext.width, ext.height)
        if longSide > CGFloat(maxPixel) {
            let s = CGFloat(maxPixel) / longSide
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let rect = CGRect(x: 0, y: 0, width: ci.extent.width.rounded(.down), height: ci.extent.height.rounded(.down))
        guard let cg = CIContextProvider.shared.createCGImage(ci, from: rect, format: .RGBA8, colorSpace: sRGB) else {
            throw AIError.imageUnreadable
        }
        return normalized(cg) ?? cg
    }

    /// Redraws into a plain RGBA8 sRGB bitmap (what Core ML image inputs and vImage expect).
    static func normalized(_ image: CGImage) -> CGImage? {
        draw(width: image.width, height: image.height) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    static func draw(width: Int, height: Int, opaque: Bool = true, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        body(ctx)
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        draw(width: width, height: height) { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    /// Crop in top-left pixel coordinates.
    static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    // MARK: Square fitting (the diffusion models work on fixed squares)

    /// Places `image` centred on a square canvas of `side` pixels. Empty borders are filled by
    /// stretching the edge pixels and blurring them, which gives the model a neutral, plausible context.
    /// Returns the canvas and the rect (top-left coordinates) that holds the image.
    struct Fitted { var image: CGImage; var rect: CGRect }

    static func fitSquare(_ image: CGImage, side: Int) -> Fitted? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = CGFloat(side) / max(w, h)
        let fw = (w * s).rounded(), fh = (h * s).rounded()
        let rect = CGRect(x: ((CGFloat(side) - fw) / 2).rounded(), y: ((CGFloat(side) - fh) / 2).rounded(), width: fw, height: fh)
        let canvas = draw(width: side, height: side) { ctx in
            // background: blurred, stretched copy
            if let blurred = blurredFill(image, side: side) {
                ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            ctx.draw(image, in: CGRect(x: rect.minX, y: CGFloat(side) - rect.maxY, width: fw, height: fh))
        }
        return canvas.map { Fitted(image: $0, rect: rect) }
    }

    private static func blurredFill(_ image: CGImage, side: Int) -> CGImage? {
        let ci = CIImage(cgImage: image).clampedToExtent()
        let sx = CGFloat(side) / CGFloat(image.width), sy = CGFloat(side) / CGFloat(image.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .applyingGaussianBlur(sigma: Double(side) / 24)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        return CIContextProvider.cpu.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: sRGB)
    }

    // MARK: Masks (8-bit grey, 255 = area to change)

    static func grayMask(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(ctx)
        return ctx.makeImage()
    }

    /// 8-bit grey image from raw bytes (row-major, top row first).
    static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard bytes.count == width * height, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Grey values of a mask at the given size (row-major, top row first, 0…1).
    static func maskValues(_ mask: CGImage, width: Int, height: Int) -> [Float] {
        var buf = [UInt8](repeating: 0, count: width * height)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buf.map { Float($0) / 255 }
    }

    /// Mask at latent resolution: area-averaged, then expanded so every latent cell that touches
    /// the painted area is regenerated (latents are 8×8 pixel blocks).
    static func latentMask(_ mask: CGImage, side: Int) -> [Float] {
        let v = maskValues(mask, width: side, height: side)
        var out = v.map { min(1, $0 * 3) }
        // one-cell dilation
        for y in 0..<side {
            for x in 0..<side where v[y * side + x] > 0.02 {
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < side, ny < side { out[ny * side + nx] = max(out[ny * side + nx], 0.85) }
                } }
            }
        }
        return out
    }

    /// Bounding box (top-left coordinates) of the painted area, nil if empty.
    static func maskBounds(_ mask: CGImage) -> CGRect? {
        let w = min(mask.width, 1024), h = max(1, Int(Double(mask.height) * Double(w) / Double(mask.width)))
        let v = maskValues(mask, width: w, height: h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where v[y * w + x] > 0.1 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return nil }
        let sx = Double(mask.width) / Double(w), sy = Double(mask.height) / Double(h)
        return CGRect(x: Double(minX) * sx, y: Double(minY) * sy, width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy)
    }

    static func maskCoverage(_ mask: CGImage) -> Double {
        let v = maskValues(mask, width: 256, height: max(1, 256 * mask.height / max(1, mask.width)))
        return Double(v.reduce(0, +)) / Double(max(1, v.count))
    }

    static func invert(_ mask: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: mask).applyingFilter("CIColorInvert")
        return CIContextProvider.cpu.createCGImage(ci, from: CGRect(x: 0, y: 0, width: mask.width, height: mask.height),
                                                   format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// Softens the mask edge by `radius` pixels.
    static func feather(_ mask: CGImage, radius: Double) -> CIImage {
        let ci = CIImage(cgImage: mask)
        guard radius > 0.5 else { return ci }
        return ci.clampedToExtent().applyingGaussianBlur(sigma: radius / 2).cropped(to: ci.extent)
    }

    /// Grows the mask by `pixels` (morphology).
    static func dilate(_ mask: CGImage, pixels: Double) -> CGImage? {
        guard pixels >= 1 else { return mask }
        let ci = CIImage(cgImage: mask).applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: pixels])
            .cropped(to: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
        return CIContextProvider.cpu.createCGImage(ci, from: CGRect(x: 0, y: 0, width: mask.width, height: mask.height),
                                                   format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// `edited` over `original` through a feathered mask – pixels outside the mask stay exactly as they were.
    static func composite(_ edited: CGImage, over original: CGImage, mask: CGImage, feather: Double) -> CGImage? {
        let size = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        var e = CIImage(cgImage: edited)
        if edited.width != original.width || edited.height != original.height {
            e = e.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(edited.width), y: size.height / CGFloat(edited.height)))
        }
        var m = AIImage.feather(mask, radius: feather)
        if mask.width != original.width || mask.height != original.height {
            m = m.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(mask.width), y: size.height / CGFloat(mask.height)))
        }
        let out = e.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: original),
                                                                   kCIInputMaskImageKey: m]).cropped(to: size)
        return CIContextProvider.shared.createCGImage(out, from: size, format: .RGBA8, colorSpace: sRGB)
    }

    /// Coloured, semi-transparent overlay of a mask for display (selected area tinted).
    static func tintedOverlay(_ mask: CGImage, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        let color = CIImage(color: CIColor(red: red, green: green, blue: blue, alpha: alpha)).cropped(to: rect)
        let out = color.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                       kCIInputMaskImageKey: CIImage(cgImage: mask)]).cropped(to: rect)
        return CIContextProvider.cpu.createCGImage(out, from: rect, format: .RGBA8, colorSpace: sRGB)
    }

    // MARK: Encoding

    static func pngData(_ image: CGImage, metadata: [CFString: Any]? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, metadata as CFDictionary?)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.92, metadata: [CFString: Any]? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var props = metadata ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func loadPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Errors with a clear explanation and a way forward.
enum AIError: LocalizedError {
    case noModel(AICapability)
    case modelMissing(String)
    case imageUnreadable
    case emptyMask
    case emptyPrompt
    case cancelled
    case invalidOutput(String, String)
    case outOfMemory
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noModel(let c):
            return String(localized: "No model for “\(c.title)” is installed. Open Model Management and download one – it only takes a moment once.")
        case .modelMissing(let modelName):
            return String(localized: "The files of \(modelName) are missing or damaged. Remove the model in Model Management and download it again.")
        case .imageUnreadable: return String(localized: "The image could not be read. Try another photo or export it as JPEG or PNG first.")
        case .emptyMask: return String(localized: "Paint over the area you want to change first.")
        case .emptyPrompt: return String(localized: "Describe what you want to see.")
        case .cancelled: return String(localized: "Cancelled.")
        case .invalidOutput(let modelName, let reason):
            return String(localized: "\(modelName) did not produce a valid image on this Mac (\(reason)). PhotoFlow does not show such results. Install a model for the other processor in Model Management (e.g. a Neural Engine variant) – PhotoFlow then switches automatically.")
        case .outOfMemory:
            return String(localized: "Not enough memory for this model. Close other apps, choose the “Energy saving” profile or a smaller model, and try again.")
        case .unsupported(let m): return m
        case .failed(let m): return m
        }
    }
}
