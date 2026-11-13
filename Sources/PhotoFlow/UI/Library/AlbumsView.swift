import SwiftUI

/// "My Albums" – every album as a card whose cover is built from its own photos.
struct AlbumsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var renaming: Album?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                PageHeader(String(localized: "My Albums"), subtitle: String(localized: "\(app.albums.count) albums")) {
                    Button { app.newAlbumRequest = [] } label: { Label(String(localized: "New Album"), systemImage: "plus") }
                        .softButton()
                }
                if app.albums.isEmpty {
                    EmptyStateView(symbol: "rectangle.stack", title: String(localized: "No Albums Yet"),
                                   message: String(localized: "Albums group photos without moving or copying files. Create one, then drag photos onto it in the sidebar."),
                                   actionTitle: String(localized: "New Album"), action: { app.newAlbumRequest = [] }, illustration: .album)
                        .frame(minHeight: 440)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: DS.Space.l)], spacing: DS.Space.xl) {
                        ForEach(Array(app.albums.enumerated()), id: \.element.id) { i, album in
                            AlbumCard(album: album, covers: covers(album))
                                .reveal(index: i)
                                .onTapGesture { withAnimation(DS.Motion.adaptive(DS.Motion.page)) { app.sidebar = .album(album.id) } }
                                .contextMenu {
                                    Button(String(localized: "Rename Album…")) { renaming = album }
                                    Button(String(localized: "Export Album…")) { app.exportRequest = app.albumMembers[album.id] ?? [] }
                                    Divider()
                                    Button(String(localized: "Delete Album"), role: .destructive) { app.deleteAlbum(album.id) }
                                }
                        }
                        NewAlbumCard { app.newAlbumRequest = [] }
                    }
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
            .padding(.bottom, DS.Space.huge)
        }
        .mask(TopFadeMask())
        .sheet(item: $renaming) { album in
            TextPromptSheet(title: String(localized: "Rename Album"), placeholder: String(localized: "Album name"),
                            initial: album.name, confirmTitle: String(localized: "Rename")) { app.renameAlbum(album.id, to: $0) }
        }
    }

    private func covers(_ album: Album) -> [PhotoRecord] {
        (app.albumMembers[album.id] ?? []).compactMap { app.photo($0) }.prefix(3).map { $0 }
    }
}

struct AlbumCard: View {
    let album: Album
    let covers: [PhotoRecord]
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ZStack {
                if covers.isEmpty {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Palette.hover)
                        .overlay(Illustration(kind: .album, size: 150).opacity(0.85))
                } else {
                    // stacked cover: two photos peeking behind the main one
                    ForEach(Array(covers.dropFirst().enumerated().reversed()), id: \.element.id) { i, p in
                        ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 320)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                            .scaleEffect(0.92 - CGFloat(i) * 0.05)
                            .offset(y: -10 - CGFloat(i) * 8)
                            .opacity(0.75)
                    }
                    ThumbnailImage(photo: covers[0], recipe: app.recipe(for: covers[0].id), pixelSize: 512)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                }
            }
            .aspectRatio(1.0, contentMode: .fit)
            .glassReflection(cornerRadius: DS.Radius.card)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                Text(String(localized: "\(album.photoCount) photos")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(.top, 14)
        .contentShape(Rectangle())
        .magneticHover(scale: 1.02, lift: 3, shadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct NewAlbumCard: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.track, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.hover))
                    .overlay(Image(systemName: "plus").font(.system(size: 30, weight: .light)).foregroundStyle(DS.Palette.brand))
                    .aspectRatio(1.0, contentMode: .fit)
                Text(String(localized: "New Album")).font(DS.Font.headline).foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, 2)
                Text(verbatim: " ").font(DS.Font.caption)
            }
            .padding(.top, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .magneticHover(scale: 1.02, lift: 3, shadow: false)
    }
}
