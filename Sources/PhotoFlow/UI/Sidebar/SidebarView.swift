import SwiftUI
import UniformTypeIdentifiers

/// PhotoFlow 2.0 sidebar – Background Glass (Material 1) with a liquid-glass selection pill that glides
/// between rows, hover lighting and the brand mark under the window controls.
struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    var onCollapse: () -> Void = {}
    @State private var renamingAlbum: Album?
    @State private var albumsExpanded = true
    @Namespace private var pill

    var body: some View {
        VStack(spacing: 0) {
            // Window controls live here (hidden title bar) – the strip also drags the window.
            ZStack(alignment: .trailing) {
                WindowDragArea()
                Button(action: onCollapse) { Image(systemName: "sidebar.left") }
                    .buttonStyle(GlassIconButtonStyle(size: 28))
                    .tip(String(localized: "Hide Sidebar"), shortcut: "⌃⌘S")
                    .padding(.trailing, DS.Space.s)
            }
            .frame(height: 52)

            HStack(spacing: DS.Space.xs) {
                BrandMark(size: 26)
                Text(verbatim: "PhotoFlow").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    group(String(localized: "Library"))
                    row(.overview, String(localized: "Overview"), "sparkles.rectangle.stack")
                    row(.allPhotos, String(localized: "All Photos"), "photo.on.rectangle.angled", count: app.photos.count)
                    row(.recentImports, String(localized: "Recent Imports"), "square.and.arrow.down.on.square")
                    row(.favorites, String(localized: "Favorites"), "heart", count: app.favoriteCount)
                    row(.recentlyEdited, String(localized: "Recently Edited"), "slider.horizontal.3")

                    group(String(localized: "Albums"))
                    row(.albums, String(localized: "My Albums"), "rectangle.stack", count: app.albums.count)
                    ForEach(app.albums) { album in albumRow(album) }
                    Button { app.newAlbumRequest = [] } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 20)
                            Text(String(localized: "New Album…")).font(.system(size: 13))
                            Spacer()
                        }
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, 10).frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarRowButtonStyle())

                    group(String(localized: "Tools"))
                    row(.batch, String(localized: "Batch Processing"), "wand.and.stars", busy: app.batch.isRunning)
                    row(.duplicates, String(localized: "Duplicate Finder"), "square.on.square",
                        count: app.duplicates.groups.isEmpty ? nil : app.duplicates.groups.count, busy: app.duplicates.isScanning)
                    row(.similar, String(localized: "Similar Photos"), "square.stack.3d.down.right",
                        count: app.similar.groups.isEmpty ? nil : app.similar.groups.count, busy: app.similar.isScanning)
                    row(.exportHistory, String(localized: "Export History"), "clock.arrow.circlepath")
                    row(.trash, String(localized: "Trash"), "trash", count: app.trashEntries.isEmpty ? nil : app.trashEntries.count)
                }
                .padding(.horizontal, DS.Space.xs)
                .padding(.bottom, DS.Space.m)
                .animation(DS.Motion.adaptive(DS.Motion.snappy), value: app.sidebar)
            }

            footer
        }
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffectBackground(material: .sidebar)
                DS.Palette.canvasDeep.opacity(0.35)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) { Rectangle().fill(DS.Palette.hairline).frame(width: 0.5).ignoresSafeArea() }
        .sheet(item: $renamingAlbum) { album in
            TextPromptSheet(title: String(localized: "Rename Album"), placeholder: String(localized: "Album name"),
                            initial: album.name, confirmTitle: String(localized: "Rename")) { name in
                app.renameAlbum(album.id, to: name)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "lock.shield.fill").foregroundStyle(DS.Palette.success)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "100 % on-device")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                if !app.photos.isEmpty {
                    Text(app.totalBytes.formattedBytes).font(DS.Font.micro).foregroundStyle(DS.Palette.textTertiary).monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.hairline).frame(height: 0.5).padding(.horizontal, DS.Space.m) }
        .help(String(localized: "All analysis and editing runs locally on this Mac. No uploads, no cloud."))
    }

    private func group(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.sectionLabel)
            .foregroundStyle(DS.Palette.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, count: Int? = nil, busy: Bool = false) -> some View {
        SidebarRow(title: title, symbol: symbol, selected: app.sidebar == item, count: count, busy: busy, pill: pill) {
            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { app.sidebar = item }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        SidebarRow(title: album.name, symbol: "photo.stack", selected: app.sidebar == .album(album.id), count: album.photoCount,
                   indent: true, pill: pill) {
            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { app.sidebar = .album(album.id) }
        }
        .contextMenu {
            Button(String(localized: "Rename Album…")) { renamingAlbum = album }
            Button(String(localized: "Add Selected Photos")) { app.add(Array(app.selection), toAlbum: album.id) }
                .disabled(app.selection.isEmpty)
            Button(String(localized: "Export Album…")) { app.exportRequest = app.albumMembers[album.id] ?? [] }
            Divider()
            Button(String(localized: "Delete Album"), role: .destructive) { app.deleteAlbum(album.id) }
        }
        .onDrop(of: [.photoFlowIDs, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers, album: album.id)
        }
    }

    /// Photos dragged from the grid carry their IDs; files dragged from Finder are imported into the album.
    private func handleDrop(_ providers: [NSItemProvider], album: Int64) -> Bool {
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.photoFlowIDs.identifier) {
            handled = true
            p.loadDataRepresentation(forTypeIdentifier: UTType.photoFlowIDs.identifier) { data, _ in
                guard let data, let s = String(data: data, encoding: .utf8) else { return }
                let ids = s.split(separator: ",").compactMap { Int64($0) }
                Task { @MainActor in AppModel.shared.move(ids, toAlbum: album) }
            }
        }
        if !handled {
            loadDroppedURLs(providers) { urls in
                let app = AppModel.shared
                app.importItems(urls)
                // Add newly imported photos once the import finished
                Task { @MainActor in
                    for _ in 0 ..< 60 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if app.activity == nil { break }
                    }
                    let paths = Set(ImportService.collectImageURLs(from: urls).map(\.path))
                    let ids = app.photos.filter { paths.contains($0.path) }.map(\.id)
                    app.add(ids, toAlbum: album)
                }
            }
            handled = true
        }
        return handled
    }
}

