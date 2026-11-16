import Foundation
import AVFoundation
import CoreImage
import Vision
import Accelerate

/// Streaming frame processor: decodes a video with AVAssetReader, transforms every frame with Core Image and
/// encodes it with AVAssetWriter; the sound track is copied unchanged. Originals are never modified.
enum VideoFrameProcessor {
    struct Source {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let size: CGSize          // display size (after rotation)
        let orientation: CGImagePropertyOrientation
        let fps: Double
        let duration: Double
        var frameCount: Int { max(1, Int((duration * fps).rounded())) }
    }

    static func open(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoIO.IOError.readFailed(String(localized: "no video track"))
        }
        let (natural, t, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let o: CGImagePropertyOrientation
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { o = .right }
        else if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { o = .left }
        else if t.a == -1 && t.d == -1 { o = .down }
        else { o = .up }
        let size = (o == .left || o == .right) ? CGSize(width: natural.height, height: natural.width) : natural
        let duration = try await asset.load(.duration).seconds
        return Source(asset: asset, track: track, size: size, orientation: o, fps: Double(rate > 0 ? rate : 30), duration: duration)
    }

    /// Decodes every frame (display orientation) and calls `body(image, index, time)`; return nil to stop.
    static func forEachFrame(_ src: Source, maxSize: CGFloat? = nil, _ body: (CIImage, Int, CMTime) throws -> Bool) throws {
        let reader = try AVAssetReader(asset: src.asset)
        let out = AVAssetReaderTrackOutput(track: src.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw VideoIO.IOError.readFailed(reader.error?.localizedDescription ?? "") }
        var i = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            var img = CIImage(cvPixelBuffer: pb).oriented(src.orientation)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            if let m = maxSize, max(img.extent.width, img.extent.height) > m {
                let s = m / max(img.extent.width, img.extent.height)
                img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            if try !body(img, i, CMSampleBufferGetPresentationTimeStamp(sb)) { reader.cancelReading(); return }
            i += 1
        }
        if reader.status == .failed { throw VideoIO.IOError.readFailed(reader.error?.localizedDescription ?? "") }
    }

