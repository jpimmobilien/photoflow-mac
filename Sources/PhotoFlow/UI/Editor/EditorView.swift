import SwiftUI

/// Photo editor – the photo is the centre, the stage is dimmed and lit by the photo's own colours,
/// tools are grouped (Light · Color · Detail · Geometry · Crop · Effects) in a floating glass panel.
struct EditorView: View {
    enum ToolGroup: String, CaseIterable, Identifiable {
        case light, color, detail, geometry, crop, effects
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: return String(localized: "Lighting")
            case .color: return String(localized: "Color")
            case .detail: return String(localized: "Detail")
            case .geometry: return String(localized: "Geometry")
            case .crop: return String(localized: "Crop")
            case .effects: return String(localized: "Effects")
            }
        }
        var symbol: String {
            switch self {
            case .light: return "sun.max"
            case .color: return "paintpalette"
            case .detail: return "circle.grid.cross"
            case .geometry: return "level"
            case .crop: return "crop"
            case .effects: return "camera.filters"
            }
        }
    }

    @EnvironmentObject private var app: AppModel
    @StateObject private var model: EditorModel
    @AppStorage(SettingsKeys.defaultStrength) private var strengthRaw = EnhanceStrength.balanced.rawValue
    @AppStorage("editorToolGroup") private var groupRaw = ToolGroup.light.rawValue
    @State private var showAdvanced = false
    @State private var savePresetPrompt = false
    @State private var savedPulse = false
    @Namespace private var tabs

    init(photo: PhotoRecord, startInCompare: Bool) {
        // The autoclosure is evaluated only once per editor identity (no repeated decoding on re-render).
        _model = StateObject(wrappedValue: EditorModel(photo: photo, recipe: AppModel.shared.recipe(for: photo.id), startInCompare: startInCompare))
    }

    private var strength: EnhanceStrength { EnhanceStrength(rawValue: strengthRaw) ?? .balanced }
    private var group: ToolGroup { ToolGroup(rawValue: groupRaw) ?? .light }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed stage, softly lit by the photo (global ambient light shows through)
            DS.Palette.stage.opacity(0.82).ignoresSafeArea()

            HStack(spacing: DS.Space.s) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panel
                    .frame(width: 330)
                    .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .padding(.top, 58)
            .padding([.horizontal, .bottom], DS.Space.s)

            topBar
        }
        .onAppear { app.activeEditor = model }
        .onDisappear { if app.activeEditor === model { app.activeEditor = nil } }
        .onChange(of: model.recipe) { _ in flashSaved() }
        .sheet(isPresented: $savePresetPrompt) {
            TextPromptSheet(title: String(localized: "Save as Preset"), placeholder: String(localized: "Preset name"),
                            confirmTitle: String(localized: "Save")) { name in
                app.saveCustomPreset(name: name, from: model.recipe)
            }
        }
    }

    private func flashSaved() {
        withAnimation(DS.Motion.snappy) { savedPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(DS.Motion.smooth) { savedPulse = false } }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: DS.Space.xs) {
                Color.clear.frame(width: 68, height: 1)
                Button { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { app.editorPhotoID = nil } } label: {
                    Label(String(localized: "Library"), systemImage: "chevron.backward")
                }
                .softButton()
                .keyboardShortcut(.escape, modifiers: [])
                .tip(String(localized: "Back to Library"), shortcut: "esc")

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.photo.filename).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    HStack(spacing: 4) {
                        if savedPulse {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                                .transition(.scale.combined(with: .opacity))
                            Text(String(localized: "Saved")).foregroundStyle(DS.Palette.success)
                        } else {
                            Text(model.recipe.isIdentity ? String(localized: "Original") : String(localized: "Edited · non-destructive"))
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .font(DS.Font.caption)
                }
                .padding(.leading, DS.Space.xxs)
                .frame(minWidth: 140, alignment: .leading)

                Spacer()

                GlassSegmented(selection: $model.mode,
                               options: CompareMode.allCases.map { .init(value: $0, title: $0.displayName, symbol: $0.symbol) },
                               compact: true)
                    .glass(.floating, in: Capsule())
                    .help(String(localized: "Before/after comparison"))

                Spacer()

                HStack(spacing: 2) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(GlassIconButtonStyle(size: 30))
                        .disabled(!model.canUndo)
                        .tip(model.undoName.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo"), shortcut: "⌘Z")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .buttonStyle(GlassIconButtonStyle(size: 30))
                        .disabled(!model.canRedo)
                        .tip(model.redoName.map { String(localized: "Redo \($0)") } ?? String(localized: "Redo"), shortcut: "⇧⌘Z")
                    Button { model.zoom.toggle() } label: { Image(systemName: model.zoom ? "minus.magnifyingglass" : "plus.magnifyingglass") }
                        .buttonStyle(GlassIconButtonStyle(size: 30, active: model.zoom))
                        .tip(String(localized: "Zoom to 100 %"))
                    Button { model.showGrid.toggle() } label: { Image(systemName: "grid") }
                        .buttonStyle(GlassIconButtonStyle(size: 30, active: model.showGrid))
                        .tip(String(localized: "Grid"))
                }
                .padding(3)
                .glass(.floating, in: Capsule())

                Button { app.exportRequest = [model.photo.id] } label: { Label(String(localized: "Export"), systemImage: "square.and.arrow.up") }
                    .prominentButton()
                    .tip(String(localized: "Export"), shortcut: "⇧⌘E")
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, 8)
        }
        .frame(height: 56)
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            Group {
                if model.zoom {
                    ZoomedView(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                } else {
                    CompareCanvas(model: model)
                        .padding(DS.Space.l)
                }
            }
            if model.isAnalyzing || (model.zoom && model.isLoadingFull) {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(model.isAnalyzing ? String(localized: "Analyzing…") : String(localized: "Loading full resolution…"))
                        .font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary)
                }
                .padding(.horizontal, DS.Space.m).padding(.vertical, 10)
                .glass(.floating, in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            if let msg = model.message {
                VStack {
                    Spacer()
                    HStack(alignment: .top, spacing: DS.Space.xs) {
                        Image(systemName: "info.circle.fill").foregroundStyle(DS.Palette.blue)
                        Text(msg).font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                        Button { withAnimation { model.message = nil } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(DS.Palette.textTertiary)
                    }
                    .padding(.horizontal, DS.Space.m).padding(.vertical, 10)
                    .frame(maxWidth: 520)
                    .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .padding(.bottom, DS.Space.m)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.message)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.isAnalyzing)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ImageHistogramView(image: model.edited)
                    .frame(height: 76)
                    .help(String(localized: "Histogram – distribution of dark (left) to bright (right) tones"))
                autoCard
                toolTabs
            }
            .padding([.horizontal, .top], DS.Space.m)
            .padding(.bottom, DS.Space.s)

            Rectangle().fill(DS.Palette.hairline).frame(height: 0.5)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    switch group {
                    case .light: lightTools
                    case .color: colorTools
                    case .detail: detailTools
                    case .geometry: geometryTools
                    case .crop: cropTools
                    case .effects: effectTools
                    }
                }
                .padding(DS.Space.m)
                .id(group)
                .transition(.opacity.combined(with: .offset(x: 8)))
            }
            .animation(DS.Motion.adaptive(DS.Motion.smooth), value: group)

            footer
        }
    }

    private var autoCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GlassSegmented(selection: $strengthRaw,
                           options: EnhanceStrength.allCases.map { .init(value: $0.rawValue, title: $0.localizedName) })
            Button { Task { await model.autoEnhance(strength) } } label: {
                Label(String(localized: "Auto Enhance"), systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(kind: .premium, large: true))
            .disabled(model.isAnalyzing)
            .keyboardShortcut("e", modifiers: [.command])
            if let info = model.recipe.auto, !info.notes.isEmpty {
                FlowChips(items: info.notes.prefix(4).map { ("checkmark", $0) })
                    .transition(.opacity)
            }
        }
    }

    /// Tool groups with a softly gliding selection indicator.
    private var toolTabs: some View {
        HStack(spacing: 2) {
            ForEach(ToolGroup.allCases) { g in
                let on = g == group
                Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { groupRaw = g.rawValue } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: g.symbol).font(.system(size: 13, weight: on ? .semibold : .regular))
                        Text(g.title).font(.system(size: 9.5, weight: on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? DS.Palette.blue : DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .fill(DS.Palette.surfaceStrong)
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Palette.rim, lineWidth: 0.5))
                                .matchedGeometryEffect(id: "tool-tab", in: tabs)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(g.title)
                .accessibilityLabel(Text(g.title))
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 3, style: .continuous).fill(DS.Palette.hover))
    }

    private func slider(_ title: String, _ key: WritableKeyPath<EditRecipe, Double>, _ range: ClosedRange<Double>,
                        step: Double = 1, format: String = "%+.0f") -> some View {
        AdjustmentSlider(title: title, value: model.binding(key), range: range, step: step, format: format) { editing in
            model.dragChanged(editing, name: title)
        }
    }

    // MARK: Light

    @ViewBuilder private var lightTools: some View {
        ToolSection(title: String(localized: "Tone")) {
            slider(String(localized: "Exposure"), \.exposure, -3 ... 3, step: 0.05, format: "%+.2f")
            slider(String(localized: "Brightness"), \.brightness, -100 ... 100)
            slider(String(localized: "Contrast"), \.contrast, -100 ... 100)
            slider(String(localized: "Highlights"), \.highlights, -100 ... 100)
            slider(String(localized: "Shadows"), \.shadows, -100 ... 100)
        }
        ToolSection(title: String(localized: "Advanced")) {
            slider(String(localized: "Whites"), \.whites, -100 ... 100)
            slider(String(localized: "Blacks"), \.blacks, -100 ... 100)
        }
    }

    // MARK: Color

    @ViewBuilder private var colorTools: some View {
        ToolSection(title: String(localized: "White Balance")) {
            Button { Task { await model.autoWhiteBalance() } } label: {
                Label(String(localized: "Auto White Balance"), systemImage: "eyedropper.halffull").frame(maxWidth: .infinity)
            }
            .softButton()
            slider(String(localized: "Temperature"), \.temperature, -100 ... 100)
            slider(String(localized: "Tint"), \.tint, -100 ... 100)
        }
        ToolSection(title: String(localized: "Color")) {
            slider(String(localized: "Vibrance"), \.vibrance, -100 ... 100)
            slider(String(localized: "Saturation"), \.saturation, -100 ... 100)
            Toggle(String(localized: "Black & White"), isOn: Binding(get: { model.recipe.monochrome },
                                                                      set: { v in model.change(String(localized: "Black & White")) { $0.monochrome = v } }))
                .toggleStyle(.glassSwitch)
                .font(DS.Font.callout)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detailTools: some View {
        ToolSection(title: String(localized: "Detail")) {
            slider(String(localized: "Sharpness"), \.sharpness, 0 ... 100, format: "%.0f")
            slider(String(localized: "Noise Reduction"), \.noiseReduction, 0 ... 100, format: "%.0f")
            slider(String(localized: "Clarity"), \.clarity, -100 ... 100)
        }
    }

    // MARK: Geometry

    @ViewBuilder private var geometryTools: some View {
        ToolSection(title: String(localized: "Straighten")) {
            HStack(spacing: DS.Space.xs) {
                Button { Task { await model.autoStraighten() } } label: {
                    Label(String(localized: "Auto Straighten"), systemImage: "level").frame(maxWidth: .infinity)
                }
                .softButton()
                Button { model.rotate90(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(GlassIconButtonStyle(size: 30)).help(String(localized: "Rotate 90° left"))
                Button { model.rotate90(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(GlassIconButtonStyle(size: 30)).help(String(localized: "Rotate 90° right"))
            }
            AdjustmentSlider(title: String(localized: "Angle"), value: model.binding(\.rotation), range: -45 ... 45, step: 0.1, format: "%+.1f°") { editing in
                if editing { model.showGrid = true }
                model.dragChanged(editing, name: String(localized: "Straighten"))
            }
            if model.recipe.hasGeometry {
                Label(String(localized: "Keeps \(Int((model.retainedArea * 100).rounded())) % of the picture after cropping"), systemImage: "crop")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        ToolSection(title: String(localized: "Perspective")) {
            HStack(spacing: DS.Space.xs) {
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
                Label(String(localized: "Document rectified"), systemImage: "checkmark.circle.fill").font(DS.Font.caption).foregroundStyle(DS.Palette.success)
            }
            if model.recipe.hasGeometry {
                Button { model.resetGeometry() } label: { Label(String(localized: "Reset Geometry"), systemImage: "arrow.counterclockwise") }
                    .buttonStyle(GlassButtonStyle(kind: .plain))
                    .foregroundStyle(DS.Palette.blue)
            }
        }
    }

    // MARK: Crop

    @ViewBuilder private var cropTools: some View {
        ToolSection(title: String(localized: "Aspect Ratio")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                ForEach(AutoCrop.Mode.choices, id: \.self) { m in
                    CropChoice(mode: m, active: isActiveCrop(m)) { Task { await model.applyCrop(m) } }
                }
            }
            Text(String(localized: "Aspect crops keep the main subject in frame. The original file is never changed."))
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private func isActiveCrop(_ m: AutoCrop.Mode) -> Bool {
        switch m {
        case .none: return model.recipe.crop == nil
        default: return false
        }
    }

    // MARK: Effects (looks / presets)

    @ViewBuilder private var effectTools: some View {
        ToolSection(title: String(localized: "Presets")) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(app.allPresets) { p in
                    PresetTile(preset: p) { Task { await model.applyPreset(p) } }
                        .help(p.adaptive ? String(localized: "Adapts to each photo, then applies the “\(p.localizedName)” style")
                                         : String(localized: "Applies “\(p.localizedName)”"))
                        .contextMenu {
                            if !p.isBuiltIn { Button(String(localized: "Delete Preset"), role: .destructive) { app.deleteCustomPreset(p.id) } }
                        }
                }
            }
            Button { savePresetPrompt = true } label: { Label(String(localized: "Save current adjustments as a preset"), systemImage: "plus").frame(maxWidth: .infinity) }
                .softButton()
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Button { model.resetAll() } label: { Label(String(localized: "Reset All"), systemImage: "arrow.counterclockwise") }
                    .buttonStyle(GlassButtonStyle(kind: .plain))
                    .foregroundStyle(DS.Palette.danger)
                    .disabled(model.recipe.isIdentity)
                Spacer()
                Button { withAnimation(DS.Motion.smooth) { model.mode = .split } } label: { Label(String(localized: "Compare"), systemImage: "square.split.2x1") }
                    .buttonStyle(GlassButtonStyle(kind: .plain))
            }
            Text(String(localized: "Edits are saved automatically. The original file is never changed."))
                .font(.system(size: 10)).foregroundStyle(DS.Palette.textTertiary).multilineTextAlignment(.center)
        }
        .padding(DS.Space.s)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.hairline).frame(height: 0.5) }
    }
}

/// Titled tool group inside the editor panel.
struct ToolSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ControlLabel(text: title)
            content()
        }
    }
}

