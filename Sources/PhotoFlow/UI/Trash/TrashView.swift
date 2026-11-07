import SwiftUI

/// Photos PhotoFlow moved to the macOS Trash – restorable (with edits, favorites and albums).
struct TrashView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selection: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SectionHeader(title: String(localized: "Trash"),
                              subtitle: String(localized: "Photos you deleted in PhotoFlow are in the macOS Trash. Restore them here – including their edits, favorites and albums."))
                Spacer()
                if !app.trashEntries.isEmpty {
                    Button { app.restore(selectedEntries.isEmpty ? app.trashEntries : selectedEntries) } label: {
                        Label(selection.isEmpty ? String(localized: "Restore All") : String(localized: "Restore Selected"), systemImage: "arrow.uturn.backward")
                    }
                    .prominentButton()
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) } label: {
                        Label(String(localized: "Open Trash"), systemImage: "trash")
                    }
                    .softButton()
                }
            }
            .padding(20)

            if app.trashEntries.isEmpty {
                EmptyStateView(symbol: "trash", title: String(localized: "Trash Is Empty"),
                               message: String(localized: "Deleted photos are always moved to the macOS Trash first – PhotoFlow never deletes files permanently."))
            } else {
                Table(app.trashEntries, selection: $selection) {
                    TableColumn(String(localized: "Name")) { e in
                        HStack {
                            Image(systemName: FileManager.default.fileExists(atPath: e.trashPath) ? "photo" : "questionmark.square.dashed")
                                .foregroundStyle(.secondary)
                            Text(e.filename)
                        }
                    }
                    TableColumn(String(localized: "Original Location")) { e in
                        Text((e.originalPath as NSString).deletingLastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    TableColumn(String(localized: "Deleted")) { e in
                        Text(e.trashedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    TableColumn(String(localized: "Size")) { e in Text(e.fileSize.formattedBytes).monospacedDigit() }
                }
                .contextMenu(forSelectionType: Int64.self) { ids in
                    let entries = app.trashEntries.filter { ids.contains($0.id) }
                    Button(String(localized: "Restore")) { app.restore(entries) }
                    Button(String(localized: "Remove from List")) { app.forgetTrashEntries(entries) }
                }
                Text(String(localized: "Files that are no longer in the macOS Trash (e.g. after emptying it) cannot be restored."))
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
    }

    private var selectedEntries: [TrashEntry] { app.trashEntries.filter { selection.contains($0.id) } }
}
