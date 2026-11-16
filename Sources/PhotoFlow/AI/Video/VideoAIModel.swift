import SwiftUI
import AppKit
import AVFoundation

/// Formats offered for video. Sizes are derived from the model's native pixel area and rounded to the
/// model's patch grid (Wan 2.1: 16 px, Wan 2.2 5B: 32 px).
enum VideoAspect: String, CaseIterable, Identifiable, Codable {
    case landscape16x9, portrait9x16, square, classic4x3, photo3x2
    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape16x9: return "16:9"
        case .portrait9x16: return "9:16"
        case .square: return "1:1"
        case .classic4x3: return "4:3"
        case .photo3x2: return "3:2"
        }
    }
    var ratio: Double {
        switch self {
        case .landscape16x9: return 16.0 / 9
        case .portrait9x16: return 9.0 / 16
        case .square: return 1
        case .classic4x3: return 4.0 / 3
        case .photo3x2: return 3.0 / 2
        }
    }
    var symbol: String {
        switch self {
        case .landscape16x9: return "rectangle"
        case .portrait9x16: return "rectangle.portrait"
        case .square: return "square"
        case .classic4x3, .photo3x2: return "rectangle.ratio.4.to.3"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case draft, standard, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .draft: return String(localized: "Draft")
        case .standard: return String(localized: "Standard")
        case .high: return String(localized: "High")
        }
    }
    /// Sampling steps (UniPC).
    var steps: Int { switch self { case .draft: return 20; case .standard: return 30; case .high: return 50 } }
    /// Fraction of the model's native pixel area.
    var areaScale: Double { switch self { case .draft: return 0.56; case .standard, .high: return 1.0 } }
}

/// Camera/subject motion presets for image to video. Wan has no numeric motion control; these are appended to
/// the prompt as instructions (the UI says so).
enum VideoMotion: String, CaseIterable, Identifiable {
    case natural, slowPushIn, slowPullOut, panLeft, panRight, orbit, still
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return String(localized: "Natural motion")
        case .slowPushIn: return String(localized: "Slow zoom in")
        case .slowPullOut: return String(localized: "Slow zoom out")
        case .panLeft: return String(localized: "Pan left")
        case .panRight: return String(localized: "Pan right")
        case .orbit: return String(localized: "Orbit around the subject")
        case .still: return String(localized: "Static camera")
        }
    }
    var instruction: String {
        switch self {
        case .natural: return "natural subtle motion"
        case .slowPushIn: return "the camera slowly pushes in"
        case .slowPullOut: return "the camera slowly pulls back"
        case .panLeft: return "the camera pans slowly to the left"
        case .panRight: return "the camera pans slowly to the right"
        case .orbit: return "the camera slowly orbits around the subject"
        case .still: return "static camera, only the subject moves"
        }
    }
}

/// Central queue for heavy AI jobs: only one runs at a time, so models never compete for GPU and unified memory.
@MainActor
final class AIJobManager: ObservableObject {
    static let shared = AIJobManager()
    struct Job: Identifiable { let id = UUID(); let title: String; let run: () async -> Void }
    @Published private(set) var current: String?
    @Published private(set) var pending: [String] = []
    private var queue: [Job] = []

    func enqueue(_ title: String, _ run: @escaping () async -> Void) {
        queue.append(Job(title: title, run: run))
        pending = queue.map(\.title)
        pump()
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        pending = queue.map(\.title)
        current = job.title
        Task {
            // Free the photo models first: video models need the memory.
            _ = try? await DiffusionEngine.shared.perform { DiffusionEngine.shared.unloadSync() }
            await job.run()
            current = nil
            pump()
        }
    }
}

@MainActor
final class VideoAIModel: ObservableObject {
    static let shared = VideoAIModel()

