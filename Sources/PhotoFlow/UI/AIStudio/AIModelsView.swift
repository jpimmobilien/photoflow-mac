import SwiftUI

/// Model management: hardware, performance profile and every downloadable model with its licence.
struct AIModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var studio = AIStudioModel.shared
    private let hw = AIHardware.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .lastTextBaseline) {
                    Text(AIStudioModel.Section.models.title).font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text(String(localized: "\(store.totalInstalledBytes.formattedBytes) installed · \(AIHardware.freeDisk().formattedBytes) free"))
                        .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                }
                hardwareCard
                downloads
                section(String(localized: "Image generation & editing"), AIModelCatalog.diffusionModels)
                section(String(localized: "Upscaling & restoration"), AIModelCatalog.upscalers)
                section(String(localized: "Object removal"), AIModelCatalog.all.filter { $0.kind == .inpainter })
                builtInCard
                Text("Models are downloaded only from their official publishers (Hugging Face repositories of Apple and Stability AI) or from PhotoFlow's public GitHub release of Core ML conversions. Every file is pinned to an exact version and checked with SHA-256 before it is used. Models contain no executable code.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, DS.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Running, queued and paused downloads at the top, so they stay visible while scrolling.
    @ViewBuilder
    private var downloads: some View {
        let active = AIModelCatalog.all.filter { m in
            switch store.state(m.id) {
            case .queued, .downloading, .paused, .verifying, .installing: return true
            default: return false
            }
        }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                GroupHeader(title: String(localized: "Downloads"), detail: nil)
                VStack(spacing: DS.Space.s) {
                    ForEach(active) { m in
                        HStack(alignment: .center, spacing: DS.Space.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                                Text(m.developer).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                            }
                            .frame(width: 240, alignment: .leading)
                            AIModelDownloadControl(model: m)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(DS.Space.m)
                .glassCard(cornerRadius: DS.Radius.panel)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: hw.isIntel ? "cpu" : "memorychip")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Palette.brand)
                    .frame(width: 40, height: 40)
                    .background(DS.Palette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hw.tier.title).font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary)
                    Text(hw.summary).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: DS.Space.xl) {
                info(String(localized: "Backends"), hw.backends)
                info(String(localized: "Recommended model"), AIModelCatalog.model(hw.recommendedDiffusionModelID)?.name ?? "–")
                info(String(localized: "Variants per run"), String(localized: "up to \(hw.maxVariants)"))
            }
            if hw.isIntel {
                Label(String(localized: "Intel Macs have no Neural Engine. Generation works, but takes minutes per image. Upscaling and object removal run comfortably."),
                      systemImage: "info.circle")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ControlLabel(text: String(localized: "Performance profile"))
                GlassSegmented(selection: $studio.profile, options: AIPerformanceProfile.allCases.map { .init(value: $0, title: $0.title) })
                Text(studio.profile.detail).font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(DS.Space.m)
        .glassCard(cornerRadius: DS.Radius.panel)
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ControlLabel(text: title)
            Text(value).font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, _ models: [AIModelDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            GroupHeader(title: title, detail: nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: DS.Space.m)], spacing: DS.Space.m) {
                ForEach(models) { m in AIModelCard(model: m) }
            }
        }
    }

    private var builtInCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            GroupHeader(title: String(localized: "Built into macOS"), detail: nil)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                builtIn("person.crop.rectangle", String(localized: "Subject detection (Apple Vision)"),
                        hw.osAtLeast(14) ? String(localized: "Available – used to select subjects and for background blur.")
                                         : String(localized: "People only on macOS 13; any subject from macOS 14."), true)
                builtIn("text.bubble", String(localized: "Prompt assistant (Apple Intelligence)"),
                        PromptAssistant.languageModelAvailable ? String(localized: "Available on this Mac.")
                            : String(localized: "Not available on this Mac (needs macOS 26 with Apple Intelligence). Rule-based templates are used instead."),
                        PromptAssistant.languageModelAvailable)
                builtIn("face.smiling", String(localized: "Portrait retouch"),
                        String(localized: "Not available: no face-restoration model with a suitable licence."), false)
            }
            .padding(DS.Space.m)
            .glassCard(cornerRadius: DS.Radius.panel)
        }
    }

    private func builtIn(_ symbol: String, _ title: String, _ text: String, _ ok: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: symbol).foregroundStyle(ok ? DS.Palette.success : DS.Palette.textTertiary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One model with licence, requirements, status and actions.
struct AIModelCard: View {
    let model: AIModelDescriptor
    var compact = false
    @ObservedObject private var store = ModelStore.shared
    @State private var confirmRemove = false
    private let hw = AIHardware.current

    private var isDefault: Bool {
        switch model.kind {
        case .diffusion: return store.defaultDiffusionModelID == model.id
        case .upscaler: return store.defaultUpscalerID == model.id
        case .inpainter: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary)
                        if isDefault && store.isInstalled(model.id) { Badge(text: String(localized: "Default"), color: DS.Palette.blue, symbol: "star.fill") }
                        if model.id == hw.recommendedDiffusionModelID { Badge(text: String(localized: "Recommended"), color: DS.Palette.success, symbol: nil) }
                    }
                    Text(model.developer).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                statusBadge
            }
            Text(model.detail).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            FlowChips(items: model.capabilities.map { ("checkmark", $0.title) })
            if !compact {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: 4) {
                    row(String(localized: "Download"), model.downloadSize.formattedBytes + " · " + String(localized: "\(model.files.count) files"))
                    row(String(localized: "Memory"), String(localized: "min. \(Int(model.minMemoryGB)) GB · recommended \(Int(model.recommendedMemoryGB)) GB"))
                    row(String(localized: "Requires"), model.macOSRequirementText + (model.requiresAppleSilicon ? " · Apple Silicon" : " · Apple Silicon / Intel"))
                    row(String(localized: "Version"), model.version + " · " + String(model.revision.prefix(18)))
                    row(String(localized: "Hardware"), model.hardwareNote)
                }
            } else {
                Text("\(model.downloadSize.formattedBytes) · \(model.macOSRequirementText) · \(model.license.name)")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            licence
            if let reason = hw.incompatibility(of: model) {
                Label(reason, systemImage: "xmark.octagon").font(DS.Font.caption).foregroundStyle(DS.Palette.danger)
            } else if let warn = hw.warning(for: model) {
                Label(warn, systemImage: "exclamationmark.triangle").font(DS.Font.caption).foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.xs) {
                AIModelDownloadControl(model: model)
                Spacer()
                if store.isInstalled(model.id) {
                    if !isDefault && model.kind != .inpainter {
                        Button(String(localized: "Set as Default")) { store.setDefault(model) }.buttonStyle(GlassButtonStyle(kind: .secondary))
                    }
                    Button(String(localized: "Remove")) { confirmRemove = true }.buttonStyle(GlassButtonStyle(kind: .destructive))
                        .disabled(AIStudioModel.shared.isBusy)
                }
            }
        }
        .padding(DS.Space.m)
        .glassCard(cornerRadius: DS.Radius.panel)
        .alert(String(localized: "Remove \(model.name)?"), isPresented: $confirmRemove) {
            Button(String(localized: "Remove"), role: .destructive) { store.uninstall(model.id) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Frees \(model.installedSize.formattedBytes). You can download it again at any time."))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            Text(v).font(DS.Font.caption).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var licence: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(DS.Palette.textSecondary)
                Link(model.license.name, destination: model.license.url).font(DS.Font.caption)
                Badge(text: String(localized: "Private use"), color: DS.Palette.success, symbol: "checkmark")
                Badge(text: model.license.commercialUse ? String(localized: "Commercial use") : String(localized: "Non-commercial only"),
                      color: model.license.commercialUse ? DS.Palette.success : DS.Palette.warning, symbol: model.license.commercialUse ? "checkmark" : "xmark")
            }
            Text(model.license.summary + " " + model.license.restrictions)
                .font(.system(size: 10.5)).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            Link(String(localized: "Model source"), destination: model.sourcePage).font(.system(size: 10.5))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch store.state(model.id) {
        case .installed:
            if store.updateAvailable(model) { Badge(text: String(localized: "Update available"), color: DS.Palette.blue, symbol: "arrow.down.circle") }
            else { Badge(text: String(localized: "Installed"), color: DS.Palette.success, symbol: "checkmark.circle.fill") }
        case .notInstalled: Badge(text: String(localized: "Not installed"), color: DS.Palette.textTertiary, symbol: nil)
        case .queued: Badge(text: String(localized: "Waiting"), color: DS.Palette.textSecondary, symbol: "clock")
        case .downloading: Badge(text: String(localized: "Downloading"), color: DS.Palette.blue, symbol: "arrow.down")
        case .paused: Badge(text: String(localized: "Paused"), color: DS.Palette.warning, symbol: "pause.fill")
        case .verifying: Badge(text: String(localized: "Verifying"), color: DS.Palette.blue, symbol: "checkmark.shield")
        case .installing: Badge(text: String(localized: "Installing"), color: DS.Palette.blue, symbol: "gearshape")
        case .failed: Badge(text: String(localized: "Failed"), color: DS.Palette.danger, symbol: "exclamationmark.triangle")
        }
    }
}

