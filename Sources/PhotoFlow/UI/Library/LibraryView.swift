import SwiftUI
import UniformTypeIdentifiers

// MARK: - Grouping (month sections · import sessions · edit days)

struct PhotoGroup: Identifiable {
    var id: String
    var title: String
    var detail: String
    var photos: [PhotoRecord]
}

enum PhotoGrouping {
    /// Groups the visible photos the way the current page reads best.
    static func groups(for photos: [PhotoRecord], sidebar: SidebarItem, sort: LibrarySort) -> [PhotoGroup] {
        guard !photos.isEmpty else { return [] }
        let cal = Calendar.current
        switch sidebar {
        case .recentImports:
            // An import session = photos imported within 10 minutes of each other
            var out: [PhotoGroup] = []
            var current: [PhotoRecord] = []
            var last: Date?
            for p in photos {   // already sorted newest first
                if let l = last, l.timeIntervalSince(p.importedAt) > 600, !current.isEmpty {
                    out.append(session(current)); current = []
                }
                current.append(p); last = p.importedAt
            }
            if !current.isEmpty { out.append(session(current)) }
            return out
        case .recentlyEdited:
            return chunk(photos, key: { cal.startOfDay(for: $0.editedAt ?? $0.importedAt) }) { day, list in
                PhotoGroup(id: "e\(day.timeIntervalSince1970)", title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                           detail: String(localized: "\(list.count) photos"), photos: list)
            }
        default:
            guard sort == .captureDate || sort == .importDate else {
                return [PhotoGroup(id: "all", title: "", detail: "", photos: photos)]
            }
            return chunk(photos, key: { p in
                let d = sort == .captureDate ? p.displayDate : p.importedAt
                return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            }) { month, list in
                PhotoGroup(id: "m\(month.timeIntervalSince1970)", title: month.formatted(.dateTime.month(.wide).year()),
                           detail: String(localized: "\(list.count) photos"), photos: list)
            }
        }
    }

    private static func session(_ list: [PhotoRecord]) -> PhotoGroup {
        let d = list.first?.importedAt ?? Date()
        return PhotoGroup(id: "i\(d.timeIntervalSince1970)", title: d.formatted(.dateTime.day().month(.wide).year().hour().minute()),
                          detail: String(localized: "\(list.count) photos imported"), photos: list)
    }

    private static func chunk(_ photos: [PhotoRecord], key: (PhotoRecord) -> Date, make: (Date, [PhotoRecord]) -> PhotoGroup) -> [PhotoGroup] {
        var out: [PhotoGroup] = []
        var currentKey: Date?
        var current: [PhotoRecord] = []
        for p in photos {
            let k = key(p)
            if k != currentKey, let ck = currentKey { out.append(make(ck, current)); current = [] }
            currentKey = k
            current.append(p)
        }
        if let ck = currentKey { out.append(make(ck, current)) }
        return out
    }
}

// MARK: - Justified mosaic layout

enum MosaicLayout {
    struct Item: Identifiable { var photo: PhotoRecord; var aspect: CGFloat; var id: Int64 { photo.id } }
    struct Row: Identifiable { var id: Int64; var items: [Item]; var height: CGFloat }

    /// Fills each row edge to edge, keeping every photo's aspect ratio (clamped so panoramas stay readable).
    static func rows(_ photos: [PhotoRecord], width: CGFloat, targetHeight: CGFloat, spacing: CGFloat) -> [Row] {
        guard width > 50 else { return [] }
        var rows: [Row] = []
        var current: [Item] = []
        var sum: CGFloat = 0
        for p in photos {
            let a = p.height > 0 ? min(2.4, max(0.55, CGFloat(p.width) / CGFloat(p.height))) : 1.5
            current.append(Item(photo: p, aspect: a)); sum += a
            let rowWidth = sum * targetHeight + CGFloat(current.count - 1) * spacing
            if rowWidth >= width {
                let h = (width - CGFloat(current.count - 1) * spacing) / sum
                rows.append(Row(id: current[0].id, items: current, height: h))
                current = []; sum = 0
            }
        }
        if !current.isEmpty { rows.append(Row(id: current[0].id, items: current, height: targetHeight)) }
        return rows
    }
}

