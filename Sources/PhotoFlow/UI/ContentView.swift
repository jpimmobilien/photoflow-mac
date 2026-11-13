import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// PhotoFlow 2.0 window: glass sidebar · content stage with floating top bar · floating inspector ·
/// floating selection bar · full-window photo viewer. The title bar is hidden; the window is dragged by the top strip.
struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @State private var keyMonitor: Any?

    static let topBarHeight: CGFloat = 52

    var body: some View {
        ZStack {
            AmbientBackground(photo: app.ambientPhoto, recipe: app.ambientPhoto.flatMap { app.recipe(for: $0.id) },
                              intensity: app.editorPhotoID != nil ? 0.6 : 1)

            HStack(spacing: 0) {
                if app.sidebarVisible && app.editorPhotoID == nil {
                    SidebarView(onCollapse: { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.sidebarVisible = false } })
                        .frame(width: 236)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                stage
            }
            .focusDepth(app.viewerPhotoID != nil || isModalOpen)

            if let id = app.viewerPhotoID, app.photo(id) != nil {
                PhotoViewer(photoID: id)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .coordinateSpace(name: "root")
        .ignoresSafeArea(.container, edges: .top)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.sidebarVisible)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.editorPhotoID)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.viewerPhotoID)
        .overlay(alignment: .bottom) { bottomLayer }
        .onDrop(of: [.fileURL], isTargeted: $app.isDropTargeted) { providers in
            loadDroppedURLs(providers) { app.importItems($0) }
            return true
        }
        .overlay { if app.isDropTargeted { DropOverlay() } }
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: app.isDropTargeted)
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
        .onAppear(perform: installKeyMonitor)
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
    }

    private var isModalOpen: Bool {
        app.exportRequest != nil || app.renameTarget != nil || app.infoTarget != nil || app.compareIDs != nil || app.newAlbumRequest != nil
    }

    private var trashTitle: String {
        guard let r = app.trashRequest else { return "" }
        return r.photoIDs.count == 1 ? String(localized: "Move this photo to the Trash?") : String(localized: "Move \(r.photoIDs.count) photos to the Trash?")
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                page
                    .id(app.editorPhotoID.map { "editor-\($0)" } ?? String(describing: app.sidebar))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: DS.Motion.reduced ? 0 : 10)).combined(with: .scale(scale: DS.Motion.reduced ? 1 : 0.99, anchor: .top)),
                        removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showsInspector {
                    InspectorView()
                        .frame(width: 300)
                        .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                        .padding(.top, Self.topBarHeight)
                        .padding([.trailing, .bottom], DS.Space.s)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(DS.Motion.adaptive(DS.Motion.page), value: app.sidebar)
            .animation(DS.Motion.adaptive(DS.Motion.smooth), value: showsInspector)

            if app.editorPhotoID == nil {
                TopBar()
                    .frame(height: Self.topBarHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsInspector: Bool {
        app.inspectorVisible && app.isLibraryContext && !app.photos.isEmpty && app.editorPhotoID == nil && !app.visiblePhotos.isEmpty
    }

    @ViewBuilder
    private var page: some View {
        if let id = app.editorPhotoID, let photo = app.photo(id) {
            EditorView(photo: photo, startInCompare: app.editorStartsInCompare)
                .id(id)
        } else {
            switch app.sidebar {
            case .overview: OverviewView()
            case .albums: AlbumsView()
            case .batch: BatchView(model: app.batch)
            case .duplicates: DuplicatesView(model: app.duplicates)
            case .similar: DuplicatesView(model: app.similar)
            case .exportHistory: ExportHistoryView()
            case .trash: TrashView()
            default: LibraryView()
            }
        }
    }

    // MARK: Bottom layer (selection bar + toast)

    private var bottomLayer: some View {
        VStack(spacing: DS.Space.s) {
            if let t = app.toast {
                ToastView(toast: t)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
            }
            if showsSelectionBar {
                SelectionBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.bottom, DS.Space.l)
        .padding(.leading, app.sidebarVisible ? 236 : 0)
        .padding(.trailing, showsInspector ? 312 : 0)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: showsSelectionBar)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.toast)
    }

    private var showsSelectionBar: Bool {
        !app.selection.isEmpty && app.isLibraryContext && app.editorPhotoID == nil && app.viewerPhotoID == nil
    }

    // MARK: Keyboard (Space opens the viewer, Esc closes it, ←/→ browse)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let app = AppModel.shared
            if event.window?.firstResponder is NSText { return event }     // typing in a text field
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty == false { return event }
            switch event.keyCode {
            case 49: // space
                if app.viewerPhotoID != nil { PhotoViewer.requestClose(); return nil }
                if app.editorPhotoID == nil, app.isLibraryContext || app.sidebar == .overview, let id = app.lastClicked ?? app.selection.first {
                    withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.openViewer(id, from: nil) }
                    return nil
                }
            case 53: // esc
                if app.viewerPhotoID != nil { PhotoViewer.requestClose(); return nil }
                if app.editorPhotoID != nil { return event }
                if !app.selection.isEmpty { app.selection = []; return nil }
            case 123, 124: // ← →
                if app.viewerPhotoID != nil { PhotoViewer.step(event.keyCode == 124 ? 1 : -1); return nil }
            default: break
            }
            return event
        }
    }
}

