import SwiftUI

struct BatchView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BatchModel
    @State private var resultsMode: CompareMode = .edited

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: String(localized: "Batch Processing"),
                              subtitle: String(localized: "Improve hundreds or thousands of photos at once. Every photo is analyzed and corrected individually."))
                if model.isRunning || model.hasResults {
                    progressCard
                    if model.hasResults { resultsSection }
                } else {
                    workflowPicker
                    configuration
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 1. Workflow

    private var workflowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle(1, String(localized: "Choose a workflow"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(BatchWorkflow.predefined) { wf in
                    let selected = model.workflow.id == wf.id
                    Button { model.workflow = wf } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: wf.symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accentGradient))
                                .frame(width: 42, height: 42)
                                .background(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.accentColor.opacity(0.1)),
                                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Text(wf.localizedName).font(.headline)
                            Text(wf.localizedSummary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .padding(14)
                        .glassCard(cornerRadius: 14)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 2./3. Photos and options

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(2, String(localized: "Select photos"))
            HStack(spacing: 12) {
                Picker(String(localized: "Photos"), selection: $model.source) {
                    Text(String(localized: "Selected Photos (\(app.selection.count))")).tag(BatchModel.Source.selection)
                    Text(String(localized: "All Photos (\(app.photos.count))")).tag(BatchModel.Source.allPhotos)
                    ForEach(app.albums) { a in
                        Text(String(localized: "Album: \(a.name) (\(a.photoCount))")).tag(BatchModel.Source.album(a.id))
                    }
                    if case .folder(let url) = model.source {
                        Text(String(localized: "Folder: \(url.lastPathComponent)")).tag(model.source)
                    }
                }
                .frame(maxWidth: 380)
                Button { model.chooseFolder(app) } label: { Label(String(localized: "Choose Folder…"), systemImage: "folder") }
                    .softButton()
                Spacer()
                Text(String(localized: "\(model.photosForSource(app).count) photos")).foregroundStyle(.secondary).monospacedDigit()
            }

            stepTitle(3, String(localized: "Processing options"))
            VStack(alignment: .leading, spacing: 14) {
                Toggle(String(localized: "Automatic enhancement"), isOn: $model.workflow.enhance)
                if model.workflow.enhance {
                    Picker(String(localized: "Strength"), selection: $model.workflow.strength) {
                        ForEach(EnhanceStrength.allCases) { Text($0.localizedName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    HStack(spacing: 18) {
                        Toggle(String(localized: "Exposure & contrast"), isOn: $model.workflow.options.tone)
                        Toggle(String(localized: "Colors"), isOn: $model.workflow.options.color)
                        Toggle(String(localized: "White balance"), isOn: $model.workflow.options.whiteBalance)
                        Toggle(String(localized: "Detail"), isOn: $model.workflow.options.detail)
                    }
                    HStack(spacing: 18) {
                        Toggle(String(localized: "Straighten horizons"), isOn: $model.workflow.options.straighten)
                        Toggle(String(localized: "Correct perspective"), isOn: $model.workflow.options.perspective)
                    }
                }
                HStack(spacing: 18) {
                    Picker(String(localized: "Preset"), selection: $model.workflow.presetID) {
                        Text(String(localized: "None")).tag(String?.none)
                        ForEach(app.allPresets) { Text($0.localizedName).tag(String?.some($0.id)) }
                    }
                    .frame(maxWidth: 300)
                    Picker(String(localized: "Automatic crop"), selection: $model.workflow.autoCrop) {
                        ForEach(AutoCrop.Mode.choices, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(maxWidth: 300)
                }
                Toggle(String(localized: "Keep existing edits and build on them"), isOn: $model.workflow.keepExistingEdits)
                Divider()
                Toggle(String(localized: "Save edits in the library (non-destructive)"), isOn: $model.workflow.saveToLibrary)
                Toggle(String(localized: "Export processed photos"), isOn: $model.workflow.exportEnabled)
                if model.workflow.exportEnabled {
                    ExportOptionsForm(options: $model.workflow.export)
                        .padding(.leading, 20)
                }
            }
            .padding(16)
            .glassCard()

            HStack {
                Label(String(localized: "Processes \(AppSettings.batchConcurrency) photos at a time on this Mac (\(HardwareProfile.current.architecture.rawValue))."),
                      systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.start(app) } label: {
                    Label(String(localized: "Start Processing"), systemImage: "play.fill").padding(.horizontal, 10)
                }
                .prominentButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.workflow.saveToLibrary && !model.workflow.exportEnabled)
            }
            if !model.workflow.saveToLibrary && !model.workflow.exportEnabled {
                Text(String(localized: "Choose at least one output: save in library or export."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func stepTitle(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.accentGradient, in: Circle())
            Text(title).font(.headline)
        }
    }

    // MARK: - Progress

    private var progressCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.workflow.localizedName).font(.headline)
                        Text(statusLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if model.isRunning {
                        if model.isPaused {
                            Button { model.resume() } label: { Label(String(localized: "Resume"), systemImage: "play.fill") }.softButton()
                        } else {
                            Button { model.pause() } label: { Label(String(localized: "Pause"), systemImage: "pause.fill") }.softButton()
                        }
                        Button(role: .destructive) { model.cancel() } label: { Label(String(localized: "Cancel"), systemImage: "stop.fill") }.softButton()
                    } else {
                        if model.failedCount > 0 {
                            Button { model.retryFailed(app) } label: { Label(String(localized: "Retry Failed (\(model.failedCount))"), systemImage: "arrow.clockwise") }.softButton()
                        }
                        if model.workflow.exportEnabled, let url = model.items.compactMap(\.exportedURL).first {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label(String(localized: "Show Exports"), systemImage: "folder") }.softButton()
                        }
                        Button { model.reset() } label: { Label(String(localized: "New Batch"), systemImage: "plus") }.prominentButton()
                    }
                }
                ProgressView(value: model.fraction).progressViewStyle(.linear).tint(model.failedCount > 0 ? .orange : .accentColor)
                HStack(spacing: 14) {
                    StatTile(symbol: "checkmark.circle.fill", value: "\(model.completedCount)", label: String(localized: "Done"), tint: .green)
                    StatTile(symbol: "exclamationmark.triangle.fill", value: "\(model.failedCount)", label: String(localized: "Failed"), tint: .orange)
                    StatTile(symbol: "clock.fill", value: timeValue, label: model.isRunning ? String(localized: "Remaining") : String(localized: "Duration"), tint: .blue)
                    if model.exportedBytes > 0 {
                        StatTile(symbol: "square.and.arrow.up.fill", value: model.exportedBytes.formattedBytes, label: String(localized: "Exported"), tint: .purple)
                    }
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    private var statusLine: String {
        if model.isPaused { return String(localized: "Paused – \(model.finishedCount) of \(model.total)") }
        if model.isRunning { return String(localized: "Processing \(model.finishedCount) of \(model.total)…") }
        return String(localized: "Finished – \(model.completedCount) of \(model.total) processed")
    }

    private var timeValue: String {
        if model.isRunning { return model.remaining?.formattedDuration ?? "–" }
        guard let s = model.startedAt, let e = model.finishedAt else { return "–" }
        return e.timeIntervalSince(s).formattedDuration
    }

    // MARK: - Results & batch comparison

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Results")).font(.headline)
                Spacer()
                Toggle(String(localized: "Only problems"), isOn: $model.showOnlyProblems).toggleStyle(.switch).controlSize(.small)
                Picker("", selection: $resultsMode) {
                    Text(String(localized: "Edited")).tag(CompareMode.edited)
                    Text(String(localized: "Original")).tag(CompareMode.original)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                .help(String(localized: "Batch comparison: switch all results between original and edited"))
                if !model.processedPhotoIDs.isEmpty {
                    Button { app.exportRequest = model.processedPhotoIDs } label: { Label(String(localized: "Export Results…"), systemImage: "square.and.arrow.up") }.softButton()
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(model.items.filter { !model.showOnlyProblems || !isDone($0.status) }) { item in
                    resultCell(item)
                }
            }
        }
    }

    private func isDone(_ s: BatchItemStatus) -> Bool { if case .done = s { return true }; return false }

    @ViewBuilder
    private func resultCell(_ item: BatchModel.Item) -> some View {
        if let photo = app.photo(item.id) {
            VStack(alignment: .leading, spacing: 6) {
                ThumbnailImage(photo: photo, recipe: resultsMode == .edited ? app.recipe(for: item.id) : nil, pixelSize: 360)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onTapGesture(count: 2) { app.openEditor(item.id, compare: true) }
                HStack(spacing: 5) {
                    statusIcon(item.status)
                    Text(item.filename).font(.caption).lineLimit(1)
                }
                if case .failed(let msg) = item.status {
                    Text(msg).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                } else if !item.notes.isEmpty {
                    Text(item.notes.prefix(3).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(8)
            .glassCard(cornerRadius: 12)
            .help(item.notes.joined(separator: "\n"))
            .contextMenu { PhotoContextMenu(clicked: item.id, explicitIDs: [item.id]) }
        }
    }

    @ViewBuilder
    private func statusIcon(_ s: BatchItemStatus) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .processing: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}
