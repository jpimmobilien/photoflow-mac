import SwiftUI

// MARK: - Floating prompt bar

struct AIPromptBar: View {
    @ObservedObject private var studio = AIStudioModel.shared
    var placeholder: String
    var actionTitle: String
    var actionSymbol: String = "sparkles"
    var promptOptional = false
    var action: () -> Void
    @FocusState private var focused: Bool
    @State private var sheen: CGFloat = -1
    @State private var hoveringGo = false

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            if let s = studio.suggestion { suggestionCard(s) }
            if let job = studio.job {
                AIJobIndicator(job: job) { studio.cancel() }
                    .glassCard(cornerRadius: DS.Radius.panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                assistantMenu
                TextField(placeholder, text: $studio.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.vertical, 9)
                    .onSubmit { if canRun { run() } }
                    .accessibilityLabel(Text("Prompt"))
                goButton
            }
            .padding(.leading, DS.Space.s)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glass(.floating, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(DS.Palette.magic, lineWidth: focused ? 1.6 : 0)
                    .opacity(focused ? 0.9 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: DS.Palette.blue.opacity(focused ? 0.22 : 0), radius: focused ? 18 : 0, y: 4)
            .scaleEffect(focused && !DS.Motion.reduced ? 1.006 : 1)
            .animation(DS.Motion.adaptive(DS.Motion.smooth), value: focused)
        }
        .frame(maxWidth: 860)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: studio.job != nil)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: studio.suggestion)
    }

    private var canRun: Bool {
        !studio.isBusy && (promptOptional || !studio.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func run() {
        // One light sweep across the button – a single, short confirmation (not a looping effect).
        if !DS.Motion.reduced {
            sheen = -1
            withAnimation(.easeOut(duration: 0.6)) { sheen = 1.4 }
        }
        action()
    }

    private var goButton: some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: actionSymbol).font(.system(size: 13, weight: .bold))
                Text(actionTitle).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(DS.Palette.brand))
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .offset(x: sheen * g.size.width)
                        .blendMode(.plusLighter)
                }
                .clipShape(Capsule())
                .allowsHitTesting(false)
            }
            .shadow(color: DS.Palette.blue.opacity(hoveringGo && canRun ? 0.45 : 0.2), radius: hoveringGo ? 10 : 5, y: 2)
            .scaleEffect(hoveringGo && canRun ? 1.03 : 1)
            .opacity(canRun ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!canRun)
        .keyboardShortcut(.return, modifiers: .command)
        .onHover { h in withAnimation(DS.Motion.hover) { hoveringGo = h } }
        .help(actionTitle + " (⌘↩)")
    }

    private var assistantMenu: some View {
        Menu {
            Section(PromptAssistant.languageModelAvailable ? String(localized: "Apple Intelligence (on this Mac)") : String(localized: "Templates (no AI model)")) {
                ForEach(PromptAssistant.Mode.allCases) { m in
                    Button { studio.assist(m) } label: { Label(m.title, systemImage: m.symbol) }
                }
            }
        } label: {
            Image(systemName: studio.assistantBusy ? "ellipsis" : "wand.and.rays")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Palette.magic)
                .frame(width: 30, height: 36)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(studio.prompt.trimmingCharacters(in: .whitespaces).isEmpty || studio.assistantBusy)
        .help(String(localized: "Prompt assistant"))
    }

    private func suggestionCard(_ s: PromptAssistant.Suggestion) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: s.byLanguageModel ? "sparkles" : "text.badge.checkmark")
                .foregroundStyle(DS.Palette.magic)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.byLanguageModel ? String(localized: "Suggestion from Apple Intelligence") : String(localized: "Suggestion from templates (no AI)"))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                Text(s.text).font(DS.Font.body).foregroundStyle(DS.Palette.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(String(localized: "Discard")) { studio.suggestion = nil }.buttonStyle(GlassButtonStyle(kind: .plain))
            Button(String(localized: "Use")) { studio.acceptSuggestion() }.buttonStyle(GlassButtonStyle(kind: .primary))
        }
        .padding(DS.Space.s)
        .glassCard(cornerRadius: DS.Radius.card)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Generate

struct AIGenerateView: View {
    @ObservedObject private var studio = AIStudioModel.shared
    @ObservedObject private var store = ModelStore.shared

    private static let examples: [String] = [
        "bright scandinavian living room with large windows, oak floor, morning light",
        "modern villa with pool at sunset, wide angle, architectural photography",
        "cup of cappuccino on a marble table, cafe, soft window light",
        "misty alpine lake at sunrise, mountains reflected in the water",
        "minimalist product shot of a ceramic vase on a beige background",
        "portrait of an elderly fisherman, natural light, detailed face"
    ]

