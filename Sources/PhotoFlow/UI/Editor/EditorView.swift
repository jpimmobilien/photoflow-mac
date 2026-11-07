import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: EditorModel
    @AppStorage(SettingsKeys.defaultStrength) private var strengthRaw = EnhanceStrength.balanced.rawValue
    @State private var showAdvanced = false
    @State private var showDetail = false
    @State private var savePresetPrompt = false

    init(photo: PhotoRecord, startInCompare: Bool) {
        // The autoclosure is evaluated only once per editor identity (no repeated decoding on re-render).
        _model = StateObject(wrappedValue: EditorModel(photo: photo, recipe: AppModel.shared.recipe(for: photo.id), startInCompare: startInCompare))
    }

    private var strength: EnhanceStrength { EnhanceStrength(rawValue: strengthRaw) ?? .balanced }

    var body: some View {
        HStack(spacing: 0) {
            canvas
            Divider()
            panel.frame(width: 310)
        }
        .onAppear { app.activeEditor = model }
        .onDisappear { if app.activeEditor === model { app.activeEditor = nil } }
        .sheet(isPresented: $savePresetPrompt) {
            TextPromptSheet(title: String(localized: "Save as Preset"), placeholder: String(localized: "Preset name"),
                            confirmTitle: String(localized: "Save")) { name in
                app.saveCustomPreset(name: name, from: model.recipe)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.92).ignoresSafeArea()
            Group {
                if model.zoom {
                    ZoomedView(model: model)
                } else {
                    CompareCanvas(model: model)
                        .padding(28)
                        .padding(.bottom, 54)
                }
            }
            if model.isAnalyzing || (model.zoom && model.isLoadingFull) {
                ProgressView(model.isAnalyzing ? String(localized: "Analyzing…") : String(localized: "Loading full resolution…"))
                    .padding(14).glassCard(cornerRadius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            canvasToolbar.padding(.bottom, 14)
        }
    }

    private var canvasToolbar: some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help(model.undoName.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo"))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help(model.redoName.map { String(localized: "Redo \($0)") } ?? String(localized: "Redo"))
            Divider().frame(height: 18)
            Picker("", selection: $model.mode) {
                ForEach(CompareMode.allCases) { m in
                    Label(m.displayName, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .help(String(localized: "Before/after comparison"))
            Divider().frame(height: 18)
            Toggle(isOn: $model.zoom) { Image(systemName: model.zoom ? "minus.magnifyingglass" : "plus.magnifyingglass") }
                .toggleStyle(.button)
                .help(String(localized: "Zoom to 100 %"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Adjustment panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                autoCard
                if let msg = model.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { model.message = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                    }
                    .padding(10)
                    .glassCard(cornerRadius: 10)
                }
                presetStrip
                lightSection
                colorSection
                detailSection
                straightenSection
                perspectiveSection
                footer
            }
            .padding(14)
        }
        .background(.ultraThinMaterial.opacity(0.5))
    }

    private var autoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Strength"), selection: $strengthRaw) {
                ForEach(EnhanceStrength.allCases) { Text($0.localizedName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button {
                Task { await model.autoEnhance(strength) }
            } label: {
                Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(model.isAnalyzing)
            if let info = model.recipe.auto, !info.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(info.notes, id: \.self) { Label($0, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
    }

    private var presetStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Presets")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { savePresetPrompt = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Save current adjustments as a preset"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.allPresets) { p in
                        Button { Task { await model.applyPreset(p) } } label: {
                            VStack(spacing: 4) {
                                Image(systemName: p.symbol).font(.system(size: 16)).frame(width: 40, height: 32)
                                Text(p.localizedName).font(.caption2).lineLimit(1).frame(width: 64)
                            }
                            .padding(6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help(p.adaptive ? String(localized: "Adapts to each photo, then applies the “\(p.localizedName)” style")
                                         : String(localized: "Applies “\(p.localizedName)”"))
                        .contextMenu {
                            if !p.isBuiltIn { Button(String(localized: "Delete Preset"), role: .destructive) { app.deleteCustomPreset(p.id) } }
                        }
                    }
                }
            }
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<EditRecipe, Double>, _ range: ClosedRange<Double>,
                        step: Double = 1, format: String = "%+.0f") -> some View {
        AdjustmentSlider(title: title, value: model.binding(key), range: range, step: step, format: format) { editing in
            model.dragChanged(editing, name: title)
        }
    }

    private var lightSection: some View {
        PanelSection(title: String(localized: "Lighting"), symbol: "sun.max") {
            slider(String(localized: "Exposure"), \.exposure, -3 ... 3, step: 0.05, format: "%+.2f")
            slider(String(localized: "Brightness"), \.brightness, -100 ... 100)
            slider(String(localized: "Contrast"), \.contrast, -100 ... 100)
            slider(String(localized: "Highlights"), \.highlights, -100 ... 100)
            slider(String(localized: "Shadows"), \.shadows, -100 ... 100)
            DisclosureGroup(String(localized: "Advanced"), isExpanded: $showAdvanced) {
                VStack(spacing: 10) {
                    slider(String(localized: "Whites"), \.whites, -100 ... 100)
                    slider(String(localized: "Blacks"), \.blacks, -100 ... 100)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var colorSection: some View {
        PanelSection(title: String(localized: "Color"), symbol: "paintpalette") {
            Button { Task { await model.autoWhiteBalance() } } label: {
                Label(String(localized: "Auto White Balance"), systemImage: "eyedropper.halffull").frame(maxWidth: .infinity)
            }
            .softButton()
            slider(String(localized: "Temperature"), \.temperature, -100 ... 100)
            slider(String(localized: "Tint"), \.tint, -100 ... 100)
            slider(String(localized: "Vibrance"), \.vibrance, -100 ... 100)
            slider(String(localized: "Saturation"), \.saturation, -100 ... 100)
            Toggle(String(localized: "Black & White"), isOn: Binding(get: { model.recipe.monochrome },
                                                                      set: { v in model.change(String(localized: "Black & White")) { $0.monochrome = v } }))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var detailSection: some View {
        PanelSection(title: String(localized: "Detail"), symbol: "circle.grid.cross", collapsible: true, expanded: $showDetail) {
            slider(String(localized: "Sharpness"), \.sharpness, 0 ... 100, format: "%.0f")
            slider(String(localized: "Noise Reduction"), \.noiseReduction, 0 ... 100, format: "%.0f")
            slider(String(localized: "Clarity"), \.clarity, -100 ... 100)
        }
    }

    private var straightenSection: some View {
        PanelSection(title: String(localized: "Straighten"), symbol: "level") {
            HStack {
                Button { Task { await model.autoStraighten() } } label: {
                    Label(String(localized: "Auto Straighten"), systemImage: "level").frame(maxWidth: .infinity)
                }
                .softButton()
                Button { model.rotate90(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .softButton().help(String(localized: "Rotate 90° left"))
                Button { model.rotate90(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .softButton().help(String(localized: "Rotate 90° right"))
            }
            AdjustmentSlider(title: String(localized: "Angle"), value: model.binding(\.rotation), range: -45 ... 45, step: 0.1, format: "%+.1f°") { editing in
                model.dragChanged(editing, name: String(localized: "Straighten"))
            }
            if model.recipe.hasGeometry {
                Text(String(localized: "Keeps \(Int((model.retainedArea * 100).rounded())) % of the picture after cropping"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var perspectiveSection: some View {
        PanelSection(title: String(localized: "Perspective"), symbol: "perspective") {
            HStack {
                Button { Task { await model.autoPerspective() } } label: {
                    Label(String(localized: "Auto"), systemImage: "building.2").frame(maxWidth: .infinity)
                }
                .softButton()
                .help(String(localized: "Corrects converging lines of buildings and interiors"))
                Button { Task { await model.documentMode() } } label: {
                    Label(String(localized: "Document"), systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
                }
                .softButton()
                .help(String(localized: "Finds a document or sign and straightens it"))
            }
            slider(String(localized: "Vertical"), \.perspectiveVertical, -100 ... 100)
            slider(String(localized: "Horizontal"), \.perspectiveHorizontal, -100 ... 100)
            if model.recipe.documentCorners != nil {
                Label(String(localized: "Document rectified"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            if model.recipe.hasGeometry {
                Button(String(localized: "Reset Geometry")) { model.resetGeometry() }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Button(role: .destructive) { model.resetAll() } label: { Label(String(localized: "Reset All"), systemImage: "arrow.counterclockwise") }
                    .disabled(model.recipe.isIdentity)
                Spacer()
                Button { app.exportRequest = [model.photo.id] } label: { Label(String(localized: "Export…"), systemImage: "square.and.arrow.up") }
            }
            .softButton()
            Text(String(localized: "Edits are saved automatically. The original file is never changed."))
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 6)
    }
}

/// Titled group in the adjustment panel.
struct PanelSection<Content: View>: View {
    var title: String
    var symbol: String
    var collapsible = false
    var expanded: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    init(title: String, symbol: String, collapsible: Bool = false, expanded: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.collapsible = collapsible; self.expanded = expanded; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if collapsible, let expanded {
                DisclosureGroup(isExpanded: expanded) {
                    VStack(alignment: .leading, spacing: 10, content: content).padding(.top, 8)
                } label: {
                    Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                }
            } else {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                content()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }
}

/// Fitted before/after display: edited, original, interactive split slider or side by side.
struct CompareCanvas: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            switch model.mode {
            case .edited:
                image(model.edited ?? model.original, label: nil, in: geo.size)
                    .overlay { if model.showGrid { GridOverlay() } }
            case .original:
                image(model.original, label: String(localized: "Original"), in: geo.size)
            case .sideBySide:
                HStack(spacing: 12) {
                    image(model.original, label: String(localized: "Original"), in: CGSize(width: (geo.size.width - 12) / 2, height: geo.size.height))
                    image(model.edited, label: String(localized: "Edited"), in: CGSize(width: (geo.size.width - 12) / 2, height: geo.size.height))
                }
            case .split:
                SplitCompare(original: model.original, edited: model.edited, split: $model.split, size: geo.size)
            }
        }
    }

    @ViewBuilder
    private func image(_ cg: CGImage?, label: String?, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let cg {
                Image(decorative: cg, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let label, cg != nil {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule()).padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct SplitCompare: View {
    var original: CGImage?
    var edited: CGImage?
    @Binding var split: CGFloat
    var size: CGSize

    var body: some View {
        let frame = fittedRect(for: edited ?? original, in: size)
        ZStack(alignment: .topLeading) {
            if let original {
                Image(decorative: original, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            if let edited {
                Image(decorative: edited, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, frame.width * (1 - split)))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .offset(x: frame.minX, y: frame.minY)
            }
            // Divider handle
            Rectangle().fill(.white).frame(width: 2, height: frame.height)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .offset(x: frame.minX + frame.width * split - 1, y: frame.minY)
            Circle().fill(.white).frame(width: 30, height: 30)
                .overlay(Image(systemName: "arrow.left.and.right").font(.caption.weight(.bold)).foregroundStyle(.black))
                .shadow(radius: 4)
                .offset(x: frame.minX + frame.width * split - 15, y: frame.midY - 15)
            Text(String(localized: "Original")).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule())
                .offset(x: frame.minX + 8, y: frame.minY + 8)
            Text(String(localized: "Edited")).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule())
                .frame(width: frame.width - 16, alignment: .trailing)
                .offset(x: frame.minX + 8, y: frame.minY + 8)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard frame.width > 0 else { return }
            split = min(1, max(0, (v.location.x - frame.minX) / frame.width))
        })
        .help(String(localized: "Drag to compare original (left) and edited (right)"))
    }

    private func fittedRect(for cg: CGImage?, in size: CGSize) -> CGRect {
        guard let cg, cg.width > 0, cg.height > 0 else { return CGRect(origin: .zero, size: size) }
        let s = min(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
        let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// 1:1 zoom (up to 6,000 px) with scrolling; shows original or edited according to the compare mode.
struct ZoomedView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let showOriginal = model.mode == .original
        let cg = showOriginal ? model.zoomedOriginal : (model.zoomedEdited ?? model.zoomedOriginal)
        ScrollView([.horizontal, .vertical]) {
            if let cg {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                Image(decorative: cg, scale: scale)
                    .interpolation(.high)
                    .padding(40)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(showOriginal ? String(localized: "Original · 100 %") : String(localized: "Edited · 100 %"))
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).padding(12)
        }
    }
}

/// Rule-of-thirds style grid shown while straightening.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1 ..< 6 {
                    let x = g.size.width * CGFloat(i) / 6, y = g.size.height * CGFloat(i) / 6
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}
