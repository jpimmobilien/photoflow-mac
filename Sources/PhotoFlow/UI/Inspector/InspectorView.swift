import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(SettingsKeys.defaultStrength) private var strengthRaw = EnhanceStrength.balanced.rawValue

    private var strength: EnhanceStrength { EnhanceStrength(rawValue: strengthRaw) ?? .balanced }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let selected = app.selectedPhotos
                if selected.count == 1, let photo = selected.first {
                    single(photo)
                } else if selected.count > 1 {
                    multiple(selected)
                } else {
                    nothing
                }
            }
            .padding(16)
        }
        .background(
            AmbientBackground(photo: app.selectedPhotos.count == 1 ? app.selectedPhotos.first : nil,
                              recipe: app.selectedPhotos.first.flatMap { app.recipe(for: $0.id) }, intensity: 0.9)
        )
        .animation(DS.Motion.smooth, value: app.selection)
    }

    // MARK: - Single photo

    @ViewBuilder
    private func single(_ photo: PhotoRecord) -> some View {
        let recipe = app.recipe(for: photo.id)
        ThumbnailImage(photo: photo, recipe: recipe, pixelSize: 640, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
            .onTapGesture(count: 2) { app.openEditor(photo.id) }
            .id(photo.id)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        VStack(alignment: .leading, spacing: 4) {
            Text(photo.filename).font(DS.Font.headline).lineLimit(2).textSelection(.enabled)
            Text(photo.displayDate.formatted(date: .long, time: .shortened)).font(DS.Font.caption).foregroundStyle(.secondary)
        }

        // Key facts as chips
        FlowChips(items: chips(for: photo))

        HistogramView(photo: photo, recipe: recipe)
            .frame(height: 64)
            .help(String(localized: "Histogram – distribution of dark (left) to bright (right) tones"))

        enhanceCard(ids: [photo.id])

        if let info = recipe?.auto, !info.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "What Auto Enhance did"), systemImage: "sparkles").font(DS.Font.headline)
                ForEach(info.notes, id: \.self) { n in
                    Label(n, systemImage: "checkmark").font(DS.Font.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
        }

        DisclosureGroup {
            PhotoMetadataGrid(photo: photo).padding(.top, 6)
        } label: {
            Text(String(localized: "Information")).font(DS.Font.headline)
        }
        .padding(12)
        .glassCard(cornerRadius: 12)

        HStack {
            Button { app.openEditor(photo.id) } label: { Label(String(localized: "Edit"), systemImage: "slider.horizontal.3") }
            Button { app.openEditor(photo.id, compare: true) } label: { Label(String(localized: "Compare"), systemImage: "square.split.2x1") }
        }
        .softButton()

        if photo.isMissing {
            Button { app.locate(photo) } label: { Label(String(localized: "Locate Original…"), systemImage: "magnifyingglass") }
                .softButton()
        }
    }

    private func chips(for p: PhotoRecord) -> [(String, String)] {
        var c: [(String, String)] = [
            ("aspectratio", "\(p.width) × \(p.height)"),
            ("doc", p.fileSize.formattedBytes),
            ("photo", p.formatName)
        ]
        if let cam = p.cameraDescription { c.append(("camera", cam)) }
        if p.isEdited { c.append(("slider.horizontal.3", String(localized: "Edited"))) }
        if p.isFavorite { c.append(("heart.fill", String(localized: "Favorite"))) }
        return c
    }

    // MARK: - Multiple

    @ViewBuilder
    private func multiple(_ photos: [PhotoRecord]) -> some View {
        let total = photos.reduce(Int64(0)) { $0 + $1.fileSize }
        HStack(spacing: -24) {
            ForEach(photos.prefix(4)) { p in
                ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 256)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                    .shadow(radius: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)

        Text(String(localized: "\(photos.count) photos selected")).font(.headline)
        Text(total.formattedBytes).font(.callout).foregroundStyle(.secondary)

        enhanceCard(ids: photos.map(\.id))

        VStack(alignment: .leading, spacing: 8) {
            Button { app.sidebar = .batch; app.batch.source = .selection } label: {
                Label(String(localized: "Batch Process Selection…"), systemImage: "square.stack.3d.up")
            }
            Button { app.exportRequest = photos.map(\.id) } label: { Label(String(localized: "Export…"), systemImage: "square.and.arrow.up") }
            Button { app.newAlbumRequest = photos.map(\.id) } label: { Label(String(localized: "New Album from Selection"), systemImage: "rectangle.stack.badge.plus") }
            Button(role: .destructive) { app.requestTrash(photos.map(\.id)) } label: { Label(String(localized: "Move to Trash"), systemImage: "trash") }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Nothing selected

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Library")).font(.headline)
            StatTile(symbol: "photo.on.rectangle", value: "\(app.photos.count)", label: String(localized: "Photos"), tint: .blue)
            StatTile(symbol: "slider.horizontal.3", value: "\(app.editedCount)", label: String(localized: "Edited"), tint: .purple)
            StatTile(symbol: "internaldrive", value: app.totalBytes.formattedBytes, label: String(localized: "Total size"), tint: .teal)
            Text(String(localized: "Select a photo to see its details. Double-click to edit."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Auto Enhance card

    private func enhanceCard(ids: [Int64]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Strength"), selection: $strengthRaw) {
                ForEach(EnhanceStrength.allCases) { Text($0.localizedName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button { app.autoEnhance(ids, strength: strength) } label: {
                Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .magicButton()
            .controlSize(.large)
            .disabled(app.activity != nil)
            Text(String(localized: "Each photo is analyzed individually on this Mac."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
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
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.07), in: Capsule())
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
