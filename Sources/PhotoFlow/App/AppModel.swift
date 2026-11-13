import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case overview, allPhotos, recentImports, favorites, recentlyEdited
    case albums, album(Int64)
    case batch, duplicates, similar, exportHistory, trash
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case captureDate, importDate, name, size, resolution
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .captureDate: return String(localized: "Date Taken")
        case .importDate: return String(localized: "Date Imported")
        case .name: return String(localized: "File Name")
        case .size: return String(localized: "File Size")
        case .resolution: return String(localized: "Resolution")
        }
    }
}

enum EditFilter: String, CaseIterable, Identifiable {
    case all, edited, unedited
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return String(localized: "All Photos")
        case .edited: return String(localized: "Edited")
        case .unedited: return String(localized: "Not Edited")
        }
    }
}

enum LibraryViewMode: String { case mosaic, grid, compact, list }

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String = "checkmark.circle.fill"
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct TrashRequest: Identifiable {
    let id = UUID()
    var photoIDs: [Int64]
    var totalBytes: Int64
}

/// Background activity shown in the toolbar (import, enhancement, export …).
struct ActivityStatus: Equatable {
    var title: String
    var completed: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// Snapshot stored with each trashed photo so restoring brings back edits, favourites and albums.
struct TrashSnapshot: Codable {
    var recipe: EditRecipe?
    var favorite: Bool
    var albumIDs: [Int64]
}

/// Central app state (MainActor). Heavy work always runs off the main thread.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: LibraryStore?
    let startupError: String?

    // Library data
    @Published private(set) var photos: [PhotoRecord] = []
    @Published private(set) var recipes: [Int64: EditRecipe] = [:]
    @Published private(set) var albums: [Album] = []
    @Published private(set) var albumMembers: [Int64: [Int64]] = [:]
    @Published private(set) var trashEntries: [TrashEntry] = []
    @Published private(set) var exportHistory: [ExportHistoryEntry] = []
    @Published private(set) var customPresets: [Preset] = []
    @Published private(set) var visiblePhotos: [PhotoRecord] = []
    private var index: [Int64: Int] = [:]

