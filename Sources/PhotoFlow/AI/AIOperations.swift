import Foundation
import CoreGraphics
import CoreImage
import Vision

// MARK: - Options shown in the UI

enum AIQuality: String, CaseIterable, Identifiable, Codable {
    case draft, standard, high, maximum
    var id: String { rawValue }

    var title: String {
        switch self {
        case .draft: return String(localized: "Draft")
        case .standard: return String(localized: "Standard")
        case .high: return String(localized: "High")
        case .maximum: return String(localized: "Maximum")
        }
    }

    var baseSteps: Int {
        switch self { case .draft: return 12; case .standard: return 20; case .high: return 30; case .maximum: return 40 }
    }

    /// Real-ESRGAN factor applied after generation (only when an upscaler is installed).
    var upscaleFactor: Int {
        switch self { case .draft, .standard: return 1; case .high: return 2; case .maximum: return 4 }
    }

    func steps(profile: AIPerformanceProfile) -> Int { max(8, Int((Double(baseSteps) * profile.stepFactor).rounded())) }
}

enum AIAspect: String, CaseIterable, Identifiable, Codable {
    case square, landscape4x3, landscape3x2, wide16x9, portrait9x16, portrait2x3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .square: return "1:1"
        case .landscape4x3: return "4:3"
        case .landscape3x2: return "3:2"
        case .wide16x9: return "16:9"
        case .portrait9x16: return "9:16"
        case .portrait2x3: return "2:3"
        }
    }
    /// width / height
    var ratio: Double {
        switch self {
        case .square: return 1
        case .landscape4x3: return 4.0 / 3
        case .landscape3x2: return 3.0 / 2
        case .wide16x9: return 16.0 / 9
        case .portrait9x16: return 9.0 / 16
        case .portrait2x3: return 2.0 / 3
        }
    }
    var symbol: String {
        switch self {
        case .square: return "square"
        case .landscape4x3, .landscape3x2: return "rectangle"
        case .wide16x9: return "rectangle.ratio.16.to.9"
        case .portrait9x16, .portrait2x3: return "rectangle.portrait"
        }
    }
    /// Crop of a generated square (top-left coordinates).
    func crop(side: Int) -> CGRect {
        let s = Double(side)
        if ratio >= 1 { let h = (s / ratio).rounded(); return CGRect(x: 0, y: ((s - h) / 2).rounded(), width: s, height: h) }
        let w = (s * ratio).rounded()
        return CGRect(x: ((s - w) / 2).rounded(), y: 0, width: w, height: s)
    }
}

/// Photographic styles. They extend the prompt (they are not filters applied afterwards).
struct AIStyle: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let positive: String
    let negative: String

    static let none = AIStyle(id: "none", title: String(localized: "No style"), symbol: "circle.slash", positive: "", negative: "")

    static let all: [AIStyle] = [
        AIStyle(id: "photo", title: String(localized: "Photorealistic"), symbol: "camera",
                positive: "photorealistic photograph, natural light, sharp focus, highly detailed, realistic textures",
                negative: "painting, illustration, drawing, cartoon, 3d render, cgi"),
        AIStyle(id: "portrait", title: String(localized: "Studio portrait"), symbol: "person.crop.square",
                positive: "professional studio portrait, softbox lighting, 85mm lens, shallow depth of field, detailed skin texture",
                negative: "distorted face, extra fingers, cartoon, harsh shadows"),
        AIStyle(id: "product", title: String(localized: "Product photo"), symbol: "shippingbox",
                positive: "commercial product photography, clean seamless background, studio lighting, crisp reflections, high detail",
                negative: "clutter, text, logo, watermark"),
        AIStyle(id: "realestate", title: String(localized: "Real estate"), symbol: "house",
                positive: "professional real estate photography, bright interior, wide angle 16mm, straight vertical lines, natural daylight, HDR",
                negative: "fisheye distortion, tilted lines, dark, cluttered"),
        AIStyle(id: "landscape", title: String(localized: "Landscape"), symbol: "mountain.2",
                positive: "landscape photography, golden hour, wide angle, dramatic sky, rich detail, high dynamic range",
                negative: "oversaturated, painting"),
        AIStyle(id: "architecture", title: String(localized: "Architecture"), symbol: "building.2",
                positive: "architectural photography, symmetrical composition, clean lines, overcast soft light, tilt-shift lens",
                negative: "distorted perspective, people"),
        AIStyle(id: "food", title: String(localized: "Food"), symbol: "fork.knife",
                positive: "food photography, appetizing, natural window light, shallow depth of field, rustic table",
                negative: "unappetizing, plastic, cartoon"),
        AIStyle(id: "film", title: String(localized: "Analog film"), symbol: "film",
                positive: "35mm analog film photograph, Kodak Portra 400, fine film grain, soft contrast, nostalgic colors",
                negative: "digital look, oversharpened"),
        AIStyle(id: "bw", title: String(localized: "Black & white"), symbol: "circle.lefthalf.filled",
                positive: "black and white photograph, monochrome, high contrast, fine grain, dramatic light",
                negative: "color, colorful"),
        AIStyle(id: "cinematic", title: String(localized: "Cinematic"), symbol: "film.stack",
                positive: "cinematic still, anamorphic lens, moody lighting, color graded, depth of field",
                negative: "flat lighting, amateur"),
        AIStyle(id: "macro", title: String(localized: "Macro"), symbol: "camera.macro",
                positive: "macro photography, extreme close-up, 100mm macro lens, intricate detail, soft bokeh",
                negative: "blurry subject, wide shot"),
        AIStyle(id: "minimal", title: String(localized: "Minimalist"), symbol: "square.dashed",
                positive: "minimalist photograph, negative space, simple composition, soft pastel tones, clean",
                negative: "clutter, busy background")
    ]

    static func style(_ id: String?) -> AIStyle { all.first { $0.id == id } ?? none }
}