// MARK: - Top bar (floating, transparent – content scrolls underneath)

struct TopBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: DS.Space.xs) {
                if !app.sidebarVisible {
                    Color.clear.frame(width: 68, height: 1)   // window controls
                    Button { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.sidebarVisible = true } } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 30))
                    .glass(.floating, in: Circle())
                    .tip(String(localized: "Show Sidebar"), shortcut: "⌃⌘S")
                }
                Spacer()
                if let a = app.activity { ActivityPill(activity: a) }
                if app.isLibraryContext && !app.photos.isEmpty {
                    Button { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.inspectorVisible.toggle() } } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 30, active: app.inspectorVisible))
                    .glass(.floating, in: Circle())
                    .tip(app.inspectorVisible ? String(localized: "Hide Inspector") : String(localized: "Show Inspector"), shortcut: "⌥⌘I")
                }
                Button { app.showImportPanel() } label: { Label(String(localized: "Import"), systemImage: "plus") }
                    .prominentButton()
                    .tip(String(localized: "Import photos or folders"), shortcut: "⇧⌘I")
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, 6)
        }
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: app.activity != nil)
    }
}

/// Live status of a background job with stop button.
struct ActivityPill: View {
    var activity: ActivityStatus
    @EnvironmentObject private var app: AppModel
    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ProgressRing(fraction: activity.total > 0 ? activity.fraction : 0.25, lineWidth: 2.5)
                .frame(width: 15, height: 15)
                .rotationEffect(.degrees(activity.total > 0 ? 0 : 360))
            Text(activity.total > 0 ? "\(activity.title) \(activity.completed)/\(activity.total)" : activity.title)
                .font(DS.Font.caption).monospacedDigit().foregroundStyle(DS.Palette.textPrimary)
                .contentTransitionNumeric()
            Button { app.cancelActivity() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.textTertiary)
                .help(String(localized: "Stop"))
        }
        .padding(.horizontal, DS.Space.s).padding(.vertical, 6)
        .glass(.floating, in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: - Floating selection bar (like a mini player for the current selection)

struct SelectionBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let ids = app.targetIDs(for: nil)
        let first = ids.compactMap { app.photo($0) }.prefix(3)
        let allFavorite = !ids.isEmpty && ids.allSatisfy { app.photo($0)?.isFavorite == true }
        HStack(spacing: DS.Space.s) {
            // fanned stack of the selected photos – regroups when the selection changes
            ZStack {
                ForEach(Array(first.enumerated().reversed()), id: \.element.id) { i, p in
                    ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 96)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .rotationEffect(.degrees(Double(i) * 7))
                        .offset(x: CGFloat(i) * 6)
                }
            }
            .frame(width: 52, height: 40, alignment: .leading)
            .animation(DS.Motion.adaptive(DS.Motion.smooth), value: ids)

            VStack(alignment: .leading, spacing: 0) {
                Text(ids.count == 1 ? (app.photo(ids[0])?.filename ?? "") : String(localized: "\(ids.count) selected"))
                    .font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    .contentTransitionNumeric()
                Text(app.records(ids).reduce(Int64(0)) { $0 + $1.fileSize }.formattedBytes)
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.blue).monospacedDigit()
            }
            .frame(minWidth: 90, maxWidth: 170, alignment: .leading)

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                Button { app.toggleFavorite(ids) } label: { HeartIcon(filled: allFavorite) }
                    .buttonStyle(GlassIconButtonStyle(size: 32, tint: allFavorite ? DS.Palette.heart : nil))
                    .tip(String(localized: "Favorite"), shortcut: "⇧⌘F", edge: .top)
                if ids.count == 1 {
                    Button { app.openEditor(ids[0]) } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(GlassIconButtonStyle(size: 32))
                        .tip(String(localized: "Edit"), shortcut: "⌘↩", edge: .top)
                }
                Button { app.compare(ids) } label: { Image(systemName: "square.split.2x1") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .tip(String(localized: "Compare"), shortcut: "⌘K", edge: .top)
                Menu {
                    ForEach(app.albums) { a in Button(a.name) { app.add(ids, toAlbum: a.id) } }
                    if !app.albums.isEmpty { Divider() }
                    Button(String(localized: "New Album…")) { app.newAlbumRequest = ids }
                } label: { Image(systemName: "rectangle.stack.badge.plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 32, height: 32)
                    .tip(String(localized: "Add to Album"), edge: .top)
                Button { app.exportRequest = ids } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .tip(String(localized: "Export"), shortcut: "⇧⌘E", edge: .top)
                Button { app.requestTrash(ids) } label: { Image(systemName: "trash") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .tip(String(localized: "Move to Trash"), shortcut: "⌘⌫", edge: .top)
            }

            Button { app.autoEnhance(ids) } label: { Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars") }
                .premiumButton()
                .tip(String(localized: "Analyze and improve the selected photos"), shortcut: "⌘E", edge: .top)

            Button { withAnimation(DS.Motion.snappy) { app.selection = [] } } label: { Image(systemName: "xmark") }
                .buttonStyle(GlassIconButtonStyle(size: 26))
                .tip(String(localized: "Deselect"), shortcut: "esc", edge: .top)
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .glass(.floating, in: Capsule())
    }
}

/// Heart that fills with a soft bounce (microinteraction).
struct HeartIcon: View {
    var filled: Bool
    @State private var bump = false
    var body: some View {
        Image(systemName: filled ? "heart.fill" : "heart")
            .foregroundStyle(filled ? DS.Palette.heart : DS.Palette.textPrimary)
            .scaleEffect(bump ? 1.3 : 1)
            .onChange(of: filled) { f in
                guard f, !DS.Motion.reduced else { return }
                withAnimation(DS.Motion.celebrate) { bump = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { withAnimation(DS.Motion.smooth) { bump = false } }
            }
    }
}

/// Full-window drop target.
struct DropOverlay: View {
    var body: some View {
        ZStack {
            DS.Palette.canvas.opacity(0.55)
            RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous)
                .strokeBorder(DS.Palette.brand, style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
                .padding(14)
            VStack(spacing: DS.Space.s) {
                Illustration(kind: .welcome, size: 200)
                Text(String(localized: "Drop to import")).font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                Text(String(localized: "Photos and whole folders – originals stay where they are."))
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(DS.Space.xxl)
            .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
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