    enum Section: String, CaseIterable, Identifiable {
        case generate, animate, transform, remove, background, optimize, upscale, projects, models
        var id: String { rawValue }
        var title: String {
            switch self {
            case .generate: return String(localized: "Generate Video")
            case .animate: return String(localized: "Animate Photo")
            case .transform: return String(localized: "Transform Video")
            case .remove: return String(localized: "Remove Objects")
            case .background: return String(localized: "Replace Background")
            case .optimize: return String(localized: "Optimise Video")
            case .upscale: return String(localized: "Video Upscaling")
            case .projects: return String(localized: "AI Video Projects")
            case .models: return String(localized: "Model Management")
            }
        }
        var symbol: String {
            switch self {
            case .generate: return "film"
            case .animate: return "photo.on.rectangle.angled"
            case .transform: return "wand.and.rays"
            case .remove: return "eraser"
            case .background: return "person.and.background.dotted"
            case .optimize: return "dial.medium"
            case .upscale: return "arrow.up.forward.square"
            case .projects: return "square.grid.2x2"
            case .models: return "cpu"
            }
        }
        var capability: AICapability? {
            switch self {
            case .generate: return .textToVideo
            case .animate: return .imageToVideo
            case .transform: return .videoToVideo
            case .remove: return .videoInpainting
            default: return nil
            }
        }
    }

    struct Progress: Equatable {
        var title: String
        var stage: String
        var step = 0
        var total = 0
        var secondsPerStep: Double?
        var variant = 1
        var variantCount = 1
        var fraction: Double? { total > 0 ? (Double(variant - 1) + Double(step) / Double(total)) / Double(variantCount) : nil }
        var remaining: Double? {
            guard let sps = secondsPerStep, total > 0 else { return nil }
            return Double(total - step) * sps + Double(variantCount - variant) * Double(total) * sps
        }
    }

    @Published var section: Section = .generate
    @Published var prompt = ""
    @Published var negativePrompt = "blurry, low quality, distorted, flickering, static, worst quality, watermark, text, deformed"
    @Published var aspect: VideoAspect = .landscape16x9
    @Published var quality: VideoQuality = .standard
    @Published var seconds: Double = 3
    @Published var variants = 1
    @Published var seedText = ""
    @Published var guidance: Double = 5.0
    @Published var motion: VideoMotion = .natural
    @Published var strength: Double = 0.6
    @Published var modelID: String?

    @Published var sourceImage: CGImage?
    @Published var sourceImageName = ""
    @Published var sourceVideo: URL?
    @Published var sourceVideoInfo: VideoIO.SourceInfo?

    @Published private(set) var progress: Progress?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var lastResult: VideoCreation?
    @Published var labelOnExport = true

    private var cancelled = false

    var isBusy: Bool { progress != nil }

    // MARK: Models

    func models(for cap: AICapability) -> [AIModelDescriptor] {
        AIModelCatalog.videoModels.filter { $0.capabilities.contains(cap) }
    }

    func installedModels(for cap: AICapability) -> [AIModelDescriptor] {
        let store = ModelStore.shared
        return models(for: cap).filter { store.isInstalled($0.id) && AIHardware.current.incompatibility(of: $0) == nil }
    }

    func activeModel(for cap: AICapability) -> AIModelDescriptor? {
        let list = installedModels(for: cap)
        return list.first { $0.id == modelID } ?? list.first
    }

    /// True when everything needed for a capability is installed: runtime, text encoder, a model.
    func ready(for cap: AICapability) -> Bool {
        let s = ModelStore.shared
        return s.isInstalled(VideoRuntime.id) && s.isInstalled("wan-umt5") && activeModel(for: cap) != nil
    }

    // MARK: Geometry

    /// Width × height for a model and format: native pixel area × quality factor, snapped to the patch grid.
    func size(for model: AIModelDescriptor, aspect: VideoAspect) -> (Int, Int) {
        let native: Double = model.videoKind == "wan-ti2v" ? 1280 * 704 : 832 * 480
        let area = native * quality.areaScale
        let grid = model.videoKind == "wan-ti2v" ? 32 : 16
        var w = (area * aspect.ratio).squareRoot()
        var h = w / aspect.ratio
        w = (w / Double(grid)).rounded() * Double(grid)
        h = (h / Double(grid)).rounded() * Double(grid)
        return (Int(max(Double(grid * 8), w)), Int(max(Double(grid * 8), h)))
    }