/// Everything a diffusion operation needs besides the images.
struct GenerationSettings {
    var model: AIModelDescriptor
    var prompt: String
    var negativePrompt: String = ""
    var style: AIStyle = .none
    var steps: Int
    var guidance: Float = 7.5

    static let baseNegative = "blurry, low quality, lowres, jpeg artifacts, watermark, signature, text, deformed, disfigured, bad anatomy"

    var fullPrompt: String {
        [prompt.trimmingCharacters(in: .whitespacesAndNewlines), style.positive].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var fullNegative: String {
        [negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines), style.negative, Self.baseNegative].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func job(seed: UInt32, start: CGImage? = nil, strength: Float = 1, mask: CGImage? = nil) -> DiffusionJob {
        DiffusionJob(model: model, prompt: fullPrompt, negativePrompt: fullNegative, steps: steps, guidance: guidance,
                     seed: seed, startingImage: start, strength: strength, mask: mask)
    }
}

// MARK: - Operations (synchronous – run them on the AI queue via DiffusionEngine.shared.perform)

enum AIOperations {
    typealias StepHandler = (StepReport) -> Void

    // MARK: Text to image

    static func textToImage(_ s: GenerationSettings, aspect: AIAspect, seed: UInt32, token: AICancelToken,
                            onStep: @escaping StepHandler) throws -> CGImage {
        let square = try DiffusionEngine.shared.generateSync(s.job(seed: seed), token: token, onStep: onStep)
        guard aspect != .square, let cropped = AIImage.crop(square, aspect.crop(side: square.width)) else { return square }
        return cropped
    }

    // MARK: Image to image

    static func imageToImage(_ source: CGImage, _ s: GenerationSettings, strength: Float, seed: UInt32, token: AICancelToken,
                             onStep: @escaping StepHandler) throws -> CGImage {
        let side = s.model.resolution
        guard let fit = AIImage.fitSquare(source, side: side) else { throw AIError.imageUnreadable }
        let square = fit.image, rect = fit.rect
        let out = try DiffusionEngine.shared.generateSync(s.job(seed: seed, start: square, strength: strength), token: token, onStep: onStep)
        return AIImage.crop(out, rect) ?? out
    }

    // MARK: Generative fill (inpainting)

    /// Regenerates the masked area of `source`. Only a context region around the mask is processed, so the
    /// rest of the photo keeps its full resolution; the result is blended back with a feathered edge.
    static func generativeFill(_ source: CGImage, mask: CGImage, _ s: GenerationSettings, strength: Float = 1, feather: Double,
                               seed: UInt32, token: AICancelToken, onStep: @escaping StepHandler) throws -> CGImage {
        guard let bounds = AIImage.maskBounds(mask) else { throw AIError.emptyMask }
        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let region = contextRegion(around: bounds, in: full, minSide: Double(s.model.resolution))
        return try fillRegion(source, mask: mask, region: region, settings: s, strength: strength, feather: feather,
                              seed: seed, token: token, onStep: onStep)
    }