// MARK: - Library page

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var width: CGFloat = 900

    var body: some View {
        Group {
            if app.viewMode == .list && !app.visiblePhotos.isEmpty {
                VStack(spacing: 0) {
                    LibraryHeader().padding(.horizontal, DS.Space.page).padding(.top, ContentView.topBarHeight + DS.Space.xxs).padding(.bottom, DS.Space.m)
                    PhotoListView()
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                        .padding([.horizontal, .bottom], DS.Space.m)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.l) {
                            LibraryHeader()
                            if app.visiblePhotos.isEmpty {
                                emptyState.frame(minHeight: 460)
                            } else {
                                PhotoSections(width: width)
                            }
                        }
                        .padding(.horizontal, DS.Space.page)
                        .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
                        .padding(.bottom, 200)    // room for the floating photo dock
                        .background(GeometryReader { g in
                            Color.clear.onAppear { width = g.size.width - DS.Space.page * 2 }
                                .onChange(of: g.size.width) { w in width = w - DS.Space.page * 2 }
                        })
                        .background(Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation(DS.Motion.snappy) { app.selection = [] } })
                    }
                    .onChange(of: app.viewerPhotoID) { id in
                        if id == nil, let s = app.lastClicked { withAnimation(DS.Motion.smooth) { proxy.scrollTo(s, anchor: .center) } }
                    }
                    .onChange(of: app.editorPhotoID) { id in
                        if id == nil, let s = app.lastClicked { proxy.scrollTo(s, anchor: .center) }
                    }
                }
                .mask(TopFadeMask())
                .onDeleteCommand { app.requestTrash(Array(app.selection)) }
                .onMoveCommand { dir in moveSelection(dir) }
            }
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.viewMode)
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.photos.isEmpty {
            EmptyStateView(symbol: "photo.stack", title: String(localized: "Welcome to PhotoFlow"),
                           message: String(localized: "Import photos or whole folders – or simply drag them into this window. Your originals stay exactly where they are and are never changed."),
                           actionTitle: String(localized: "Import Photos"), action: { app.showImportPanel() }, illustration: .welcome,
                           hint: String(localized: "Or drop photos and folders anywhere in this window"))
        } else if !app.searchText.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: String(localized: "No Results"),
                           message: String(localized: "No photo matches “\(app.searchText)”."), illustration: .search)
        } else {
            switch app.sidebar {
            case .favorites:
                EmptyStateView(symbol: "heart", title: String(localized: "No Favorites Yet"),
                               message: String(localized: "Mark photos with the heart button or press ⇧⌘F."), illustration: .favorites)
            case .album:
                EmptyStateView(symbol: "rectangle.stack", title: String(localized: "This Album Is Empty"),
                               message: String(localized: "Drag photos onto the album in the sidebar, or use “Move to Album” in the context menu."), illustration: .album)
            case .recentlyEdited:
                EmptyStateView(symbol: "slider.horizontal.3", title: String(localized: "Nothing Edited Recently"),
                               message: String(localized: "Photos you enhance or edit appear here."), illustration: .edited)
            case .recentImports:
                EmptyStateView(symbol: "square.and.arrow.down", title: String(localized: "No Recent Imports"),
                               message: String(localized: "Photos imported in the last 30 days appear here, grouped by import."),
                               actionTitle: String(localized: "Import Photos"), action: { app.showImportPanel() }, illustration: .welcome)
            default:
                EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "No Matching Photos"),
                               message: String(localized: "Try removing a filter."), illustration: .search)
            }
        }
    }

    private func moveSelection(_ dir: MoveCommandDirection) {
        let list = app.visiblePhotos
        guard !list.isEmpty else { return }
        let current = app.lastClicked.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
        let columns = max(1, Int((width + 10) / (app.thumbnailSize + 10)))
        var next = current
        switch dir {
        case .left: next = max(0, current - 1)
        case .right: next = min(list.count - 1, current + 1)
        case .up: next = max(0, current - columns)
        case .down: next = min(list.count - 1, current + columns)
        @unknown default: break
        }
        app.selection = [list[next].id]
        app.lastClicked = list[next].id
    }
}

/// Soft fade where content scrolls under the floating top bar.
struct TopFadeMask: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: ContentView.topBarHeight + 8)
            Color.black
        }
        .ignoresSafeArea()
    }
}