    /// Clip lengths the model generates in one pass (frames = 4·k + 1).
    func durations(for model: AIModelDescriptor) -> [Double] {
        let maxSeconds = Double(model.videoMaxFrames - 1) / Double(max(model.videoFPS, 1))
        return [2, 3, 5].filter { $0 <= maxSeconds + 0.01 }
    }

    func frames(for model: AIModelDescriptor, seconds: Double) -> Int {
        let raw = Int((seconds * Double(model.videoFPS)).rounded())
        let k = max(1, (raw - 1) / 4)
        return min(model.videoMaxFrames, 4 * k + 1)
    }

    /// Rough memory estimate (GB) for a job – replaced by the value measured on this Mac once one ran.
    func memoryEstimate(model: AIModelDescriptor, width: Int, height: Int, frames: Int) -> Double {
        if let measured = measuredPeak(model.id, width: width, height: height, frames: frames) { return measured }
        let weights: Double = switch model.videoKind { case "wan-ti2v": 10.0; case "wan-vace": 3.6; default: 2.8 }
        let vae: Double = model.videoKind == "wan-ti2v" ? 2.8 : 0.5
        let stride = model.videoKind == "wan-ti2v" ? 32.0 : 16.0
        let tokens = Double(width * height) / (stride * stride) * Double((frames - 1) / 4 + 1)
        let activations = tokens * 0.00012     // GB per token, incl. chunked attention and VAE decode (estimate)
        let generation = weights + vae + activations + 1.5
        return max(generation, 12.5)          // the text encoder phase needs ~11.5 GB
    }

    private func measuredPeak(_ id: String, width: Int, height: Int, frames: Int) -> Double? {
        let key = "videoPeak.\(id).\(width)x\(height)x\(frames)"
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : nil
    }

    private func storePeak(_ gb: Double, _ id: String, width: Int, height: Int, frames: Int) {
        UserDefaults.standard.set(gb, forKey: "videoPeak.\(id).\(width)x\(height)x\(frames)")
    }

    // MARK: Sources

    func pickImage(_ cg: CGImage, name: String) { sourceImage = cg; sourceImageName = name }

    func pickVideo(_ url: URL) {
        sourceVideo = url
        sourceVideoInfo = nil
        Task {
            do { sourceVideoInfo = try await VideoIO.info(url) } catch { errorMessage = error.localizedDescription; sourceVideo = nil }
        }
    }

    // MARK: Jobs

    func cancel() {
        cancelled = true
        VideoEngineClient.shared.cancelCurrent()
    }

    func start() {
        guard !isBusy, let cap = section.capability else { return }
        guard let model = activeModel(for: cap) else {
            errorMessage = String(localized: "No suitable video model is installed. Download one in Model Management.")
            return
        }
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if cap == .textToVideo && promptText.isEmpty { errorMessage = String(localized: "Describe the video you want."); return }
        if cap == .imageToVideo && sourceImage == nil { errorMessage = String(localized: "Choose a photo first."); return }
        if cap == .videoToVideo && sourceVideo == nil { errorMessage = String(localized: "Choose a video first."); return }
        let (w, h) = size(for: model, aspect: cap == .imageToVideo ? aspectOf(sourceImage) : (cap == .videoToVideo ? aspectOf(sourceVideoInfo) : aspect))
        let frameCount = frames(for: model, seconds: seconds)
        let baseSeed = UInt32(seedText) ?? UInt32.random(in: 1...UInt32.max - 10)
        let count = cap == .videoToVideo ? 1 : variants
        errorMessage = nil
        notice = nil
        cancelled = false
        progress = Progress(title: section.title, stage: String(localized: "Waiting…"), variantCount: count)
        let snapshot = (prompt: promptText, negative: negativePrompt, guidance: guidance, steps: quality.steps,
                        strength: strength, motion: motion, image: sourceImage, imageName: sourceImageName, video: sourceVideo)
        AIJobManager.shared.enqueue(section.title) { [weak self] in
            guard let self else { return }
            for v in 1...count {
                if self.cancelled { break }
                self.progress?.variant = v
                do {
                    let c = try await self.runOne(cap: cap, model: model, width: w, height: h, frames: frameCount,
                                                  seed: baseSeed &+ UInt32(v - 1), s: snapshot)
                    self.lastResult = c
                    VideoProjectStore.shared.add(c)
                } catch VideoEngineClient.EngineError.cancelled {
                    break
                } catch {
                    self.errorMessage = error.localizedDescription
                    break
                }
            }
            self.progress = nil
        }
    }