/// Kept for screens that still group controls in a card.
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
            Label(title, systemImage: symbol).font(DS.Font.headline)
            content()
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: DS.Radius.card)
    }
}

struct CropChoice: View {
    var mode: AutoCrop.Mode
    var active: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                shape.frame(height: 26)
                Text(mode.displayName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(active ? DS.Palette.blue : DS.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(active ? DS.Palette.blue.opacity(0.11) : (hovering ? DS.Palette.hover : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(active ? DS.Palette.blue.opacity(0.4) : DS.Palette.hairline, lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var shape: some View {
        switch mode {
        case .none: Image(systemName: "crop").font(.system(size: 15))
        case .trimBorders: Image(systemName: "rectangle.dashed").font(.system(size: 15))
        case .aspect(let w, let h):
            let r = CGFloat(w / h)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: r >= 1 ? 26 : 26 * r, height: r >= 1 ? 26 / r : 26)
        }
    }
}

struct PresetTile: View {
    var preset: Preset
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Palette.brand)
                    .frame(height: 24)
                Text(preset.localizedName).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(hovering ? DS.Palette.blue.opacity(0.09) : DS.Palette.hover))
            .scaleEffect(hovering && !DS.Motion.reduced ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
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
                    .overlay { if model.showGrid { GridOverlay().frame(width: fitted(model.edited ?? model.original, in: geo.size).width, height: fitted(model.edited ?? model.original, in: geo.size).height) } }
            case .original:
                image(model.original, label: String(localized: "Original"), in: geo.size)
            case .sideBySide:
                HStack(spacing: DS.Space.s) {
                    image(model.original, label: String(localized: "Original"), in: CGSize(width: (geo.size.width - 12) / 2, height: geo.size.height))
                    image(model.edited, label: String(localized: "Edited"), in: CGSize(width: (geo.size.width - 12) / 2, height: geo.size.height))
                }
            case .split:
                SplitCompare(original: model.original, edited: model.edited, split: $model.split, size: geo.size)
            }
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.mode)
    }

