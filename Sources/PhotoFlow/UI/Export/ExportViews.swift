import SwiftUI
import AppKit

/// Reusable export options form (used by the export sheet and batch workflows).
struct ExportOptionsForm: View {
    @Binding var options: ExportOptions
    @State private var watermarkOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ExportOptions.Preset.allCases) { p in
                    Button { options.apply(p) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).font(.callout.weight(.semibold))
                            Text(p.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(width: 128, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(String(localized: "Format")).foregroundStyle(.secondary)
                    Picker("", selection: $options.format) {
                        ForEach(ExportFormat.available) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                if options.format.isLossy {
                    GridRow {
                        Text(String(localized: "Quality")).foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $options.quality, in: 0.3 ... 1.0).frame(width: 200)
                            Text(verbatim: "\(Int(options.quality * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                GridRow {
                    Text(String(localized: "Size")).foregroundStyle(.secondary)
                    Picker("", selection: $options.maxLongSide) {
                        Text(String(localized: "Full Resolution")).tag(Int?.none)
                        ForEach([4096, 3072, 2560, 2160, 2048, 1600, 1280, 1080], id: \.self) { n in
                            Text(String(localized: "\(n) px long side")).tag(Int?.some(n))
                        }
                    }
                    .labelsHidden().frame(width: 200)
                }
                GridRow {
                    Text(String(localized: "Color Space")).foregroundStyle(.secondary)
                    Picker("", selection: $options.colorSpace) {
                        ForEach(ExportColorSpace.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                GridRow {
                    Text(String(localized: "File Names")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("{name}", text: $options.filenamePattern).textFieldStyle(.roundedBorder).frame(width: 260)
                        Text(String(localized: "Placeholders: {name} {date} {counter} {width} {height}")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(String(localized: "Destination")).foregroundStyle(.secondary)
                    HStack {
                        Text(options.destination.path).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Choose…")) { chooseDestination() }
                    }
                }
                GridRow {
                    Text(String(localized: "Metadata")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(String(localized: "Preserve metadata (EXIF, date, camera)"), isOn: $options.preserveMetadata)
                        Toggle(String(localized: "Remove location information"), isOn: $options.stripLocation)
                    }
                }
                GridRow {
                    Text(String(localized: "Edits")).foregroundStyle(.secondary)
                    Toggle(String(localized: "Apply PhotoFlow edits"), isOn: $options.applyEdits)
                }
                GridRow {
                    Text(String(localized: "Watermark")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(String(localized: "Add text watermark"), isOn: Binding(
                            get: { options.watermark != nil },
                            set: { options.watermark = $0 ? (options.watermark ?? WatermarkOptions()) : nil }))
                        if options.watermark != nil {
                            HStack {
                                TextField(String(localized: "Text"), text: Binding(get: { options.watermark?.text ?? "" },
                                                                                   set: { options.watermark?.text = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 180)
                                Picker("", selection: Binding(get: { options.watermark?.position ?? .bottomRight },
                                                              set: { options.watermark?.position = $0 })) {
                                    ForEach(WatermarkOptions.Position.allCases) { Text($0.displayName).tag($0) }
                                }
                                .labelsHidden().frame(width: 140)
                            }
                            HStack {
                                Text(String(localized: "Opacity")).font(.caption)
                                Slider(value: Binding(get: { options.watermark?.opacity ?? 0.6 }, set: { options.watermark?.opacity = $0 }), in: 0.1 ... 1)
                                    .frame(width: 140)
                                Text(String(localized: "Size")).font(.caption)
                                Slider(value: Binding(get: { options.watermark?.relativeSize ?? 0.03 }, set: { options.watermark?.relativeSize = $0 }), in: 0.01 ... 0.08)
                                    .frame(width: 120)
                            }
                        }
                    }
                }
            }
            Text(String(localized: "Originals are never overwritten. Existing files get a new name such as “Photo (2).jpg”."))
                .font(.caption).foregroundStyle(.secondary)
        }
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

struct ExportSheet: View {
    let photoIDs: [Int64]
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions.fromSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.on.square").font(.title).foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading) {
                    Text(String(localized: "Export \(photoIDs.count) Photos")).font(.title3.weight(.semibold))
                    Text(String(localized: "\(editedCount) with edits · \(totalBytes.formattedBytes) originals")).font(.callout).foregroundStyle(.secondary)
                }
            }
            ExportOptionsForm(options: $options)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Export")) {
                    app.runExport(photoIDs, options: options, source: String(localized: "Manual export"))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .prominentButton()
                .disabled(photoIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 720)
    }

    private var editedCount: Int { photoIDs.filter { app.recipe(for: $0) != nil }.count }
    private var totalBytes: Int64 { app.records(photoIDs).reduce(0) { $0 + $1.fileSize } }
}

struct ExportHistoryView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: String(localized: "Export History"), subtitle: String(localized: "Every export PhotoFlow has created."))
                Spacer()
                if !app.exportHistory.isEmpty {
                    Button(String(localized: "Clear History")) {
                        try? app.store?.clearExportHistory()
                        app.reloadAll()
                    }
                    .softButton()
                }
            }
            .padding(20)
            if app.exportHistory.isEmpty {
                EmptyStateView(symbol: "clock", title: String(localized: "No Exports Yet"),
                               message: String(localized: "Exported photos are saved to “Processed Photos” in your Pictures folder by default."))
            } else {
                Table(app.exportHistory) {
                    TableColumn(String(localized: "Date")) { e in Text(e.date, format: .dateTime.year().month().day().hour().minute()) }
                    TableColumn(String(localized: "Source")) { e in Text(e.source) }
                    TableColumn(String(localized: "Photos")) { e in
                        Text(e.failed > 0 ? String(localized: "\(e.count) (\(e.failed) failed)") : "\(e.count)").monospacedDigit()
                    }
                    TableColumn(String(localized: "Format")) { e in Text(e.format) }
                    TableColumn(String(localized: "Size")) { e in Text(e.totalBytes.formattedBytes).monospacedDigit() }
                    TableColumn(String(localized: "Destination")) { e in
                        HStack {
                            Text(e.destination).lineLimit(1).truncationMode(.middle)
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: e.destination)) } label: { Image(systemName: "arrow.right.circle") }
                                .buttonStyle(.plain).help(String(localized: "Open folder"))
                        }
                    }
                }
            }
        }
    }
}