    var body: some View {
        VStack(spacing: DS.Space.m) {
            AISectionHeader(section: .generate)
            HStack(alignment: .top, spacing: DS.Space.l) {
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                AIGenerateSettings()
                    .frame(width: 292)
            }
            .frame(maxHeight: .infinity)
            AIPromptBar(placeholder: String(localized: "Describe the image you want – e.g. a sunny terrace with a view of the sea"),
                        actionTitle: String(localized: "Generate")) { studio.generate() }
                .disabled(studio.activeModel == nil)
        }
    }

    @ViewBuilder
    private var stage: some View {
        let list = studio.results.filter { $0.creation.kind == .textToImage }
        if studio.activeModel == nil {
            AISetupCard(capability: .textToImage)
        } else if let r = list.first(where: { $0.id == studio.selectedResultID }) ?? list.first {
            VStack(spacing: DS.Space.s) {
                AIStageImage(image: r.image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(r.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                AIResultMeta(creation: r.creation)
                AIResultActions(result: r, comparing: .constant(false))
                AIResultStrip(kinds: [.textToImage])
            }
        } else if studio.isBusy {
            VStack(spacing: DS.Space.m) {
                Image(systemName: "sparkles")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(DS.Palette.magic)
                    .symbolRenderingMode(.hierarchical)
                Text("Your image is being created on this Mac").font(DS.Font.title2).foregroundStyle(DS.Palette.textPrimary)
                Text("Progress and remaining time are shown below the stage – measured, not estimated in advance.")
                    .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard(cornerRadius: DS.Radius.hero)
        } else {
            VStack(spacing: DS.Space.l) {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(DS.Palette.magic)
                        .symbolRenderingMode(.hierarchical)
                    Text("What should PhotoFlow create?").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                    Text("Describe it in the field below. English prompts work best; the prompt assistant can help.")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: DS.Space.xs)], spacing: DS.Space.xs) {
                    ForEach(Self.examples, id: \.self) { e in
                        Button { studio.prompt = e } label: {
                            Text(e).font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Space.s)
                                .glassCard(cornerRadius: DS.Radius.card, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Title row of every section: name, model in use, hardware profile.
struct AISectionHeader: View {
    let section: AIStudioModel.Section
    @ObservedObject private var studio = AIStudioModel.shared
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: DS.Space.m) {
            Text(section.title)
                .font(DS.Font.display)
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: DS.Space.s)
            if [.generate, .edit, .fill, .expand].contains(section), !store.installedDiffusionModels.isEmpty {
                Menu {
                    ForEach(store.installedDiffusionModels) { m in
                        Button { studio.modelID = m.id } label: {
                            if m.id == studio.activeModel?.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                        }
                    }
                } label: {
                    Label(studio.activeModel?.name ?? "–", systemImage: "cpu")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(DS.Font.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glass(.interactive, in: Capsule())
                .help(String(localized: "Model"))
            }
            Menu {
                ForEach(AIPerformanceProfile.allCases) { p in
                    Button { studio.profile = p } label: {
                        if p == studio.profile { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                    }
                }
            } label: {
                Label(studio.profile.title, systemImage: "gauge.with.dots.needle.67percent")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .font(DS.Font.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glass(.interactive, in: Capsule())
            .help(studio.profile.detail)
        }
    }
}

/// Right-hand settings for text-to-image.
struct AIGenerateSettings: View {
    @ObservedObject private var studio = AIStudioModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                group(String(localized: "Format")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(AIAspect.allCases) { a in
                            chip(a.title, symbol: a.symbol, on: studio.aspect == a) { studio.aspect = a }
                        }
                    }
                    if let m = studio.activeModel {
                        let r = studio.aspect.crop(side: m.resolution)
                        Text("\(Int(r.width)) × \(Int(r.height)) px" + (studio.aspect == .square ? "" : " · " + String(localized: "cropped from the model's square image")))
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                group(String(localized: "Quality")) {
                    GlassSegmented(selection: $studio.quality, options: AIQuality.allCases.map { .init(value: $0, title: $0.title) })
                    Text(qualityNote).font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                group(String(localized: "Variants")) {
                    GlassSegmented(selection: $studio.variants, options: [1, 2, 4].map { .init(value: $0, title: "\($0)") })
                    if studio.variants > studio.maxVariants {
                        Label(String(localized: "This Mac creates up to \(studio.maxVariants) variants per run."), systemImage: "info.circle")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.warning)
                    }
                }
                group(String(localized: "Style")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                        chip(AIStyle.none.title, symbol: AIStyle.none.symbol, on: studio.styleID == "none") { studio.styleID = "none" }
                        ForEach(AIStyle.all) { s in
                            chip(s.title, symbol: s.symbol, on: studio.styleID == s.id) { studio.styleID = s.id }
                        }
                    }
                }
                AIAdvancedSettings()
            }
            .padding(DS.Space.m)
        }
        .glassCard(cornerRadius: DS.Radius.panel)
    }

    private var qualityNote: String {
        let steps = studio.effectiveSteps
        var t = String(localized: "\(steps) steps")
        if let m = studio.activeModel, let sps = DiffusionEngine.shared.knownSecondsPerStep(modelID: m.id) {
            t += " · " + String(localized: "about \((Double(steps) * sps + 3).formattedDuration) per image on this Mac")
        }
        if studio.quality.upscaleFactor > 1 {
            t += ModelStoreSnapshot.current.upscaler() != nil
                ? " · " + String(localized: "\(studio.quality.upscaleFactor)× Real-ESRGAN upscaling")
                : " · " + String(localized: "install Real-ESRGAN for higher resolution")
        }
        return t
    }

    func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ControlLabel(text: title)
            content()
        }
    }

    func chip(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { action() } }) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? DS.Palette.textPrimary : DS.Palette.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(on ? DS.Palette.surfaceStrong : DS.Palette.hover))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(on ? DS.Palette.blue.opacity(0.7) : DS.Palette.hairline, lineWidth: on ? 1.2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Seed, steps, guidance, negative prompt, resolution – shared by all diffusion sections.
struct AIAdvancedSettings: View {
    @ObservedObject private var studio = AIStudioModel.shared

    var body: some View {
        DisclosureGroup(isExpanded: $studio.showAdvanced) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    ControlLabel(text: String(localized: "Seed"))
                    HStack(spacing: 6) {
                        TextField(String(localized: "Random"), text: $studio.seedText)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Font.number)
                        Button { studio.seedText = String(UInt32.random(in: 1...4_000_000_000)) } label: { Image(systemName: "dice") }
                            .buttonStyle(GlassIconButtonStyle())
                            .help(String(localized: "New random seed"))
                    }
                    Text("The same seed, prompt and settings reproduce the same image.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ControlLabel(text: String(localized: "Steps"))
                        Spacer()
                        Text("\(studio.effectiveSteps)").font(DS.Font.number)
                    }
                    FluidSlider(value: Binding(get: { Double(studio.effectiveSteps) }, set: { studio.stepsOverride = Int($0) }), range: 8...60, step: 1)
                        .frame(height: 22)
                    if studio.stepsOverride != nil {
                        Button(String(localized: "Use quality preset")) { studio.stepsOverride = nil }
                            .buttonStyle(.link).font(DS.Font.caption)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ControlLabel(text: String(localized: "Prompt guidance"))
                        Spacer()
                        Text(String(format: "%.1f", studio.guidance)).font(DS.Font.number)
                    }
                    FluidSlider(value: $studio.guidance, range: 1...15, step: 0.5)
                        .frame(height: 22)
                    Text("Higher values follow the prompt more literally; lower values look more natural.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ControlLabel(text: String(localized: "Negative prompt"))
                    TextField(String(localized: "What should not appear"), text: $studio.negativePrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ControlLabel(text: String(localized: "Resolution"))
                    if let m = studio.activeModel {
                        Text("\(m.resolution) × \(m.resolution) px (\(m.name))").font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Text("Free resolutions are not supported by the Core ML models; they work at their native size. Use Quality “High” or “Maximum” or AI Upscaling for larger images.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, DS.Space.s)
        } label: {
            ControlLabel(text: String(localized: "Advanced"))
        }
    }
}

// MARK: - Setup card (no model installed yet)

struct AISetupCard: View {
    let capability: AICapability
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var studio = AIStudioModel.shared

    var body: some View {
        let hw = AIHardware.current
        let model: AIModelDescriptor? = capability == .objectRemoval ? AIModelCatalog.model("lama")
            : capability == .upscaling ? AIModelCatalog.model("realesrgan-x4plus")
            : capability == .denoise ? AIModelCatalog.model("realesr-general-x4v3")
            : AIModelCatalog.model(hw.recommendedDiffusionModelID)
        VStack(spacing: DS.Space.l) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(DS.Palette.brand)
            VStack(spacing: DS.Space.xs) {
                Text("One download, then everything runs offline").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("“\(capability.title)” needs a local AI model. PhotoFlow does not include models in the app – you choose which ones to download from their official sources.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            if let model {
                AIModelCard(model: model, compact: true)
                    .frame(maxWidth: 560)
            }
            Button { withAnimation(DS.Motion.adaptive(DS.Motion.page)) { studio.section = .models } } label: {
                Label(String(localized: "All models"), systemImage: "cpu")
            }
            .buttonStyle(GlassButtonStyle(kind: .secondary))
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
    }
}