struct LibraryHeader: View {
    @EnvironmentObject private var app: AppModel
    @State private var showSize = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // Title left, floating control capsule right (same row)
            HStack(alignment: .center, spacing: DS.Space.m) {
                Text(app.sidebarTitle)
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Spacer(minLength: DS.Space.s)
                ViewThatFits(in: .horizontal) {
                    controls(compact: false)
                    controls(compact: true)
                }
            }
            GlassSearchField(text: $app.searchText, prompt: String(localized: "File name or camera"))
                .frame(maxWidth: 620)
            Text(subtitle)
                .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                .contentTransitionNumeric()
                .padding(.leading, 2)
        }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 2) {
            GlassSegmented(selection: Binding(get: { app.viewMode }, set: { m in withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.viewMode = m } }),
                           options: [.init(value: .mosaic, title: String(localized: "Mosaic"), symbol: "square.grid.3x3.topleft.filled"),
                                     .init(value: .grid, title: String(localized: "Grid"), symbol: "square.grid.2x2"),
                                     .init(value: .compact, title: String(localized: "Compact Grid"), symbol: "square.grid.4x3.fill"),
                                     .init(value: .list, title: String(localized: "List"), symbol: "list.bullet")],
                           compact: true)

            capsuleDivider

            if app.sidebar != .recentImports && app.sidebar != .recentlyEdited {
                Menu {
                    Picker(String(localized: "Sort By"), selection: $app.sort) {
                        ForEach(LibrarySort.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle(String(localized: "Ascending"), isOn: $app.sortAscending)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                        if !compact { Text(app.sort.displayName).font(.system(size: 13, weight: .semibold)) }
                        Image(systemName: app.sortAscending ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Palette.blue)
                    }
                    .foregroundStyle(DS.Palette.textPrimary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, DS.Space.xs)
                .tip(String(localized: "Sort"))
            }

            Menu {
                Picker(String(localized: "Editing Status"), selection: $app.editFilter) {
                    ForEach(EditFilter.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker(String(localized: "Format"), selection: $app.formatFilter) {
                    Text(String(localized: "All Formats")).tag(String?.none)
                    ForEach(app.availableFormats, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isFiltered ? DS.Palette.blue : DS.Palette.textPrimary)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tip(isFiltered ? filterLabel : String(localized: "Filter"))

            Button { showSize.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(GlassIconButtonStyle(size: 30))
                .disabled(app.viewMode == .list)
                .tip(String(localized: "Thumbnail size"))
                .popover(isPresented: $showSize, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ControlLabel(text: String(localized: "Thumbnail size"))
                        HStack(spacing: 6) {
                            Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(DS.Palette.textTertiary)
                            FluidSlider(value: $app.thumbnailSize, range: 90 ... 340, step: 1).frame(width: 180)
                            Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    .padding(DS.Space.m)
                }

            capsuleDivider

            Button { app.showRandomPhoto() } label: { Image(systemName: "shuffle") }
                .buttonStyle(GlassIconButtonStyle(size: 30))
                .disabled(app.visiblePhotos.isEmpty)
                .tip(String(localized: "Random Photo"))
            Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: { Image(systemName: "gearshape") }
                .buttonStyle(GlassIconButtonStyle(size: 30))
                .tip(String(localized: "Settings"), shortcut: "⌘,")
        }
        .padding(4)
        .glass(.floating, in: Capsule())
        .fixedSize()
    }

    private var capsuleDivider: some View {
        Rectangle().fill(DS.Palette.hairline).frame(width: 0.5, height: 20).padding(.horizontal, 4)
    }

    private var isFiltered: Bool { app.editFilter != .all || app.formatFilter != nil }

    private var filterLabel: String {
        var parts: [String] = []
        if app.editFilter != .all { parts.append(app.editFilter.displayName) }
        if let f = app.formatFilter { parts.append(f) }
        return parts.isEmpty ? String(localized: "Filter") : parts.joined(separator: " · ")
    }

    private var subtitle: String {
        let n = app.visiblePhotos.count
        let bytes = app.visiblePhotos.reduce(Int64(0)) { $0 + $1.fileSize }
        var s = String(localized: "\(n) photos") + " · " + bytes.formattedBytes
        if !app.selection.isEmpty { s += " · " + String(localized: "\(app.selection.count) selected") }
        return s
    }
}

// MARK: - Sections + grid / mosaic

struct PhotoSections: View {
    var width: CGFloat
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let groups = PhotoGrouping.groups(for: app.visiblePhotos, sidebar: app.sidebar, sort: app.sort)
        let spacing: CGFloat = 6
        LazyVStack(alignment: .leading, spacing: DS.Space.xl, pinnedViews: []) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if !group.title.isEmpty { GroupHeader(title: group.title, detail: group.detail) }
                    if app.viewMode == .mosaic {
                        let rows = MosaicLayout.rows(group.photos, width: width, targetHeight: app.thumbnailSize * 1.05, spacing: spacing)
                        LazyVStack(alignment: .leading, spacing: spacing) {
                            ForEach(rows) { row in
                                HStack(spacing: spacing) {
                                    ForEach(row.items) { item in
                                        cell(item.photo, index: 0)
                                            .frame(width: max(20, item.aspect * row.height), height: row.height)
                                    }
                                }
                            }
                        }
                    } else if app.viewMode == .grid {
                        // large square tiles with title and details below (album-style)
                        let side = max(140, app.thumbnailSize * 1.25)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.35), spacing: DS.Space.l)], spacing: DS.Space.xl) {
                            ForEach(group.photos) { photo in
                                VStack(alignment: .leading, spacing: 7) {
                                    cell(photo, index: 0).aspectRatio(1, contentMode: .fit)
                                    PhotoCaption(photo: photo, highlighted: app.selection.contains(photo.id))
                                }
                            }
                        }
                    } else {
                        let side = max(70, app.thumbnailSize * 0.62)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.4), spacing: 6)], spacing: 6) {
                            ForEach(group.photos) { photo in
                                cell(photo, index: 0).aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
            }
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.thumbnailSize)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.editFilter)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.formatFilter)
    }

    private func cell(_ photo: PhotoRecord, index: Int) -> some View {
        let fresh = app.freshlyImported.contains(photo.id)
        return PhotoCell(photo: photo, recipe: app.recipe(for: photo.id), selected: app.selection.contains(photo.id),
                         radius: app.viewMode == .grid ? DS.Radius.card : (app.viewMode == .mosaic ? 8 : DS.Radius.xs + 2))
            .contextMenu { PhotoContextMenu(clicked: photo.id) }
            .onDrag { dragProvider(for: photo) }
            .reveal(index: fresh ? (app.visiblePhotos.firstIndex(of: photo) ?? 0) : 0, enabled: fresh)
            .id(photo.id)
    }

    private func dragProvider(for photo: PhotoRecord) -> NSItemProvider {
        let ids = app.selection.contains(photo.id) ? app.targetIDs(for: nil) : [photo.id]
        let provider = NSItemProvider(object: photo.url as NSURL)
        let payload = ids.map(String.init).joined(separator: ",").data(using: .utf8) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.photoFlowIDs.identifier, visibility: .ownProcess) { done in
            done(payload, nil)
            return nil
        }
        return provider
    }
}

