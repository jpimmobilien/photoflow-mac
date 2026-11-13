import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// PhotoFlow 2.0 window: glass sidebar · content stage with floating top bar · floating inspector ·
/// floating selection bar · full-window photo viewer. The title bar is hidden; the window is dragged by the top strip.
struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @State private var keyMonitor: Any?

    static let topBarHeight: CGFloat = 68

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
            if showsDock {
                PhotoDock()
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.97)))
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
        .padding(.leading, app.sidebarVisible ? 236 : 0)
        .padding(.trailing, showsInspector ? 312 : 0)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: showsDock)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.toast)
    }

    /// The photo dock shows the current photo (like a "now playing" bar) or a running background job.
    private var showsDock: Bool {
        guard app.editorPhotoID == nil, app.viewerPhotoID == nil else { return false }
        let pageWithPhotos = app.isLibraryContext || app.sidebar == .overview
        return (pageWithPhotos && !app.selection.isEmpty) || (app.activity != nil && app.sidebar != .batch)
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
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .glass(.floating, in: Circle())
                    .tip(String(localized: "Show Sidebar"), shortcut: "⌃⌘S")
                }
                Spacer()
                if app.isLibraryContext && !app.photos.isEmpty {
                    Button { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.inspectorVisible.toggle() } } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 32, active: app.inspectorVisible))
                    .glass(.floating, in: Circle())
                    .tip(app.inspectorVisible ? String(localized: "Hide Inspector") : String(localized: "Show Inspector"), shortcut: "⌥⌘I")
                }
                Button { app.showImportPanel() } label: { Label(String(localized: "Import"), systemImage: "plus") }
                    .prominentButton()
                    .tip(String(localized: "Import photos or folders"), shortcut: "⇧⌘I")
            }
            .padding(.horizontal, DS.Space.m)

            // Floating glass tab bar, centred (full labels when there is room, icons only otherwise)
            ViewThatFits(in: .horizontal) {
                TabBar(compact: false).padding(.horizontal, 190)
                TabBar(compact: true).padding(.horizontal, 150)
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .padding(.top, 8)
    }
}

/// The main navigation: a floating Liquid-Glass capsule with icon + label tabs and a gliding active pill.
struct TabBar: View {
    var compact: Bool
    @EnvironmentObject private var app: AppModel
    @Namespace private var pill
    @State private var showMore = false

    struct Tab: Identifiable { var id: String; var title: String; var symbol: String; var items: [SidebarItem] }

    static var tabs: [Tab] {
        [Tab(id: "overview", title: String(localized: "Overview"), symbol: "sparkles.rectangle.stack", items: [.overview]),
         Tab(id: "photos", title: String(localized: "Photos"), symbol: "photo.on.rectangle.angled", items: [.allPhotos]),
         Tab(id: "albums", title: String(localized: "Albums"), symbol: "rectangle.stack", items: [.albums]),
         Tab(id: "favorites", title: String(localized: "Favorites"), symbol: "heart", items: [.favorites]),
         Tab(id: "batch", title: String(localized: "Batch"), symbol: "wand.and.stars", items: [.batch]),
         Tab(id: "duplicates", title: String(localized: "Duplicates"), symbol: "square.on.square", items: [.duplicates])]
    }

    static let moreItems: [(SidebarItem, String, String)] = [
        (.recentImports, "Recent Imports", "square.and.arrow.down.on.square"),
        (.recentlyEdited, "Recently Edited", "slider.horizontal.3"),
        (.similar, "Similar Photos", "square.stack.3d.down.right"),
        (.exportHistory, "Export History", "clock.arrow.circlepath"),
        (.trash, "Trash", "trash")
    ]

    private func isActive(_ t: Tab) -> Bool {
        if t.id == "albums", case .album = app.sidebar { return true }
        return t.items.contains(app.sidebar)
    }

    private var moreActive: Bool { Self.moreItems.contains { $0.0 == app.sidebar } }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs) { t in
                tabButton(title: t.title, symbol: t.symbol, active: isActive(t)) {
                    withAnimation(DS.Motion.adaptive(DS.Motion.page)) { app.sidebar = t.items[0] }
                }
            }
            tabButton(title: moreActive ? moreTitle : String(localized: "More"), symbol: moreActive ? moreSymbol : "ellipsis.circle", active: moreActive) {
                showMore.toggle()
            }
            .popover(isPresented: $showMore, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.moreItems.indices, id: \.self) { i in
                        let item = Self.moreItems[i]
                        InspectorAction(title: String(localized: String.LocalizationValue(item.1)), symbol: item.2) {
                            showMore = false
                            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { app.sidebar = item.0 }
                        }
                    }
                }
                .padding(DS.Space.xs)
                .frame(width: 240)
            }
        }
        .padding(4)
        .glass(.floating, in: Capsule())
        .fixedSize()
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: app.sidebar)
    }

    private var moreTitle: String {
        Self.moreItems.first { $0.0 == app.sidebar }.map { String(localized: String.LocalizationValue($0.1)) } ?? String(localized: "More")
    }
    private var moreSymbol: String { Self.moreItems.first { $0.0 == app.sidebar }?.2 ?? "ellipsis.circle" }

    private func tabButton(title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        TabBarButton(title: title, symbol: symbol, active: active, compact: compact, pill: pill, action: action)
    }
}

