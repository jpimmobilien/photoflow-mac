import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader()
            Divider().opacity(0.5)
            if app.visiblePhotos.isEmpty {
                emptyState
            } else if app.viewMode == .grid {
                PhotoGridView()
            } else {
                PhotoListView()
            }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: Text(String(localized: "Search file names")))
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.photos.isEmpty {
            EmptyStateView(symbol: "photo.stack", title: String(localized: "Welcome to PhotoFlow"),
                           message: String(localized: "Import photos or whole folders – or simply drag them into this window. Your originals stay exactly where they are and are never changed."),
                           actionTitle: String(localized: "Import Photos"), action: { app.showImportPanel() })
        } else if !app.searchText.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: String(localized: "No Results"),
                           message: String(localized: "No photo matches “\(app.searchText)”."))
        } else {
            switch app.sidebar {
            case .favorites:
                EmptyStateView(symbol: "heart", title: String(localized: "No Favorites Yet"),
                               message: String(localized: "Mark photos with the heart button or press ⇧⌘F."))
            case .album:
                EmptyStateView(symbol: "rectangle.stack", title: String(localized: "This Album Is Empty"),
                               message: String(localized: "Drag photos onto the album in the sidebar, or use “Move to Album” in the context menu."))
            case .recentlyEdited:
                EmptyStateView(symbol: "slider.horizontal.3", title: String(localized: "Nothing Edited Recently"),
                               message: String(localized: "Photos you enhance or edit appear here."))
            default:
                EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "No Matching Photos"),
                               message: String(localized: "Try removing a filter."))
            }
        }
    }
}

struct LibraryHeader: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.sidebarTitle).font(.system(.title3, design: .rounded).weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()

            Menu {
                Picker(String(localized: "Sort By"), selection: $app.sort) {
                    ForEach(LibrarySort.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(String(localized: "Ascending"), isOn: $app.sortAscending)
            } label: {
                Label(app.sort.displayName, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Sort"))

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
                Label(filterLabel, systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Filter"))

            Picker("", selection: Binding(get: { app.viewMode }, set: { app.viewMode = $0 })) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
            .help(String(localized: "Grid or list"))

            if app.viewMode == .grid {
                HStack(spacing: 4) {
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $app.thumbnailSize, in: 90 ... 340).frame(width: 100).controlSize(.small)
                    Image(systemName: "photo").font(.callout).foregroundStyle(.secondary)
                }
                .help(String(localized: "Thumbnail size"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
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
        var s = String(localized: "\(n) photos")
        if !app.selection.isEmpty { s += " · " + String(localized: "\(app.selection.count) selected") }
        return s
    }
}

struct PhotoGridView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: app.thumbnailSize, maximum: app.thumbnailSize * 1.6), spacing: 10)], spacing: 10) {
                    ForEach(app.visiblePhotos) { photo in
                        PhotoCell(photo: photo, recipe: app.recipe(for: photo.id), selected: app.selection.contains(photo.id))
                            .frame(height: app.thumbnailSize)
                            .onTapGesture(count: 2) { app.openEditor(photo.id) }
                            .simultaneousGesture(TapGesture().onEnded { app.click(photo.id) })
                            .contextMenu { PhotoContextMenu(clicked: photo.id) }
                            .onDrag { dragProvider(for: photo) }
                            .id(photo.id)
                    }
                }
                .padding(16)
            }
            .background(
                // Click on empty space clears the selection
                Color.clear.contentShape(Rectangle()).onTapGesture { app.selection = [] }
            )
            .onChange(of: app.editorPhotoID) { id in
                if id == nil, let s = app.lastClicked { proxy.scrollTo(s, anchor: .center) }
            }
        }
        .onDeleteCommand { app.requestTrash(Array(app.selection)) }
        .onMoveCommand { dir in moveSelection(dir) }
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

    private func moveSelection(_ dir: MoveCommandDirection) {
        let list = app.visiblePhotos
        guard !list.isEmpty else { return }
        let current = app.lastClicked.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
        let columns = 4
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

struct PhotoCell: View {
    let photo: PhotoRecord
    let recipe: EditRecipe?
    let selected: Bool
    @State private var hovering = false
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailImage(photo: photo, recipe: recipe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 4) {
                if photo.isEdited {
                    Image(systemName: "slider.horizontal.3").help(String(localized: "Edited"))
                }
                if photo.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(String(localized: "Original missing"))
                }
                Spacer()
                if photo.isFavorite || hovering {
                    Button { app.toggleFavorite([photo.id]) } label: {
                        Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(photo.isFavorite ? .pink : .white)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Favorite"))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .padding(7)

            if hovering {
                Text(photo.filename)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: selected ? 3 : 0.5)
        )
        .scaleEffect(hovering && !selected ? 1.015 : 1)
        .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help(photo.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(photo.filename))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(52)
            TableColumn(String(localized: "Name"), value: \.filename) { p in
                HStack(spacing: 6) {
                    Text(p.filename).lineLimit(1)
                    if p.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
                    if p.isEdited { Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).font(.caption) }
                    if p.isMissing { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.caption) }
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
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let first = ids.first {
                PhotoContextMenu(clicked: first, explicitIDs: Array(ids))
            }
        } primaryAction: { ids in
            if let first = ids.first { app.openEditor(first) }
        }
        .onDeleteCommand { app.requestTrash(Array(app.selection)) }
    }

    private var rows: [PhotoRecord] {
        sortOrder.isEmpty ? app.visiblePhotos : app.visiblePhotos.sorted(using: sortOrder)
    }
}
