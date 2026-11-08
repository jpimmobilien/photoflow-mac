import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            ZStack {
                detail
                    .id(app.editorPhotoID.map { "editor-\($0)" } ?? String(describing: app.sidebar))
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            }
            .animation(DS.Motion.smooth, value: app.sidebar)
            .animation(DS.Motion.smooth, value: app.editorPhotoID)
                .toolbar { MainToolbar(showInspector: $showInspector) }
                .navigationTitle(app.sidebarTitle)
        }
        .background(AppBackground())
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                ToastView(toast: t)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $app.isDropTargeted) { providers in
            loadDroppedURLs(providers) { app.importItems($0) }
            return true
        }
        .overlay {
            if app.isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accentGradient, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .overlay(Label(String(localized: "Drop to import"), systemImage: "square.and.arrow.down").font(.title2.weight(.semibold)).padding(18).glassCapsule())
                    .allowsHitTesting(false)
            }
        }
        .alert(item: $app.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { app.trashRequest != nil }, set: { if !$0 { app.trashRequest = nil } }),
                            titleVisibility: .visible, presenting: app.trashRequest) { req in
            Button(String(localized: "Move \(req.photoIDs.count) to Trash"), role: .destructive) { app.performTrash(req.photoIDs) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { req in
            Text(String(localized: "\(req.photoIDs.count) files (\(req.totalBytes.formattedBytes)) will be moved to the macOS Trash. You can restore them from PhotoFlow's Trash or with Finder's “Put Back”."))
        }
        .sheet(item: Binding(get: { app.exportRequest.map { IDList(ids: $0) } }, set: { app.exportRequest = $0?.ids })) { list in
            ExportSheet(photoIDs: list.ids)
        }
        .sheet(item: $app.renameTarget) { p in RenameSheet(photo: p) }
        .sheet(item: $app.infoTarget) { p in PhotoInfoSheet(photo: p) }
        .sheet(item: Binding(get: { app.compareIDs.map { IDList(ids: $0) } }, set: { app.compareIDs = $0?.ids })) { list in
            ComparePhotosSheet(ids: list.ids)
        }
        .sheet(item: Binding(get: { app.newAlbumRequest.map { IDList(ids: $0) } }, set: { app.newAlbumRequest = $0?.ids })) { list in
            NewAlbumSheet(photoIDs: list.ids)
        }
        .quickLookPreview($app.quickLookURL)
        .overlay {
            if let err = app.startupError {
                EmptyStateView(symbol: "externaldrive.badge.exclamationmark", title: String(localized: "The library could not be opened"), message: err)
                    .background(.regularMaterial)
            }
        }
    }

    private var trashTitle: String {
        guard let r = app.trashRequest else { return "" }
        return r.photoIDs.count == 1 ? String(localized: "Move this photo to the Trash?") : String(localized: "Move \(r.photoIDs.count) photos to the Trash?")
    }

    @ViewBuilder
    private var detail: some View {
        if let id = app.editorPhotoID, let photo = app.photo(id) {
            EditorView(photo: photo, startInCompare: app.editorStartsInCompare)
                .id(id)
        } else {
            switch app.sidebar {
            case .overview: OverviewView()
            case .batch: BatchView(model: app.batch)
            case .duplicates: DuplicatesView(model: app.duplicates)
            case .similar: DuplicatesView(model: app.similar)
            case .exportHistory: ExportHistoryView()
            case .trash: TrashView()
            default:
                HStack(spacing: 0) {
                    LibraryView()
                    if showInspector && !app.photos.isEmpty {
                        Divider()
                        InspectorView()
                            .frame(width: 280)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
    }
}

struct IDList: Identifiable {
    var ids: [Int64]
    var id: String { ids.map(String.init).joined(separator: ",") }
}

/// Resolves file URLs from drag providers.
func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let urls = box.all
        Task { @MainActor in completion(urls) }
    }
}

final class URLBox: @unchecked Sendable {
    private var urls: [URL] = []
    private let lock = NSLock()
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var app: AppModel
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if app.editorPhotoID != nil {
                Button { app.editorPhotoID = nil } label: { Label(String(localized: "Back to Library"), systemImage: "chevron.backward") }
                    .help(String(localized: "Back to Library"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let a = app.activity {
                HStack(spacing: 8) {
                    ProgressView(value: a.total > 0 ? a.fraction : nil).progressViewStyle(.circular).controlSize(.small)
                    Text(a.total > 0 ? "\(a.title) \(a.completed)/\(a.total)" : a.title).font(.caption).monospacedDigit()
                    Button { app.cancelActivity() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(String(localized: "Stop"))
                }
                .padding(.horizontal, 8)
            }
            Button { app.showImportPanel() } label: { Label(String(localized: "Import"), systemImage: "square.and.arrow.down") }
                .help(String(localized: "Import photos or folders"))

            Menu {
                ForEach(EnhanceStrength.allCases) { s in
                    Button(s.localizedName) { app.autoEnhance(Array(app.selection), strength: s) }
                }
            } label: {
                Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars")
            } primaryAction: {
                app.autoEnhance(Array(app.selection))
            }
            .disabled(app.selection.isEmpty)
            .help(String(localized: "Analyze and improve the selected photos (click), or choose a strength"))

            Button { app.sidebar = .batch } label: { Label(String(localized: "Batch Edit"), systemImage: "square.stack.3d.up") }
                .help(String(localized: "Process many photos at once"))

            Button { app.compare(Array(app.selection)) } label: { Label(String(localized: "Compare"), systemImage: "square.split.2x1") }
                .disabled(app.selection.isEmpty)
                .help(String(localized: "Compare before/after, or two selected photos"))

            Button { app.sidebar = .duplicates } label: { Label(String(localized: "Find Duplicates"), systemImage: "square.on.square.dashed") }
                .help(String(localized: "Find duplicate and similar photos"))

            Button { app.exportRequest = Array(app.selection) } label: { Label(String(localized: "Export"), systemImage: "square.and.arrow.up") }
                .disabled(app.selection.isEmpty)
                .help(String(localized: "Export the selected photos"))

            if app.isLibraryContext && app.editorPhotoID == nil {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() } } label: {
                    Label(String(localized: "Inspector"), systemImage: "sidebar.right")
                }
                .help(String(localized: "Show or hide the inspector"))
            }
        }
    }
}