    private func fitted(_ cg: CGImage?, in size: CGSize) -> CGSize {
        guard let cg, cg.width > 0, cg.height > 0 else { return size }
        let s = min(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
        return CGSize(width: CGFloat(cg.width) * s, height: CGFloat(cg.height) * s)
    }

    @ViewBuilder
    private func image(_ cg: CGImage?, label: String?, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let cg {
                Image(decorative: cg, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
            } else {
                ShimmerBlock(cornerRadius: DS.Radius.card).frame(width: size.width * 0.8, height: size.height * 0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let label, cg != nil {
                Text(label).font(DS.Font.caption).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.4), in: Capsule()).padding(10)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Edited vs. original with a draggable, glowing divider (effect 8).
struct SplitCompare: View {
    var original: CGImage?
    var edited: CGImage?
    @Binding var split: CGFloat
    var size: CGSize
    @State private var dragging = false

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
            CompareDivider(height: frame.height, active: dragging)
                .offset(x: frame.minX + frame.width * split - 17, y: frame.minY)
            label(String(localized: "Original"))
                .offset(x: frame.minX + 10, y: frame.minY + 10)
            label(String(localized: "Edited"))
                .frame(width: frame.width - 20, alignment: .trailing)
                .offset(x: frame.minX + 10, y: frame.minY + 10)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard frame.width > 0 else { return }
                dragging = true
                split = min(1, max(0, (v.location.x - frame.minX) / frame.width))
            }
            .onEnded { _ in dragging = false })
        .help(String(localized: "Drag to compare original (left) and edited (right)"))
    }

    private func label(_ t: String) -> some View {
        Text(t).font(DS.Font.caption).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.4), in: Capsule())
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
                .font(DS.Font.caption).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule()).padding(12)
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