struct TabBarButton: View {
    var title: String
    var symbol: String
    var active: Bool
    var compact: Bool
    var pill: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: active && !symbol.hasSuffix(".fill") && symbol == "heart" ? "heart.fill" : symbol)
                    .font(.system(size: 15, weight: active ? .semibold : .regular))
                    .frame(height: 18)
                if !compact {
                    Text(title).font(.system(size: 11, weight: active ? .semibold : .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(active ? DS.Palette.blue : DS.Palette.textPrimary.opacity(0.85))
            .frame(minWidth: compact ? 40 : 74)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 9 : 7)
            .background {
                if active {
                    Capsule().fill(DS.Palette.blue.opacity(0.16))
                        .overlay(Capsule().strokeBorder(DS.Palette.blue.opacity(0.22), lineWidth: 0.6))
                        .matchedGeometryEffect(id: "tab-pill", in: pill)
                } else if hovering {
                    Capsule().fill(DS.Palette.hover)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .onHover { h in withAnimation(DS.Motion.quick) { hovering = h } }
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
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

// MARK: - Photo dock (the "now playing" bar of PhotoFlow)

/// Floating glass dock at the bottom: the current photo with title, accent subtitle and details, a position
/// bar that scrubs through the page, browse controls and the main actions. Shows background jobs as well.
struct PhotoDock: View {
    @EnvironmentObject private var app: AppModel
    @State private var scrubbing = false

    var body: some View {
        let ids = app.targetIDs(for: nil)
        let current = app.currentPhoto
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.l) {
                artwork(ids: ids, current: current)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        titles(ids: ids, current: current)
                        Spacer(minLength: DS.Space.s)
                        actionIcons(ids: ids, current: current)
                    }
                    positionBar(current: current)
                    ViewThatFits(in: .horizontal) {
                        controls(ids: ids, current: current, compact: false)
                        controls(ids: ids, current: current, compact: true)
                    }
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: 940)
        .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.hero + 2, style: .continuous))
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: current?.id)
    }

    // MARK: Artwork

    @ViewBuilder
    private func artwork(ids: [Int64], current: PhotoRecord?) -> some View {
        Group {
            if ids.count > 1 {
                ZStack {
                    ForEach(Array(app.records(ids.prefix(3)).enumerated().reversed()), id: \.element.id) { i, p in
                        ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 256)
                            .frame(width: 92, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.75), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            .rotationEffect(.degrees(Double(i) * 6))
                            .offset(x: CGFloat(i) * 7)
                    }
                }
            } else if let current {
                ThumbnailImage(photo: current, recipe: app.recipe(for: current.id), pixelSize: 256)
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous).strokeBorder(DS.Palette.rim, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    .id(current.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .onTapGesture(count: 2) { app.openViewer(current.id) }
            } else {
                BrandMark(size: 96)
            }
        }
        .frame(width: 116, height: 108)
    }

    // MARK: Titles

    @ViewBuilder
    private func titles(ids: [Int64], current: PhotoRecord?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if ids.count > 1 {
                Text(String(localized: "\(ids.count) selected")).font(.system(size: 19, weight: .bold)).foregroundStyle(DS.Palette.textPrimary)
                    .contentTransitionNumeric()
                Text(app.records(ids).reduce(Int64(0)) { $0 + $1.fileSize }.formattedBytes)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Palette.blue)
                Text(String(localized: "Multiple selection – Auto Enhance, export or batch-process them together"))
                    .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            } else if let p = current {
                Text(p.filename).font(.system(size: 19, weight: .bold)).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                Text(p.displayDate.formatted(date: .long, time: .shortened))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Palette.blue).lineLimit(1)
                Text(details(p)).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            } else if let a = app.activity {
                Text(a.title).font(.system(size: 19, weight: .bold)).foregroundStyle(DS.Palette.textPrimary)
                Text(String(localized: "Running in the background")).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Palette.blue)
                Text(String(localized: "You can keep working – PhotoFlow stays responsive.")).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private func details(_ p: PhotoRecord) -> String {
        var parts = ["\(p.width) × \(p.height)", p.fileSize.formattedBytes, p.formatName]
        if let cam = p.cameraDescription { parts.append(cam) }
        if p.isEdited { parts.append(String(localized: "Edited")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Icon actions (top right)

    @ViewBuilder
    private func actionIcons(ids: [Int64], current: PhotoRecord?) -> some View {
        if !ids.isEmpty {
            let allFavorite = ids.allSatisfy { app.photo($0)?.isFavorite == true }
            HStack(spacing: 0) {
                Button { app.toggleFavorite(ids) } label: { HeartIcon(filled: allFavorite) }
                    .buttonStyle(GlassIconButtonStyle(size: 32, tint: allFavorite ? DS.Palette.heart : nil))
                    .tip(String(localized: "Favorite"), shortcut: "⇧⌘F", edge: .top)
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
                if let c = current, ids.count == 1 {
                    Button { app.openViewer(c.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(GlassIconButtonStyle(size: 32))
                        .tip(String(localized: "Open Photo"), shortcut: "␣", edge: .top)
                }
                Button { withAnimation(DS.Motion.snappy) { app.selection = [] } } label: { Image(systemName: "xmark") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .tip(String(localized: "Deselect"), shortcut: "esc", edge: .top)
            }
        } else if app.activity != nil {
            Button { app.cancelActivity() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(GlassIconButtonStyle(size: 32, tint: DS.Palette.danger))
                .tip(String(localized: "Stop"), edge: .top)
        }
    }

    // MARK: Position / progress bar

    @ViewBuilder
    private func positionBar(current: PhotoRecord?) -> some View {
        if let a = app.activity {
            HStack(spacing: DS.Space.s) {
                Text(verbatim: "\(a.completed)").font(DS.Font.number).foregroundStyle(DS.Palette.textSecondary).frame(minWidth: 30, alignment: .trailing)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Palette.track)
                        Capsule().fill(DS.Palette.brand).frame(width: max(6, g.size.width * (a.total > 0 ? a.fraction : 0.08)))
                    }
                }
                .frame(height: 5)
                Text(verbatim: a.total > 0 ? "\(a.total)" : "…").font(DS.Font.number).foregroundStyle(DS.Palette.textSecondary).frame(minWidth: 30, alignment: .leading)
            }
            .animation(DS.Motion.smooth, value: a.completed)
        } else {
            let list = app.visiblePhotos
            let index = current.flatMap { c in list.firstIndex { $0.id == c.id } }
            if list.count > 1, let index {
                HStack(spacing: DS.Space.s) {
                    Text(verbatim: "\(index + 1)").font(DS.Font.number).foregroundStyle(DS.Palette.textSecondary)
                        .frame(minWidth: 30, alignment: .trailing).contentTransitionNumeric()
                    // drag to scrub through the photos of this page
                    FluidSlider(value: Binding(get: { Double(index) }, set: { app.selectIndex(Int($0.rounded())) }),
                                range: 0 ... Double(list.count - 1), step: 1)
                        .help(String(localized: "Drag to browse the photos of this page"))
                    Text(verbatim: "\(list.count)").font(DS.Font.number).foregroundStyle(DS.Palette.textSecondary)
                        .frame(minWidth: 30, alignment: .leading)
                }
            }
        }
    }

    // MARK: Controls

    private func controls(ids: [Int64], current: PhotoRecord?, compact: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(DS.Palette.textTertiary)
                FluidSlider(value: $app.thumbnailSize, range: 90 ... 340, step: 1).frame(width: compact ? 80 : 140)
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(DS.Palette.textTertiary)
            }
            .tip(String(localized: "Thumbnail size"), edge: .top)
            Spacer(minLength: DS.Space.s)
            HStack(spacing: DS.Space.s) {
                Button { app.showRandomPhoto() } label: { Image(systemName: "shuffle") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .tip(String(localized: "Random Photo"), edge: .top)
                Button { app.stepSelection(-1) } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(GlassIconButtonStyle(size: 36))
                    .tip(String(localized: "Previous Photo"), shortcut: "←", edge: .top)
                Button { if let c = current { app.openViewer(c.id) } } label: {
                    Image(systemName: "eye.fill").font(.system(size: 19, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(DS.Palette.surfaceStrong))
                        .overlay(Circle().strokeBorder(DS.Palette.rim, lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                }
                .buttonStyle(SidebarRowButtonStyle())
                .foregroundStyle(DS.Palette.textPrimary)
                .disabled(current == nil)
                .tip(String(localized: "Open Photo"), shortcut: "␣", edge: .top)
                Button { app.stepSelection(1) } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(GlassIconButtonStyle(size: 36))
                    .tip(String(localized: "Next Photo"), shortcut: "→", edge: .top)
                Button { if let c = current { app.openEditor(c.id, compare: true) } } label: { Image(systemName: "square.split.2x1") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .disabled(current == nil)
                    .tip(String(localized: "Before/after comparison"), edge: .top)
            }
            Spacer(minLength: DS.Space.s)
            HStack(spacing: DS.Space.xs) {
                Button { app.autoEnhance(ids) } label: {
                    if compact { Image(systemName: "wand.and.stars") } else { Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars") }
                }
                .premiumButton().fixedSize()
                .disabled(ids.isEmpty || app.activity != nil)
                .tip(String(localized: "Analyze and improve the selected photos"), shortcut: "⌘E", edge: .top)
                Button { if let c = current { app.openEditor(c.id) } } label: {
                    if compact { Image(systemName: "slider.horizontal.3") } else { Label(String(localized: "Edit"), systemImage: "slider.horizontal.3") }
                }
                .softButton().fixedSize()
                .disabled(current == nil || ids.count > 1)
                .tip(String(localized: "Edit"), shortcut: "⌘↩", edge: .top)
            }
        }
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
            DS.Palette.canvas.opacity(0.92)
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
