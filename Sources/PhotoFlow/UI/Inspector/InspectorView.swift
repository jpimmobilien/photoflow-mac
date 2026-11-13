import SwiftUI

/// Floating inspector next to the library (Floating Glass). Shows details for one photo, a summary for
/// several, or library statistics when nothing is selected.
struct InspectorView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                let selected = app.selectedPhotos
                if selected.count == 1, let photo = selected.first {
                    PhotoDetailsPanel(photo: photo, showsPreview: true)
                        .id(photo.id)
                        .transition(.opacity.combined(with: .offset(x: 12)))
                } else if selected.count > 1 {
                    multiple(selected)
                        .transition(.opacity)
                } else {
                    nothing
                        .transition(.opacity)
                }
            }
            .padding(DS.Space.m)
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: app.selection)
    }

    // MARK: - Multiple

    @ViewBuilder
    private func multiple(_ photos: [PhotoRecord]) -> some View {
        let total = photos.reduce(Int64(0)) { $0 + $1.fileSize }
        ZStack {
            ForEach(Array(photos.prefix(4).enumerated().reversed()), id: \.element.id) { i, p in
                ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 256)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous).strokeBorder(.white.opacity(0.75), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .rotationEffect(.degrees(Double(i) * 6 - 6))
                    .offset(x: CGFloat(i) * 16 - 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: photos.map(\.id))

        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "\(photos.count) photos selected")).font(DS.Font.title2).foregroundStyle(DS.Palette.textPrimary)
            Text(total.formattedBytes).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
        }

        EnhanceCard(ids: photos.map(\.id))

        VStack(alignment: .leading, spacing: 0) {
            InspectorAction(title: String(localized: "Batch Process Selection…"), symbol: "wand.and.stars") {
                app.sidebar = .batch; app.batch.source = .selection
            }
            InspectorAction(title: String(localized: "Export…"), symbol: "square.and.arrow.up") { app.exportRequest = photos.map(\.id) }
            InspectorAction(title: String(localized: "New Album from Selection"), symbol: "rectangle.stack.badge.plus") { app.newAlbumRequest = photos.map(\.id) }
            InspectorAction(title: String(localized: "Move to Trash"), symbol: "trash", destructive: true) { app.requestTrash(photos.map(\.id)) }
        }
        .padding(DS.Space.xxs)
        .background(DS.Palette.hover, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    // MARK: - Nothing selected

    private var nothing: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ControlLabel(text: String(localized: "Library"))
            StatTile(symbol: "photo.on.rectangle", value: "\(app.photos.count)", label: String(localized: "Photos"), tint: DS.Palette.blue)
            StatTile(symbol: "wand.and.stars", value: "\(app.editedCount)", label: String(localized: "Edited"), tint: DS.Palette.iris)
            StatTile(symbol: "heart.fill", value: "\(app.favoriteCount)", label: String(localized: "Favorites"), tint: DS.Palette.heart)
            StatTile(symbol: "internaldrive", value: app.totalBytes.formattedBytes, label: String(localized: "Total size"), tint: DS.Palette.sky)
            Label(String(localized: "Select a photo to see its details. Double-click or press Space to open it."), systemImage: "info.circle")
                .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                .padding(.top, DS.Space.xxs)
        }
    }
}

