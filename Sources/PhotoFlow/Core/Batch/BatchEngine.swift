import Foundation
import CoreGraphics

/// A reusable recipe for processing many photos.
struct BatchWorkflow: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var summary: String
    var enhance: Bool = true
    var strength: EnhanceStrength = .balanced
    var options: AutoEnhanceOptions = .enhanceOnly
    var presetID: String?
    var autoCrop: AutoCrop.Mode = .none
    var keepExistingEdits: Bool = false
    var saveToLibrary: Bool = true
    var exportEnabled: Bool = false
    var export: ExportOptions = .fromSettings
    var resizeLongSide: Int?

    var localizedName: String { String(localized: String.LocalizationValue(name)) }
    var localizedSummary: String { String(localized: String.LocalizationValue(summary)) }

    static let predefined: [BatchWorkflow] = {
        var all: [BatchWorkflow] = []
        all.append(BatchWorkflow(id: "auto-everything", name: "Auto Improve Everything", symbol: "wand.and.stars",
                                 summary: "Exposure, colors, white balance, straightening and perspective – decided per photo.",
                                 options: .everything))
        all.append(BatchWorkflow(id: "natural", name: "Natural Colors", symbol: "leaf",
                                 summary: "Gentle corrections with neutral, true-to-life colors.",
                                 strength: .subtle, options: AutoEnhanceOptions(tone: true, color: true, whiteBalance: true, straighten: false, perspective: false, detail: true),
                                 presetID: "natural"))
        all.append(BatchWorkflow(id: "bright-clean", name: "Bright and Clean", symbol: "sun.max",
                                 summary: "Brighter, airy look with clean whites.", presetID: "bright"))
        all.append(BatchWorkflow(id: "landscape", name: "Landscape Optimization", symbol: "mountain.2",
                                 summary: "Straight horizons, rich skies and crisp detail.",
                                 options: AutoEnhanceOptions(tone: true, color: true, whiteBalance: true, straighten: true, perspective: false, detail: true),
                                 presetID: "landscape"))
        all.append(BatchWorkflow(id: "portrait", name: "Portrait Optimization", symbol: "person.crop.square",
                                 summary: "Face-aware exposure, natural skin tones, soft detail.",
                                 presetID: "portrait"))
        all.append(BatchWorkflow(id: "straighten", name: "Straighten and Enhance", symbol: "level",
                                 summary: "Fixes crooked horizons and converging lines, then enhances.",
                                 options: .everything))
        var web = BatchWorkflow(id: "web", name: "Web Export", symbol: "globe",
                                summary: "Enhance and export compact JPEGs (2048 px, sRGB) for websites and sharing.",
                                saveToLibrary: false, exportEnabled: true)
        web.export.apply(.webOptimized)
        all.append(web)
        return all
    }()
}

enum BatchItemStatus: Equatable, Sendable {
    case waiting, processing, done, failed(String), skipped(String)
}

struct BatchItemResult: Sendable {
    var photoID: Int64
    var status: BatchItemStatus
    var recipe: EditRecipe?
    var editedAt: Date?
    var exportedURL: URL?
    var exportedBytes: Int64
    var duration: TimeInterval
    var notes: [String]
}

/// Pause/resume gate checked by workers before starting each photo.
actor PauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() { paused = true }
    func resume() {
        paused = false
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }
    var isPaused: Bool { paused }
    func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Processes photos with controlled concurrency (adapted to the Mac – see `HardwareProfile`). Each worker
/// decodes at most one full-resolution image at a time, so memory stays bounded for 1,000+ photo batches.
final class BatchRunner: @unchecked Sendable {
    private let store: LibraryStore
    let gate = PauseGate()

    init(store: LibraryStore) { self.store = store }

