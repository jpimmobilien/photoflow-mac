import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reusable export options form (used by the export sheet and batch workflows).
struct ExportOptionsForm: View {
    @Binding var options: ExportOptions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            // quick presets
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], spacing: 6) {
                ForEach(ExportOptions.Preset.allCases) { p in
                    ExportPresetTile(preset: p) { withAnimation(DS.Motion.snappy) { options.apply(p) } }
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                row(String(localized: "Format")) {
                    Menu {
                        ForEach(ExportFormat.available) { f in Button(f.displayName) { options.format = f } }
                    } label: { menuLabel(options.format.displayName) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if options.format.isLossy {
                    row(String(localized: "Quality")) {
                        HStack(spacing: DS.Space.xs) {
                            FluidSlider(value: $options.quality, range: 0.3 ... 1.0, step: 0.01)
                                .frame(width: 170)
                            Text(verbatim: "\(Int(options.quality * 100)) %").font(DS.Font.number).foregroundStyle(DS.Palette.blue)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                row(String(localized: "Size")) {
                    Menu {
                        Button(String(localized: "Full Resolution")) { options.maxLongSide = nil }
                        Divider()
                        ForEach([4096, 3072, 2560, 2160, 2048, 1600, 1280, 1080], id: \.self) { n in
                            Button(String(localized: "\(n) px long side")) { options.maxLongSide = n }
                        }
                    } label: { menuLabel(options.maxLongSide.map { n in String(localized: "\(n) px long side") } ?? String(localized: "Full Resolution")) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                row(String(localized: "Color Space")) {
                    GlassSegmented(selection: $options.colorSpace,
                                   options: ExportColorSpace.allCases.map { .init(value: $0, title: $0.displayName) })
                        .frame(width: 200)
                }
                row(String(localized: "File Names")) {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("{name}", text: $options.filenamePattern)
                            .textFieldStyle(.plain).font(DS.Font.body)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glass(.interactive, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .frame(width: 240)
                        Text(String(localized: "Placeholders: {name} {date} {counter} {width} {height}")).font(.system(size: 10)).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                row(String(localized: "Destination")) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "folder.fill").foregroundStyle(DS.Palette.blue)
                        Text(options.destination.lastPathComponent).font(DS.Font.body.weight(.medium)).lineLimit(1)
                            .help(options.destination.path)
                        Button(String(localized: "Choose…")) { chooseDestination() }.softButton()
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Toggle(String(localized: "Apply PhotoFlow edits"), isOn: $options.applyEdits)
                Toggle(String(localized: "Preserve metadata (EXIF, date, camera)"), isOn: $options.preserveMetadata)
                Toggle(String(localized: "Remove location information"), isOn: $options.stripLocation)
                Toggle(String(localized: "Add text watermark"), isOn: Binding(
                    get: { options.watermark != nil },
                    set: { v in withAnimation(DS.Motion.smooth) { options.watermark = v ? (options.watermark ?? WatermarkOptions()) : nil } }))
            }
            .toggleStyle(.glassSwitch)
            .font(DS.Font.body)

            if options.watermark != nil {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        TextField(String(localized: "Text"), text: Binding(get: { options.watermark?.text ?? "" }, set: { options.watermark?.text = $0 }))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glass(.interactive, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .frame(width: 180)
                        Menu {
                            ForEach(WatermarkOptions.Position.allCases) { p in Button(p.displayName) { options.watermark?.position = p } }
                        } label: { menuLabel((options.watermark?.position ?? .bottomRight).displayName) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    HStack(spacing: DS.Space.xs) {
                        Text(String(localized: "Opacity")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        FluidSlider(value: Binding(get: { options.watermark?.opacity ?? 0.6 }, set: { options.watermark?.opacity = $0 }), range: 0.1 ... 1, step: 0.01)
                            .frame(width: 120)
                        Text(String(localized: "Size")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        FluidSlider(value: Binding(get: { options.watermark?.relativeSize ?? 0.03 }, set: { options.watermark?.relativeSize = $0 }), range: 0.01 ... 0.08, step: 0.001)
                            .frame(width: 110)
                    }
                }
                .padding(DS.Space.s)
                .background(DS.Palette.hover, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Label(String(localized: "Originals are never overwritten. Existing files get a new name such as “Photo (2).jpg”."), systemImage: "lock.shield")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).frame(width: 96, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(DS.Font.body.weight(.medium))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(DS.Palette.blue)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(DS.Palette.blue.opacity(0.09), in: Capsule())
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = options.destination
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { options.destinationPath = url.path }
    }
}

struct ExportPresetTile: View {
    var preset: ExportOptions.Preset
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Palette.textPrimary)
                Text(preset.detail).font(.system(size: 10)).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(hovering ? DS.Palette.blue.opacity(0.09) : DS.Palette.hover))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.quick) { hovering = h } }
    }
}

/// Export dialog with a small preview and a size estimate measured by really encoding a sample.
struct ExportSheet: View {
    let photoIDs: [Int64]
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions.fromSettings
    @State private var estimate: Int64?
    @State private var estimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                preview
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Export \(photoIDs.count) Photos")).font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                    Text(String(localized: "\(editedCount) with edits · \(totalBytes.formattedBytes) originals")).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(DS.Palette.blue)
                        if estimating {
                            ProgressView().controlSize(.mini)
                            Text(String(localized: "Estimating size…"))
                        } else if let estimate {
                            Text(String(localized: "Estimated size: ≈ \(estimate.formattedBytes)")).contentTransitionNumeric()
                        } else {
                            Text(String(localized: "Size depends on the original files"))
                        }
                    }
                    .font(DS.Font.callout.weight(.medium)).foregroundStyle(DS.Palette.textPrimary)
                    .padding(.top, 4)
                }
                Spacer()
            }
            ScrollView { ExportOptionsForm(options: $options).padding(.trailing, 4) }
                .frame(maxHeight: 460)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).softButton()
                Button {
                    app.runExport(photoIDs, options: options, source: String(localized: "Manual export"))
                    dismiss()
                } label: { Label(String(localized: "Export"), systemImage: "square.and.arrow.up") }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(GlassButtonStyle(kind: .premium, large: true))
                .disabled(photoIDs.isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 760)
        .task(id: "\(options.format.rawValue)-\(options.quality)-\(options.maxLongSide ?? 0)-\(options.applyEdits)") { await runEstimate() }
    }

    private var preview: some View {
        let photos = app.records(photoIDs.prefix(3))
        return ZStack {
            ForEach(Array(photos.enumerated().reversed()), id: \.element.id) { i, p in
                ThumbnailImage(photo: p, recipe: options.applyEdits ? app.recipe(for: p.id) : nil, pixelSize: 320)
                    .frame(width: 110, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .rotationEffect(.degrees(Double(i) * 6))
                    .offset(x: CGFloat(i) * 9, y: CGFloat(i) * -4)
            }
        }
        .frame(width: 140, height: 100)
    }

    /// Encodes a 1024 px render of the first photo with the chosen format/quality and scales the
    /// measured bytes-per-pixel to the output size of every photo. Shown as an approximation.
    private func runEstimate() async {
        guard let first = app.records(photoIDs.prefix(1)).first, let type = options.format.utType else { estimate = nil; return }
        estimating = true
        let recipe = options.applyEdits ? app.recipe(for: first.id) : nil
        let cg = await ThumbnailService.shared.thumbnail(for: first, recipe: recipe, pixelSize: 1024)
        let quality = options.quality, lossy = options.format.isLossy
        let bpp: Double? = await Task.detached(priority: .utility) { () -> Double? in
            guard let cg else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            var props: [CFString: Any] = [:]
            if lossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return Double(data.length) / Double(max(1, cg.width * cg.height))
        }.value
        guard !Task.isCancelled else { return }
        if let bpp {
            let maxSide = options.maxLongSide
            let total = app.records(photoIDs).reduce(0.0) { sum, p in
                var w = Double(p.width), h = Double(p.height)
                if let m = maxSide, Double(max(p.width, p.height)) > Double(m) {
                    let s = Double(m) / Double(max(p.width, p.height)); w *= s; h *= s
                }
                return sum + w * h * bpp
            }
            withAnimation(DS.Motion.smooth) { estimate = Int64(total) }
        } else {
            estimate = nil
        }
        estimating = false
    }

    private var editedCount: Int { photoIDs.filter { app.recipe(for: $0) != nil }.count }
    private var totalBytes: Int64 { app.records(photoIDs).reduce(0) { $0 + $1.fileSize } }
}

/// Export history as a clear timeline of export jobs.
struct ExportHistoryView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                PageHeader(String(localized: "Export History"), subtitle: String(localized: "Every export PhotoFlow has created.")) {
                    if !app.exportHistory.isEmpty {
                        Button(String(localized: "Clear History")) {
                            try? app.store?.clearExportHistory()
                            app.reloadAll()
                        }
                        .softButton()
                    }
                }
                if app.exportHistory.isEmpty {
                    EmptyStateView(symbol: "clock", title: String(localized: "No Exports Yet"),
                                   message: String(localized: "Exported photos are saved to “Processed Photos” in your Pictures folder by default."),
                                   illustration: .exports)
                        .frame(minHeight: 440)
                } else {
                    HStack(spacing: DS.Space.s) {
                        StatTile(symbol: "square.and.arrow.up.fill", value: "\(app.exportHistory.count)", label: String(localized: "Exports"), tint: DS.Palette.blue)
                        StatTile(symbol: "photo.stack.fill", value: "\(app.exportHistory.reduce(0) { $0 + $1.count })", label: String(localized: "Photos"), tint: DS.Palette.iris)
                        StatTile(symbol: "internaldrive.fill", value: app.exportHistory.reduce(Int64(0)) { $0 + $1.totalBytes }.formattedBytes, label: String(localized: "Total size"), tint: DS.Palette.sky)
                    }
                    LazyVStack(spacing: DS.Space.s) {
                        ForEach(Array(app.exportHistory.enumerated()), id: \.element.id) { i, e in
                            ExportHistoryRow(entry: e).reveal(index: i)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
            .padding(.bottom, DS.Space.huge)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .mask(TopFadeMask())
    }
}

struct ExportHistoryRow: View {
    let entry: ExportHistoryEntry
    @State private var hovering = false

    var body: some View {
        let ok = entry.failed == 0
        HStack(spacing: DS.Space.m) {
            ZStack {
                Circle().fill((ok ? DS.Palette.success : DS.Palette.warning).opacity(0.14))
                Image(systemName: ok ? "checkmark" : "exclamationmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ok ? DS.Palette.success : DS.Palette.warning)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month().year().hour().minute())
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: DS.Space.s)
            HStack(spacing: 6) {
                Badge(text: entry.format, color: DS.Palette.blue, symbol: "photo")
                Badge(text: entry.failed > 0 ? String(localized: "\(entry.count) (\(entry.failed) failed)") : String(localized: "\(entry.count) photos"),
                      color: ok ? DS.Palette.iris : DS.Palette.warning)
                Badge(text: entry.totalBytes.formattedBytes, color: DS.Palette.sky, symbol: "internaldrive")
            }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: entry.destination)) } label: {
                Label((entry.destination as NSString).lastPathComponent, systemImage: "folder")
            }
            .softButton()
            .help(entry.destination)
        }
        .padding(DS.Space.s)
        .padding(.horizontal, DS.Space.xxs)
        .glassCard(cornerRadius: DS.Radius.card)
        .magneticHover(scale: 1.005, lift: 1)
    }
}
