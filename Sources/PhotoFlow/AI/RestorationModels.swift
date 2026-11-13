import Foundation
import CoreML
import CoreImage
import CoreGraphics

/// Loads compiled single-file Core ML models (Real-ESRGAN, LaMa) installed by the ModelStore.
private func loadCompiledModel(_ desc: AIModelDescriptor, preferNeuralEngine: Bool) throws -> MLModel {
    let url = ModelStore.compiledModelURL(for: desc.id)
    guard FileManager.default.fileExists(atPath: url.path) else { throw AIError.modelMissing(desc.name) }
    let cfg = MLModelConfiguration()
    let hw = AIHardware.current
    if !hw.base.hasMetal || UserDefaults.standard.bool(forKey: "forceCPURendering") {
        cfg.computeUnits = .cpuOnly
    } else if hw.hasNeuralEngine && preferNeuralEngine {
        cfg.computeUnits = .all
    } else {
        cfg.computeUnits = .cpuAndGPU
    }
    return try MLModel(contentsOf: url, configuration: cfg)
}

private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
    let ci = CIImage(cvPixelBuffer: buffer)
    return CIContextProvider.cpu.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: AIImage.sRGB)
}

// MARK: - Real-ESRGAN

/// Tiled Real-ESRGAN super-resolution (256 px tiles with overlap, so any image size works).
final class Upscaler: @unchecked Sendable {
    static let shared = Upscaler()
    private let lock = NSLock()
    private var model: MLModel?
    private var loadedID: String?

    func unload() { lock.lock(); model = nil; loadedID = nil; lock.unlock() }

    /// Largest output the app will produce (memory safety).
    static let maxOutputPixels = 240_000_000
    static let maxOutputSide = 20_000

    static func estimatedOutput(width: Int, height: Int, factor: Int) -> (Int, Int, Int64) {
        let w = width * factor, h = height * factor
        // PNG of a photo: roughly 1.6 bytes per pixel; JPEG ~0.35.
        return (w, h, Int64(Double(w * h) * 1.6))
    }

