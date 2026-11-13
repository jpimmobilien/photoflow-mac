import SwiftUI

/// Batch processing – a professional processing centre: seven workflows with their own imagery,
/// a live before/after preview computed by the real planner, a clear settings panel, a staged start,
/// a live processing view and a calm completion summary.
struct BatchView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BatchModel
    @State private var resultsMode: CompareMode = .edited
    @State private var launching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                PageHeader(String(localized: "Batch Processing"),
                           subtitle: String(localized: "Improve hundreds or thousands of photos at once. Every photo is analyzed and corrected individually."))
                if model.isRunning || model.hasResults {
                    BatchProgressPanel(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    if !model.items.isEmpty { resultsSection }
                } else {
                    setup
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
            .padding(.bottom, DS.Space.huge)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .mask(TopFadeMask())
        .animation(DS.Motion.adaptive(DS.Motion.page), value: model.isRunning || model.hasResults)
        .onAppear { model.refreshPreview(app) }
        .onChange(of: model.workflow) { _ in model.refreshPreview(app) }
        .onChange(of: model.source) { _ in model.previewPhotoID = nil; model.refreshPreview(app) }
        .onChange(of: model.previewPhotoID) { _ in model.refreshPreview(app) }
        .onChange(of: app.photos.count) { _ in model.refreshPreview(app) }
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                GroupHeader(title: String(localized: "Choose a workflow"), detail: nil)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: DS.Space.m)], spacing: DS.Space.m) {
                    ForEach(Array(BatchWorkflow.predefined.enumerated()), id: \.element.id) { i, wf in
                        WorkflowChoiceCard(workflow: wf, sample: model.previewPhoto(app), recipe: model.cardRecipes[wf.id],
                                           selected: model.workflow.id == wf.id) {
                            withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { model.workflow = wf }
                        }
                        .reveal(index: i)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    previewPanel.frame(minWidth: 520)
                    settingsPanel.frame(width: 372)
                }
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    previewPanel
                    settingsPanel
                }
            }
        }
    }

    // MARK: Live preview

    private var previewPanel: some View {
        let photo = model.previewPhoto(app)
        let scene = SampleScene.for(model.workflow.id)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "eye").foregroundStyle(DS.Palette.blue)
                Text(String(localized: "Live Preview")).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                if model.previewLoading { ProgressView().controlSize(.mini).transition(.opacity) }
                Spacer()
                Text(photo?.filename ?? String(localized: "Sample image"))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
            BeforeAfterSlider(beforeLabel: String(localized: "Original"), afterLabel: model.workflow.localizedName) {
                if let photo {
                    ThumbnailImage(photo: photo, recipe: model.workflow.keepExistingEdits ? app.recipe(for: photo.id) : nil, pixelSize: 1400)
                } else {
                    SamplePhoto(scene: scene, look: .before)
                }
            } after: {
                if let photo {
                    ZStack {
                        ThumbnailImage(photo: photo, recipe: nil, pixelSize: 1400)
                        if let r = model.previewRecipe {
                            ThumbnailImage(photo: photo, recipe: r, pixelSize: 1400)
                                .id(r.cacheKey)
                                .transition(.opacity)
                        }
                    }
                    .animation(DS.Motion.adaptive(.easeInOut(duration: 0.35)), value: model.previewRecipe?.cacheKey)
                } else {
                    SamplePhoto(scene: scene, look: SampleScene.look(for: model.workflow.id))
                        .rotationEffect(.degrees(0))
                }
            }
            .aspectRatio(photo.map { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : 1.5 } ?? 1.5, contentMode: .fit)
            .frame(maxHeight: 460)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
            .frame(maxWidth: .infinity)

            if photo != nil {
                if !model.previewNotes.isEmpty {
                    FlowChips(items: model.previewNotes.prefix(6).map { ("sparkle", $0) })
                        .transition(.opacity)
                }
                previewPicker
            } else {
                Label(String(localized: "Sample image – import photos to preview the workflow on your own pictures."), systemImage: "info.circle")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(DS.Space.m)
        .glassCard(cornerRadius: DS.Radius.panel)
    }

    private var previewPicker: some View {
        let pool = Array(model.photosForSource(app).filter { !$0.isMissing }.prefix(14))
        let current = model.previewPhoto(app)?.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pool) { p in
                    ThumbnailImage(photo: p, recipe: nil, pixelSize: 128)
                        .frame(width: 48, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(p.id == current ? DS.Palette.blue : Color.clear, lineWidth: 2))
                        .opacity(p.id == current ? 1 : 0.75)
                        .onTapGesture { withAnimation(DS.Motion.snappy) { model.previewPhotoID = p.id } }
                        .help(p.filename)
                }
            }
            .padding(2)
        }
    }

    // MARK: Settings

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ControlLabel(text: String(localized: "Photos"))
            sourceMenu

            Divider().opacity(0.6)

            Toggle(isOn: $model.workflow.enhance) {
                Label(String(localized: "Automatic enhancement"), systemImage: "wand.and.stars").font(DS.Font.headline)
            }
            .toggleStyle(.glassSwitch)
            if model.workflow.enhance {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    GlassSegmented(selection: $model.workflow.strength,
                                   options: EnhanceStrength.allCases.map { .init(value: $0, title: $0.localizedName) })
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        OptionChip(title: String(localized: "Exposure & contrast"), symbol: "sun.max", isOn: $model.workflow.options.tone)
                        OptionChip(title: String(localized: "Colors"), symbol: "paintpalette", isOn: $model.workflow.options.color)
                        OptionChip(title: String(localized: "White balance"), symbol: "thermometer.sun", isOn: $model.workflow.options.whiteBalance)
                        OptionChip(title: String(localized: "Detail"), symbol: "circle.grid.cross", isOn: $model.workflow.options.detail)
                        OptionChip(title: String(localized: "Straighten horizons"), symbol: "level", isOn: $model.workflow.options.straighten)
                        OptionChip(title: String(localized: "Correct perspective"), symbol: "perspective", isOn: $model.workflow.options.perspective)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.6)

            GlassMenuRow(title: String(localized: "Preset"), symbol: "camera.filters",
                         value: model.workflow.presetID.flatMap { id in app.allPresets.first { $0.id == id }?.localizedName } ?? String(localized: "None")) {
                Button(String(localized: "None")) { model.workflow.presetID = nil }
                Divider()
                ForEach(app.allPresets) { p in Button(p.localizedName) { model.workflow.presetID = p.id } }
            }
            GlassMenuRow(title: String(localized: "Automatic crop"), symbol: "crop", value: model.workflow.autoCrop.displayName) {
                ForEach(AutoCrop.Mode.choices, id: \.self) { m in Button(m.displayName) { model.workflow.autoCrop = m } }
            }
            Toggle(String(localized: "Keep existing edits and build on them"), isOn: $model.workflow.keepExistingEdits)
                .toggleStyle(.glassSwitch).font(DS.Font.body)

            Divider().opacity(0.6)

            ControlLabel(text: String(localized: "Output"))
            Toggle(String(localized: "Save edits in the library (non-destructive)"), isOn: $model.workflow.saveToLibrary)
                .toggleStyle(.glassSwitch).font(DS.Font.body)
            Toggle(String(localized: "Export processed photos"), isOn: $model.workflow.exportEnabled)
                .toggleStyle(.glassSwitch).font(DS.Font.body)
            if model.workflow.exportEnabled {
                ExportOptionsForm(options: $model.workflow.export)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            startButton
                .padding(.top, DS.Space.xs)
            if !model.workflow.saveToLibrary && !model.workflow.exportEnabled {
                Label(String(localized: "Choose at least one output: save in library or export."), systemImage: "exclamationmark.triangle")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.warning)
            }
            Label(String(localized: "Processes \(AppSettings.batchConcurrency) photos at a time on this Mac (\(HardwareProfile.current.architecture.rawValue))."),
                  systemImage: "cpu")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.workflow.enhance)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.workflow.exportEnabled)
        .padding(DS.Space.l)
        .glassCard(cornerRadius: DS.Radius.panel)
        .scaleEffect(launching && !DS.Motion.reduced ? 0.97 : 1)
        .opacity(launching ? 0.6 : 1)
    }

    private var sourceMenu: some View {
        let count = model.photosForSource(app).count
        return Menu {
            Button(String(localized: "Selected Photos (\(app.selection.count))")) { model.source = .selection }
            Button(String(localized: "All Photos (\(app.photos.count))")) { model.source = .allPhotos }
            if !app.albums.isEmpty {
                Divider()
                ForEach(app.albums) { a in Button(String(localized: "Album: \(a.name) (\(a.photoCount))")) { model.source = .album(a.id) } }
            }
            Divider()
            Button(String(localized: "Choose Folder…")) { model.chooseFolder(app) }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: sourceSymbol).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.Palette.blue)
                    .frame(width: 34, height: 34)
                    .background(DS.Palette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(sourceName).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    Text(String(localized: "\(count) photos")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(DS.Space.xs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .background(DS.Palette.hover, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private var sourceName: String {
        switch model.source {
        case .selection: return String(localized: "Selected Photos")
        case .allPhotos: return String(localized: "All Photos")
        case .album(let id): return app.albums.first { $0.id == id }?.name ?? String(localized: "Album")
        case .folder(let url): return url.lastPathComponent
        }
    }

    private var sourceSymbol: String {
        switch model.source {
        case .selection: return "checkmark.circle"
        case .allPhotos: return "photo.on.rectangle.angled"
        case .album: return "rectangle.stack"
        case .folder: return "folder"
        }
    }

    private var startButton: some View {
        Button {
            guard !launching else { return }
            withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { launching = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + (DS.Motion.reduced ? 0.05 : 0.45)) {
                model.start(app)
                launching = false
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                if launching {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(String(localized: "Preparing…"))
                } else {
                    Image(systemName: "play.fill")
                    Text(String(localized: "Start Processing"))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassButtonStyle(kind: .premium, large: true))
        .keyboardShortcut(.defaultAction)
        .disabled(!model.workflow.saveToLibrary && !model.workflow.exportEnabled)
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                GroupHeader(title: String(localized: "Results"), detail: String(localized: "\(model.finishedCount) of \(model.total)"))
                Toggle(String(localized: "Only problems"), isOn: $model.showOnlyProblems).toggleStyle(.glassSwitch).font(DS.Font.callout)
                    .fixedSize()
                GlassSegmented(selection: $resultsMode,
                               options: [.init(value: .edited, title: String(localized: "Edited")), .init(value: .original, title: String(localized: "Original"))])
                    .frame(width: 190)
                    .help(String(localized: "Batch comparison: switch all results between original and edited"))
                if !model.processedPhotoIDs.isEmpty {
                    Button { app.exportRequest = model.processedPhotoIDs } label: { Label(String(localized: "Export Results…"), systemImage: "square.and.arrow.up") }
                        .softButton()
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: DS.Space.s)], spacing: DS.Space.s) {
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
                ZStack(alignment: .topTrailing) {
                    ThumbnailImage(photo: photo, recipe: resultsMode == .edited ? app.recipe(for: item.id) : nil, pixelSize: 360)
                        .frame(height: 118)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile - 2, style: .continuous))
                        .id("\(item.id)-\(resultsMode.rawValue)")
                        .transition(.opacity)
                    BatchStatusIcon(status: item.status).padding(6)
                }
                .onTapGesture(count: 2) { app.openEditor(item.id, compare: true) }
                Text(item.filename).font(DS.Font.caption).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                if case .failed(let msg) = item.status {
                    Text(msg).font(.system(size: 10)).foregroundStyle(DS.Palette.warning).lineLimit(3)
                } else if !item.notes.isEmpty {
                    Text(item.notes.prefix(3).joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                }
            }
            .padding(DS.Space.xs)
            .glassCard(cornerRadius: DS.Radius.card)
            .animation(DS.Motion.adaptive(.easeInOut(duration: 0.3)), value: resultsMode)
            .help(item.notes.joined(separator: "\n"))
            .contextMenu { PhotoContextMenu(clicked: item.id, explicitIDs: [item.id]) }
        }
    }
}

// MARK: - Processing / completion panel

struct BatchProgressPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BatchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .center, spacing: DS.Space.xl) {
                    ring
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(model.isRunning ? model.workflow.localizedName : String(localized: "Batch finished"))
                            .font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                        Text(statusLine).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                            .contentTransitionNumeric()
                        FlowChips(items: summaryChips)
                            .padding(.top, 2)
                        buttons.padding(.top, DS.Space.xs)
                    }
                    Spacer(minLength: DS.Space.m)
                    if model.isRunning, let current = model.currentItem, let photo = app.photo(current.id) {
                        currentPhoto(photo)
                    } else if !model.isRunning, let last = model.processedPhotoIDs.first, let photo = app.photo(last) {
                        ThumbnailImage(photo: photo, recipe: app.recipe(for: photo.id), pixelSize: 640)
                            .frame(width: 240, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    }
                }
                HStack(spacing: DS.Space.s) {
                    StatTile(symbol: "checkmark.circle.fill", value: "\(model.completedCount)", label: String(localized: "Done"), tint: DS.Palette.success)
                    StatTile(symbol: "minus.circle.fill", value: "\(model.skippedCount)", label: String(localized: "Skipped"), tint: DS.Palette.textTertiary)
                    StatTile(symbol: "exclamationmark.triangle.fill", value: "\(model.failedCount)", label: String(localized: "Failed"), tint: DS.Palette.warning)
                    StatTile(symbol: "clock.fill", value: timeValue, label: model.isRunning ? String(localized: "Remaining") : String(localized: "Duration"), tint: DS.Palette.blue)
                    if model.exportedBytes > 0 {
                        StatTile(symbol: "square.and.arrow.up.fill", value: model.exportedBytes.formattedBytes, label: String(localized: "Exported"), tint: DS.Palette.iris)
                    }
                }
            }
            .padding(DS.Space.xl)
            .glassCard(cornerRadius: DS.Radius.hero)
        }
    }

    private var finishedCleanly: Bool { !model.isRunning && model.failedCount == 0 && model.total > 0 }

    private var ring: some View {
        ZStack {
            ProgressRing(fraction: model.fraction, lineWidth: 11,
                         gradient: model.failedCount > 0 ? [DS.Palette.sun, DS.Palette.peach, DS.Palette.sun] : [DS.Palette.sky, DS.Palette.blue, DS.Palette.iris])
            if finishedCleanly {
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(DS.Palette.success)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    Text(verbatim: "\(Int((model.fraction * 100).rounded())) %")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(DS.Palette.textPrimary)
                        .contentTransitionNumeric()
                    Text(verbatim: "\(model.finishedCount) / \(model.total)")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                }
            }
        }
        .frame(width: 140, height: 140)
        .animation(DS.Motion.adaptive(DS.Motion.celebrate), value: finishedCleanly)
    }

    private func currentPhoto(_ photo: PhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ThumbnailImage(photo: photo, recipe: nil, pixelSize: 640)
                ShimmerBlock(cornerRadius: DS.Radius.card).opacity(0.5)
            }
            .frame(width: 240, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .id(photo.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(photo.filename).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
        }
        .frame(width: 240)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: photo.id)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: DS.Space.xs) {
            if model.isRunning {
                if model.isPaused {
                    Button { model.resume() } label: { Label(String(localized: "Resume"), systemImage: "play.fill") }.softButton()
                } else {
                    Button { model.pause() } label: { Label(String(localized: "Pause"), systemImage: "pause.fill") }.softButton()
                }
                Button { model.cancel() } label: { Label(String(localized: "Cancel"), systemImage: "stop.fill") }
                    .buttonStyle(GlassButtonStyle(kind: .secondary))
                    .foregroundStyle(DS.Palette.danger)
                    .keyboardShortcut(.cancelAction)
            } else {
                if !model.processedPhotoIDs.isEmpty {
                    Button {
                        let ids = model.processedPhotoIDs
                        app.sidebar = .recentlyEdited
                        app.selection = Set(ids)
                    } label: { Label(String(localized: "View Results"), systemImage: "photo.on.rectangle") }
                    .prominentButton()
                }
                if model.failedCount > 0 {
                    Button { model.retryFailed(app) } label: { Label(String(localized: "Retry Failed (\(model.failedCount))"), systemImage: "arrow.clockwise") }.softButton()
                }
                if model.workflow.exportEnabled, let url = model.items.compactMap(\.exportedURL).first {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label(String(localized: "Show Exports"), systemImage: "folder") }.softButton()
                }
                Button { model.reset() } label: { Label(String(localized: "New Batch"), systemImage: "plus") }.softButton()
            }
        }
    }

    private var summaryChips: [(String, String)] {
        var c: [(String, String)] = [("photo.stack", String(localized: "\(model.total) photos"))]
        if model.workflow.enhance { c.append(("wand.and.stars", model.workflow.strength.localizedName)) }
        if let id = model.workflow.presetID, let p = app.allPresets.first(where: { $0.id == id }) { c.append(("camera.filters", p.localizedName)) }
        if model.workflow.saveToLibrary { c.append(("tray.and.arrow.down", String(localized: "Saved in library"))) }
        if model.workflow.exportEnabled { c.append(("square.and.arrow.up", model.workflow.export.format.displayName)) }
        return c
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
}

