import SwiftUI

/// Shared workspace for the five sections that work on an existing photo.
struct AIEditWorkspace: View {
    @ObservedObject private var studio = AIStudioModel.shared
    @ObservedObject private var store = ModelStore.shared
    @State private var showResult = false
    @State private var comparing = true

    private var section: AIStudioModel.Section { studio.section }

    private var kinds: Set<AIOperationKind> {
        switch section {
        case .edit: return [.imageToImage]
        case .fill: return [.fill, .remove, .background]
        case .expand: return [.expand]
        case .enhance: return [.enhance]
        case .upscale: return [.upscale]
        default: return []
        }
    }

    private var currentResult: AIResult? {
        let list = studio.results.filter { kinds.contains($0.creation.kind) }
        return list.first { $0.id == studio.selectedResultID } ?? list.first
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            AISectionHeader(section: section)
            if let src = studio.source {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    VStack(spacing: DS.Space.s) {
                        stage(src)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showResult, let r = currentResult {
                            AIResultMeta(creation: r.creation)
                            HStack(spacing: DS.Space.xs) {
                                Button { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { showResult = false } } label: {
                                    Label(String(localized: "Back to original"), systemImage: "arrow.uturn.backward")
                                }
                                .buttonStyle(GlassButtonStyle(kind: .secondary))
                                Button {
                                    studio.setSource(result: r, section: section)
                                    showResult = false
                                } label: { Label(String(localized: "Continue with result"), systemImage: "arrow.forward.circle") }
                                    .buttonStyle(GlassButtonStyle(kind: .secondary))
                                AIResultActions(result: r, comparing: $comparing)
                            }
                            AIResultStrip(kinds: kinds)
                        }
                    }
                    controls
                        .frame(width: 292)
                }
                .frame(maxHeight: .infinity)
                bottomBar
            } else {
                AISourcePicker(message: sourceMessage)
            }
        }
        .onChange(of: studio.results.first?.id) { _ in
            if let r = studio.results.first, kinds.contains(r.creation.kind) {
                withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { showResult = true; comparing = true }
            }
        }
        .onChange(of: studio.source) { _ in showResult = false }
    }

    private var sourceMessage: String {
        switch section {
        case .edit: return String(localized: "Pick a photo and describe how it should change. The original is never overwritten.")
        case .fill: return String(localized: "Paint over an area to fill it with something new, remove an object, or replace the background.")
        case .expand: return String(localized: "Drag the edges outwards and let the model continue the scene.")
        case .enhance: return String(localized: "Restore detail, remove noise or blur the background – with specialised models.")
        default: return String(localized: "Enlarge photos 2×, 4× or 8× with Real-ESRGAN.")
        }
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(_ src: AISource) -> some View {
        if showResult, let r = currentResult {
            if comparing, let before = r.before, before.width * r.image.height == before.height * r.image.width || r.creation.kind == .upscale {
                BeforeAfterView(before: before, after: r.image)
            } else {
                AIStageImage(image: r.image).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            switch section {
            case .fill:
                VStack(spacing: DS.Space.s) {
                    AIMaskToolbar()
                    AIMaskCanvas(image: src.image)
                }
            case .expand:
                AIExpandCanvas(image: src.image)
            default:
                AIStageImage(image: src.image).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch section {
        case .edit:
            AIPromptBar(placeholder: String(localized: "How should the photo change? – e.g. winter evening with snow on the roofs"),
                        actionTitle: String(localized: "Apply")) { studio.imageToImage() }
                .disabled(studio.activeModel == nil)
        case .fill:
            switch studio.fillMode {
            case .fill:
                AIPromptBar(placeholder: String(localized: "What should appear in the painted area?"), actionTitle: String(localized: "Fill")) { studio.runFill() }
            case .remove:
                AIPromptBar(placeholder: String(localized: "No description needed – just paint over the object"), actionTitle: String(localized: "Remove"),
                            actionSymbol: "eraser", promptOptional: true) { studio.runFill() }
            case .background:
                AIPromptBar(placeholder: String(localized: "Describe the new background – e.g. bright loft with plants"),
                            actionTitle: String(localized: "Replace")) { studio.runFill() }
            }
        case .expand:
            AIPromptBar(placeholder: String(localized: "Optional: what should the new areas show?"), actionTitle: String(localized: "Expand"),
                        actionSymbol: "arrow.up.left.and.arrow.down.right", promptOptional: true) { studio.runExpand() }
        case .enhance:
            AIRunBar(title: studio.enhanceKind.title, symbol: studio.enhanceKind.symbol,
                     enabled: studio.enhanceKind != .faceRetouch) { studio.runEnhance() }
        default:
            AIRunBar(title: String(localized: "Upscale \(studio.upscaleFactor)×"), symbol: "arrow.up.forward.square",
                     enabled: true) { studio.runUpscale() }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                sourceCard
                switch section {
                case .edit: editControls
                case .fill: fillControls
                case .expand: expandControls
                case .enhance: enhanceControls
                default: upscaleControls
                }
            }
            .padding(DS.Space.m)
        }
        .glassCard(cornerRadius: DS.Radius.panel)
    }

    private var sourceCard: some View {
        HStack(spacing: DS.Space.s) {
            if let s = studio.source {
                Image(decorative: s.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(DS.Font.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(s.image.width) × \(s.image.height) px").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Button { studio.source = nil; studio.resetEditing() } label: { Image(systemName: "xmark") }
                    .buttonStyle(GlassIconButtonStyle(size: 26))
                    .help(String(localized: "Choose another photo"))
            }
        }
    }

    private var editControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if studio.activeModel == nil {
                missingModel(.imageToImage)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { ControlLabel(text: String(localized: "Strength")); Spacer(); Text("\(Int(studio.strength * 100)) %").font(DS.Font.number) }
                    FluidSlider(value: $studio.strength, range: 0.1...0.95, step: 0.05).frame(height: 22)
                    Text("Low values stay close to the original; high values change more.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                styleGrid
                AIAdvancedSettings()
            }
        }
    }

    private var styleGrid: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ControlLabel(text: String(localized: "Style"))
            Picker(String(localized: "Style"), selection: $studio.styleID) {
                Text(AIStyle.none.title).tag("none")
                ForEach(AIStyle.all) { s in Label(s.title, systemImage: s.symbol).tag(s.id) }
            }
            .labelsHidden()
        }
    }

    private var fillControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ControlLabel(text: String(localized: "Mode"))
                ForEach(AIStudioModel.FillMode.allCases) { m in
                    let on = studio.fillMode == m
                    Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { studio.fillMode = m } } label: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: m.symbol).frame(width: 18)
                            Text(m.title)
                            Spacer()
                            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Palette.blue) }
                        }
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .padding(.horizontal, DS.Space.s).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(on ? DS.Palette.surfaceStrong : DS.Palette.hover))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            switch studio.fillMode {
            case .fill:
                if studio.activeModel == nil { missingModel(.inpainting) }
                note(String(localized: "Inpainting with \(studio.activeModel?.name ?? "Stable Diffusion"): only the painted area is regenerated, the rest of the photo keeps its full resolution."))
            case .remove:
                if store.lamaInstalled {
                    note(String(localized: "Uses LaMa, a model specialised in removing objects. Paint generously over the object and its shadow."))
                } else if studio.activeModel != nil {
                    note(String(localized: "LaMa is not installed – Stable Diffusion is used instead. LaMa gives cleaner results."))
                    downloadButton("lama")
                } else {
                    missingModel(.objectRemoval)
                }
            case .background:
                if studio.activeModel == nil { missingModel(.inpainting) }
                Button { studio.selectSubject() } label: { Label(String(localized: "Select subject automatically"), systemImage: "person.crop.rectangle") }
                    .buttonStyle(GlassButtonStyle(kind: .secondary))
                    .disabled(studio.isBusy)
                Toggle(String(localized: "Add contact shadow"), isOn: $studio.addShadow).toggleStyle(.glassSwitch)
                note(String(localized: "The subject (white) stays untouched; everything else is generated anew. Correct the selection with the brush and eraser."))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { ControlLabel(text: String(localized: "Soft edge")); Spacer(); Text("\(Int(studio.mask.feather)) px").font(DS.Font.number) }
                FluidSlider(value: $studio.mask.feather, range: 0...40, step: 1).frame(height: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { ControlLabel(text: String(localized: "Refine selection")); Spacer()
                    Text(studio.mask.refine == 0 ? "0" : String(format: "%+.0f", studio.mask.refine)).font(DS.Font.number) }
                FluidSlider(value: $studio.mask.refine, range: -20...20, step: 1, neutral: 0).frame(height: 22)
                Text("Grow or shrink the selection.").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            if studio.fillMode != .remove { AIAdvancedSettings() }
        }
    }

    private var expandControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if studio.activeModel == nil { missingModel(.outpainting) }
            if let s = studio.source {
                let e = studio.expansion
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ControlLabel(text: String(localized: "Quick presets"))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        preset(String(localized: "+25 % all round")) {
                            let dx = s.image.width / 4, dy = s.image.height / 4
                            studio.expansion = .init(left: dx / 2, top: dy / 2, right: dx / 2, bottom: dy / 2)
                        }
                        preset("16:9") { studio.expansion = Self.toAspect(16.0 / 9, s.image) }
                        preset("1:1") { studio.expansion = Self.toAspect(1, s.image) }
                        preset("9:16") { studio.expansion = Self.toAspect(9.0 / 16, s.image) }
                        preset("4:3") { studio.expansion = Self.toAspect(4.0 / 3, s.image) }
                        preset(String(localized: "Reset")) { studio.expansion = .init() }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ControlLabel(text: String(localized: "New size"))
                    Text("\(s.image.width + e.left + e.right) × \(s.image.height + e.top + e.bottom) px")
                        .font(DS.Font.number).foregroundStyle(DS.Palette.textPrimary)
                    Text("Original pixels stay unchanged. New areas are generated at the model's resolution and upscaled.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            AIAdvancedSettings()
        }
    }

    static func toAspect(_ ratio: Double, _ img: CGImage) -> AIOperations.Expansion {
        let w = Double(img.width), h = Double(img.height)
        if w / h < ratio {
            let add = Int((h * ratio - w).rounded())
            return .init(left: add / 2, top: 0, right: add - add / 2, bottom: 0)
        } else {
            let add = Int((w / ratio - h).rounded())
            return .init(left: 0, top: add / 2, right: 0, bottom: add - add / 2)
        }
    }

    private func preset(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { action() } }) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(DS.Palette.hover))
        }
        .buttonStyle(.plain)
    }

    private var enhanceControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ControlLabel(text: String(localized: "Optimisation"))
                ForEach(AIOperations.EnhanceKind.allCases) { k in enhanceRow(k) }
            }
            if studio.enhanceKind != .faceRetouch {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { ControlLabel(text: String(localized: "Amount")); Spacer(); Text("\(Int(studio.enhanceAmount * 100)) %").font(DS.Font.number) }
                    FluidSlider(value: $studio.enhanceAmount, range: 0.2...1, step: 0.05).frame(height: 22)
                }
            }
        }
    }

    private func enhanceRow(_ k: AIOperations.EnhanceKind) -> some View {
        let on = studio.enhanceKind == k
        let snap = ModelStoreSnapshot.current
        let missing: Bool = {
            switch k {
            case .restoreDetail: return snap.upscaler(scale: 2) == nil && snap.upscaler(scale: 4) == nil
            case .denoise: return snap.upscaler(denoise: true) == nil
            default: return false
            }
        }()
        return Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { studio.enhanceKind = k } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: k.symbol).frame(width: 18)
                    Text(k.title).font(.system(size: 13, weight: on ? .semibold : .medium))
                    Spacer()
                    if k == .faceRetouch {
                        Badge(text: String(localized: "Not available"), color: DS.Palette.textTertiary, symbol: nil)
                    } else if missing {
                        Badge(text: String(localized: "Model missing"), color: DS.Palette.warning, symbol: nil)
                    }
                }
                if on {
                    Text(k.detail).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if missing { downloadButton(k == .denoise ? "realesr-general-x4v3" : "realesrgan-x2plus") }
                }
            }
            .foregroundStyle(DS.Palette.textPrimary)
            .padding(DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(on ? DS.Palette.surfaceStrong : DS.Palette.hover))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(on ? DS.Palette.blue.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var upscaleControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            let snap = ModelStoreSnapshot.current
            if snap.upscaler() == nil {
                missingModel(.upscaling)
            } else if let s = studio.source {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ControlLabel(text: String(localized: "Factor"))
                    GlassSegmented(selection: $studio.upscaleFactor, options: [2, 4, 8].map { .init(value: $0, title: "\($0)×") })
                }
                let est = Upscaler.estimatedOutput(width: s.image.width, height: s.image.height, factor: studio.upscaleFactor)
                let tooBig = est.0 > Upscaler.maxOutputSide || est.1 > Upscaler.maxOutputSide || est.0 * est.1 > Upscaler.maxOutputPixels
                VStack(alignment: .leading, spacing: 4) {
                    ControlLabel(text: String(localized: "Result"))
                    Text("\(est.0) × \(est.1) px").font(DS.Font.number).foregroundStyle(tooBig ? DS.Palette.danger : DS.Palette.textPrimary)
                    Text(String(localized: "Estimated file size: about \(est.2.formattedBytes) (PNG)"))
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                    if tooBig {
                        Text("Too large for this factor – choose a smaller one or crop the photo first.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.danger).fixedSize(horizontal: false, vertical: true)
                    }
                    if studio.upscaleFactor == 8 && (snap.upscaler(scale: 4) == nil || snap.upscaler(scale: 2) == nil) {
                        Text("8× needs Real-ESRGAN x4plus and x2plus.").font(DS.Font.caption).foregroundStyle(DS.Palette.warning)
                    }
                }
                note(String(localized: "Real-ESRGAN reconstructs detail tile by tile (256 px), so any size works within the memory limits."))
            }
        }
    }

    // MARK: Helpers

    private func note(_ text: String) -> some View {
        Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private func missingModel(_ c: AICapability) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(String(localized: "Model required"), systemImage: "arrow.down.circle").font(DS.Font.headline).foregroundStyle(DS.Palette.warning)
            Text(AIError.noModel(c).errorDescription ?? "").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Open Model Management")) { withAnimation(DS.Motion.adaptive(DS.Motion.page)) { studio.section = .models } }
                .buttonStyle(GlassButtonStyle(kind: .primary))
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.warning.opacity(0.08)))
    }

    @ViewBuilder
    private func downloadButton(_ id: String) -> some View {
        if let m = AIModelCatalog.model(id) {
            AIModelDownloadControl(model: m)
        }
    }
}

/// Run bar for sections without a prompt.
struct AIRunBar: View {
    @ObservedObject private var studio = AIStudioModel.shared
    var title: String
    var symbol: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            if let job = studio.job {
                AIJobIndicator(job: job) { studio.cancel() }
                    .glassCard(cornerRadius: DS.Radius.panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button(action: action) { Label(title, systemImage: symbol).padding(.horizontal, 10) }
                    .buttonStyle(GlassButtonStyle(kind: .premium, large: true))
                    .disabled(!enabled)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .frame(maxWidth: 860)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: studio.job != nil)
    }
}
