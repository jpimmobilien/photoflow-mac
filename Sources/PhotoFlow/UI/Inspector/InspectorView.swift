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
        .background(.ultraThinMaterial.opacity(0.5))
    }

    // MARK: - Single photo

    @ViewBuilder
    private func single(_ photo: PhotoRecord) -> some View {
        ThumbnailImage(photo: photo, recipe: app.recipe(for: photo.id), pixelSize: 640, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(count: 2) { app.openEditor(photo.id) }

        VStack(alignment: .leading, spacing: 2) {
            Text(photo.filename).font(.headline).lineLimit(2).textSelection(.enabled)
            Text((photo.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }

        enhanceCard(ids: [photo.id])

        if let info = app.recipe(for: photo.id)?.auto, !info.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "What Auto Enhance did"), systemImage: "sparkles").font(.subheadline.weight(.semibold))
                ForEach(info.notes, id: \.self) { n in
                    Label(n, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
        }

        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Information")).font(.subheadline.weight(.semibold))
            PhotoMetadataGrid(photo: photo)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .prominentButton()
            .controlSize(.large)
            .disabled(app.activity != nil)
            Text(String(localized: "Each photo is analyzed individually on this Mac."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
    }
}