    /// Context rectangle: the mask's bounds plus generous margins, at least `minSide` where the image allows.
    static func contextRegion(around b: CGRect, in full: CGRect, minSide: Double) -> CGRect {
        let margin = max(b.width, b.height) * 0.45 + 16
        var r = b.insetBy(dx: -margin, dy: -margin)
        if r.width < minSide { r = r.insetBy(dx: -(minSide - r.width) / 2, dy: 0) }
        if r.height < minSide { r = r.insetBy(dx: 0, dy: -(minSide - r.height) / 2) }
        // shift inside the image before clipping, to keep as much context as possible
        if r.minX < 0 { r.origin.x = 0 }
        if r.minY < 0 { r.origin.y = 0 }
        if r.maxX > full.maxX { r.origin.x = max(0, full.maxX - r.width) }
        if r.maxY > full.maxY { r.origin.y = max(0, full.maxY - r.height) }
        return r.intersection(full).integral
    }

    private static func fillRegion(_ source: CGImage, mask: CGImage, region: CGRect, settings s: GenerationSettings, strength: Float,
                                   feather: Double, seed: UInt32, token: AICancelToken, onStep: @escaping StepHandler) throws -> CGImage {
        let side = s.model.resolution
        guard let crop = AIImage.crop(source, region),
              let maskFull = mask.width == source.width && mask.height == source.height ? mask : AIImage.resize(mask, width: source.width, height: source.height),
              let maskCrop = AIImage.crop(maskFull, region),
              let fit = AIImage.fitSquare(crop, side: side),
              let squareMask = fitMask(maskCrop, side: side, rect: fit.rect) else { throw AIError.imageUnreadable }
        let square = fit.image, rect = fit.rect
        let generated = try DiffusionEngine.shared.generateSync(s.job(seed: seed, start: square, strength: strength, mask: squareMask),
                                                                token: token, onStep: onStep)
        guard let content = AIImage.crop(generated, rect) else { throw AIError.imageUnreadable }
        let resized = try enlarge(content, toWidth: Int(region.width), height: Int(region.height), token: token)
        guard let blended = AIImage.composite(resized, over: crop, mask: maskCrop, feather: feather) else { throw AIError.imageUnreadable }
        return paste(blended, into: source, at: region) ?? source
    }

