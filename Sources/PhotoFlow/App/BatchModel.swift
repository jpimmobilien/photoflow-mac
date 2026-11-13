import Foundation
import SwiftUI
import AppKit

/// State of the batch-processing screen.
@MainActor
final class BatchModel: ObservableObject {
    enum Source: Hashable {
        case selection, allPhotos, album(Int64), folder(URL)
    }

    struct Item: Identifiable, Equatable {
        var id: Int64
        var filename: String
        var status: BatchItemStatus
        var duration: TimeInterval = 0
        var notes: [String] = []
        var exportedURL: URL?
    }

    @Published var workflow: BatchWorkflow = BatchWorkflow.predefined[0]
    @Published var source: Source = .allPhotos
    @Published var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var exportedBytes: Int64 = 0
    @Published var showOnlyProblems = false

    // Live preview (the real planner applied to one photo of the chosen source)
    @Published var previewPhotoID: Int64?
    @Published private(set) var previewRecipe: EditRecipe?
    @Published private(set) var previewNotes: [String] = []
    @Published private(set) var cardRecipes: [String: EditRecipe] = [:]
    @Published private(set) var previewLoading = false
    private var analysisCache: [Int64: PhotoAnalysis] = [:]
    private var previewTask: Task<Void, Never>?

    private var task: Task<Void, Never>?
    private var runner: BatchRunner?
    private var positions: [Int64: Int] = [:]

    var total: Int { items.count }
    var completedCount: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var skippedCount: Int { items.filter { if case .skipped = $0.status { return true }; return false }.count }
    var finishedCount: Int { completedCount + failedCount + skippedCount }
    var fraction: Double { total > 0 ? Double(finishedCount) / Double(total) : 0 }
    var hasResults: Bool { !items.isEmpty && !isRunning }

    /// Estimated remaining time from the observed throughput (accounts for parallel workers).
    var remaining: TimeInterval? {
        guard isRunning, !isPaused, let s = startedAt, finishedCount >= 2 else { return nil }
        let elapsed = Date().timeIntervalSince(s)
        let perItem = elapsed / Double(finishedCount)
        return perItem * Double(total - finishedCount)
    }

    func photosForSource(_ app: AppModel) -> [PhotoRecord] {
        switch source {
        case .selection: return app.selectedPhotos.isEmpty ? app.records(app.selection) : app.selectedPhotos
        case .allPhotos: return app.photos
        case .album(let id): return app.records(app.albumMembers[id] ?? [])
        case .folder(let url):
            let prefix = url.standardizedFileURL.path + "/"
            return app.photos.filter { $0.path.hasPrefix(prefix) }
        }
    }

    /// The photo shown in the live preview: the user's pick, else a landscape-format photo of the source.
    func previewPhoto(_ app: AppModel) -> PhotoRecord? {
        if let id = previewPhotoID, let p = app.photo(id), !p.isMissing { return p }
        let pool = photosForSource(app).filter { !$0.isMissing }
        return pool.first { $0.width > $0.height } ?? pool.first ?? app.photos.first { !$0.isMissing }
    }