    private func model(for desc: AIModelDescriptor) throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let model, loadedID == desc.id { return model }
        let m = try loadCompiledModel(desc, preferNeuralEngine: true)
        model = m
        loadedID = desc.id
        return m
    }

    /// Upscales by the model's factor. Runs synchronously – call on the AI queue.
    func upscaleSync(_ image: CGImage, with desc: AIModelDescriptor, token: AICancelToken,
                     progress: @escaping (Double) -> Void) throws -> CGImage {
        let s = desc.scale
        guard image.width * s <= Self.maxOutputSide, image.height * s <= Self.maxOutputSide,
              image.width * image.height * s * s <= Self.maxOutputPixels else {
            throw AIError.unsupported(String(localized: "The result would be too large (\(image.width * s) × \(image.height * s) px). Choose a smaller factor or crop the image first."))
        }
        let m = try model(for: desc)
        guard let inputDesc = m.modelDescription.inputDescriptionsByName["input"], let constraint = inputDesc.imageConstraint else {
            throw AIError.modelMissing(desc.name)
        }
        let tile = constraint.pixelsWide
        let overlap = 16
        let stride = tile - 2 * overlap
        let W = image.width, H = image.height
        let PW = max(W, tile), PH = max(H, tile)

        // Pad small images by extending their edges.
        let src: CGImage
        if PW != W || PH != H {
            let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(PH - H)))
                .clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: PW, height: PH))
            guard let padded = CIContextProvider.cpu.createCGImage(ci, from: CGRect(x: 0, y: 0, width: PW, height: PH),
                                                                   format: .RGBA8, colorSpace: AIImage.sRGB) else { throw AIError.imageUnreadable }
            src = padded
        } else {
            src = AIImage.normalized(image) ?? image
        }

        let OW = PW * s, OH = PH * s
        guard let out = CGContext(data: nil, width: OW, height: OH, bitsPerComponent: 8, bytesPerRow: 0, space: AIImage.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AIError.outOfMemory }
        out.interpolationQuality = .none

        func origins(_ length: Int) -> [Int] {
            if length <= tile { return [0] }
            var o: [Int] = []
            var x = 0
            while true {
                if x + tile >= length { o.append(length - tile); break }
                o.append(x)
                x += stride
            }
            return o
        }
        let xs = origins(PW), ys = origins(PH)
        let total = xs.count * ys.count
        var done = 0
        for (yi, y0) in ys.enumerated() {
            for (xi, x0) in xs.enumerated() {
                if token.isCancelled { throw AIError.cancelled }
                try autoreleasepool {
                    guard let tileImage = src.cropping(to: CGRect(x: x0, y: y0, width: tile, height: tile)) else { return }
                    let value = try MLFeatureValue(cgImage: tileImage, constraint: constraint, options: nil)
                    let result = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": value]))
                    guard let buffer = result.featureValue(for: "output")?.imageBufferValue, let tileOut = cgImage(from: buffer) else {
                        throw AIError.failed(String(localized: "The upscaling model returned no image."))
                    }
                    // Keep the tile centre; edges come from the neighbouring tile (avoids seams).
                    let left = xi == 0 ? 0 : overlap
                    let top = yi == 0 ? 0 : overlap
                    let right = xi == xs.count - 1 ? 0 : overlap
                    let bottom = yi == ys.count - 1 ? 0 : overlap
                    let valid = CGRect(x: left * s, y: top * s, width: (tile - left - right) * s, height: (tile - top - bottom) * s)
                    guard let part = tileOut.cropping(to: valid) else { return }
                    let dx = (x0 + left) * s, dy = (y0 + top) * s
                    out.draw(part, in: CGRect(x: dx, y: OH - dy - Int(valid.height), width: Int(valid.width), height: Int(valid.height)))
                }
                done += 1
                progress(Double(done) / Double(total))
            }
        }
        guard let full = out.makeImage() else { throw AIError.outOfMemory }
        if PW == W && PH == H { return full }
        return full.cropping(to: CGRect(x: 0, y: 0, width: W * s, height: H * s)) ?? full
    }
}

// MARK: - LaMa

/// Object removal with Big-LaMa (fixed 800 × 800 input). The area around the mask is cropped, filled by
/// the model and blended back, so the rest of the photo keeps its full resolution.
final class LaMaRemover: @unchecked Sendable {
    static let shared = LaMaRemover()
    private let lock = NSLock()
    private var model: MLModel?

    func unload() { lock.lock(); model = nil; lock.unlock() }

    private func loaded() throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        guard let desc = AIModelCatalog.model("lama") else { throw AIError.noModel(.objectRemoval) }
        let m = try loadCompiledModel(desc, preferNeuralEngine: false)
        model = m
        return m
    }

    /// Fills the square `image` (any size) where `mask` is white. Returns an image of the same size.
    func inpaintSquareSync(_ image: CGImage, mask: CGImage, token: AICancelToken) throws -> CGImage {
        let m = try loaded()
        guard let ic = m.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let mc = m.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint else {
            throw AIError.modelMissing("LaMa")
        }
        let side = ic.pixelsWide
        guard let img = AIImage.resize(image, width: side, height: side) else { throw AIError.imageUnreadable }
        // Binary mask (the model treats any non-zero value as "fill").
        let values = AIImage.maskValues(mask, width: side, height: side)
        guard let bin = AIImage.grayImage(values.map { $0 > 0.35 ? 255 : 0 }, width: side, height: side) else { throw AIError.imageUnreadable }
        if token.isCancelled { throw AIError.cancelled }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": try MLFeatureValue(cgImage: img, constraint: ic, options: nil),
            "mask": try MLFeatureValue(cgImage: bin, constraint: mc, options: nil)
        ])
        let out = try m.prediction(from: input)
        guard let buffer = out.featureValue(for: "output")?.imageBufferValue, let filled = cgImage(from: buffer) else {
            throw AIError.failed(String(localized: "The removal model returned no image."))
        }
        return AIImage.resize(filled, width: image.width, height: image.height) ?? filled
    }
}