    func run(_ photos: [PhotoRecord], workflow: BatchWorkflow, existing: [Int64: EditRecipe], customPresets: [Preset],
             concurrency: Int, onStart: @escaping @Sendable (Int64) -> Void,
             onResult: @escaping @Sendable (BatchItemResult) -> Void) async {
        if workflow.exportEnabled { try? ExportEngine.prepareDestination(workflow.export) }
        let limit = max(1, concurrency)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < photos.count else { return }
                let photo = photos[next]
                let counter = next + 1
                next += 1
                group.addTask { [self] in
                    await gate.waitIfPaused()
                    if Task.isCancelled {
                        onResult(BatchItemResult(photoID: photo.id, status: .skipped(String(localized: "Cancelled")), recipe: nil,
                                                 editedAt: nil, exportedURL: nil, exportedBytes: 0, duration: 0, notes: []))
                        return
                    }
                    onStart(photo.id)
                    let result = self.process(photo, workflow: workflow, base: existing[photo.id], customPresets: customPresets, counter: counter)
                    onResult(result)
                }
            }
            for _ in 0 ..< min(limit, photos.count) { enqueue() }
            while await group.next() != nil {
                if !Task.isCancelled { enqueue() }
            }
        }
    }

    /// Processes a single photo synchronously (called on a worker task).
    func process(_ photo: PhotoRecord, workflow: BatchWorkflow, base: EditRecipe?, customPresets: [Preset], counter: Int) -> BatchItemResult {
        let started = Date()
        var notes: [String] = []
        do {
            guard FileManager.default.fileExists(atPath: photo.path) else {
                throw ExportEngine.ExportError.sourceMissing(photo.filename)
            }
            var recipe = workflow.keepExistingEdits ? (base ?? .identity) : .identity
            let preset = workflow.presetID.flatMap { Preset.preset(id: $0, custom: customPresets) }
            let needsAnalysis = workflow.enhance || (preset?.adaptive ?? false) || workflow.autoCrop != .none
            var analysis: PhotoAnalysis?
            if needsAnalysis {
                analysis = autoreleasepool { PhotoAnalyzer.analyze(url: photo.url, iso: photo.iso) }
                guard analysis != nil else { throw ImageLoader.LoadError.unreadable(photo.filename) }
            }
            if let a = analysis, workflow.enhance || (preset?.adaptive ?? false) {
                let opts = workflow.enhance ? workflow.options : .enhanceOnly
                let strength = workflow.enhance ? workflow.strength : .subtle
                let outcome = AutoEnhanceEngine.enhance(a, base: recipe, strength: strength, options: opts)
                recipe = outcome.recipe
                notes = outcome.notes
            }
            if let preset {
                let auto = recipe.auto
                recipe = preset.apply(to: recipe)
                recipe.auto = auto
                notes.append(String(localized: "Applied preset “\(preset.localizedName)”"))
            }
            if let a = analysis {
                switch workflow.autoCrop {
                case .none: break
                case .trimBorders:
                    if !recipe.hasGeometry, let px = PixelBuffer(cgImage: a.analysisImage, maxSide: 768), let crop = AutoCrop.trimBorders(px) {
                        recipe.crop = crop
                        notes.append(String(localized: "Removed borders"))
                    }
                case .aspect(let w, let h):
                    let size = CGSize(width: a.analysisImage.width, height: a.analysisImage.height)
                    recipe.crop = AutoCrop.aspectCrop(imageSize: size, ratio: w / h, salient: a.scene.salientRect)
                    notes.append(String(localized: "Cropped to \(Int(w)):\(Int(h))"))
                }
            }
            var editedAt: Date?
            if workflow.saveToLibrary {
                editedAt = try store.saveRecipe(recipe, for: photo.id)
                ThumbnailService.shared.invalidate(photoID: photo.id)
            }
            var exported: ExportEngine.Output?
            if workflow.exportEnabled {
                var opts = workflow.export
                if let r = workflow.resizeLongSide { opts.maxLongSide = r }
                exported = try ExportEngine.export(photo: photo, recipe: recipe, options: opts, counter: counter)
            }
            return BatchItemResult(photoID: photo.id, status: .done, recipe: recipe, editedAt: editedAt,
                                   exportedURL: exported?.url, exportedBytes: exported?.bytes ?? 0,
                                   duration: Date().timeIntervalSince(started), notes: notes)
        } catch {
            return BatchItemResult(photoID: photo.id, status: .failed(error.localizedDescription), recipe: nil, editedAt: nil,
                                   exportedURL: nil, exportedBytes: 0, duration: Date().timeIntervalSince(started), notes: notes)
        }
    }
}