/// Everything about one photo – used by the library inspector and the full-size viewer.
struct PhotoDetailsPanel: View {
    let photo: PhotoRecord
    var showsPreview = true
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let recipe = app.recipe(for: photo.id)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if showsPreview {
                ThumbnailImage(photo: photo, recipe: recipe, pixelSize: 640, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                    .onTapGesture(count: 2) { app.openViewer(photo.id) }
                    .help(String(localized: "Double-click to open"))
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.filename).font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary).lineLimit(2).textSelection(.enabled)
                    Text(photo.displayDate.formatted(date: .long, time: .shortened)).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Button { app.toggleFavorite([photo.id]) } label: { HeartIcon(filled: photo.isFavorite) }
                    .buttonStyle(GlassIconButtonStyle(size: 30, tint: photo.isFavorite ? DS.Palette.heart : nil))
                    .help(String(localized: "Favorite"))
            }

            HistogramView(photo: photo, recipe: recipe)
                .frame(height: 70)
                .help(String(localized: "Histogram – distribution of dark (left) to bright (right) tones"))

            VStack(spacing: 0) {
                infoRow("aspectratio", String(localized: "Resolution"), "\(photo.width) × \(photo.height) · \(String(format: "%.1f", photo.megapixels)) MP")
                infoRow("doc", String(localized: "Format"), photo.formatName)
                infoRow("internaldrive", String(localized: "File Size"), photo.fileSize.formattedBytes)
                if let d = photo.captureDate { infoRow("calendar", String(localized: "Taken"), d.formatted(date: .abbreviated, time: .shortened)) }
                if let cam = photo.cameraDescription { infoRow("camera", String(localized: "Camera"), cam) }
                if let lens = photo.lensModel { infoRow("camera.aperture", String(localized: "Lens"), lens) }
                if let ex = photo.exposureDescription { infoRow("timer", String(localized: "Exposure"), ex) }
                infoRow(photo.isEdited ? "wand.and.stars" : "photo", String(localized: "Status"), status, tint: photo.isEdited ? DS.Palette.iris : nil, last: true)
            }
            .padding(.horizontal, DS.Space.s)
            .background(DS.Palette.hover, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

            EnhanceCard(ids: [photo.id])

            if let info = recipe?.auto, !info.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "What Auto Enhance did"), systemImage: "sparkles").font(DS.Font.headline)
                        .foregroundStyle(DS.Palette.textPrimary)
                    ForEach(info.notes, id: \.self) { n in
                        Label(n, systemImage: "checkmark").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.iris.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }

            HStack(spacing: DS.Space.xs) {
                Button { app.openEditor(photo.id) } label: { Label(String(localized: "Edit"), systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                Button { app.openEditor(photo.id, compare: true) } label: { Label(String(localized: "Compare"), systemImage: "square.split.2x1").frame(maxWidth: .infinity) }
            }
            .softButton()

            if photo.isMissing {
                Button { app.locate(photo) } label: { Label(String(localized: "Locate Original…"), systemImage: "magnifyingglass") }
                    .softButton()
            }
        }
    }

    private var status: String {
        if photo.isMissing { return String(localized: "Original missing") }
        if let e = photo.editedAt { return String(localized: "Edited \(e.formatted(.relative(presentation: .named)))") }
        return String(localized: "Original (not edited)")
    }

    private func infoRow(_ symbol: String, _ key: String, _ value: String, tint: Color? = nil, last: Bool = false) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint ?? DS.Palette.textTertiary).frame(width: 16)
            Text(key).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            Spacer(minLength: DS.Space.xs)
            Text(value).font(DS.Font.callout.weight(.medium)).foregroundStyle(tint ?? DS.Palette.textPrimary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(DS.Palette.hairline).frame(height: 0.5) } }
    }
}

/// Auto Enhance moment (Premium Glass): strength + action.
struct EnhanceCard: View {
    var ids: [Int64]
    @EnvironmentObject private var app: AppModel
    @AppStorage(SettingsKeys.defaultStrength) private var strengthRaw = EnhanceStrength.balanced.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(DS.Palette.magic)
                Text(String(localized: "Auto Enhance")).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
            }
            GlassSegmented(selection: $strengthRaw,
                           options: EnhanceStrength.allCases.map { .init(value: $0.rawValue, title: $0.localizedName) })
            Button { app.autoEnhance(ids, strength: EnhanceStrength(rawValue: strengthRaw) ?? .balanced) } label: {
                Label(String(localized: "Auto Enhance"), systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(kind: .premium, large: true))
            .disabled(app.activity != nil)
            Text(String(localized: "Each photo is analyzed individually on this Mac."))
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Space.s)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(LinearGradient(colors: [DS.Palette.blue.opacity(0.08), DS.Palette.iris.opacity(0.08), DS.Palette.sun.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.rim, lineWidth: 0.6))
        }
    }
}

struct InspectorAction: View {
    var title: String
    var symbol: String
    var destructive = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).opacity(hovering ? 0.7 : 0.3)
            }
            .font(DS.Font.body)
            .foregroundStyle(destructive ? DS.Palette.danger : DS.Palette.textPrimary)
            .padding(.horizontal, DS.Space.s).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(hovering ? DS.Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.quick) { hovering = h } }
    }
}

/// Wrapping row of small capsule chips (icon + text).
struct FlowChips: View {
    var items: [(String, String)]
    var body: some View {
        FlowLayoutCompat(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item.1, systemImage: item.0)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(DS.Palette.hover, in: Capsule())
            }
        }
    }
}

/// Simple flow layout (macOS 13 Layout protocol).
struct FlowLayoutCompat: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(maxW, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