    // Navigation & presentation
    @Published var sidebar: SidebarItem = .overview { didSet { if oldValue != sidebar { editorPhotoID = nil; viewerPhotoID = nil; refreshVisible() } } }
    @Published var selection: Set<Int64> = []
    @Published var lastClicked: Int64?
    @Published var searchText = "" { didSet { refreshVisible() } }
    @Published var sort: LibrarySort = .captureDate { didSet { refreshVisible() } }
    @Published var sortAscending = false { didSet { refreshVisible() } }
    @Published var formatFilter: String? { didSet { refreshVisible() } }
    @Published var editFilter: EditFilter = .all { didSet { refreshVisible() } }
    @Published var viewModeRaw: String = UserDefaults.standard.string(forKey: "libraryViewMode") ?? LibraryViewMode.mosaic.rawValue {
        didSet { UserDefaults.standard.set(viewModeRaw, forKey: "libraryViewMode") }
    }
    @Published var thumbnailSize: Double = UserDefaults.standard.object(forKey: "thumbnailSize") as? Double ?? 170 {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize") }
    }
    @Published var editorPhotoID: Int64?
    @Published var sidebarVisible: Bool = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }
    @Published var inspectorVisible: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? false {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: "showInspector") }
    }
    /// Full-size photo viewer (detail view with inspector) – opened by double-click / Space.
    @Published var viewerPhotoID: Int64?
    /// Where the opened thumbnail sits on screen (in the "stage" coordinate space) – the viewer zooms from/to it.
    @Published var viewerSourceRect: CGRect?
    /// IDs of photos that arrived with the latest import – the grid reveals them with a staggered animation.
    @Published var freshlyImported: Set<Int64> = []
    @Published var editorStartsInCompare = false

    // Feedback
    @Published var activity: ActivityStatus?
    @Published var toast: Toast?
    @Published var alert: AppAlert?
    @Published var trashRequest: TrashRequest?
    @Published var exportRequest: [Int64]?
    @Published var renameTarget: PhotoRecord?
    @Published var infoTarget: PhotoRecord?
    @Published var compareIDs: [Int64]?
    @Published var quickLookURL: URL?
    @Published var newAlbumRequest: [Int64]?
    @Published var isDropTargeted = false
    /// The editor currently on screen (receives Undo/Redo from the Edit menu).
    weak var activeEditor: EditorModel?

    let batch: BatchModel
    let duplicates: DuplicatesModel
    let similar: DuplicatesModel

    private var activityTask: Task<Void, Never>?

    var viewMode: LibraryViewMode {
        get { LibraryViewMode(rawValue: viewModeRaw) ?? .mosaic }
        set { viewModeRaw = newValue.rawValue }
    }

    private init() {
        AppSettings.registerDefaults()
        var s: LibraryStore?
        var err: String?
        do { s = try LibraryStore() } catch { err = error.localizedDescription }
        store = s
        startupError = err
        batch = BatchModel()
        duplicates = DuplicatesModel(kind: .duplicates)
        similar = DuplicatesModel(kind: .similar)
        reloadAll()
        if UserDefaults.standard.bool(forKey: SettingsKeys.validateOnLaunch) { validateLibrary() }
    }

    // MARK: - Loading

    func reloadAll() {
        guard let store else { return }
        do {
            photos = try store.allPhotos()
            rebuildIndex()
            let edited = photos.filter(\.isEdited).map(\.id)
            recipes = try store.recipes(for: edited)
            reloadAlbums()
            trashEntries = try store.trashEntries()
            exportHistory = try store.exportHistory()
            customPresets = try store.customPresets()
        } catch {
            alert = AppAlert(title: String(localized: "The library could not be loaded"), message: error.localizedDescription)
        }
        refreshVisible()
    }

    func reloadAlbums() {
        guard let store else { return }
        albums = (try? store.albums()) ?? []
        var members: [Int64: [Int64]] = [:]
        for a in albums { members[a.id] = (try? store.photoIDs(inAlbum: a.id)) ?? [] }
        albumMembers = members
    }

    private func rebuildIndex() {
        index = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
    }

    func photo(_ id: Int64) -> PhotoRecord? { index[id].map { photos[$0] } }

    func records(_ ids: some Sequence<Int64>) -> [PhotoRecord] { ids.compactMap { photo($0) } }

    var selectedPhotos: [PhotoRecord] { visiblePhotos.filter { selection.contains($0.id) } }

    // MARK: - Filtering & sorting

    func refreshVisible() {
        var list: [PhotoRecord]
        let now = Date()
        switch sidebar {
        case .recentImports:
            list = photos.filter { now.timeIntervalSince($0.importedAt) < 30 * 86400 }
        case .favorites:
            list = photos.filter(\.isFavorite)
        case .recentlyEdited:
            list = photos.filter { ($0.editedAt.map { now.timeIntervalSince($0) } ?? .infinity) < 30 * 86400 }
        case .album(let id):
            let ids = albumMembers[id] ?? []
            list = ids.compactMap { photo($0) }
        default:
            list = photos
        }
        if let f = formatFilter { list = list.filter { $0.formatName == f } }
        switch editFilter {
        case .all: break
        case .edited: list = list.filter(\.isEdited)
        case .unedited: list = list.filter { !$0.isEdited }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.filename.localizedCaseInsensitiveContains(q) || ($0.cameraDescription?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        let asc = sortAscending
        switch sidebar {
        case .recentImports: list.sort { $0.importedAt > $1.importedAt }
        case .recentlyEdited: list.sort { ($0.editedAt ?? .distantPast) > ($1.editedAt ?? .distantPast) }
        default:
            switch sort {
            case .captureDate: list.sort { asc ? $0.displayDate < $1.displayDate : $0.displayDate > $1.displayDate }
            case .importDate: list.sort { asc ? $0.importedAt < $1.importedAt : $0.importedAt > $1.importedAt }
            case .name: list.sort { asc ? $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
                                        : $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
            case .size: list.sort { asc ? $0.fileSize < $1.fileSize : $0.fileSize > $1.fileSize }
            case .resolution: list.sort { asc ? $0.width * $0.height < $1.width * $1.height : $0.width * $0.height > $1.width * $1.height }
            }
        }
        visiblePhotos = list
        selection = selection.filter { id in list.contains { $0.id == id } }
    }

    var availableFormats: [String] { Array(Set(photos.map(\.formatName))).sorted() }

    var sidebarTitle: String {
        switch sidebar {
        case .overview: return String(localized: "Overview")
        case .allPhotos: return String(localized: "All Photos")
        case .recentImports: return String(localized: "Recent Imports")
        case .favorites: return String(localized: "Favorites")
        case .recentlyEdited: return String(localized: "Recently Edited")
        case .albums: return String(localized: "My Albums")
        case .album(let id): return albums.first { $0.id == id }?.name ?? String(localized: "Album")
        case .batch: return String(localized: "Batch Processing")
        case .duplicates: return String(localized: "Duplicate Finder")
        case .similar: return String(localized: "Similar Photos")
        case .exportHistory: return String(localized: "Export History")
        case .trash: return String(localized: "Trash")
        }
    }

    var isLibraryContext: Bool {
        switch sidebar {
        case .allPhotos, .recentImports, .favorites, .recentlyEdited, .album: return true
        default: return false
        }
    }

    // MARK: - Selection (grid click handling)

    func click(_ id: Int64) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            lastClicked = id
        } else if flags.contains(.shift), let anchor = lastClicked,
                  let a = visiblePhotos.firstIndex(where: { $0.id == anchor }),
                  let b = visiblePhotos.firstIndex(where: { $0.id == id }) {
            let range = min(a, b) ... max(a, b)
            selection.formUnion(visiblePhotos[range].map(\.id))
        } else {
            selection = [id]
            lastClicked = id
        }
    }

    func selectAll() { selection = Set(visiblePhotos.map(\.id)) }

    /// IDs an action should apply to: the right-clicked photo plus the selection if it belongs to it.
    func targetIDs(for clicked: Int64?) -> [Int64] {
        if let c = clicked, !selection.contains(c) { return [c] }
        return visiblePhotos.filter { selection.contains($0.id) }.map(\.id)
    }

    // MARK: - Import

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder, .rawImage]
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose photos or folders to add to PhotoFlow. Your originals stay where they are.")
        if panel.runModal() == .OK { importItems(panel.urls) }
    }

    func importItems(_ urls: [URL]) {
        guard let store, !urls.isEmpty else { return }
        let service = ImportService(store: store)
        activity = ActivityStatus(title: String(localized: "Importing…"), completed: 0, total: 0)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await service.importItems(urls) { p in
                        Task { @MainActor in
                            AppModel.shared.activity = ActivityStatus(title: String(localized: "Importing…"), completed: p.scanned, total: p.total)
                        }
                    }
                }.value
                freshlyImported = Set(result.imported.map(\.id))
                photos.append(contentsOf: result.imported)
                rebuildIndex()
                refreshVisible()
                activity = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    AppModel.shared.freshlyImported = []
                }
                var msg = String(localized: "Imported \(result.imported.count) photos")
                if result.duplicatesSkipped > 0 { msg += " · " + String(localized: "\(result.duplicatesSkipped) already in library") }
                if !result.unreadable.isEmpty { msg += " · " + String(localized: "\(result.unreadable.count) unreadable") }
                showToast(msg, symbol: "square.and.arrow.down.fill")
            } catch {
                activity = nil
                alert = AppAlert(title: String(localized: "Import failed"), message: error.localizedDescription)
            }
        }
    }

    // MARK: - Library validation (moved / renamed / missing files)

    func validateLibrary() {
        guard let store else { return }
        let snapshot = photos
        Task {
            let outcome = await Task.detached(priority: .utility) { LibraryValidator.validate(snapshot) }.value
            for r in outcome.relocated { try? store.updateLocation(id: r.id, path: r.path, bookmark: MetadataReader.bookmark(for: URL(fileURLWithPath: r.path))) }
            try? store.setMissing(outcome.missing, missing: true)
            try? store.setMissing(outcome.found, missing: false)
            for id in outcome.changed {
                if let p = photo(id), let rec = MetadataReader.record(for: p.url) {
                    try? store.updateFileInfo(id: id, size: rec.fileSize, modified: rec.fileModified, width: rec.width, height: rec.height)
                }
            }
            if !outcome.relocated.isEmpty || !outcome.missing.isEmpty || !outcome.found.isEmpty || !outcome.changed.isEmpty {
                photos = (try? store.allPhotos()) ?? photos
                rebuildIndex()
                refreshVisible()
            }
            if !outcome.missing.isEmpty {
                showToast(String(localized: "\(outcome.missing.count) originals could not be found"), symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func locate(_ photo: PhotoRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .rawImage]
        panel.message = String(localized: "Locate the original of “\(photo.filename)”")
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        try? store.updateLocation(id: photo.id, path: url.path, bookmark: MetadataReader.bookmark(for: url))
        reloadAll()
    }

    // MARK: - Favorites & albums

    func toggleFavorite(_ ids: [Int64]) {
        guard let store, !ids.isEmpty else { return }
        let newValue = !ids.allSatisfy { photo($0)?.isFavorite ?? false }
        try? store.setFavorite(ids, favorite: newValue)
        for id in ids { if let i = index[id] { photos[i].isFavorite = newValue } }
        refreshVisible()
    }

    func createAlbum(named name: String, with ids: [Int64] = []) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = try? store.createAlbum(name: trimmed) else { return }
        if !ids.isEmpty { try? store.add(ids, toAlbum: id) }
        reloadAlbums()
        sidebar = .album(id)
    }

    func renameAlbum(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? store?.renameAlbum(id: id, name: trimmed)
        reloadAlbums()
    }

    func deleteAlbum(_ id: Int64) {
        try? store?.deleteAlbum(id: id)
        if sidebar == .album(id) { sidebar = .allPhotos }
        reloadAlbums()
        showToast(String(localized: "Album deleted – the photos remain in your library"), symbol: "rectangle.stack.badge.minus")
    }

    func add(_ ids: [Int64], toAlbum albumID: Int64) {
        guard !ids.isEmpty else { return }
        try? store?.add(ids, toAlbum: albumID)
        reloadAlbums()
        refreshVisible()
        let name = albums.first { $0.id == albumID }?.name ?? ""
        showToast(String(localized: "Added \(ids.count) photos to “\(name)”"), symbol: "rectangle.stack.badge.plus")
    }

    /// "Move to Album": when viewing an album, the photos leave the current album.
    func move(_ ids: [Int64], toAlbum albumID: Int64) {
        if case .album(let current) = sidebar, current != albumID { try? store?.remove(ids, fromAlbum: current) }
        add(ids, toAlbum: albumID)
    }

    func removeFromCurrentAlbum(_ ids: [Int64]) {
        guard case .album(let id) = sidebar else { return }
        try? store?.remove(ids, fromAlbum: id)
        reloadAlbums()
        refreshVisible()
    }

    // MARK: - Edits

    func recipe(for id: Int64) -> EditRecipe? { recipes[id] }

    func saveRecipe(_ recipe: EditRecipe, for id: Int64) {
        guard let store else { return }
        do {
            let editedAt = try store.saveRecipe(recipe, for: id)
            if recipe.isIdentity { recipes.removeValue(forKey: id) } else { recipes[id] = recipe }
            if let i = index[id] { photos[i].editedAt = editedAt }
            refreshVisibleIfEditFilterActive()
        } catch {
            alert = AppAlert(title: String(localized: "Edits could not be saved"), message: error.localizedDescription)
        }
    }

    /// Applies results produced by the batch engine (already persisted).
    func applyBatchResult(_ r: BatchItemResult) {
        guard let recipe = r.recipe, r.editedAt != nil || recipe.isIdentity else { return }
        if recipe.isIdentity { recipes.removeValue(forKey: r.photoID) } else { recipes[r.photoID] = recipe }
        if let i = index[r.photoID] { photos[i].editedAt = r.editedAt }
    }

    private func refreshVisibleIfEditFilterActive() {
        if editFilter != .all || sidebar == .recentlyEdited { refreshVisible() }
        else {
            // keep visiblePhotos records in sync (edit badges)
            visiblePhotos = visiblePhotos.map { p in index[p.id].map { photos[$0] } ?? p }
        }
    }

    func revertToOriginal(_ ids: [Int64]) {
        for id in ids { saveRecipe(.identity, for: id) }
        refreshVisible()
        showToast(String(localized: "Restored \(ids.count) originals"), symbol: "arrow.uturn.backward.circle.fill")
    }

    func copyAdjustments(from id: Int64) {
        guard let r = recipes[id] else { return }
        let data = r.adjustmentsOnly.encoded()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: NSPasteboard.PasteboardType("de.photoflow.adjustments"))
        showToast(String(localized: "Adjustments copied"), symbol: "doc.on.doc.fill")
    }

    func pasteAdjustments(to ids: [Int64]) {
        guard let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("de.photoflow.adjustments")),
              let adj = EditRecipe.decode(data) else { return }
        for id in ids {
            var r = adj
            if let existing = recipes[id] { r.adoptGeometry(from: existing) }
            saveRecipe(r, for: id)
        }
        refreshVisible()
    }

    var canPasteAdjustments: Bool {
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("de.photoflow.adjustments")) != nil
    }

    // MARK: - One-click Auto Enhance (single photo or collections)

    func autoEnhance(_ ids: [Int64], strength: EnhanceStrength? = nil) {
        guard let store, !ids.isEmpty else { return }
        let targets = records(ids).filter { !$0.isMissing }
        guard !targets.isEmpty else { return }
        var wf = BatchWorkflow(id: "quick-enhance", name: "Auto Enhance", symbol: "wand.and.stars", summary: "")
        wf.strength = strength ?? AppSettings.defaultStrength
        wf.options = .enhanceOnly
        wf.keepExistingEdits = true
        wf.saveToLibrary = true
        let runner = BatchRunner(store: store)
        let existing = recipes
        let presets = customPresets
        let total = targets.count
        activity = ActivityStatus(title: String(localized: "Enhancing…"), completed: 0, total: total)
        activityTask?.cancel()
        let counter = Counter()
        let workflow = wf
        activityTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                await runner.run(targets, workflow: workflow, existing: existing, customPresets: presets,
                                 concurrency: AppSettings.batchConcurrency, onStart: { _ in }) { result in
                    Task { @MainActor in
                        let model = AppModel.shared
                        model.applyBatchResult(result)
                        let done = counter.increment()
                        if !Task.isCancelled && model.activityTask != nil {
                            model.activity = ActivityStatus(title: String(localized: "Enhancing…"), completed: done, total: total)
                        }
                    }
                }
            }
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            let cancelled = Task.isCancelled
            await MainActor.run {
                self.activity = nil
                self.refreshVisible()
                guard !cancelled else { return }
                self.showToast(total == 1 ? String(localized: "Photo enhanced") : String(localized: "\(total) photos enhanced"),
                               symbol: "wand.and.stars")
            }
        }
    }

    func cancelActivity() {
        activityTask?.cancel()
        activityTask = nil
        activity = nil
    }

    // MARK: - Trash & file management

    func requestTrash(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let mode = UserDefaults.standard.string(forKey: SettingsKeys.confirmDeletion) ?? "always"
        let large = UserDefaults.standard.integer(forKey: SettingsKeys.largeDeletionCount)
        let bytes = records(ids).reduce(Int64(0)) { $0 + $1.fileSize }
        if mode == "never" || (mode == "large" && ids.count < max(2, large)) {
            performTrash(ids)
        } else {
            trashRequest = TrashRequest(photoIDs: ids, totalBytes: bytes)
        }
    }

    func performTrash(_ ids: [Int64]) {
        guard let store else { return }
        let targets = records(ids)
        let snapshots: [Int64: Data] = Dictionary(uniqueKeysWithValues: targets.map { p in
            let albumsOf = albumMembers.filter { $0.value.contains(p.id) }.map(\.key)
            let snap = TrashSnapshot(recipe: recipes[p.id], favorite: p.isFavorite, albumIDs: albumsOf)
            return (p.id, (try? JSONEncoder().encode(snap)) ?? Data())
        })
        activity = ActivityStatus(title: String(localized: "Moving to Trash…"), completed: 0, total: targets.count)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { FileOperations.moveToTrash(targets) }.value
            for t in outcome.trashed {
                try? store.logTrash(photoID: t.photoID, originalPath: t.originalPath, trashPath: t.trashPath,
                                    fileSize: t.size, snapshot: snapshots[t.photoID])
            }
            let removed = outcome.trashed.map(\.photoID)
            try? store.removePhotos(removed)
            removeFromMemory(removed)
            trashEntries = (try? store.trashEntries()) ?? []
            activity = nil
            if !removed.isEmpty {
                showToast(String(localized: "Moved \(removed.count) photos to the Trash"), symbol: "trash.fill")
            }
            if !outcome.failures.isEmpty {
                let details = outcome.failures.prefix(6).map { "• \(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n")
                let more = outcome.failures.count > 6 ? "\n" + String(localized: "…and \(outcome.failures.count - 6) more") : ""
                alert = AppAlert(title: String(localized: "\(outcome.failures.count) photos could not be moved to the Trash"),
                                 message: details + more)
            }
        }
    }

    private func removeFromMemory(_ ids: [Int64]) {
        let set = Set(ids)
        photos.removeAll { set.contains($0.id) }
        for id in ids { recipes.removeValue(forKey: id) }
        selection.subtract(set)
        rebuildIndex()
        reloadAlbums()
        refreshVisible()
        duplicates.removePhotos(set)
        similar.removePhotos(set)
        if let e = editorPhotoID, set.contains(e) { editorPhotoID = nil }
    }

    func removeFromLibrary(_ ids: [Int64]) {
        try? store?.removePhotos(ids)
        removeFromMemory(ids)
        showToast(String(localized: "Removed \(ids.count) photos from the library (files kept)"), symbol: "minus.circle.fill")
    }

    func restore(_ entries: [TrashEntry]) {
        guard let store else { return }
        var restored = 0
        var errors: [String] = []
        for e in entries {
            do {
                let url = try FileOperations.restore(e)
                if var rec = MetadataReader.record(for: url) {
                    rec.importedAt = Date()
                    if let inserted = try store.insert([rec]).first {
                        if let data = try? store.trashSnapshot(id: e.id), let snap = try? JSONDecoder().decode(TrashSnapshot.self, from: data) {
                            if let r = snap.recipe { _ = try? store.saveRecipe(r, for: inserted.id) }
                            if snap.favorite { try? store.setFavorite([inserted.id], favorite: true) }
                            for a in snap.albumIDs where albums.contains(where: { $0.id == a }) { try? store.add([inserted.id], toAlbum: a) }
                        }
                    }
                }
                try store.markRestored(e.id)
                restored += 1
            } catch {
                errors.append("• \(e.filename): \(error.localizedDescription)")
            }
        }
        reloadAll()
        if restored > 0 { showToast(String(localized: "Restored \(restored) photos"), symbol: "arrow.uturn.backward.circle.fill") }
        if !errors.isEmpty { alert = AppAlert(title: String(localized: "Some photos could not be restored"), message: errors.joined(separator: "\n")) }
    }

    func forgetTrashEntries(_ entries: [TrashEntry]) {
        for e in entries { try? store?.forgetTrashEntry(e.id) }
        trashEntries = (try? store?.trashEntries()) ?? []
    }

    func rename(_ photo: PhotoRecord, to name: String) {
        do {
            let url = try FileOperations.rename(photo, to: name)
            try store?.updateLocation(id: photo.id, path: url.path, bookmark: MetadataReader.bookmark(for: url))
            reloadAll()
        } catch {
            alert = AppAlert(title: String(localized: "Rename failed"), message: error.localizedDescription)
        }
    }

    func moveOrCopyFiles(_ ids: [Int64], copy: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = copy ? String(localized: "Copy Here") : String(localized: "Move Here")
        guard panel.runModal() == .OK, let folder = panel.url, let store else { return }
        let targets = records(ids)
        let result = FileOperations.transfer(targets, to: folder, copy: copy)
        if copy {
            importItems(result.done.map { $0.1 })
        } else {
            for (id, url) in result.done { try? store.updateLocation(id: id, path: url.path, bookmark: MetadataReader.bookmark(for: url)) }
            reloadAll()
            showToast(String(localized: "Moved \(result.done.count) files"), symbol: "folder.fill")
        }
        if !result.failures.isEmpty {
            alert = AppAlert(title: String(localized: "Some files could not be transferred"),
                             message: result.failures.map { "• \(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n"))
        }
    }

    func reveal(_ ids: [Int64]) { FileOperations.revealInFinder(records(ids).map(\.url)) }

    func openInDefaultApp(_ ids: [Int64]) { for p in records(ids) { NSWorkspace.shared.open(p.url) } }

    func quickLook(_ id: Int64?) { quickLookURL = id.flatMap { photo($0)?.url } }

    func openEditor(_ id: Int64, compare: Bool = false) {
        editorStartsInCompare = compare
        viewerPhotoID = nil
        editorPhotoID = id
        selection = [id]
    }

    /// Opens the full-size viewer for `id`, zooming from `rect` (the thumbnail's frame) when known.
    func openViewer(_ id: Int64, from rect: CGRect? = nil) {
        viewerSourceRect = rect
        selection = [id]
        lastClicked = id
        viewerPhotoID = id
    }

    /// The photo the dock and the viewer refer to: the last clicked photo of the selection.
    var currentPhoto: PhotoRecord? {
        if let id = lastClicked, selection.contains(id), let p = photo(id) { return p }
        return selectedPhotos.first ?? selection.first.flatMap { photo($0) }
    }

    /// Moves the single selection through the visible photos (dock ◀ ▶, scrubbing).
    func stepSelection(_ delta: Int) {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        let i = currentPhoto.flatMap { c in list.firstIndex { $0.id == c.id } } ?? (delta > 0 ? -1 : list.count)
        selectIndex(i + delta)
    }

    func selectIndex(_ index: Int) {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        let n = min(max(index, 0), list.count - 1)
        selection = [list[n].id]
        lastClicked = list[n].id
    }

    /// Opens a random photo of the current page in the viewer ("shuffle").
    func showRandomPhoto() {
        guard let p = visiblePhotos.randomElement() else { return }
        openViewer(p.id)
    }

    /// The photo whose colours light the interface (effect 1 – Dynamic Ambient Light).
    var ambientPhoto: PhotoRecord? {
        if let id = editorPhotoID ?? viewerPhotoID, let p = photo(id) { return p }
        if let id = lastClicked, selection.contains(id), let p = photo(id) { return p }
        if let id = selection.first, let p = photo(id) { return p }
        if sidebar == .overview || sidebar == .batch { return highlightPhotos.first }
        return nil
    }

    /// A handful of recent, well-sized photos for the Overview mosaic (cheap: looks only at the newest imports).
    var highlightPhotos: [PhotoRecord] {
        let recent = photos.suffix(80).filter { !$0.isMissing }
        let ranked = recent.sorted { ($0.importedAt, $0.megapixels) > ($1.importedAt, $1.megapixels) }
        let landscape = ranked.filter { $0.width >= $0.height }
        return Array((landscape + ranked.filter { $0.width < $0.height }).prefix(7))
    }

    func compare(_ ids: [Int64]) {
        if ids.count >= 2 { compareIDs = Array(ids.prefix(2)) }
        else if let id = ids.first { openEditor(id, compare: true) }
    }

    // MARK: - Export

    func recordExport(destination: String, format: String, count: Int, failed: Int, bytes: Int64, source: String) {
        try? store?.logExport(destination: destination, format: format, count: count, failed: failed, bytes: bytes, source: source)
        exportHistory = (try? store?.exportHistory()) ?? []
    }

    func runExport(_ ids: [Int64], options: ExportOptions, source: String) {
        guard let store, !ids.isEmpty else { return }
        let targets = records(ids)
        var wf = BatchWorkflow(id: "export", name: "Export", symbol: "square.and.arrow.up", summary: "")
        wf.enhance = false
        wf.keepExistingEdits = true
        wf.saveToLibrary = false
        wf.exportEnabled = true
        wf.export = options
        let existing = recipes
        let runner = BatchRunner(store: store)
        let total = targets.count
        let counter = Counter()
        let stats = ExportTally()
        activity = ActivityStatus(title: String(localized: "Exporting…"), completed: 0, total: total)
        let workflow = wf
        activityTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                await runner.run(targets, workflow: workflow, existing: existing, customPresets: [],
                                 concurrency: AppSettings.batchConcurrency, onStart: { _ in }) { result in
                    stats.add(result)
                    Task { @MainActor in
                        let done = counter.increment()
                        if AppModel.shared.activityTask != nil {
                            AppModel.shared.activity = ActivityStatus(title: String(localized: "Exporting…"), completed: done, total: total)
                        }
                    }
                }
            }
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            let s = stats.snapshot()
            await MainActor.run {
                self.activity = nil
                self.recordExport(destination: options.destinationPath, format: options.format.displayName, count: s.ok, failed: s.failed,
                                  bytes: s.bytes, source: source)
                if s.failed > 0 {
                    self.alert = AppAlert(title: String(localized: "\(s.failed) photos could not be exported"), message: s.errors.prefix(8).joined(separator: "\n"))
                }
                self.showToast(String(localized: "Exported \(s.ok) photos"), symbol: "square.and.arrow.up.fill")
                if s.ok > 0 { NSWorkspace.shared.activateFileViewerSelecting(s.urls.prefix(1).map { $0 }) }
            }
        }
    }

    // MARK: - Presets

    func saveCustomPreset(name: String, from recipe: EditRecipe) {
        let p = Preset(id: UUID().uuidString, name: name, recipe: recipe.adjustmentsOnly, adaptive: false, isBuiltIn: false, symbol: "slider.horizontal.3")
        try? store?.savePreset(p)
        customPresets = (try? store?.customPresets()) ?? customPresets
        showToast(String(localized: "Preset “\(name)” saved"), symbol: "camera.filters")
    }

    func deleteCustomPreset(_ id: String) {
        try? store?.deletePreset(id: id)
        customPresets = (try? store?.customPresets()) ?? []
    }

    var allPresets: [Preset] { Preset.builtIn + customPresets }

    // MARK: - Feedback

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill") {
        let t = Toast(message: message, symbol: symbol)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = t }
        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if toast?.id == t.id { withAnimation(.easeOut(duration: 0.3)) { toast = nil } }
        }
    }

    // MARK: - Statistics for the overview

    var totalBytes: Int64 { photos.reduce(0) { $0 + $1.fileSize } }
    var editedCount: Int { photos.filter(\.isEdited).count }
    var favoriteCount: Int { photos.filter(\.isFavorite).count }
    var missingCount: Int { photos.filter(\.isMissing).count }
}

/// Thread-safe counter for progress callbacks.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// Thread-safe tally of export results.
final class ExportTally: @unchecked Sendable {
    struct Snapshot { var ok: Int; var failed: Int; var bytes: Int64; var errors: [String]; var urls: [URL] }
    private var s = Snapshot(ok: 0, failed: 0, bytes: 0, errors: [], urls: [])
    private let lock = NSLock()
    func add(_ r: BatchItemResult) {
        lock.lock(); defer { lock.unlock() }
        switch r.status {
        case .done:
            s.ok += 1; s.bytes += r.exportedBytes
            if let u = r.exportedURL { s.urls.append(u) }
        case .failed(let m): s.failed += 1; s.errors.append(m)
        default: break
        }
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return s }
}

extension UTType {
    /// Internal drag type carrying photo IDs (declared in Info.plist).
    static let photoFlowIDs = UTType(exportedAs: "de.photoflow.photo-ids")
}
