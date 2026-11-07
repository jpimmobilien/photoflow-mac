import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @State private var renamingAlbum: Album?
    @State private var renameText = ""

    var body: some View {
        List(selection: Binding(get: { app.sidebar }, set: { if let v = $0 { app.sidebar = v } })) {
            Section {
                row(.overview, String(localized: "Overview"), "square.grid.2x2")
            }
            Section(String(localized: "Photo Library")) {
                row(.allPhotos, String(localized: "All Photos"), "photo.on.rectangle.angled", count: app.photos.count)
                row(.recentImports, String(localized: "Recent Imports"), "clock.arrow.circlepath")
                row(.favorites, String(localized: "Favorites"), "heart", count: app.favoriteCount)
                row(.recentlyEdited, String(localized: "Recently Edited"), "slider.horizontal.3")
            }
            Section {
                ForEach(app.albums) { album in
                    albumRow(album)
                }
                Button {
                    app.newAlbumRequest = []
                } label: {
                    Label(String(localized: "New Album…"), systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                Text(String(localized: "Albums"))
            }
            Section(String(localized: "Tools")) {
                row(.batch, String(localized: "Batch Processing"), "square.stack.3d.up", busy: app.batch.isRunning)
                row(.duplicates, String(localized: "Duplicate Finder"), "square.on.square.dashed",
                    count: app.duplicates.groups.isEmpty ? nil : app.duplicates.groups.count, busy: app.duplicates.isScanning)
                row(.similar, String(localized: "Similar Photos"), "rectangle.3.group",
                    count: app.similar.groups.isEmpty ? nil : app.similar.groups.count, busy: app.similar.isScanning)
                row(.exportHistory, String(localized: "Export History"), "clock")
                row(.trash, String(localized: "Trash"), "trash", count: app.trashEntries.isEmpty ? nil : app.trashEntries.count)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                Text(String(localized: "100 % on-device"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .help(String(localized: "All analysis and editing runs locally on this Mac. No uploads, no cloud."))
        }
        .sheet(item: $renamingAlbum) { album in
            TextPromptSheet(title: String(localized: "Rename Album"), placeholder: String(localized: "Album name"),
                            initial: album.name, confirmTitle: String(localized: "Rename")) { name in
                app.renameAlbum(album.id, to: name)
            }
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, count: Int? = nil, busy: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if busy { ProgressView().controlSize(.mini) }
            if let count, count > 0 {
                Text(verbatim: "\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .tag(item)
    }

    private func albumRow(_ album: Album) -> some View {
        HStack {
            Label(album.name, systemImage: "rectangle.stack")
            Spacer()
            Text(verbatim: "\(album.photoCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .tag(SidebarItem.album(album.id))
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
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
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
