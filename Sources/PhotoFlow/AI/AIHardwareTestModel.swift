import SwiftUI
import AppKit

/// Runs the hardware acceptance test from the app (Model Management) and remembers a pending restart check.
@MainActor
final class AIHardwareTestModel: ObservableObject {
    static let shared = AIHardwareTestModel()

    enum Mode: String {
        case check, quick, full
        var title: String {
            switch self {
            case .check: return String(localized: "Model check")
            case .quick: return String(localized: "Quick test")
            case .full: return String(localized: "Full test")
            }
        }
    }

    struct Result: Equatable {
        var passed: Bool
        var passedCount: Int
        var total: Int
        var folder: URL
        var mode: Mode
        var modelName: String
    }

    @Published private(set) var running: Mode?
    @Published private(set) var runningModel: String?
    @Published private(set) var phase = ""
    @Published private(set) var fraction = 0.0
    @Published private(set) var lastResult: Result?
    @Published private(set) var restartPending: URL?

    private var token: AICancelToken?
    private static let pendingKey = "aiAcceptanceRestartPending"

    private init() {
        if let p = UserDefaults.standard.string(forKey: Self.pendingKey), FileManager.default.fileExists(atPath: p) {
            restartPending = URL(fileURLWithPath: p)
        }
    }

    var isRunning: Bool { running != nil }

    /// Models used by the quick/full test: the active model first, then one more installed model (model switching).
    private func testModels() -> [AIModelDescriptor] {
        let store = ModelStore.shared
        var list: [AIModelDescriptor] = []
        if let a = AIStudioModel.shared.activeModel ?? store.activeDiffusionModel { list.append(a) }
        for m in store.installedDiffusionModels where !list.contains(m) && list.count < 2 { list.append(m) }
        return list
    }

    func start(_ mode: Mode, model: AIModelDescriptor? = nil) {
        guard running == nil, !AIStudioModel.shared.isBusy else { return }
        let models = model.map { [$0] } ?? testModels()
        let source = AppModel.shared.photos.first(where: { !$0.isRAW && !$0.isMissing })?.url
        var opts = AIAcceptanceTest.Options(models: models, outDir: AIAcceptanceTest.defaultOutputDir())
        switch mode {
        case .check: opts.consecutive = 2; opts.extended = false; opts.includeEditing = false
        case .quick: opts.consecutive = 10; opts.includeEditing = false
        case .full: opts.consecutive = 20; opts.includeEditing = true; opts.sourcePhoto = source
        }
        let t = AICancelToken()
        token = t
        let test = AIAcceptanceTest(options: opts, token: t)
        test.progress = { text, f in
            Task { @MainActor in
                AIHardwareTestModel.shared.phase = text
                AIHardwareTestModel.shared.fraction = f
            }
        }
        running = mode
        runningModel = models.first?.name
        phase = String(localized: "Preparing…")
        fraction = 0
        Task {
            _ = try? await DiffusionEngine.shared.perform { test.run() }
            let r = test.report
            lastResult = Result(passed: r.passed, passedCount: r.entries.filter(\.passed).count, total: r.entries.count,
                                folder: opts.outDir, mode: mode, modelName: models.first?.name ?? "–")
            if mode == .full && !t.isCancelled {
                restartPending = opts.outDir
                UserDefaults.standard.set(opts.outDir.path, forKey: Self.pendingKey)
            }
            running = nil
            runningModel = nil
            token = nil
            ModelStore.shared.objectWillChange.send()
        }
    }

    func cancel() { token?.cancel() }

    /// One generation after the app was restarted, appended to the pending full-test report.
    func runRestartCheck() {
        guard running == nil, let dir = restartPending, let model = AIStudioModel.shared.activeModel ?? ModelStore.shared.activeDiffusionModel else { return }
        running = .check
        runningModel = model.name
        phase = String(localized: "Generation after restart")
        fraction = 0.5
        Task {
            let ok = (try? await DiffusionEngine.shared.perform { AIAcceptanceTest.restartCheck(reportDir: dir, model: model) }) ?? false
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            restartPending = nil
            running = nil
            runningModel = nil
            lastResult = Result(passed: ok, passedCount: ok ? 1 : 0, total: 1, folder: dir, mode: .check, modelName: model.name)
        }
    }

    func openReport(_ folder: URL) {
        let html = folder.appendingPathComponent("index.html")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: html.path) ? html : folder)
    }

    func revealReport(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("report.md")])
    }
}
