import SwiftUI
import ImageIO

/// Photos PhotoFlow moved to the macOS Trash – restorable (with edits, favorites and albums).
/// Calm and clear: thumbnails from the files in the Trash, one-click restore, no aggressive warnings.
struct TrashView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selection: Set<Int64> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                PageHeader(String(localized: "Trash"), subtitle: subtitle) {
                    if !app.trashEntries.isEmpty {
                        HStack(spacing: DS.Space.xs) {
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) } label: {
                                Label(String(localized: "Open Trash"), systemImage: "trash")
                            }
                            .softButton()
                            Button { withAnimation(DS.Motion.smooth) { app.restore(selectedEntries.isEmpty ? app.trashEntries : selectedEntries); selection = [] } } label: {
                                Label(selection.isEmpty ? String(localized: "Restore All") : String(localized: "Restore Selected"), systemImage: "arrow.uturn.backward")
                            }
                            .prominentButton()
                        }
                    }
                }
                if app.trashEntries.isEmpty {
                    EmptyStateView(symbol: "trash", title: String(localized: "Trash Is Empty"),
                                   message: String(localized: "Deleted photos are always moved to the macOS Trash first – PhotoFlow never deletes files permanently."),
                                   illustration: .trash)
                        .frame(minHeight: 440)
                } else {
                    Label(String(localized: "Files that are no longer in the macOS Trash (e.g. after emptying it) cannot be restored."), systemImage: "info.circle")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: DS.Space.m)], spacing: DS.Space.m) {
                        ForEach(app.trashEntries) { e in
                            TrashCard(entry: e, selected: selection.contains(e.id)) {
                                withAnimation(DS.Motion.snappy) {
                                    if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                        if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) }
                                    } else {
                                        selection = selection == [e.id] ? [] : [e.id]
                                    }
                                }
                            }
                            .contextMenu {
                                let entries = selection.contains(e.id) ? selectedEntries : [e]
                                Button(String(localized: "Restore")) { app.restore(entries) }
                                Button(String(localized: "Remove from List")) { app.forgetTrashEntries(entries) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
            .padding(.bottom, DS.Space.huge)
        }
        .mask(TopFadeMask())
    }

    private var subtitle: String {
        if app.trashEntries.isEmpty { return String(localized: "Photos you deleted in PhotoFlow are in the macOS Trash. Restore them here – including their edits, favorites and albums.") }
        let bytes = app.trashEntries.reduce(Int64(0)) { $0 + $1.fileSize }
        return String(localized: "\(app.trashEntries.count) photos") + " · " + bytes.formattedBytes + " · " + String(localized: "restorable with edits, favorites and albums")
    }

    private var selectedEntries: [TrashEntry] { app.trashEntries.filter { selection.contains($0.id) } }
}

struct TrashCard: View {
    let entry: TrashEntry
    var selected: Bool
    var onTap: () -> Void
    @EnvironmentObject private var app: AppModel
    @State private var thumb: CGImage?
    @State private var hovering = false

    private var available: Bool { FileManager.default.fileExists(atPath: entry.trashPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let thumb {
                        Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else if available {
                        ShimmerBlock(cornerRadius: 0)
                    } else {
                        Rectangle().fill(DS.Palette.hover)
                            .overlay(Image(systemName: "questionmark.square.dashed").font(.system(size: 24, weight: .light)).foregroundStyle(DS.Palette.textTertiary))
                    }
                }
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipped()
                .saturation(0.55)
                .opacity(0.9)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .strokeBorder(selected ? DS.Palette.blue : DS.Palette.hairline, lineWidth: selected ? 2.5 : 0.5))
                if hovering && available {
                    Button { withAnimation(DS.Motion.smooth) { app.restore([entry]) } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(GlassIconButtonStyle(size: 28))
                        .glass(.floating, in: Circle())
                        .padding(6)
                        .help(String(localized: "Restore"))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            Text(entry.filename).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
            Text((entry.originalPath as NSString).deletingLastPathComponent)
                .font(.system(size: 10.5)).foregroundStyle(DS.Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                .help(entry.originalPath)
            HStack {
                Text(entry.trashedAt, format: .relative(presentation: .named)).font(.system(size: 10.5)).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Text(entry.fileSize.formattedBytes).font(.system(size: 10.5)).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
            }
            if !available {
                Label(String(localized: "No longer in the macOS Trash"), systemImage: "exclamationmark.circle")
                    .font(.system(size: 10.5)).foregroundStyle(DS.Palette.warning)
            }
        }
        .padding(DS.Space.xs)
        .glassCard(cornerRadius: DS.Radius.card)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(DS.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .task(id: entry.id) {
            let path = entry.trashPath
            thumb = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 360,
                                             kCGImageSourceCreateThumbnailWithTransform: true]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