    /// Full pass: transform every frame, write a new movie with the original sound.
    static func process(_ url: URL, to dest: URL, codec: VideoIO.Codec = .h264, metadata: VideoIO.AIMetadata?,
                        isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void,
                        transform: @escaping (CIImage, Int, CMTime) -> CIImage) async throws {
        let src = try await open(url)
        let w = Int(src.size.width) / 2 * 2, h = Int(src.size.height) / 2 * 2
        try? FileManager.default.removeItem(at: dest)
        let writer = try AVAssetWriter(outputURL: dest, fileType: codec.fileType)
        var settings: [String: Any] = [AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: w, AVVideoHeightKey: h]
        if codec != .proRes422 {
            let rate = (try? await src.track.load(.estimatedDataRate)).map { Int($0) } ?? 0
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(rate, Int(Double(w * h) * src.fps * 0.1))]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        if let metadata { writer.metadata = VideoIO.metadataItems(metadata) }

        // Sound: copied without re-encoding when possible
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let audioReader = try AVAssetReader(asset: src.asset)
        for t in try await src.asset.loadTracks(withMediaType: .audio) {
            let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
            let fmt = try await t.load(.formatDescriptions).first
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
            ai.expectsMediaDataInRealTime = false
            if audioReader.canAdd(o), writer.canAdd(ai) { audioReader.add(o); writer.add(ai); audioPairs.append((o, ai)) }
        }
        guard writer.startWriting() else { throw VideoIO.IOError.writerFailed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
        if !audioPairs.isEmpty { audioReader.startReading() }
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        let total = Double(src.frameCount)
        var failure: Error?
        try forEachFrame(src) { img, i, t in
            if isCancelled() { failure = VideoEngineClient.EngineError.cancelled; return false }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { failure = VideoIO.IOError.writerFailed("pool"); return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { failure = VideoIO.IOError.writerFailed("buffer"); return false }
            let outImg = transform(img, i, t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.render(outImg, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: cs)
            if !adaptor.append(pb, withPresentationTime: t) { failure = VideoIO.IOError.writerFailed(writer.error?.localizedDescription ?? "append"); return false }
            progress(min(1, Double(i + 1) / total))
            return true
        }
        input.markAsFinished()
        for (o, ai) in audioPairs {
            while let s = o.copyNextSampleBuffer() {
                while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                ai.append(s)
            }
            ai.markAsFinished()
        }
        if let failure { writer.cancelWriting(); try? FileManager.default.removeItem(at: dest); throw failure }
        await writer.finishWriting()
        if writer.status != .completed { throw VideoIO.IOError.writerFailed(writer.error?.localizedDescription ?? "") }
    }
}

// MARK: - Background replacement (Apple Vision person / subject segmentation)

enum VideoBackgroundReplacer {
    enum Background {
        case image(CIImage)
        case video(URL)
        case blur(Double)
        case color(CIColor)
    }
    enum Subject: String, CaseIterable, Identifiable {
        case people, anySubject
        var id: String { rawValue }
        var title: String {
            switch self {
            case .people: return String(localized: "People")
            case .anySubject: return String(localized: "Any subject")
            }
        }
    }

    /// Segmentation mask (white = subject) at the frame's size. People: VNGeneratePersonSegmentationRequest;
    /// any subject (macOS 14+): VNGenerateForegroundInstanceMaskRequest.
    static func mask(for img: CIImage, subject: Subject, ctx: CIContext) throws -> CIImage? {
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg)
        var pb: CVPixelBuffer?
        if subject == .anySubject, #available(macOS 14.0, *) {
            let r = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([r])
            if let obs = r.results?.first {
                pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            }
        } else {
            let r = VNGeneratePersonSegmentationRequest()
            r.qualityLevel = .accurate
            r.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([r])
            pb = r.results?.first?.pixelBuffer
        }
        guard let pb else { return nil }
        var m = CIImage(cvPixelBuffer: pb)
        m = m.transformed(by: CGAffineTransform(scaleX: img.extent.width / m.extent.width, y: img.extent.height / m.extent.height))
        return m
    }

    static func run(_ url: URL, background: Background, subject: Subject, to dest: URL,
                    isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) async throws {
        let src = try await VideoFrameProcessor.open(url)
        let size = src.size
        let ctx = CIContext(options: [.cacheIntermediates: false])
        var previousMask: CIImage?
        // Background video: decode frames on demand with an image generator (loops if shorter)
        var bgGen: AVAssetImageGenerator?
        var bgDuration = 0.0
        if case .video(let u) = background {
            let a = AVURLAsset(url: u)
            let g = AVAssetImageGenerator(asset: a)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            bgGen = g
            bgDuration = try await a.load(.duration).seconds
        }
        let meta = VideoIO.AIMetadata(generated: false, model: "Apple Vision", prompt: "", operation: "backgroundReplace", seed: nil)
        try await VideoFrameProcessor.process(url, to: dest, metadata: meta, isCancelled: isCancelled, progress: progress) { img, _, t in
            // 1. mask, smoothed over time (exponential average) against flicker at the edges
            var m = (try? mask(for: img, subject: subject, ctx: ctx)) ?? previousMask ?? CIImage(color: .white).cropped(to: img.extent)
            if let p = previousMask {
                m = m.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": p, "inputTime": 0.35])
            }
            previousMask = m
            m = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1.0, Double(size.height) / 720.0)]).cropped(to: img.extent)
            // 2. new background, filled to the frame
            var bg: CIImage
            switch background {
            case .image(let b): bg = VideoIO.fill(b, to: size)
            case .color(let c): bg = CIImage(color: c).cropped(to: img.extent)
            case .blur(let r): bg = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r * Double(size.height) / 1080.0]).cropped(to: img.extent)
            case .video:
                let secs = bgDuration > 0 ? t.seconds.truncatingRemainder(dividingBy: bgDuration) : 0
                if let g = bgGen, let cg = try? g.copyCGImage(at: CMTime(seconds: secs, preferredTimescale: 600), actualTime: nil) {
                    bg = VideoIO.fill(CIImage(cgImage: cg), to: size)
                } else { bg = CIImage(color: .black).cropped(to: img.extent) }
            }
            // 3. light wrap: a little of the new background's light spills over the subject's edge
            let edge = m.applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: 2]).cropped(to: img.extent)
            let wrapped = bg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]).cropped(to: img.extent)
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: edge.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.25, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.25, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.25, w: 0)])])
            return wrapped.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m])
        }
    }
}