    private func aspectOf(_ img: CGImage?) -> VideoAspect {
        guard let img else { return aspect }
        return nearestAspect(Double(img.width) / Double(img.height))
    }
    private func aspectOf(_ info: VideoIO.SourceInfo?) -> VideoAspect {
        guard let info, info.size.height > 0 else { return aspect }
        return nearestAspect(info.size.width / info.size.height)
    }
    private func nearestAspect(_ r: Double) -> VideoAspect {
        VideoAspect.allCases.min { abs(log($0.ratio / r)) < abs(log($1.ratio / r)) } ?? .landscape16x9
    }

    private typealias Snapshot = (prompt: String, negative: String, guidance: Double, steps: Int, strength: Double,
                                  motion: VideoMotion, image: CGImage?, imageName: String, video: URL?)

    private func runOne(cap: AICapability, model: AIModelDescriptor, width: Int, height: Int, frames: Int,
                        seed: UInt32, s: Snapshot) async throws -> VideoCreation {
        let engine = VideoEngineClient.shared
        let work = VideoProjectStore.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        progress?.stage = String(localized: "Starting the video engine…")
        _ = try await engine.hello()
        progress?.stage = String(localized: "Loading \(model.name)…")
        try await engine.load(model)

        var args: [String: Any] = ["prompt": s.prompt, "negative_prompt": s.negative, "width": width, "height": height,
                                   "frames": frames, "steps": s.steps, "guidance": s.guidance, "seed": Int(seed),
                                   "out": work.appendingPathComponent("frames").path]
        // Wan: flow shift 3 for 480p, 5 for 720p (diffusers / Wan guidance)
        args["flow_shift"] = height * width >= 1280 * 704 * 9 / 10 ? 5.0 : 3.0
        var cmd = "t2v"
        var kind = VideoCreation.Kind.textToVideo
        var sourceName: String?
        var sourcePath: String?
        var fps = model.videoFPS
        switch cap {
        case .imageToVideo:
            guard let img = s.image else { throw VideoEngineClient.EngineError.failed(String(localized: "Choose a photo first.")) }
            let imgURL = work.appendingPathComponent("source.png")
            let fitted = VideoIO.fill(CIImage(cgImage: img), to: CGSize(width: width, height: height))
            guard let cg = CIContext().createCGImage(fitted, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
                throw VideoEngineClient.EngineError.failed("image")
            }
            try VideoIO.writePNG(cg, to: imgURL)
            args["image"] = imgURL.path
            let base = s.prompt.isEmpty ? Self.describe(img) : s.prompt
            args["prompt"] = base + ", " + s.motion.instruction
            cmd = "i2v"; kind = .imageToVideo; sourceName = s.imageName
        case .videoToVideo:
            guard let src = s.video else { throw VideoEngineClient.EngineError.failed(String(localized: "Choose a video first.")) }
            progress?.stage = String(localized: "Reading the video…")
            let info = try await VideoIO.info(src)
            // Sample the source at the model's frame rate; the clip length is limited to what the model handles.
            let n = min(frames, max(5, Int(info.duration * Double(model.videoFPS)) / 4 * 4 + 1))
            let framesDir = work.appendingPathComponent("source", isDirectory: true)
            try await VideoIO.extractFrames(from: src, fps: Double(model.videoFPS), count: n,
                                            size: CGSize(width: width, height: height), to: framesDir)
            args["video_frames"] = framesDir.path
            args["strength"] = s.strength
            args["frames"] = n
            cmd = "v2v"; kind = .videoToVideo; sourceName = src.lastPathComponent; sourcePath = src.path
        default: break
        }

        let started = Date()
        progress?.stage = String(localized: "Understanding the prompt…")
        let result = try await engine.request(cmd, args) { [weak self] ev in
            Task { @MainActor in
                guard let self else { return }
                switch ev.kind {
                case "progress":
                    let step = ev.int("step") ?? 0, total = ev.int("total") ?? 0
                    let el = ev.double("elapsed") ?? 0
                    self.progress?.step = step
                    self.progress?.total = total
                    self.progress?.secondsPerStep = step > 0 ? el / Double(step) : nil
                    self.progress?.stage = String(localized: "Generating frames")
                case "status":
                    if ev.string("stage") == "text" { self.progress?.stage = String(localized: "Understanding the prompt…") }
                default: break
                }
            }
        }
        progress?.stage = String(localized: "Checking and saving the video…")
        let valid = (result["valid"] as? Bool) ?? false
        let reasons = (result["reasons"] as? [String]) ?? []
        guard valid else {
            throw VideoEngineClient.EngineError.failed(String(localized: "The model produced an unusable video (\(reasons.joined(separator: ", "))). It was not saved."))
        }
        var c = VideoCreation(kind: kind, prompt: (args["prompt"] as? String) ?? s.prompt, negativePrompt: s.negative,
                              modelID: model.id, modelName: model.name, seed: seed, steps: s.steps,
                              width: result["width"] as? Int ?? width, height: result["height"] as? Int ?? height,
                              frames: result["frames"] as? Int ?? frames, fps: fps)
        fps = c.fps
        c.seconds = Date().timeIntervalSince(started)
        c.peakMemoryGB = (result["peak_rss_gb"] as? NSNumber)?.doubleValue
        c.sourceName = sourceName
        c.sourcePath = sourcePath
        c.strength = cap == .videoToVideo ? s.strength : nil
        c.fileName = c.id.uuidString + ".mp4"
        if let m = result["metrics"] as? [String: Any], let d = m["mean_frame_diff"] as? NSNumber, let f = m["brightness_flicker"] as? NSNumber {
            c.validation = String(format: "motion %.4f · flicker %.4f", d.doubleValue, f.doubleValue)
        }
        if let peak = c.peakMemoryGB { storePeak(peak, model.id, width: width, height: height, frames: frames) }
        let meta = VideoIO.AIMetadata(generated: kind.generated, model: model.name, prompt: c.prompt, operation: kind.rawValue, seed: seed)
        try await VideoIO.writeMovie(frames: work.appendingPathComponent("frames"), fps: fps,
                                     to: VideoProjectStore.folder.appendingPathComponent(c.fileName), codec: .h264,
                                     metadata: meta, audioFrom: cap == .videoToVideo ? sourcePath.map(URL.init(fileURLWithPath:)) : nil)
        return c
    }

