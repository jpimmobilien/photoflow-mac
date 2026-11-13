import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Image the user works on in the editing sections.
struct AISource: Equatable {
    var image: CGImage
    var name: String
    var photoID: Int64?
    var creationID: UUID?
    static func == (a: AISource, b: AISource) -> Bool { a.image === b.image && a.name == b.name }
}

/// A finished result shown in the results strip.
struct AIResult: Identifiable, Equatable {
    var id: UUID { creation.id }
    var image: CGImage
    var creation: AICreation
    /// What the result replaced (for before/after), nil for text-to-image.
    var before: CGImage?
    static func == (a: AIResult, b: AIResult) -> Bool { a.creation == b.creation && a.image === b.image }
}

/// Live status of a running job. Only real values: steps reported by the model, measured times.
struct AIJobStatus: Equatable {
    var title: String
    var phase: Phase
    var variant = 1
    var variantCount = 1
    var startedAt = Date()

    enum Phase: Equatable {
        case loading                 // model is being loaded (no percentage known)
        case steps(Int, Int, Double?)  // step, count, seconds per step (measured)
        case fraction(Double)        // tiles processed (upscaling)
        case finishing
    }

    var fraction: Double? {
        switch phase {
        case .loading, .finishing: return nil
        case .steps(let s, let n, _): return n > 0 ? (Double(variant - 1) + Double(s) / Double(n)) / Double(max(1, variantCount)) : nil
        case .fraction(let f): return f
        }
    }

    /// Remaining time – only once the step time has been measured.
    var remainingSeconds: Double? {
        guard case .steps(let s, let n, let sps) = phase, let sps else { return nil }
        let remainingThis = Double(n - s) * sps
        let otherVariants = Double(variantCount - variant) * (Double(n) * sps + 2)
        return remainingThis + otherVariants
    }
}

@MainActor
final class AIStudioModel: ObservableObject {
    static let shared = AIStudioModel()

    enum Section: String, CaseIterable, Identifiable {
        case generate, edit, fill, expand, enhance, upscale, creations, models
        var id: String { rawValue }
        var title: String {
            switch self {
            case .generate: return String(localized: "Generate Image")
            case .edit: return String(localized: "Edit Image")
            case .fill: return String(localized: "Generative Fill")
            case .expand: return String(localized: "Expand Image")
            case .enhance: return String(localized: "Enhance Image")
            case .upscale: return String(localized: "AI Upscaling")
            case .creations: return String(localized: "My AI Creations")
            case .models: return String(localized: "Model Management")
            }
        }
        var symbol: String {
            switch self {
            case .generate: return "sparkles"
            case .edit: return "photo.on.rectangle.angled"
            case .fill: return "paintbrush.pointed"
            case .expand: return "arrow.up.left.and.arrow.down.right"
            case .enhance: return "wand.and.stars"
            case .upscale: return "arrow.up.forward.square"
            case .creations: return "square.grid.2x2"
            case .models: return "cpu"
            }
        }
        var usesSource: Bool { [.edit, .fill, .expand, .enhance, .upscale].contains(self) }
    }

