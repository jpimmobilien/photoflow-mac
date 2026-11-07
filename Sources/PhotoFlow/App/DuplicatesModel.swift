import Foundation
import SwiftUI

/// State of the Duplicate Finder and Similar Photos screens (same engine, different sensitivity).
@MainActor
final class DuplicatesModel: ObservableObject {
    enum Kind { case duplicates, similar }
    enum Scope: Hashable { case library, selection, album(Int64) }

    let kind: Kind
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress: DuplicateEngine.Progress?
    @Published private(set) var lastReport: DuplicateEngine.Report?
    @Published private(set) var lastScan: Date?
    @Published var markedForDeletion: Set<Int64> = []
    @Published var scope: Scope = .library
    @Published var categoryFilter: SimilarityCategory?
    @Published var expandedGroup: String?
    @Published var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: settingsKey) }
    }

    private var task: Task<Void, Never>?
    private var settingsKey: String { kind == .duplicates ? SettingsKeys.duplicateSensitivity : SettingsKeys.similarSensitivity }

    init(kind: Kind) {
        self.kind = kind
        let key = kind == .duplicates ? SettingsKeys.duplicateSensitivity : SettingsKeys.similarSensitivity
        let stored = UserDefaults.standard.double(forKey: key)
        sensitivity = stored > 0 ? stored : (kind == .duplicates ? 95 : 80)
    }

    var visibleGroups: [DuplicateGroup] {
        guard let f = categoryFilter else { return groups }
        return groups.filter { $0.category == f }
    }

    var markedBytes: Int64 {
        groups.flatMap(\.members).filter { markedForDeletion.contains($0.id) }.reduce(0) { $0 + $1.photo.fileSize }
    }

    var potentialSavings: Int64 { groups.reduce(0) { $0 + $1.potentialSavings } }

    var phaseText: String {
        guard let p = progress else { return "" }
        switch p.phase {
        case .preparing: return String(localized: "Preparing…")
        case .hashingFiles: return String(localized: "Comparing file contents (\(p.completed) of \(p.total))…")
        case .analyzingImages: return String(localized: "Analyzing images (\(p.completed) of \(p.total))…")
        case .comparing: return String(localized: "Comparing photos…")
        case .grouping: return String(localized: "Grouping results…")
        }
    }

    func scan(_ app: AppModel) {
        guard let store = app.store, !isScanning else { return }
        let photos: [PhotoRecord]
        switch scope {
        case .library: photos = app.photos
        case .selection: photos = app.selectedPhotos.isEmpty ? app.photos : app.selectedPhotos
        case .album(let id): photos = app.records(app.albumMembers[id] ?? [])
        }
        var options = DuplicateEngine.Options()
        options.thresholds = AppSettings.similarityThresholds
        options.minimumScore = sensitivity
        options.includeExact = true
        options.includeVisual = true
        let edited = Set(app.recipes.keys)
        let engine = DuplicateEngine(store: store)
        isScanning = true
        progress = DuplicateEngine.Progress(phase: .preparing, completed: 0, total: photos.count)
        markedForDeletion = []
        let kind = self.kind
        let scanOptions = options
        task = Task {
            do {
                let work = Task.detached(priority: .userInitiated) {
                    try await engine.scan(photos: photos, edited: edited, options: scanOptions) { p in
                        Task { @MainActor in
                            let m = kind == .duplicates ? AppModel.shared.duplicates : AppModel.shared.similar
                            m.progress = p
                        }
                    }
                }
                let report = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self.groups = report.groups
                self.lastReport = report
                self.lastScan = Date()
            } catch is CancellationError {
                // keep previous results
            } catch {
                app.alert = AppAlert(title: String(localized: "The scan failed"), message: error.localizedDescription)
            }
            self.isScanning = false
            self.progress = nil
        }
    }

    func cancel() { task?.cancel() }

    // MARK: - Review actions (selection only – never deletes on its own)

    func toggleMark(_ id: Int64) {
        if markedForDeletion.contains(id) { markedForDeletion.remove(id) } else { markedForDeletion.insert(id) }
    }

    func keepOnly(_ id: Int64, in group: DuplicateGroup) {
        for m in group.members { if m.id == id { markedForDeletion.remove(m.id) } else { markedForDeletion.insert(m.id) } }
    }

    func keepAll(_ group: DuplicateGroup) {
        for m in group.members { markedForDeletion.remove(m.id) }
    }

    func selectRecommended(in group: DuplicateGroup? = nil) {
        let target = group.map { [$0] } ?? visibleGroups
        for g in target {
            for m in g.members {
                if m.isRecommended { markedForDeletion.remove(m.id) } else { markedForDeletion.insert(m.id) }
            }
        }
    }

    func clearMarks() { markedForDeletion = [] }

    func trashMarked(_ app: AppModel) {
        // Safety: never allow every photo of a group to be deleted in one go.
        var ids = Array(markedForDeletion)
        for g in groups where g.members.allSatisfy({ markedForDeletion.contains($0.id) }) {
            ids.removeAll { $0 == g.recommendedID }
        }
        app.requestTrash(ids)
    }

    var groupsWithEverythingMarked: Int {
        groups.filter { g in g.members.allSatisfy { markedForDeletion.contains($0.id) } }.count
    }

    /// Called after photos were trashed/removed elsewhere.
    func removePhotos(_ ids: Set<Int64>) {
        guard !ids.isEmpty, !groups.isEmpty else { return }
        markedForDeletion.subtract(ids)
        groups = groups.compactMap { g in
            var g = g
            g.members.removeAll { ids.contains($0.id) }
            guard g.members.count > 1 else { return nil }
            if !g.members.contains(where: \.isRecommended), let first = g.members.first {
                g.recommendedID = first.id
                g.members[0].isRecommended = true
            }
            return g
        }
    }
}