struct BatchStatusIcon: View {
    var status: BatchItemStatus
    var body: some View {
        Group {
            switch status {
            case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.white.opacity(0.8))
            case .processing: ProgressView().controlSize(.mini)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, DS.Palette.success)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.white, DS.Palette.textTertiary)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .shadow(color: .black.opacity(0.35), radius: 2)
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Workflow cards (each with its own imagery)

/// Which built-in sample scene illustrates a workflow when the library is empty.
enum SampleScene {
    static func `for`(_ id: String) -> SamplePhoto.Scene {
        switch id {
        case "natural": return .lake
        case "bright-clean": return .bright
        case "landscape": return .alpine
        case "portrait": return .portrait
        case "straighten": return .tilted
        case "web": return .lake
        default: return .landscape
        }
    }
    static func look(for id: String) -> SamplePhoto.Look {
        switch id {
        case "natural": return .natural
        case "bright-clean": return .bright
        default: return .after
        }
    }
}

struct WorkflowChoiceCard: View {
    var workflow: BatchWorkflow
    var sample: PhotoRecord?
    var recipe: EditRecipe?
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                WorkflowArt(workflowID: workflow.id, photo: sample, recipe: recipe ?? .illustrativeEnhancement)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card - 5, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white, DS.Palette.blue)
                                .shadow(color: .black.opacity(0.3), radius: 3)
                                .padding(7)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                    .padding(5)
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Image(systemName: workflow.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : DS.Palette.blue)
                        .frame(width: 26, height: 26)
                        .background(selected ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(DS.Palette.blue.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workflow.localizedName).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                        Text(workflow.localizedSummary).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.top, 4)
                .padding(.bottom, DS.Space.s)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            }
            .glassCard(cornerRadius: DS.Radius.card)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(Color.clear), lineWidth: 2))
            .shadow(color: selected ? DS.Palette.blue.opacity(0.3) : .clear, radius: 14, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .magneticHover(scale: selected ? 1 : 1.015, lift: selected ? 0 : 2)
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: selected)
        .accessibilityLabel(Text(workflow.localizedName))
        .accessibilityHint(Text(workflow.localizedSummary))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The picture on each workflow card – the user's photo when available, else a built-in sample scene.