struct SidebarRow: View {
    var title: String
    var symbol: String
    var selected: Bool
    var count: Int? = nil
    var busy = false
    var indent = false
    var pill: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? filled(symbol) : symbol)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(DS.Palette.textSecondary))
                    .frame(width: 20)
                    .scaleEffect(selected && !DS.Motion.reduced ? 1.06 : 1)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                if let count, count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(DS.Palette.textTertiary)
                        .contentTransitionNumeric()
                }
            }
            .padding(.leading, indent ? 22 : 10)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background {
                if selected {
                    // Liquid-glass selection pill – glides to the new row (effect 5)
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Palette.surfaceStrong)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(LinearGradient(colors: [DS.Palette.blue.opacity(0.10), DS.Palette.iris.opacity(0.06)], startPoint: .leading, endPoint: .trailing)))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Palette.rim, lineWidth: 0.6))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 1.5)
                        .matchedGeometryEffect(id: "sidebar-pill", in: pill)
                } else if hovering {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .onHover { h in withAnimation(DS.Motion.quick) { hovering = h } }
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func filled(_ s: String) -> String {
        switch s {
        case "heart": return "heart.fill"
        case "trash": return "trash.fill"
        case "square.on.square": return "square.on.square.fill"
        case "rectangle.stack": return "rectangle.stack.fill"
        case "photo.stack": return "photo.stack.fill"
        default: return s
        }
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(DS.Motion.hover, value: configuration.isPressed)
    }
}

/// Generic single-text-field sheet.
struct TextPromptSheet: View {
    var title: String
    var placeholder: String
    var initial: String = ""
    var confirmTitle: String
    var onConfirm: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(title).font(DS.Font.title2)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .padding(.horizontal, DS.Space.s).padding(.vertical, 8)
                .glass(.interactive, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .frame(width: 340)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).softButton()
                Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).prominentButton()
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .onAppear { text = initial }
    }

    private func confirm() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onConfirm(text)
        dismiss()
    }
}

struct NewAlbumSheet: View {
    var photoIDs: [Int64]
    @EnvironmentObject private var app: AppModel
    var body: some View {
        TextPromptSheet(title: photoIDs.isEmpty ? String(localized: "New Album") : String(localized: "New Album with \(photoIDs.count) Photos"),
                        placeholder: String(localized: "Album name"), confirmTitle: String(localized: "Create")) { name in
            app.createAlbum(named: name, with: photoIDs)
        }
    }
}