// MARK: - Automatic optimisation (per scene, temporally smooth) + stabilisation

enum VideoOptimizer {
    struct Options {
        var color = true
        var stabilize = false
        var strength: EnhanceStrength = .balanced
    }

    struct Plan {
        var keyTimes: [Double] = []
        var recipes: [EditRecipe] = []
        var cuts: [Double] = []
        var notes: [String] = []
        var shifts: [CGPoint] = []      // per frame stabilisation correction (pixels at full size)
        var zoom: CGFloat = 1
    }

    /// Analysis: scene cuts, a keyframe every 2 s analysed by PhotoFlow's enhancement engine, camera shake.
    static func analyze(_ url: URL, options: Options, isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) async throws -> Plan {
        let src = try await VideoFrameProcessor.open(url)
        var plan = Plan()
        let ctx = CIContext()
        var prevHist: [Float]?
        var prevCG: CGImage?
        var path: [CGPoint] = [.zero]
        var lastKey = -10.0
        let scale = 512 / max(src.size.width, src.size.height)
        try VideoFrameProcessor.forEachFrame(src, maxSize: 512) { img, i, t in
            if isCancelled() { return false }
            let secs = t.seconds
            guard let cg = ctx.createCGImage(img, from: img.extent) else { return true }
            // scene cut: luma histogram distance between consecutive frames
            let hist = lumaHistogram(cg)
            var cut = false
            if let p = prevHist {
                let d = zip(hist, p).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / 2
                if d > 0.45 { cut = true; plan.cuts.append(secs) }
            }
            prevHist = hist
            if options.color && (cut || secs - lastKey >= 2.0 || i == 0) {
                if let a = PhotoAnalyzer.analyze(image: cg) {
                    var opts = AutoEnhanceOptions.enhanceOnly
                    opts.detail = false
                    let o = AutoEnhanceEngine.enhance(a, strength: options.strength, options: opts)
                    plan.keyTimes.append(secs)
                    plan.recipes.append(o.recipe.adjustmentsOnly)
                    if plan.notes.isEmpty { plan.notes = o.notes }
                }
                lastKey = secs
            }
            if options.stabilize {
                if let p = prevCG, !cut {
                    let req = VNTranslationalImageRegistrationRequest(targetedCGImage: cg)
                    let h = VNImageRequestHandler(cgImage: p)
                    try? h.perform([req])
                    let tr = req.results?.first?.alignmentTransform ?? .identity
                    let last = path.last ?? .zero
                    path.append(CGPoint(x: last.x + tr.tx / scale, y: last.y + tr.ty / scale))
                } else if prevCG != nil {
                    path.append(path.last ?? .zero)
                }
                prevCG = cg
            }
            progress(min(1, Double(i + 1) / Double(src.frameCount)))
            return true
        }
        if options.stabilize && path.count > 2 {
            let smooth = gaussianSmooth(path, sigma: max(8, src.fps * 0.5))
            // path[i] aligns frame i to the first frame (Vision: alignmentTransform maps the target onto the
            // reference). Applying path − smooth removes the shake but keeps the intended, smoothed camera motion.
            plan.shifts = zip(path, smooth).map { CGPoint(x: $0.x - $1.x, y: $0.y - $1.y) }
            let maxX = plan.shifts.map { abs($0.x) }.max() ?? 0, maxY = plan.shifts.map { abs($0.y) }.max() ?? 0
            plan.zoom = min(1.15, 1 + 2 * max(maxX / src.size.width, maxY / src.size.height))
        }
        return plan
    }