/// Download / pause / resume / cancel with precise progress.
struct AIModelDownloadControl: View {
    let model: AIModelDescriptor
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        let compatible = AIHardware.current.incompatibility(of: model) == nil
        switch store.state(model.id) {
        case .notInstalled:
            Button { store.download(model) } label: { Label(String(localized: "Download \(model.downloadSize.formattedBytes)"), systemImage: "arrow.down.circle") }
                .buttonStyle(GlassButtonStyle(kind: .primary))
                .disabled(!compatible)
        case .queued:
            HStack(spacing: DS.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Waiting for the current download").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Button(String(localized: "Cancel")) { store.cancel(model.id) }.buttonStyle(GlassButtonStyle(kind: .plain))
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p.fraction).progressViewStyle(.linear).tint(DS.Palette.blue).frame(minWidth: 180)
                HStack(spacing: DS.Space.xs) {
                    Text(progressText(p)).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                    Spacer(minLength: DS.Space.xs)
                    Button { store.pause(model.id) } label: { Image(systemName: "pause.fill") }.buttonStyle(GlassIconButtonStyle(size: 26))
                        .help(String(localized: "Pause"))
                    Button { store.cancel(model.id) } label: { Image(systemName: "xmark") }.buttonStyle(GlassIconButtonStyle(size: 26))
                        .help(String(localized: "Cancel"))
                }
            }
            .frame(maxWidth: 360)
        case .paused(let p):
            HStack(spacing: DS.Space.xs) {
                Button { store.resume(model.id) } label: { Label(String(localized: "Resume"), systemImage: "play.fill") }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
                Text("\(p.received.formattedBytes) / \(p.total.formattedBytes)").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                Button(String(localized: "Cancel")) { store.cancel(model.id) }.buttonStyle(GlassButtonStyle(kind: .plain))
            }
        case .verifying(let file):
            HStack(spacing: DS.Space.xs) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Checking SHA-256 of \(file)…")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
        case .installing:
            HStack(spacing: DS.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        case .installed:
            if store.updateAvailable(model) {
                Button { store.download(model) } label: { Label(String(localized: "Update"), systemImage: "arrow.down.circle") }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
            } else {
                Label(String(localized: "Ready – works offline"), systemImage: "checkmark.circle.fill").font(DS.Font.caption).foregroundStyle(DS.Palette.success)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(DS.Font.caption).foregroundStyle(DS.Palette.danger).fixedSize(horizontal: false, vertical: true)
                Button { store.download(model) } label: { Label(String(localized: "Try Again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle(kind: .secondary))
                    .disabled(!compatible)
            }
        }
    }

    private func progressText(_ p: DownloadProgress) -> String {
        var t = "\(Int(p.fraction * 100)) % · \(p.received.formattedBytes) / \(p.total.formattedBytes)"
        if let s = p.bytesPerSecond { t += " · \(Int64(s).formattedBytes)/s" }
        if let r = p.remainingSeconds { t += " · " + String(localized: "\(r.formattedDuration) left") }
        if p.fileCount > 1 { t += " · " + String(localized: "file \(p.fileIndex) of \(p.fileCount)") }
        return t
    }
}