/// Title + details under a large grid tile; the active photo's title is tinted with the accent colour.
struct PhotoCaption: View {
    let photo: PhotoRecord
    var highlighted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(photo.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(highlighted ? DS.Palette.blue : DS.Palette.textPrimary)
                if photo.isFavorite { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(DS.Palette.heart) }
            }
            Text(photo.cameraDescription ?? photo.formatName).font(.system(size: 12)).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            Text(verbatim: "\(photo.displayDate.formatted(.dateTime.day().month(.abbreviated).year())) · \(photo.width) × \(photo.height) · \(photo.fileSize.formattedBytes)")
                .font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 2)
        .animation(DS.Motion.snappy, value: highlighted)
    }
}

/// One photo tile: subtle zoom + light reflection on hover, info fades in, animated selection ring.
struct PhotoCell: View {
    let photo: PhotoRecord
    let recipe: EditRecipe?
    let selected: Bool
    var radius: CGFloat = DS.Radius.tile
    @State private var hovering = false
    @EnvironmentObject private var app: AppModel

    var body: some View {
        GeometryReader { g in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                ThumbnailImage(photo: photo, recipe: recipe)
                    .scaleEffect(hovering && !DS.Motion.reduced ? 1.045 : 1)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipShape(shape)

                // info gradient + labels (fade in on hover)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(shape)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white, DS.Palette.blue)
                                .shadow(color: .black.opacity(0.3), radius: 3)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                        Spacer()
                        if photo.isFavorite || hovering {
                            Button { app.toggleFavorite([photo.id]) } label: {
                                HeartIcon(filled: photo.isFavorite)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(.ultraThinMaterial.opacity(photo.isFavorite ? 0.0 : 0.9), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .shadow(color: .black.opacity(0.35), radius: 3)
                            .help(String(localized: "Favorite"))
                            .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 5) {
                        if hovering && g.size.width > 110 {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(photo.filename).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text(photo.displayDate, format: .dateTime.day().month(.abbreviated).year())
                                    .font(.system(size: 10)).opacity(0.8)
                            }
                            .foregroundStyle(.white)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                        }
                        Spacer(minLength: 0)
                        if photo.isEdited {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(DS.Palette.brand.opacity(0.9), in: Circle())
                                .help(String(localized: "Edited"))
                        }
                        if photo.isMissing {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                                .help(String(localized: "Original missing"))
                        }
                    }
                }
                .padding(7)
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .overlay {
                if selected {
                    shape.strokeBorder(DS.Palette.blue, lineWidth: 3)
                        .overlay(shape.inset(by: 3).strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                        .transition(.opacity)
                }
            }
            .glassReflection(cornerRadius: radius)
            .scaleEffect(selected && !DS.Motion.reduced ? 0.965 : 1)
            .shadow(color: selected ? DS.Palette.blue.opacity(0.35) : .black.opacity(hovering ? 0.22 : 0.0),
                    radius: selected ? 10 : (hovering ? 12 : 0), y: hovering ? 6 : 2)
            .contentShape(shape)
            .onTapGesture(count: 2) {
                withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.openViewer(photo.id, from: g.frame(in: .named("root"))) }
            }
            .simultaneousGesture(TapGesture().onEnded { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { app.click(photo.id) } })
        }
        .animation(DS.Motion.hover, value: hovering)
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: selected)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(photo.filename))
        .accessibilityValue(Text(photo.displayDate, format: .dateTime.day().month().year()))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { app.click(photo.id) }
        .accessibilityAction(named: Text(String(localized: "Open Photo"))) { app.openViewer(photo.id) }
    }
}