    /// Recipe at a time: linear interpolation between keyframes of the same scene; hard switch at a cut.
    static func recipe(at t: Double, _ plan: Plan) -> EditRecipe {
        guard !plan.recipes.isEmpty else { return .identity }
        guard let next = plan.keyTimes.firstIndex(where: { $0 > t }) else { return plan.recipes.last! }
        if next == 0 { return plan.recipes[0] }
        let a = next - 1
        let t0 = plan.keyTimes[a], t1 = plan.keyTimes[next]
        if plan.cuts.contains(where: { $0 > t0 && $0 <= t1 }) {
            return plan.cuts.first(where: { $0 > t0 && $0 <= t1 }).map { t >= $0 ? plan.recipes[next] : plan.recipes[a] } ?? plan.recipes[a]
        }
        let f = (t - t0) / max(0.001, t1 - t0)
        return mix(plan.recipes[a], plan.recipes[next], f)
    }

    static func mix(_ a: EditRecipe, _ b: EditRecipe, _ f: Double) -> EditRecipe {
        var r = a
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        r.exposure = m(a.exposure, b.exposure); r.brightness = m(a.brightness, b.brightness); r.contrast = m(a.contrast, b.contrast)
        r.highlights = m(a.highlights, b.highlights); r.shadows = m(a.shadows, b.shadows); r.whites = m(a.whites, b.whites)
        r.blacks = m(a.blacks, b.blacks); r.temperature = m(a.temperature, b.temperature); r.tint = m(a.tint, b.tint)
        r.saturation = m(a.saturation, b.saturation); r.vibrance = m(a.vibrance, b.vibrance)
        return r
    }

    static func run(_ url: URL, plan: Plan, to dest: URL, isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) async throws {
        let src = try await VideoFrameProcessor.open(url)
        let meta = VideoIO.AIMetadata(generated: false, model: "PhotoFlow Auto Enhance", prompt: "", operation: "optimize", seed: nil)
        try await VideoFrameProcessor.process(url, to: dest, metadata: meta, isCancelled: isCancelled, progress: progress) { img, i, t in
            var out = plan.recipes.isEmpty ? img : RenderPipeline.apply(recipe(at: t.seconds, plan), to: img).cropped(to: img.extent)
            if !plan.shifts.isEmpty {
                let s = plan.shifts[min(i, plan.shifts.count - 1)]
                let c = CGPoint(x: src.size.width / 2, y: src.size.height / 2)
                let tf = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: plan.zoom, y: plan.zoom)
                    .translatedBy(x: -c.x + s.x, y: -c.y + s.y)
                out = out.clampedToExtent().transformed(by: tf).cropped(to: img.extent)
            }
            return out
        }
    }

    private static func lumaHistogram(_ cg: CGImage) -> [Float] {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hist = [Float](repeating: 0, count: 32)
        for v in px { hist[Int(v) / 8] += 1 }
        return hist.map { $0 / Float(w * h) }
    }

    private static func gaussianSmooth(_ p: [CGPoint], sigma: Double) -> [CGPoint] {
        let r = Int(sigma * 3)
        let k = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        return p.indices.map { i in
            var sx = 0.0, sy = 0.0, sw = 0.0
            for (j, w) in k.enumerated() {
                let idx = min(max(i + j - r, 0), p.count - 1)
                sx += Double(p[idx].x) * w; sy += Double(p[idx].y) * w; sw += w
            }
            return CGPoint(x: sx / sw, y: sy / sw)
        }
    }
}