struct WorkflowArt: View {
    var workflowID: String
    var photo: PhotoRecord?
    var recipe: EditRecipe
    @State private var phase = false

    var body: some View {
        ZStack {
            switch workflowID {
            case "straighten":
                StraightenThumb(photo: photo, sample: .tilted)
            case "web":
                ExportThumb(photo: photo, sample: .lake)
            case "auto-everything":
                ZStack(alignment: .topLeading) {
                    beforeAfter
                    Sparkle(size: 16).padding(10).opacity(phase ? 1 : 0.5).scaleEffect(phase ? 1 : 0.7)
                }
            case "natural":
                // gentle cross-fade from a colour cast to neutral colours
                ZStack {
                    layer(after: false)
                    layer(after: true).opacity(phase ? 1 : 0)
                }
            case "bright-clean":
                ZStack {
                    layer(after: false)
                    layer(after: true).opacity(phase ? 1 : 0)
                    RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: 0.7, y: 0.25), startRadius: 0, endRadius: 120)
                        .opacity(phase ? 1 : 0)
                        .blendMode(.screen)
                }
            case "landscape":
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        beforeAfter
                        // animated horizon line
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * 0.45, height: 1.5)
                            .shadow(color: DS.Palette.sky, radius: 4)
                            .offset(x: phase ? g.size.width * 0.6 : -g.size.width * 0.1, y: g.size.height * 0.56)
                    }
                }
            case "portrait":
                ZStack {
                    beforeAfter
                    // soft highlight of the face / skin area
                    Ellipse()
                        .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 58, height: 72)
                        .shadow(color: DS.Palette.peach.opacity(0.8), radius: 6)
                        .offset(y: photo == nil ? -6 : 0)
                        .opacity(phase ? 0.95 : 0.35)
                }
            default:
                beforeAfter
            }
        }
        .clipped()
        .loopAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: phase)
        .onAppear {
            guard !DS.Motion.reduced else { phase = true; return }
            DispatchQueue.main.async { phase = true }
        }
    }

    @ViewBuilder
    private var beforeAfter: some View {
        if let photo {
            BeforeAfterThumb(photo: photo, after: recipe)
        } else {
            SampleBeforeAfter(scene: SampleScene.for(workflowID), look: SampleScene.look(for: workflowID))
        }
    }

    @ViewBuilder
    private func layer(after: Bool) -> some View {
        if let photo {
            ThumbnailImage(photo: photo, recipe: after ? recipe : nil, pixelSize: 480)
        } else {
            SamplePhoto(scene: SampleScene.for(workflowID), look: after ? SampleScene.look(for: workflowID) : .before)
        }
    }
}