    enum FillMode: String, CaseIterable, Identifiable {
        case fill, remove, background
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fill: return String(localized: "Fill with prompt")
            case .remove: return String(localized: "Remove object")
            case .background: return String(localized: "Replace background")
            }
        }
        var symbol: String {
            switch self {
            case .fill: return "paintbrush.pointed"
            case .remove: return "eraser"
            case .background: return "person.and.background.dotted"
            }
        }
    }

    @Published var section: Section = .generate

    // Prompt & settings
    @Published var prompt = ""
    @Published var negativePrompt = ""
    @Published var styleID = "none"
    @Published var aspect: AIAspect = .square
    @Published var quality: AIQuality = .standard
    @Published var variants = 1
    @Published var seedText = ""
    @Published var guidance: Double = 7.5
    @Published var stepsOverride: Int?
    @Published var modelID: String?
    @Published var showAdvanced = false
    @Published var profile: AIPerformanceProfile = .current {
        didSet { UserDefaults.standard.set(profile.rawValue, forKey: "aiPerformanceProfile") }
    }

    // Editing
    @Published var source: AISource?
    @Published var mask = MaskDocument()
    @Published var tool: MaskDocument.Tool = .brush
    @Published var brushSize: Double = 0.05
    @Published var fillMode: FillMode = .fill
    @Published var strength: Double = 0.6
    @Published var expansion = AIOperations.Expansion()
    @Published var enhanceKind: AIOperations.EnhanceKind = .restoreDetail
    @Published var enhanceAmount: Double = 1
    @Published var upscaleFactor = 2
    @Published var addShadow = true

    // Results & jobs
    @Published var results: [AIResult] = []
    @Published var selectedResultID: UUID?
    @Published private(set) var job: AIJobStatus?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var suggestion: PromptAssistant.Suggestion?
    @Published var assistantBusy = false

    private var token: AICancelToken?

    var isBusy: Bool { job != nil }
    var selectedResult: AIResult? { results.first { $0.id == selectedResultID } ?? results.first }

    var activeModel: AIModelDescriptor? {
        let store = ModelStore.shared
        if let modelID, store.isInstalled(modelID), let m = AIModelCatalog.model(modelID), AIHardware.current.incompatibility(of: m) == nil { return m }
        return store.activeDiffusionModel
    }

    var effectiveSteps: Int { stepsOverride ?? quality.steps(profile: profile) }
    var maxVariants: Int { AIHardware.current.maxVariants }

    // MARK: Settings

    private func settings(prompt override: String? = nil) throws -> GenerationSettings {
        guard let m = activeModel else { throw AIError.noModel(.textToImage) }
        return GenerationSettings(model: m, prompt: override ?? prompt, negativePrompt: negativePrompt, style: .style(styleID),
                                  steps: effectiveSteps, guidance: Float(guidance))
    }

    private func nextSeed(offset: Int = 0) -> UInt32 {
        if let s = UInt32(seedText.trimmingCharacters(in: .whitespaces)) { return s &+ UInt32(offset) }
        return UInt32.random(in: 1...4_000_000_000)
    }

    // MARK: Source

    func setSource(photo: PhotoRecord) {
        let recipe = AppModel.shared.recipe(for: photo.id)
        Task {
            do {
                let img = try await Task.detached(priority: .userInitiated) { try AIImage.load(url: photo.url, recipe: recipe, maxPixel: 6000) }.value
                source = AISource(image: img, name: photo.filename, photoID: photo.id)
                resetEditing()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func setSource(url: URL) {
        Task {
            do {
                let img = try await Task.detached(priority: .userInitiated) { try AIImage.load(url: url, maxPixel: 6000) }.value
                source = AISource(image: img, name: url.lastPathComponent)
                resetEditing()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func setSource(result: AIResult, section target: Section) {
        source = AISource(image: result.image, name: result.creation.prompt.isEmpty ? result.creation.kind.title : result.creation.prompt,
                          photoID: result.creation.sourcePhotoID, creationID: result.creation.id)
        resetEditing()
        withAnimation(DS.Motion.adaptive(DS.Motion.page)) { section = target }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { setSource(url: url) }
    }

    func resetEditing() {
        mask.clear()
        expansion = AIOperations.Expansion()
        results = []
        selectedResultID = nil
    }

    // MARK: Jobs

    func cancel() {
        token?.cancel()
    }

    private func begin(_ title: String, variants: Int = 1) -> AICancelToken {
        let t = AICancelToken()
        token = t
        errorMessage = nil
        notice = nil
        job = AIJobStatus(title: title, phase: .loading, variant: 1, variantCount: variants)
        return t
    }

    private func finish() {
        job = nil
        token = nil
    }

    private func fail(_ error: Error) {
        if case AIError.cancelled = error {
            notice = String(localized: "Cancelled. Nothing was changed.")
        } else {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        finish()
    }

    /// Step callback hopping to the main actor.
    nonisolated static func stepHandler() -> (StepReport) -> Void {
        { report in
            Task { @MainActor in
                guard var j = AIStudioModel.shared.job else { return }
                j.phase = report.step >= report.stepCount ? .finishing : .steps(report.step, report.stepCount, report.secondsPerStep)
                AIStudioModel.shared.job = j
            }
        }
    }

    nonisolated static func fractionHandler() -> (Double) -> Void {
        { f in Task { @MainActor in
            guard var j = AIStudioModel.shared.job else { return }
            j.phase = .fraction(f)
            AIStudioModel.shared.job = j
        } }
    }

    private func record(_ image: CGImage, kind: AIOperationKind, settings s: GenerationSettings?, seed: UInt32?, strength: Double? = nil,
                        before: CGImage?, started: Date, note: String? = nil, modelOverride: AIModelDescriptor? = nil) {
        let model = modelOverride ?? s?.model
        let c = AICreation(kind: kind, prompt: s?.prompt ?? "", negativePrompt: s?.negativePrompt ?? "", styleID: s?.style.id,
                           modelID: model?.id ?? "photoflow", modelName: model?.name ?? "PhotoFlow",
                           seed: seed, steps: s?.steps, guidance: s.map { Double($0.guidance) }, strength: strength,
                           quality: kind == .textToImage ? quality.rawValue : nil, aspect: kind == .textToImage ? aspect.rawValue : nil,
                           width: image.width, height: image.height, sourceName: source?.name, sourcePhotoID: source?.photoID,
                           parentID: source?.creationID, duration: Date().timeIntervalSince(started), note: note, fileName: "")
        if DiffusionEngine.shared.lastRunFellBackToCPU {
            notice = String(localized: "The graphics processor reported an error; PhotoFlow reloaded the model and finished the image.")
        }
        do {
            let saved = try CreationStore.shared.add(image, c)
            let r = AIResult(image: image, creation: saved, before: before)
            withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) {
                results.insert(r, at: 0)
                selectedResultID = r.id
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Text to image, `count` variants with consecutive seeds.
    func generate(count requested: Int? = nil, seedBase: UInt32? = nil) {
        guard !isBusy else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { errorMessage = AIError.emptyPrompt.errorDescription; return }
        let s: GenerationSettings
        do { s = try settings() } catch { errorMessage = (error as? LocalizedError)?.errorDescription; return }
        let count = min(requested ?? variants, maxVariants)
        let base = seedBase ?? nextSeed()
        let aspect = self.aspect
        let upscale = quality.upscaleFactor
        let token = begin(String(localized: "Generating"), variants: count)
        if seedBase == nil { results = results.filter { $0.creation.kind != .textToImage } }
        Task {
            for i in 0..<count {
                if token.isCancelled { break }
                job?.variant = i + 1
                job?.phase = .loading
                let seed = base &+ UInt32(i)
                let started = Date()
                do {
                    var img = try await DiffusionEngine.shared.perform {
                        try AIOperations.textToImage(s, aspect: aspect, seed: seed, token: token, onStep: Self.stepHandler())
                    }
                    var note: String?
                    if upscale > 1 {
                        if ModelStoreSnapshot.current.upscaler() != nil {
                            job?.phase = .finishing
                            let generated = img
                            img = try await DiffusionEngine.shared.perform {
                                try AIOperations.upscale(generated, factor: upscale, token: token) { _ in }
                            }
                        } else {
                            note = String(localized: "Install a Real-ESRGAN model to get higher resolution at this quality level.")
                        }
                    }
                    record(img, kind: .textToImage, settings: s, seed: seed, before: nil, started: started, note: note)
                    if let note { notice = note }
                } catch {
                    fail(error)
                    return
                }
            }
            if token.isCancelled { notice = String(localized: "Stopped. Finished images were kept.") }
            finish()
        }
    }

    func moreVariants(like r: AIResult) {
        prompt = r.creation.prompt
        negativePrompt = r.creation.negativePrompt
        styleID = r.creation.styleID ?? "none"
        seedText = ""
        generate(count: min(4, maxVariants), seedBase: nextSeed())
    }

    func regenerate(_ c: AICreation) {
        prompt = c.prompt
        negativePrompt = c.negativePrompt
        styleID = c.styleID ?? "none"
        if let a = c.aspect, let v = AIAspect(rawValue: a) { aspect = v }
        if let q = c.quality, let v = AIQuality(rawValue: q) { quality = v }
        if let g = c.guidance { guidance = g }
        if CreationStore.shared.creations.contains(where: { $0.id == c.id }), c.kind == .textToImage {
            modelID = c.modelID
            seedText = c.seed.map(String.init) ?? ""
            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { section = .generate }
            generate(count: 1)
        }
    }

    func imageToImage() {
        guard !isBusy, let src = source else { return }
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { errorMessage = AIError.emptyPrompt.errorDescription; return }
        let s: GenerationSettings
        do { s = try settings() } catch { errorMessage = (error as? LocalizedError)?.errorDescription; return }
        let seed = nextSeed(), strength = Float(self.strength)
        let token = begin(String(localized: "Editing image"))
        let started = Date()
        Task {
            do {
                var img = try await DiffusionEngine.shared.perform {
                    try AIOperations.imageToImage(src.image, s, strength: strength, seed: seed, token: token, onStep: Self.stepHandler())
                }
                if img.width < src.image.width / 2, ModelStoreSnapshot.current.upscaler() != nil {
                    job?.phase = .finishing
                    let generated = img
                    let w = min(src.image.width, generated.width * 4), h = min(src.image.height, generated.height * 4)
                    img = try await DiffusionEngine.shared.perform {
                        try AIOperations.enlarge(generated, toWidth: w, height: h, token: token)
                    }
                }
                record(img, kind: .imageToImage, settings: s, seed: seed, strength: Double(strength), before: src.image, started: started)
                finish()
            } catch { fail(error) }
        }
    }

    func runFill() {
        guard !isBusy, let src = source else { return }
        let mode = fillMode
        let doc = mask
        let feather = mask.feather
        let shadow = addShadow
        if mode != .background && doc.isEmpty { errorMessage = AIError.emptyMask.errorDescription; return }
        if mode != .remove && prompt.trimmingCharacters(in: .whitespaces).isEmpty { errorMessage = AIError.emptyPrompt.errorDescription; return }
        let s: GenerationSettings?
        do { s = try settings() } catch {
            if mode == .remove { s = nil } else { errorMessage = (error as? LocalizedError)?.errorDescription; return }
        }
        if mode == .remove, s == nil, !ModelStore.shared.lamaInstalled { errorMessage = AIError.noModel(.objectRemoval).errorDescription; return }
        let seed = nextSeed()
        let title: String
        switch mode {
        case .fill: title = String(localized: "Filling selection")
        case .remove: title = String(localized: "Removing object")
        case .background: title = String(localized: "Replacing background")
        }
        let token = begin(title)
        let started = Date()
        Task {
            do {
                switch mode {
                case .fill:
                    guard let s else { return }
                    let img = try await DiffusionEngine.shared.perform { () throws -> CGImage in
                        guard let m = doc.render(width: src.image.width, height: src.image.height) else { throw AIError.emptyMask }
                        return try AIOperations.generativeFill(src.image, mask: m, s, feather: feather, seed: seed, token: token, onStep: Self.stepHandler())
                    }
                    record(img, kind: .fill, settings: s, seed: seed, before: src.image, started: started)
                case .remove:
                    let r = try await DiffusionEngine.shared.perform { () throws -> AIOperations.RemovalResult in
                        guard let m = doc.render(width: src.image.width, height: src.image.height) else { throw AIError.emptyMask }
                        return try AIOperations.removeObject(src.image, mask: m, token: token, fallback: s, onStep: Self.stepHandler())
                    }
                    let note = r.usedDiffusionFallback ? String(localized: "Removed with Stable Diffusion because LaMa is not installed. LaMa gives cleaner results.") : nil
                    record(r.image, kind: .remove, settings: r.usedDiffusionFallback ? s : nil, seed: r.usedDiffusionFallback ? seed : nil,
                           before: src.image, started: started, note: note,
                           modelOverride: r.usedDiffusionFallback ? nil : AIModelCatalog.model("lama"))
                    if let note { notice = note }
                case .background:
                    guard let s else { return }
                    let img = try await DiffusionEngine.shared.perform { () throws -> CGImage in
                        let subject: CGImage
                        if doc.isEmpty {
                            subject = try AIOperations.subjectMask(src.image)
                        } else {
                            guard let m = doc.render(width: src.image.width, height: src.image.height) else { throw AIError.emptyMask }
                            subject = m
                        }
                        return try AIOperations.replaceBackground(src.image, subject: subject, s, shadow: shadow, seed: seed, token: token,
                                                                  onStep: Self.stepHandler())
                    }
                    record(img, kind: .background, settings: s, seed: seed, before: src.image, started: started)
                }
                finish()
            } catch { fail(error) }
        }
    }

    /// Finds the subject with Vision and puts it into the mask (for background replacement).
    func selectSubject() {
        guard let src = source, !isBusy else { return }
        let token = begin(String(localized: "Finding subject"))
        Task {
            do {
                let m = try await DiffusionEngine.shared.perform { try AIOperations.subjectMask(src.image) }
                if !token.isCancelled {
                    mask.clear()
                    mask.base = m
                }
                finish()
            } catch { fail(error) }
        }
    }

    func runExpand() {
        guard !isBusy, let src = source else { return }
        guard !expansion.isEmpty else { errorMessage = String(localized: "Drag the edges of the image outwards first."); return }
        let s: GenerationSettings
        do { s = try settings(prompt: prompt.isEmpty ? "seamless natural continuation of the scene" : prompt) } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription; return
        }
        let e = expansion, seed = nextSeed()
        let token = begin(String(localized: "Expanding image"))
        let started = Date()
        Task {
            do {
                let img = try await DiffusionEngine.shared.perform {
                    try AIOperations.expand(src.image, by: e, s, seed: seed, token: token, onStep: Self.stepHandler())
                }
                record(img, kind: .expand, settings: s, seed: seed, before: src.image, started: started)
                finish()
            } catch { fail(error) }
        }
    }

    func runEnhance() {
        guard !isBusy, let src = source else { return }
        let kind = enhanceKind, amount = enhanceAmount
        let token = begin(kind.title)
        let started = Date()
        let modelUsed: AIModelDescriptor? = {
            let snap = ModelStoreSnapshot.current
            switch kind {
            case .restoreDetail: return snap.upscaler(scale: 2) ?? snap.upscaler(scale: 4)
            case .denoise: return snap.upscaler(denoise: true)
            default: return nil
            }
        }()
        Task {
            do {
                let img = try await DiffusionEngine.shared.perform {
                    try AIOperations.enhance(src.image, kind: kind, amount: amount, token: token, progress: Self.fractionHandler())
                }
                let note = kind == .backgroundBlur ? "Apple Vision" : (kind == .autoEnhance ? "PhotoFlow Auto Enhance" : nil)
                record(img, kind: .enhance, settings: nil, seed: nil, strength: amount, before: src.image, started: started,
                       note: note.map { "\(kind.title) · \($0)" } ?? kind.title, modelOverride: modelUsed)
                finish()
            } catch { fail(error) }
        }
    }

    func runUpscale() {
        guard !isBusy, let src = source else { return }
        let factor = upscaleFactor
        let token = begin(String(localized: "Upscaling \(factor)×"))
        let started = Date()
        let used = ModelStoreSnapshot.current.upscaler(scale: factor == 2 ? 2 : 4)
        Task {
            do {
                let img = try await DiffusionEngine.shared.perform {
                    try AIOperations.upscale(src.image, factor: factor, token: token, progress: Self.fractionHandler())
                }
                record(img, kind: .upscale, settings: nil, seed: nil, before: src.image, started: started, note: "\(factor)×", modelOverride: used)
                finish()
            } catch { fail(error) }
        }
    }

    // MARK: Prompt assistant

    func assist(_ mode: PromptAssistant.Mode) {
        let text = prompt
        assistantBusy = true
        Task {
            let s = await PromptAssistant.suggest(text, mode: mode)
            assistantBusy = false
            withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { suggestion = s }
        }
    }

    func acceptSuggestion() {
        if let s = suggestion { prompt = s.text }
        suggestion = nil
    }

    // MARK: Library

    /// Writes the result into ~/Pictures/PhotoFlow AI/ (with AI metadata) and imports it into the library.
    func saveToLibrary(_ creation: AICreation, albumID: Int64? = nil, newAlbum: String? = nil, thenEdit: Bool = false) {
        let app = AppModel.shared
        if let path = creation.libraryPath, let existing = app.photos.first(where: { $0.path == path }) {
            finishLibrary([existing], albumID: albumID, newAlbum: newAlbum, thenEdit: thenEdit)
            return
        }
        guard let image = CreationStore.shared.image(creation) else { errorMessage = AIError.imageUnreadable.errorDescription; return }
        do {
            let folder = AIMetadata.libraryFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appendingPathComponent(AIMetadata.libraryFileName(for: creation))
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent((AIMetadata.libraryFileName(for: creation) as NSString).deletingPathExtension + " \(n).png")
                n += 1
            }
            guard let data = AIMetadata.png(image, for: creation) else { throw AIError.imageUnreadable }
            try data.write(to: url, options: .atomic)
            var c = creation
            c.libraryPath = url.path
            CreationStore.shared.update(c)
            if let i = results.firstIndex(where: { $0.id == c.id }) { results[i].creation = c }
            app.importItems([url]) { [weak self] imported in
                self?.finishLibrary(imported, albumID: albumID, newAlbum: newAlbum, thenEdit: thenEdit)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finishLibrary(_ photos: [PhotoRecord], albumID: Int64?, newAlbum: String?, thenEdit: Bool) {
        let app = AppModel.shared
        let ids = photos.map(\.id)
        guard !ids.isEmpty else { return }
        if let albumID { app.add(ids, toAlbum: albumID) }
        if let newAlbum, !newAlbum.trimmingCharacters(in: .whitespaces).isEmpty {
            app.createAlbum(named: newAlbum, with: ids, select: false)
        }
        if thenEdit, let id = ids.first {
            app.sidebar = .allPhotos
            app.openEditor(id)
        } else {
            app.showToast(String(localized: "Saved to your library"), symbol: "photo.badge.checkmark")
        }
    }

    func export(_ creation: AICreation) {
        guard let image = CreationStore.shared.image(creation) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = AIMetadata.libraryFileName(for: creation)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = url.pathExtension.lowercased() == "png" ? AIMetadata.png(image, for: creation) : AIMetadata.jpeg(image, for: creation)
        do {
            guard let data else { throw AIError.imageUnreadable }
            try data.write(to: url, options: .atomic)
            AppModel.shared.showToast(String(localized: "Exported"), symbol: "square.and.arrow.up")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openFromCreations(_ c: AICreation, section target: Section) {
        guard let img = CreationStore.shared.image(c) else { return }
        setSource(result: AIResult(image: img, creation: c, before: nil), section: target)
    }
}