    /// The mask drawn into the same letterboxed square as the image (borders = keep).
    static func fitMask(_ mask: CGImage, side: Int, rect: CGRect) -> CGImage? {
        AIImage.grayMask(width: side, height: side) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(mask, in: CGRect(x: rect.minX, y: CGFloat(side) - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    /// Scales a generated region up to its destination size, with Real-ESRGAN when installed and useful.
    static func enlarge(_ image: CGImage, toWidth w: Int, height h: Int, token: AICancelToken) throws -> CGImage {
        if image.width == w && image.height == h { return image }
        let factor = Double(w) / Double(image.width)
        if factor > 1.6, let up = ModelStoreSnapshot.current.upscaler(scale: factor > 2.8 ? 4 : 2) {
            let big = try Upscaler.shared.upscaleSync(image, with: up, token: token) { _ in }
            return AIImage.resize(big, width: w, height: h) ?? big
        }
        return AIImage.resize(image, width: w, height: h) ?? image
    }

    static func paste(_ patch: CGImage, into base: CGImage, at region: CGRect) -> CGImage? {
        AIImage.draw(width: base.width, height: base.height) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            ctx.draw(patch, in: CGRect(x: region.minX, y: CGFloat(base.height) - region.maxY, width: region.width, height: region.height))
        }
    }

    // MARK: Expand (outpainting)

    struct Expansion: Equatable { var left = 0, top = 0, right = 0, bottom = 0
        var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    }

    /// Extends the canvas and lets the model invent the new areas. Original pixels are kept exactly.
    static func expand(_ source: CGImage, by e: Expansion, _ s: GenerationSettings, seed: UInt32, token: AICancelToken,
                       onStep: @escaping StepHandler) throws -> CGImage {
        guard !e.isEmpty else { throw AIError.emptyMask }
        let W = source.width + e.left + e.right, H = source.height + e.top + e.bottom
        guard W <= 12_000, H <= 12_000 else { throw AIError.unsupported(String(localized: "The expanded image would be too large.")) }
        let inner = CGRect(x: e.left, y: e.top, width: source.width, height: source.height)
        // Prefill: the image mirrored at its edges, softened. Generation then starts from this prefill (strength < 1),
        // so colours, light and layout continue across the border instead of the model inventing an unrelated scene.
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
        guard let mirrored = mirrorExtend(source, e), let canvas = AIImage.draw(width: W, height: H, { ctx in
            let soft = CIImage(cgImage: mirrored).clampedToExtent()
                .applyingGaussianBlur(sigma: Double(max(e.left, e.right, e.top, e.bottom)) / 14).cropped(to: canvasRect)
            if let b = CIContextProvider.cpu.createCGImage(soft, from: canvasRect, format: .RGBA8, colorSpace: AIImage.sRGB) {
                ctx.draw(b, in: canvasRect)
            }
            ctx.draw(source, in: CGRect(x: e.left, y: e.bottom, width: source.width, height: source.height))
        }) else { throw AIError.imageUnreadable }
        // Without a prompt, describe the photo with Apple's on-device classifier so the continuation matches it.
        var s = s
        if s.prompt.trimmingCharacters(in: .whitespaces).isEmpty { s.prompt = describe(source) }
        // The new strips are generated tile by tile: each tile is a square that contains part of a new strip plus
        // real image content next to it, so the model sees the scene at a useful resolution and continues it.
        // Tiles are processed one after another, later tiles see the earlier results.
        let band = max(6.0, Double(max(W, H)) * 0.015)      // seam band inside the original that is redrawn
        let maxSquare = min(W, H)
        var current = canvas
        var tiles: [(CGRect, CGRect, Bool)] = []             // (tile, strip, horizontal) in top-left coordinates
        func addTiles(strip: CGRect, horizontalStrip: Bool) {
            let thickness = Int(horizontalStrip ? strip.height : strip.width)
            guard thickness > 0 else { return }
            let t = min(maxSquare, max(Int(Double(thickness) * 2.6), min(maxSquare, 384)))
            let length = Int(horizontalStrip ? strip.width : strip.height)
            let stepLen = max(1, Int(Double(t) * 0.7))
            var pos = 0
            while true {
                let p = min(pos, max(0, length - t))
                var tile: CGRect
                if horizontalStrip {
                    let y = strip.minY < CGFloat(e.top) + 1 ? 0 : CGFloat(H - t)        // top or bottom edge
                    tile = CGRect(x: strip.minX + CGFloat(p), y: y, width: CGFloat(t), height: CGFloat(t))
                } else {
                    let x = strip.minX < 1 ? 0 : CGFloat(W - t)                         // left or right edge
                    tile = CGRect(x: x, y: strip.minY + CGFloat(p), width: CGFloat(t), height: CGFloat(t))
                }
                tile = tile.intersection(canvasRect)
                tiles.append((tile, strip, horizontalStrip))
                if p + t >= length { break }
                pos += stepLen
            }
        }
        if e.left > 0 { addTiles(strip: CGRect(x: 0, y: e.top, width: e.left, height: source.height), horizontalStrip: false) }
        if e.right > 0 { addTiles(strip: CGRect(x: W - e.right, y: e.top, width: e.right, height: source.height), horizontalStrip: false) }
        if e.top > 0 { addTiles(strip: CGRect(x: 0, y: 0, width: W, height: e.top), horizontalStrip: true) }
        if e.bottom > 0 { addTiles(strip: CGRect(x: 0, y: H - e.bottom, width: W, height: e.bottom), horizontalStrip: true) }

        for (i, (tile, strip, horizontal)) in tiles.enumerated() {
            if token.isCancelled { throw AIError.cancelled }
            // Mask: the part of the strip inside this tile, widened by the seam band towards the image. Along the strip,
            // tile edges inside the canvas are kept out of the mask so neighbouring tiles blend softly (no seams).
            var maskRect = strip.insetBy(dx: -CGFloat(band), dy: -CGFloat(band)).intersection(tile)
            let inset = CGFloat(min(band * 2, Double(min(tile.width, tile.height)) * 0.12))
            // Only tile edges strictly inside the strip are pulled in; the strip's own ends stay covered.
            if horizontal {
                if tile.minX > strip.minX + 0.5 { maskRect.origin.x += inset; maskRect.size.width -= inset }
                if tile.maxX < strip.maxX - 0.5 { maskRect.size.width -= inset }
            } else {
                if tile.minY > strip.minY + 0.5 { maskRect.origin.y += inset; maskRect.size.height -= inset }
                if tile.maxY < strip.maxY - 0.5 { maskRect.size.height -= inset }
            }
            guard let mask = AIImage.grayMask(width: W, height: H, { ctx in
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: maskRect.minX, y: CGFloat(H) - maskRect.maxY, width: maskRect.width, height: maskRect.height))
            }) else { throw AIError.imageUnreadable }
            current = try fillRegion(current, mask: mask, region: tile, settings: s, strength: outpaintStrength, feather: band * 1.5,
                                     seed: seed &+ UInt32(i), token: token, onStep: onStep)
        }
        // Original pixels (away from the seam band) are restored exactly.
        guard let keep = AIImage.grayMask(width: W, height: H, { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(canvasRect)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: inner.minX, y: CGFloat(H) - inner.maxY, width: inner.width, height: inner.height).insetBy(dx: CGFloat(band), dy: CGFloat(band)))
        }), let out = AIImage.composite(current, over: canvas, mask: keep, feather: band * 0.5) else { throw AIError.imageUnreadable }
        return out
    }

    /// How much the model may deviate from the mirrored prefill when expanding (1 = ignore it).
    static let outpaintStrength: Float = 0.82

    /// Canvas of the expanded size with the source in place and mirrored copies in the new areas.
    static func mirrorExtend(_ source: CGImage, _ e: Expansion) -> CGImage? {
        let w = source.width, h = source.height
        let W = w + e.left + e.right, H = h + e.top + e.bottom
        return AIImage.draw(width: W, height: H) { ctx in
            // CoreGraphics origin is bottom-left: the source sits at (left, bottom).
            func put(_ flipX: Bool, _ flipY: Bool, dx: Int, dy: Int) {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(dx + (flipX ? w : 0)), y: CGFloat(dy + (flipY ? h : 0)))
                ctx.scaleBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
                ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()
            }
            let x0 = e.left, y0 = e.bottom
            for (fx, ox) in [(false, 0), (true, -w), (true, w)] {
                for (fy, oy) in [(false, 0), (true, -h), (true, h)] {
                    put(fx, fy, dx: x0 + ox, dy: y0 + oy)
                }
            }
        }
    }

    /// Short English description of a photo from Vision's classifier ("a photo of macaw, bird, …").
    static func describe(_ image: CGImage) -> String {
        let labels = AIImageValidator.labels(image, limit: 6).filter { $0.1 > 0.15 }.map { $0.0.replacingOccurrences(of: "_", with: " ") }
        return labels.isEmpty ? "a photo, seamless continuation of the scene, same light and colours"
            : "a photo of " + labels.joined(separator: ", ") + ", seamless continuation of the scene, same light and colours"
    }

    // MARK: Object removal

    struct RemovalResult { var image: CGImage; var usedDiffusionFallback: Bool }

    static func removeObject(_ source: CGImage, mask: CGImage, token: AICancelToken, fallback: GenerationSettings?,
                             onStep: @escaping StepHandler) throws -> RemovalResult {
        guard let bounds = AIImage.maskBounds(mask) else { throw AIError.emptyMask }
        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        // Slightly larger mask: catches edges and soft shadows of the object.
        let grow = max(4, Double(max(bounds.width, bounds.height)) * 0.04)
        guard let maskFull = mask.width == source.width && mask.height == source.height ? mask : AIImage.resize(mask, width: source.width, height: source.height),
              let grown = AIImage.dilate(maskFull, pixels: grow) else { throw AIError.imageUnreadable }
        if ModelStoreSnapshot.current.lamaInstalled {
            let region = squareRegion(around: bounds.insetBy(dx: -grow, dy: -grow), in: full, minSide: 800)
            guard let crop = AIImage.crop(source, region), let maskCrop = AIImage.crop(grown, region) else { throw AIError.imageUnreadable }
            onStep(StepReport(step: 0, stepCount: 1, secondsPerStep: nil))
            let filled = try LaMaRemover.shared.inpaintSquareSync(crop, mask: maskCrop, token: token)
            onStep(StepReport(step: 1, stepCount: 1, secondsPerStep: nil))
            guard let blended = AIImage.composite(filled, over: crop, mask: maskCrop, feather: max(2, grow / 2)) else { throw AIError.imageUnreadable }
            return RemovalResult(image: paste(blended, into: source, at: region) ?? source, usedDiffusionFallback: false)
        }
        guard var s = fallback else { throw AIError.noModel(.objectRemoval) }
        s.prompt = "empty background, seamless continuation of the surroundings, nothing there"
        s.negativePrompt = "person, object, animal, text, logo, duplicate, artifacts"
        s.style = .none
        let out = try generativeFill(source, mask: grown, s, feather: max(2, grow / 2), seed: UInt32.random(in: 1...999_999),
                                     token: token, onStep: onStep)
        return RemovalResult(image: out, usedDiffusionFallback: true)
    }

    /// Square context region (LaMa works on squares), as large as possible up to the image's short side.
    static func squareRegion(around b: CGRect, in full: CGRect, minSide: Double) -> CGRect {
        var side = max(Double(max(b.width, b.height)) * 1.8, minSide)
        side = min(side, Double(min(full.width, full.height)))
        var r = CGRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
        if r.minX < 0 { r.origin.x = 0 }
        if r.minY < 0 { r.origin.y = 0 }
        if r.maxX > full.maxX { r.origin.x = full.maxX - side }
        if r.maxY > full.maxY { r.origin.y = full.maxY - side }
        return r.intersection(full).integral
    }

    // MARK: Background replacement

    /// Subject mask (grey, 255 = subject) from Apple's on-device Vision models.
    static func subjectMask(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if #available(macOS 14.0, *) {
            let req = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([req])
            if let obs = req.results?.first, !obs.allInstances.isEmpty {
                let buffer = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
                if let cg = maskImage(from: buffer, width: image.width, height: image.height) { return cg }
            }
        }
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([person])
        if let buffer = person.results?.first?.pixelBuffer, let cg = maskImage(from: buffer, width: image.width, height: image.height),
           AIImage.maskCoverage(cg) > 0.01 {
            return cg
        }
        throw AIError.unsupported(String(localized: "No subject was found. Paint the subject by hand with the brush."))
    }

    private static func maskImage(from buffer: CVPixelBuffer, width: Int, height: Int) -> CGImage? {
        var ci = CIImage(cvPixelBuffer: buffer)
        let sx = CGFloat(width) / ci.extent.width, sy = CGFloat(height) / ci.extent.height
        ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return CIContextProvider.cpu.createCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                   format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// Generates a new background around the (unchanged) subject and adds a soft contact shadow.
    static func replaceBackground(_ source: CGImage, subject: CGImage, _ s: GenerationSettings, shadow: Bool, seed: UInt32,
                                  token: AICancelToken, onStep: @escaping StepHandler) throws -> CGImage {
        guard let subjectFull = subject.width == source.width && subject.height == source.height ? subject : AIImage.resize(subject, width: source.width, height: source.height),
              let background = AIImage.invert(subjectFull),
              let grownBG = AIImage.dilate(background, pixels: 3) else { throw AIError.imageUnreadable }
        let side = s.model.resolution
        guard let fit = AIImage.fitSquare(source, side: side), let squareMask = fitMask(grownBG, side: side, rect: fit.rect) else {
            throw AIError.imageUnreadable
        }
        let square = fit.image, rect = fit.rect
        let generated = try DiffusionEngine.shared.generateSync(s.job(seed: seed, start: square, strength: 1, mask: squareMask),
                                                                token: token, onStep: onStep)
        guard let content = AIImage.crop(generated, rect) else { throw AIError.imageUnreadable }
        var newBackground = try enlarge(content, toWidth: source.width, height: source.height, token: token)
        if shadow, let shadowed = contactShadow(on: newBackground, subject: subjectFull) { newBackground = shadowed }
        // Subject from the original over the new background.
        guard let out = AIImage.composite(source, over: newBackground, mask: subjectFull, feather: 1.5) else { throw AIError.imageUnreadable }
        return out
    }

    /// Soft shadow under the subject: its silhouette, flattened at the base, blurred and multiplied.
    static func contactShadow(on background: CGImage, subject: CGImage) -> CGImage? {
        guard let b = AIImage.maskBounds(subject) else { return background }
        let H = CGFloat(background.height)
        let base = H - b.maxY                       // bottom of the subject in CI coordinates
        let silhouette = CIImage(cgImage: subject)
        let squash = CGAffineTransform(translationX: 0, y: base).scaledBy(x: 1, y: 0.12).translatedBy(x: 0, y: -base)
        let contact = silhouette.transformed(by: squash).applyingGaussianBlur(sigma: Double(b.width) * 0.03 + 2)
        let ambient = silhouette.transformed(by: CGAffineTransform(translationX: 0, y: -b.height * 0.02))
            .applyingGaussianBlur(sigma: Double(b.width) * 0.06 + 4)
        let rect = CGRect(x: 0, y: 0, width: background.width, height: background.height)
        let black = CIImage(color: .black).cropped(to: rect)
        func darken(_ img: CIImage, _ k: CGFloat) -> CIImage {
            // 1 − k·value, opaque (read from the red channel of the grey silhouette)
            img.composited(over: black).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: -k, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: -k, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1)]).cropped(to: rect)
        }
        let factor = darken(contact, 0.42).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: darken(ambient, 0.18)])
        let out = CIImage(cgImage: background).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: factor.cropped(to: rect)])
            .cropped(to: rect)
        return CIContextProvider.shared.createCGImage(out, from: rect, format: .RGBA8, colorSpace: AIImage.sRGB)
    }

    // MARK: Upscaling

    static func upscale(_ source: CGImage, factor: Int, token: AICancelToken, progress: @escaping (Double) -> Void) throws -> CGImage {
        let store = ModelStoreSnapshot.current
        switch factor {
        case 8:
            guard let x4 = store.upscaler(scale: 4), let x2 = store.upscaler(scale: 2) else { throw AIError.noModel(.upscaling) }
            let a = try Upscaler.shared.upscaleSync(source, with: x4, token: token) { progress($0 * 0.5) }
            return try Upscaler.shared.upscaleSync(a, with: x2, token: token) { progress(0.5 + $0 * 0.5) }
        case 4:
            guard let x4 = store.upscaler(scale: 4) else {
                guard let x2 = store.upscaler(scale: 2) else { throw AIError.noModel(.upscaling) }
                let a = try Upscaler.shared.upscaleSync(source, with: x2, token: token) { progress($0 * 0.5) }
                return try Upscaler.shared.upscaleSync(a, with: x2, token: token) { progress(0.5 + $0 * 0.5) }
            }
            return try Upscaler.shared.upscaleSync(source, with: x4, token: token, progress: progress)
        default:
            if let x2 = store.upscaler(scale: 2) { return try Upscaler.shared.upscaleSync(source, with: x2, token: token, progress: progress) }
            guard let x4 = store.upscaler(scale: 4) else { throw AIError.noModel(.upscaling) }
            let big = try Upscaler.shared.upscaleSync(source, with: x4, token: token, progress: progress)
            return AIImage.resize(big, width: source.width * 2, height: source.height * 2) ?? big
        }
    }

    // MARK: Photo optimisation

    enum EnhanceKind: String, CaseIterable, Identifiable {
        case restoreDetail, denoise, backgroundBlur, autoEnhance, faceRetouch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .restoreDetail: return String(localized: "Restore detail")
            case .denoise: return String(localized: "Remove noise & artefacts")
            case .backgroundBlur: return String(localized: "Background blur")
            case .autoEnhance: return String(localized: "Auto Enhance")
            case .faceRetouch: return String(localized: "Portrait retouch")
            }
        }
        var symbol: String {
            switch self {
            case .restoreDetail: return "sparkle.magnifyingglass"
            case .denoise: return "aqi.low"
            case .backgroundBlur: return "camera.aperture"
            case .autoEnhance: return "wand.and.stars"
            case .faceRetouch: return "face.smiling"
            }
        }
        var detail: String {
            switch self {
            case .restoreDetail: return String(localized: "Real-ESRGAN reconstructs fine detail at 2× and the result is scaled back to the original size.")
            case .denoise: return String(localized: "Real-ESRGAN General removes noise and JPEG artefacts.")
            case .backgroundBlur: return String(localized: "Apple's on-device subject detection separates the subject; the background gets a lens-like blur.")
            case .autoEnhance: return String(localized: "PhotoFlow's analysis engine (measurements and rules, not a generative model) corrects light and colour.")
            case .faceRetouch: return String(localized: "Not available: there is currently no face-restoration model whose licence allows use in PhotoFlow.")
            }
        }
    }

    static func enhance(_ source: CGImage, kind: EnhanceKind, amount: Double, token: AICancelToken,
                        progress: @escaping (Double) -> Void) throws -> CGImage {
        let store = ModelStoreSnapshot.current
        switch kind {
        case .restoreDetail:
            guard let x2 = store.upscaler(scale: 2) ?? store.upscaler(scale: 4) else { throw AIError.noModel(.upscaling) }
            let big = try Upscaler.shared.upscaleSync(source, with: x2, token: token, progress: progress)
            guard let back = AIImage.resize(big, width: source.width, height: source.height) else { throw AIError.imageUnreadable }
            return blend(back, over: source, amount: amount) ?? back
        case .denoise:
            guard let g = store.upscaler(denoise: true) else { throw AIError.noModel(.denoise) }
            // The general model upscales 4×; work on a half-size copy to keep memory and time reasonable.
            let half = AIImage.resize(source, width: max(1, source.width / 2), height: max(1, source.height / 2)) ?? source
            let big = try Upscaler.shared.upscaleSync(half, with: g, token: token, progress: progress)
            guard let back = AIImage.resize(big, width: source.width, height: source.height) else { throw AIError.imageUnreadable }
            return blend(back, over: source, amount: amount) ?? back
        case .backgroundBlur:
            progress(0.2)
            let subject = try subjectMask(source)
            progress(0.6)
            let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let bgMask = AIImage.feather(AIImage.invert(subject) ?? subject, radius: 6)
            let radius = (Double(max(source.width, source.height)) / 120) * (0.4 + amount)
            let out = CIImage(cgImage: source).clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": bgMask, kCIInputRadiusKey: radius]).cropped(to: rect)
            progress(1)
            guard let cg = CIContextProvider.shared.createCGImage(out, from: rect, format: .RGBA8, colorSpace: AIImage.sRGB) else { throw AIError.imageUnreadable }
            return cg
        case .autoEnhance:
            progress(0.3)
            guard let analysis = PhotoAnalyzer.analyze(image: source) else { throw AIError.imageUnreadable }
            let strength: EnhanceStrength = amount < 0.4 ? .subtle : (amount > 0.75 ? .strong : .balanced)
            let recipe = AutoEnhanceEngine.enhance(analysis, strength: strength, options: .enhanceOnly).recipe
            let out = RenderPipeline.apply(recipe, to: CIImage(cgImage: source))
            let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            progress(1)
            guard let cg = CIContextProvider.shared.createCGImage(out.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: AIImage.sRGB) else { throw AIError.imageUnreadable }
            return cg
        case .faceRetouch:
            throw AIError.unsupported(kind.detail)
        }
    }

    private static func blend(_ a: CGImage, over b: CGImage, amount: Double) -> CGImage? {
        if amount >= 0.99 { return a }
        let rect = CGRect(x: 0, y: 0, width: b.width, height: b.height)
        let top = CIImage(cgImage: a).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))])
        let out = top.composited(over: CIImage(cgImage: b)).cropped(to: rect)
        return CIContextProvider.shared.createCGImage(out, from: rect, format: .RGBA8, colorSpace: AIImage.sRGB)
    }
}