struct PhotoListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var sortOrder: [KeyPathComparator<PhotoRecord>] = []

    var body: some View {
        Table(rows, selection: $app.selection, sortOrder: $sortOrder) {
            TableColumn("") { p in
                ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 96)
                    .frame(width: 44, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            }
            .width(52)
            TableColumn(String(localized: "Name"), value: \.filename) { p in
                HStack(spacing: 6) {
                    Text(p.filename).lineLimit(1)
                    if p.isFavorite { Image(systemName: "heart.fill").foregroundStyle(DS.Palette.heart).font(.caption) }
                    if p.isEdited { Image(systemName: "wand.and.stars").foregroundStyle(DS.Palette.blue).font(.caption) }
                    if p.isMissing { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning).font(.caption) }
                }
            }
            TableColumn(String(localized: "Date"), value: \.displayDate) { p in
                Text(p.displayDate, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            }
            TableColumn(String(localized: "Dimensions"), value: \.megapixels) { p in
                Text(verbatim: "\(p.width) × \(p.height)").monospacedDigit().foregroundStyle(.secondary)
            }
            TableColumn(String(localized: "Size"), value: \.fileSize) { p in
                Text(p.fileSize.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
            }
            TableColumn(String(localized: "Format"), value: \.formatName) { p in
                Text(p.formatName).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.Palette.surface)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let first = ids.first {
                PhotoContextMenu(clicked: first, explicitIDs: Array(ids))
            }
        } primaryAction: { ids in
            if let first = ids.first { app.openViewer(first) }
        }
        .onDeleteCommand { app.requestTrash(Array(app.selection)) }
    }

    private var rows: [PhotoRecord] {
        sortOrder.isEmpty ? app.visiblePhotos : app.visiblePhotos.sorted(using: sortOrder)
    }
}