    /// Short English description of a photo (Vision labels) used when no prompt is given for image to video.
    nonisolated static func describe(_ image: CGImage) -> String {
        let labels = AIImageValidator.labels(image, limit: 5).filter { $0.1 > 0.15 }.map { $0.0.replacingOccurrences(of: "_", with: " ") }
        return labels.isEmpty ? "a realistic video, the scene comes to life" : "a realistic video of " + labels.joined(separator: ", ")
    }

    // MARK: Export

    func export(_ c: VideoCreation, to dest: URL, codec: VideoIO.Codec, scale: Double, label: Bool) async throws {
        let src = VideoProjectStore.shared.url(c)
        let tmp = VideoProjectStore.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await VideoIO.extractFrames(from: src, fps: Double(c.fps), count: c.frames,
                                        size: CGSize(width: c.width, height: c.height), to: tmp)
        let size = CGSize(width: Double(c.width) * scale, height: Double(c.height) * scale)
        let meta = VideoIO.AIMetadata(generated: c.kind.generated, model: c.modelName, prompt: c.prompt, operation: c.kind.rawValue, seed: c.seed)
        try await VideoIO.writeMovie(frames: tmp, fps: c.fps, to: dest, codec: codec, size: size, metadata: meta,
                                     label: label ? (c.kind.generated ? String(localized: "AI-generated") : String(localized: "Edited with AI")) : nil,
                                     audioFrom: src)
    }
}