/// Before/after split for a sample scene (empty library).
struct SampleBeforeAfter: View {
    var scene: SamplePhoto.Scene
    var look: SamplePhoto.Look
    @State private var phase: CGFloat = 0.42
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                SamplePhoto(scene: scene, look: look)
                SamplePhoto(scene: scene, look: .before)
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * phase) }
                CompareDivider(height: g.size.height, compact: true).offset(x: g.size.width * phase - 11)
            }
        }
        .loopAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: phase)
        .onAppear {
            guard !DS.Motion.reduced else { return }
            DispatchQueue.main.async { phase = 0.62 }
        }
    }
}

// MARK: - Settings controls

/// Toggle as a chip that lights up (used for the enhancement options).
struct OptionChip: View {
    var title: String
    var symbol: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { isOn.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? DS.Palette.blue : DS.Palette.textTertiary)
                    .frame(width: 16)
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(isOn ? DS.Palette.blue.opacity(0.11) : (hovering ? DS.Palette.hover : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(isOn ? DS.Palette.blue.opacity(0.35) : DS.Palette.hairline, lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? String(localized: "On") : String(localized: "Off")))
    }
}

/// A labelled row that opens a menu (glass, with current value).
struct GlassMenuRow<Content: View>: View {
    var title: String
    var symbol: String
    var value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(DS.Font.body).foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            Menu { content() } label: {
                HStack(spacing: 4) {
                    Text(value).font(DS.Font.body.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DS.Palette.blue)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(DS.Palette.blue.opacity(0.09), in: Capsule())
        }
    }
}
