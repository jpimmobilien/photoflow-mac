import SwiftUI

/// Native right-click menu for photos (grid, list, duplicate review).
struct PhotoContextMenu: View {
    @EnvironmentObject private var app: AppModel
    var clicked: Int64
    var explicitIDs: [Int64]?

    private var ids: [Int64] { explicitIDs ?? app.targetIDs(for: clicked) }
    private var single: PhotoRecord? { ids.count == 1 ? app.photo(ids[0]) : nil }

    var body: some View {
        Button(String(localized: "Show Photo")) { app.openViewer(clicked) }
        Button(String(localized: "Open in Default App")) { app.openInDefaultApp(ids) }
        Button(String(localized: "Quick Look")) { app.quickLook(clicked) }
        Divider()
        Button(String(localized: "Auto Enhance")) { app.autoEnhance(ids) }
        Menu(String(localized: "Auto Enhance Strength")) {
            ForEach(EnhanceStrength.allCases) { s in
                Button(s.localizedName) { app.autoEnhance(ids, strength: s) }
            }
        }
        Button(String(localized: "Edit")) { app.openEditor(clicked) }
        Button(String(localized: "Compare")) { app.compare(ids) }
        if ids.contains(where: { app.recipe(for: $0) != nil }) {
            Button(String(localized: "Restore Original")) { app.revertToOriginal(ids) }
        }
        if ids.count == 1, app.recipe(for: clicked) != nil {
            Button(String(localized: "Copy Adjustments")) { app.copyAdjustments(from: clicked) }
        }
        if app.canPasteAdjustments {
            Button(String(localized: "Paste Adjustments")) { app.pasteAdjustments(to: ids) }
        }
        Divider()
        let allFavorite = ids.allSatisfy { app.photo($0)?.isFavorite ?? false }
        Button(allFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
            app.toggleFavorite(ids)
        }
        Menu(String(localized: "Move to Album")) {
            ForEach(app.albums) { album in
                Button(album.name) { app.move(ids, toAlbum: album.id) }
            }
            if !app.albums.isEmpty { Divider() }
            Button(String(localized: "New Album…")) { app.newAlbumRequest = ids }
        }
        if case .album = app.sidebar {
            Button(String(localized: "Remove from Album")) { app.removeFromCurrentAlbum(ids) }
        }
        Divider()
        if let p = single {
            Button(String(localized: "Rename…")) { app.renameTarget = p }
        }
        Button(String(localized: "Reveal in Finder")) { app.reveal(ids) }
        Menu(String(localized: "File")) {
            Button(String(localized: "Copy to Folder…")) { app.moveOrCopyFiles(ids, copy: true) }
            Button(String(localized: "Move to Folder…")) { app.moveOrCopyFiles(ids, copy: false) }
            if let p = single, p.isMissing {
                Button(String(localized: "Locate Original…")) { app.locate(p) }
            }
            Divider()
            Button(String(localized: "Remove from Library (Keep File)")) { app.removeFromLibrary(ids) }
        }
        Button(String(localized: "Export…")) { app.exportRequest = ids }
        Divider()
        Button(String(localized: "Move to Trash"), role: .destructive) { app.requestTrash(ids) }
        Divider()
        if let p = single {
            Button(String(localized: "Get Information")) { app.infoTarget = p }
        }
    }
}

struct RenameSheet: View {
    let photo: PhotoRecord
    @EnvironmentObject private var app: AppModel
    var body: some View {
        TextPromptSheet(title: String(localized: "Rename File"), placeholder: String(localized: "File name"),
                        initial: (photo.filename as NSString).deletingPathExtension, confirmTitle: String(localized: "Rename")) { name in
            app.rename(photo, to: name)
        }
    }
}

struct PhotoInfoSheet: View {
    let photo: PhotoRecord
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ThumbnailImage(photo: photo, recipe: app.recipe(for: photo.id), pixelSize: 420, contentMode: .fit)
                    .frame(width: 220, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(photo.filename).font(DS.Font.title2).lineLimit(2)
                    Text(photo.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                }
            }
            PhotoMetadataGrid(photo: photo, extended: true)
            HStack {
                Button(String(localized: "Reveal in Finder")) { app.reveal([photo.id]) }.softButton()
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction).prominentButton()
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// Key/value metadata table used by the inspector and the info sheet.
struct PhotoMetadataGrid: View {
    let photo: PhotoRecord
    var extended = false
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row(String(localized: "Dimensions"), "\(photo.width) × \(photo.height)  (\(String(format: "%.1f", photo.megapixels)) MP)")
            row(String(localized: "File Size"), photo.fileSize.formattedBytes)
            row(String(localized: "Format"), photo.formatName)
            if let d = photo.captureDate { row(String(localized: "Taken"), d.formatted(date: .abbreviated, time: .shortened)) }
            if let d = photo.creationDate { row(String(localized: "Created"), d.formatted(date: .abbreviated, time: .shortened)) }
            if extended { row(String(localized: "Modified"), photo.fileModified.formatted(date: .abbreviated, time: .shortened)) }
            if let cam = photo.cameraDescription { row(String(localized: "Camera"), cam) }
            if let lens = photo.lensModel { row(String(localized: "Lens"), lens) }
            if let ex = photo.exposureDescription { row(String(localized: "Exposure"), ex) }
            row(String(localized: "Imported"), photo.importedAt.formatted(date: .abbreviated, time: .shortened))
            row(String(localized: "Status"), status)
        }
        .font(.callout)
    }

    private var status: String {
        if photo.isMissing { return String(localized: "Original missing") }
        if let e = photo.editedAt { return String(localized: "Edited \(e.formatted(.relative(presentation: .named)))") }
        return String(localized: "Original (not edited)")
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled).lineLimit(2)
        }
    }
}