/// Thread-safe snapshot of which models are installed (the ModelStore itself lives on the main actor).
struct ModelStoreSnapshot {
    var installedIDs: Set<String>
    var defaultUpscalerID: String

    static var current: ModelStoreSnapshot {
        let ids = Set(AIModelCatalog.all.map(\.id).filter {
            FileManager.default.fileExists(atPath: ModelStore.directory(for: $0).appendingPathComponent("install.json").path)
        })
        return ModelStoreSnapshot(installedIDs: ids, defaultUpscalerID: UserDefaults.standard.string(forKey: "aiDefaultUpscaler") ?? "realesrgan-x4plus")
    }

    var lamaInstalled: Bool { installedIDs.contains("lama") }

    func upscaler(scale: Int? = nil, denoise: Bool = false) -> AIModelDescriptor? {
        let list = AIModelCatalog.upscalers.filter { installedIDs.contains($0.id) }
        if denoise { return list.first { $0.capabilities.contains(.denoise) } }
        guard let scale else { return list.first { $0.id == defaultUpscalerID } ?? list.first }
        if let d = list.first(where: { $0.id == defaultUpscalerID && $0.scale == scale }) { return d }
        return list.first { $0.scale == scale && !$0.capabilities.contains(.denoise) } ?? list.first { $0.scale == scale }
    }
}
