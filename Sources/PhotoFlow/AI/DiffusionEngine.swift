import Foundation
import CoreML
import CoreGraphics
import StableDiffusion

/// Cancellation flag shared between the UI and a running AI job.
final class AICancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// One diffusion run producing one image.
struct DiffusionJob {
    var model: AIModelDescriptor
    var prompt: String
    var negativePrompt: String
    var steps: Int
    var guidance: Float
    var seed: UInt32
    /// Exactly `model.resolution` square, required for image-to-image and inpainting.
    var startingImage: CGImage?
    var strength: Float = 1
    /// Mask at the model resolution (grey, 255 = regenerate) for inpainting / outpainting.
    var mask: CGImage?
}

struct StepReport: Sendable {
    var step: Int
    var stepCount: Int
    /// Measured average time per step (nil until two steps have been timed).
    var secondsPerStep: Double?
}

/// Runs Apple's Core ML Stable Diffusion pipelines on a dedicated serial queue, keeps the last
/// pipeline loaded for fast follow-up runs and releases it when idle or under memory pressure.
final class DiffusionEngine: @unchecked Sendable {
    static let shared = DiffusionEngine()

    private let queue = DispatchQueue(label: "photoflow.ai.diffusion", qos: .userInitiated)
    /// The loaded pipeline (typed as Any so the engine itself does not require macOS 13.1).
    private var pipelineStorage: Any?
    private var loadedKey: String?
    private(set) var loadedModelID: String?
    private var idleWork: DispatchWorkItem?
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Measured seconds per step per model + compute configuration (for ETAs before the first step).
    private var stepTimes: [String: Double] = [:]
    private let stateLock = NSLock()
    /// Models whose GPU run failed in this session – they continue in "safe" mode (CPU where possible).
    private var cpuFallback = Set<String>()
    /// Set when the last run had to switch to the CPU (shown to the user).
    private(set) var lastRunFellBackToCPU = false

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in self?.unloadNow() }
        src.resume()
        pressureSource = src
    }

    /// Typical seconds per step measured on this Mac for a model, if known.
    func knownSecondsPerStep(modelID: String) -> Double? {
        stateLock.lock(); defer { stateLock.unlock() }
        return stepTimes[modelID] ?? (UserDefaults.standard.object(forKey: "aiStepTime.\(modelID)") as? Double)
    }

    var isLoaded: Bool { stateLock.lock(); defer { stateLock.unlock() }; return loadedModelID != nil }

    /// Runs `body` on the engine queue (serial – one heavy job at a time).
    func perform<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                c.resume(with: Result { try autoreleasepool { try body() } })
            }
        }
    }

    func unloadIfUsing(modelID: String) {
        queue.async { [weak self] in
            guard let self, self.loadedModelID == modelID else { return }
            self.unloadNow()
        }
    }

    func unload() { queue.async { [weak self] in self?.unloadNow() } }

    @available(macOS 13.1, *)
    private var pipeline: StableDiffusionPipelineProtocol? {
        get { pipelineStorage as? StableDiffusionPipelineProtocol }
        set { pipelineStorage = newValue }
    }

    private func unloadNow() {
        if #available(macOS 13.1, *) { pipeline?.unloadResources() }
        pipelineStorage = nil
        stateLock.lock(); loadedKey = nil; loadedModelID = nil; stateLock.unlock()
    }

    private func scheduleIdleUnload() {
        idleWork?.cancel()
        let minutes: Double = AIPerformanceProfile.current == .maximumSpeed ? 15 : (AIPerformanceProfile.current == .energySaving ? 1 : 5)
        let w = DispatchWorkItem { [weak self] in self?.unloadNow() }
        idleWork = w
        queue.asyncAfter(deadline: .now() + minutes * 60, execute: w)
    }

    // MARK: Loading (engine queue only)

    @available(macOS 13.1, *)
    private func loadPipeline(_ model: AIModelDescriptor) throws -> StableDiffusionPipelineProtocol {
        let hw = AIHardware.current
        let profile = AIPerformanceProfile.current
        let plan = hw.diffusionPlan(safe: cpuFallback.contains(model.id))
        let reduce = hw.reduceMemory(for: model, profile: profile)
        let key = "\(model.id)|\(plan.signature)|\(reduce)"
        if let pipeline, loadedKey == key { return pipeline }
        unloadNow()

        let dir = ModelStore.directory(for: model.id)
        let required = model.family == .sdxl
            ? ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]
            : ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]
        for r in required where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(r).path) {
            throw AIError.modelMissing(model.name)
        }

        let config = MLModelConfiguration()
        config.computeUnits = plan.base
        ComponentConfiguration.set(plan.overrides)
        let p: StableDiffusionPipelineProtocol
        switch model.family {
        case .sdxl:
            guard #available(macOS 14.0, *) else { throw AIError.unsupported(String(localized: "Stable Diffusion XL requires macOS 14.")) }
            p = try StableDiffusionXLPipeline(resourcesAt: dir, configuration: config, reduceMemory: reduce)
        default:
            p = try StableDiffusionPipeline(resourcesAt: dir, controlNet: [], configuration: config, disableSafety: true, reduceMemory: reduce)
        }
        try p.loadResources()
        pipeline = p
        stateLock.lock(); loadedKey = key; loadedModelID = model.id; stateLock.unlock()
        return p
    }

    // MARK: Generation

    /// Core ML errors are technical; explain what the user can do.
    static func friendly(_ error: Error) -> Error {
        if error is AIError { return error }
        let hw = AIHardware.current
        if hw.isIntel {
            return AIError.failed(String(localized: "Core ML could not run the model on this Intel Mac's graphics processor. Restart PhotoFlow and try again; if it keeps failing, use the “Energy saving” profile or Stable Diffusion 2.1 Compact. (\(error.localizedDescription))"))
        }
        return AIError.failed(String(localized: "Core ML could not run the model. Restart PhotoFlow and try again, or remove and re-download the model. (\(error.localizedDescription))"))
    }

    /// Generates one image. Call through `perform` (runs on the engine queue).
    func generateSync(_ job: DiffusionJob, token: AICancelToken, onStep: @escaping (StepReport) -> Void) throws -> CGImage {
        guard #available(macOS 13.1, *) else {
            throw AIError.unsupported(String(localized: "Image generation requires macOS 13.1 or later."))
        }
        return try run(job, token: token, onStep: onStep)
    }

    @available(macOS 13.1, *)
    private func run(_ job: DiffusionJob, token: AICancelToken, onStep: @escaping (StepReport) -> Void) throws -> CGImage {
        idleWork?.cancel()
        defer { scheduleIdleUnload() }
        if token.isCancelled { throw AIError.cancelled }
        let p = try loadPipeline(job.model)
        if token.isCancelled { throw AIError.cancelled }

        var cfg = PipelineConfiguration(prompt: job.prompt)
        cfg.negativePrompt = job.negativePrompt
        cfg.stepCount = max(1, job.steps)
        cfg.seed = job.seed
        cfg.guidanceScale = job.guidance
        cfg.imageCount = 1
        cfg.disableSafety = true
        cfg.schedulerType = .dpmSolverMultistepScheduler
        cfg.rngType = .numpyRNG
        if job.model.family == .sdxl {
            cfg.encoderScaleFactor = 0.13025
            cfg.decoderScaleFactor = 0.13025
            cfg.originalSize = Float32(job.model.resolution)
            cfg.targetSize = Float32(job.model.resolution)
        }
        var inpainting: LatentInpainting?
        if let start = job.startingImage {
            cfg.startingImage = start
            cfg.strength = min(1, max(0.05, job.strength))
            if let mask = job.mask {
                inpainting = LatentInpainting(image: start, latentMask: AIImage.latentMask(mask, side: job.model.resolution / 8))
            }
        }

        var lastTime: Date?
        var timed: [Double] = []
        func attempt(_ p: StableDiffusionPipelineProtocol) throws -> [CGImage?] {
            lastTime = nil
            timed = []
            return try p.generateImages(configuration: cfg, inpainting: inpainting) { progress in
                let now = Date()
                if let lastTime { timed.append(now.timeIntervalSince(lastTime)) }
                lastTime = now
                let avg = timed.count >= 2 ? timed.reduce(0, +) / Double(timed.count) : nil
                onStep(StepReport(step: progress.step + 1, stepCount: progress.stepCount, secondsPerStep: avg))
                return !token.isCancelled
            }
        }
        lastRunFellBackToCPU = false
        let images: [CGImage?]
        do {
            images = try attempt(p)
        } catch {
            // GPU drivers can fail (hangs, unsupported operations, virtual GPUs). Retry once on the CPU.
            let hw = AIHardware.current
            guard !token.isCancelled, !cpuFallback.contains(job.model.id), hw.diffusionPlan(safe: true) != hw.diffusionPlan(safe: false) else {
                throw Self.friendly(error)
            }
            print("AI: run failed (\(error.localizedDescription)) – retrying in safe mode (CPU where possible)")
            cpuFallback.insert(job.model.id)
            lastRunFellBackToCPU = true
            unloadNow()
            do {
                images = try attempt(try loadPipeline(job.model))
            } catch {
                throw Self.friendly(error)
            }
        }
        if token.isCancelled { throw AIError.cancelled }
        if timed.count >= 2 {
            let avg = timed.reduce(0, +) / Double(timed.count)
            stateLock.lock(); stepTimes[job.model.id] = avg; stateLock.unlock()
            UserDefaults.standard.set(avg, forKey: "aiStepTime.\(job.model.id)")
        }
        guard let first = images.first, let image = first else {
            throw AIError.failed(String(localized: "The model returned no image. Try another prompt or seed."))
        }
        return image
    }
}
