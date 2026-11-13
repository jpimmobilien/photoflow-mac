import SwiftUI

/// Full-window photo detail view. Zooms out of the thumbnail it was opened from (spatial continuity),
/// dims the interface, slides the inspector in, cross-fades while browsing (←/→) and returns the photo
/// to its grid position when closed (Esc / Space / ✕).
struct PhotoViewer: View {
    let photoID: Int64
    @EnvironmentObject private var app: AppModel
    @State private var expanded = false
    @State private var showDetails = true
    @State private var openedID: Int64?
    @State private var hoverEdge: HorizontalEdge?

    static let closeNote = Notification.Name("PhotoViewer.close")
    static let stepNote = Notification.Name("PhotoViewer.step")

    static func requestClose() { NotificationCenter.default.post(name: closeNote, object: nil) }
    static func step(_ delta: Int) { NotificationCenter.default.post(name: stepNote, object: delta) }

    var body: some View {
        GeometryReader { g in
            let panel: CGFloat = showDetails ? 330 : 0
            let stage = CGRect(x: 24, y: 70, width: g.size.width - 48 - panel, height: g.size.height - 70 - 34)
            ZStack(alignment: .topLeading) {
                // Background recedes: anthracite / warm grey veil + this photo's light
                DS.Palette.stage.opacity(0.94)
                .opacity(expanded ? 1 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

                if let photo = app.photo(photoID) {
                    AmbientBackground(photo: photo, recipe: app.recipe(for: photo.id), intensity: 1.1, base: .clear)
                        .opacity(expanded ? 1 : 0)
                        .allowsHitTesting(false)

                    let target = fitted(photo, in: stage)
                    let from = openedID == photo.id ? (app.viewerSourceRect ?? shrunk(target)) : shrunk(target)
                    let r = expanded ? target : from
                    ZStack {
                        ThumbnailImage(photo: photo, recipe: app.recipe(for: photo.id), pixelSize: 640, contentMode: .fill)
                        ThumbnailImage(photo: photo, recipe: app.recipe(for: photo.id), pixelSize: 2400, contentMode: .fill)
                    }
                    .frame(width: r.width, height: r.height)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? DS.Radius.tile : DS.Radius.tile, style: .continuous))
                    .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 30, y: 16)
                    .position(x: r.midX, y: r.midY)
                    .id(photo.id)
                    .transition(.opacity)
                    .onTapGesture(count: 2) { app.openEditor(photo.id) }
                    .accessibilityLabel(Text(photo.filename))
                    .accessibilityAddTraits(.isImage)

                    // browse arrows (appear on hover near the edges)
                    HStack {
                        edgeButton(.leading, "chevron.left") { step(-1) }
                        Spacer()
                        edgeButton(.trailing, "chevron.right") { step(1) }
                    }
                    .frame(width: stage.width, height: stage.height)
                    .position(x: stage.midX, y: stage.midY)
                    .opacity(expanded ? 1 : 0)

                    topBar(photo)
                        .frame(width: g.size.width - panel)
                        .opacity(expanded ? 1 : 0)
                        .offset(y: expanded ? 0 : -10)

                    if showDetails {
                        ScrollView(showsIndicators: false) {
                            PhotoDetailsPanel(photo: photo, showsPreview: false)
                                .padding(DS.Space.m)
                        }
                        .frame(width: panel - 14, height: g.size.height - 70 - 14)
                        .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                        .position(x: g.size.width - panel / 2 - 2, y: 70 + (g.size.height - 70 - 14) / 2)
                        .offset(x: expanded ? 0 : panel + 40)
                        .opacity(expanded ? 1 : 0)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            openedID = photoID
            withAnimation(DS.Motion.adaptive(.spring(response: 0.48, dampingFraction: 0.86))) { expanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.closeNote)) { _ in close() }
        .onReceive(NotificationCenter.default.publisher(for: Self.stepNote)) { n in step(n.object as? Int ?? 1) }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: showDetails)
        .animation(DS.Motion.adaptive(.easeInOut(duration: 0.25)), value: photoID)
    }

    // MARK: Pieces

    private func topBar(_ photo: PhotoRecord) -> some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: DS.Space.xs) {
                Color.clear.frame(width: 68, height: 1)
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(GlassIconButtonStyle(size: 32))
                    .glass(.floating, in: Circle())
                    .tip(String(localized: "Close"), shortcut: "esc")
                VStack(alignment: .leading, spacing: 0) {
                    Text(photo.filename).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    Text(positionText).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                }
                .padding(.leading, DS.Space.xxs)
                Spacer()
                HStack(spacing: 2) {
                    Button { app.toggleFavorite([photo.id]) } label: { HeartIcon(filled: photo.isFavorite) }
                        .buttonStyle(GlassIconButtonStyle(size: 32, tint: photo.isFavorite ? DS.Palette.heart : nil))
                        .tip(String(localized: "Favorite"), shortcut: "⇧⌘F")
                    Button { app.openEditor(photo.id) } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(GlassIconButtonStyle(size: 32))
                        .tip(String(localized: "Edit"), shortcut: "⌘↩")
                    Button { app.exportRequest = [photo.id] } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(GlassIconButtonStyle(size: 32))
                        .tip(String(localized: "Export"), shortcut: "⇧⌘E")
                    Button { withAnimation { showDetails.toggle() } } label: { Image(systemName: "info") }
                        .buttonStyle(GlassIconButtonStyle(size: 32, active: showDetails))
                        .tip(String(localized: "Information"))
                }
                .padding(3)
                .glass(.floating, in: Capsule())
                Button { app.autoEnhance([photo.id]) } label: { Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars") }
                    .premiumButton()
                    .disabled(app.activity != nil)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, 10)
        }
        .frame(height: 60)
    }

    private func edgeButton(_ edge: HorizontalEdge, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(GlassIconButtonStyle(size: 38))
            .glass(.floating, in: Circle())
            .opacity(hoverEdge == edge ? 1 : 0.001)
            .frame(width: 90, height: 200)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(DS.Motion.quick) { hoverEdge = h ? edge : nil } }
            .help(edge == .leading ? String(localized: "Previous Photo") : String(localized: "Next Photo"))
    }

    private var positionText: String {
        let list = app.visiblePhotos
        guard let i = list.firstIndex(where: { $0.id == photoID }) else { return "" }
        return String(localized: "\(i + 1) of \(list.count)")
    }

    // MARK: Geometry

    private func fitted(_ p: PhotoRecord, in r: CGRect) -> CGRect {
        let a = p.height > 0 ? CGFloat(p.width) / CGFloat(p.height) : 1.5
        var w = r.width, h = w / a
        if h > r.height { h = r.height; w = h * a }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private func shrunk(_ r: CGRect) -> CGRect { r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04) }

    // MARK: Actions

    private func step(_ delta: Int) {
        let list = app.visiblePhotos
        guard let i = list.firstIndex(where: { $0.id == photoID }) else { return }
        let n = i + delta
        guard list.indices.contains(n) else { return }
        withAnimation(DS.Motion.adaptive(.easeInOut(duration: 0.25))) {
            app.selection = [list[n].id]
            app.lastClicked = list[n].id
            app.viewerPhotoID = list[n].id
        }
    }

    private func close() {
        guard expanded else { return }
        withAnimation(DS.Motion.adaptive(.spring(response: 0.42, dampingFraction: 0.9))) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (DS.Motion.reduced ? 0.12 : 0.34)) {
            app.viewerPhotoID = nil
        }
    }
}