    /// Recomputes the preview recipe (debounced). The photo is analysed once and cached; changing settings
    /// only re-runs the cheap planning step, so the preview updates without reloading the screen.
    func refreshPreview(_ app: AppModel) {
        previewTask?.cancel()
        guard let photo = previewPhoto(app) else {
            previewRecipe = nil; previewNotes = []; cardRecipes = [:]; previewLoading = false
            return
        }
        let wf = workflow, presets = app.customPresets, base = app.recipe(for: photo.id)
        let cached = analysisCache[photo.id]
        previewLoading = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let analysis: PhotoAnalysis?
            if let cached { analysis = cached } else {
                analysis = await Task.detached(priority: .userInitiated) { PhotoAnalyzer.analyze(url: photo.url, iso: photo.iso) }.value
            }
            guard !Task.isCancelled, let self else { return }
            if let analysis {
                if self.analysisCache.count > 24 { self.analysisCache.removeAll() }
                self.analysisCache[photo.id] = analysis
            }
            let planned = BatchPlanner.recipe(workflow: wf, analysis: analysis, base: base, customPresets: presets)
            var cards: [String: EditRecipe] = [:]
            for w in BatchWorkflow.predefined {
                cards[w.id] = BatchPlanner.recipe(workflow: w, analysis: analysis, base: base, customPresets: presets).recipe
            }
            withAnimation(DS.Motion.smooth) {
                self.previewRecipe = planned.recipe
                self.previewNotes = planned.notes
                self.cardRecipes = cards
                self.previewLoading = false
            }
        }
    }

    /// The photo currently being processed (for the live processing view).
    var currentItem: Item? { items.last { $0.status == .processing } }

    func chooseFolder(_ app: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Photos in this folder (and subfolders) will be imported if needed and processed.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = .folder(url)
        app.importItems([url])
    }

    func start(_ app: AppModel, photos override: [PhotoRecord]? = nil) {
        guard let store = app.store, !isRunning else { return }
        let photos = (override ?? photosForSource(app)).filter { !$0.isMissing }
        guard !photos.isEmpty else {
            app.alert = AppAlert(title: String(localized: "No photos to process"),
                                 message: String(localized: "Select photos in the library, choose an album or import a folder first."))
            return
        }
        items = photos.map { Item(id: $0.id, filename: $0.filename, status: .waiting) }
        positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        isRunning = true
        isPaused = false
        startedAt = Date()
        finishedAt = nil
        exportedBytes = 0
        let runner = BatchRunner(store: store)
        self.runner = runner
        let wf = workflow
        let existing = app.recipes
        let presets = app.customPresets
        let concurrency = AppSettings.batchConcurrency
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                await runner.run(photos, workflow: wf, existing: existing, customPresets: presets, concurrency: concurrency,
                                 onStart: { id in
                                     Task { @MainActor in AppModel.shared.batch.mark(id, .processing) }
                                 },
                                 onResult: { result in
                                     Task { @MainActor in AppModel.shared.batch.apply(result) }
                                 })
            }
            // Forward cancellation into the detached worker task.
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            // Let queued main-actor updates land before finishing
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.finish(app)
        }
    }

    private func mark(_ id: Int64, _ status: BatchItemStatus) {
        guard let i = positions[id] else { return }
        items[i].status = status
    }

    private func apply(_ r: BatchItemResult) {
        guard let i = positions[r.photoID] else { return }
        items[i].status = r.status
        items[i].duration = r.duration
        items[i].notes = r.notes
        items[i].exportedURL = r.exportedURL
        exportedBytes += r.exportedBytes
        AppModel.shared.applyBatchResult(r)
    }

    private func finish(_ app: AppModel) {
        for i in items.indices where items[i].status == .waiting || items[i].status == .processing {
            items[i].status = .skipped(String(localized: "Cancelled"))
        }
        isRunning = false
        isPaused = false
        finishedAt = Date()
        app.refreshVisible()
        if workflow.exportEnabled {
            app.recordExport(destination: workflow.export.destinationPath, format: workflow.export.format.displayName,
                             count: completedCount, failed: failedCount, bytes: exportedBytes, source: workflow.localizedName)
        }
        NSApp.requestUserAttention(.informationalRequest)
        app.showToast(String(localized: "Batch finished: \(completedCount) done, \(failedCount) failed"), symbol: "checkmark.seal.fill")
    }

    func pause() {
        guard let runner else { return }
        isPaused = true
        Task { await runner.gate.pause() }
    }

    func resume() {
        guard let runner else { return }
        isPaused = false
        Task { await runner.gate.resume() }
    }

    func cancel() {
        task?.cancel()
        if let runner { Task { await runner.gate.resume() } }
    }

    func retryFailed(_ app: AppModel) {
        let failedIDs = items.filter { if case .failed = $0.status { return true }; return false }.map(\.id)
        let photos = app.records(failedIDs)
        guard !photos.isEmpty else { return }
        start(app, photos: photos)
    }

    func reset() {
        guard !isRunning else { return }
        items = []
        startedAt = nil
        finishedAt = nil
    }

    var processedPhotoIDs: [Int64] {
        items.filter { if case .done = $0.status { return true }; return false }.map(\.id)
    }
}
