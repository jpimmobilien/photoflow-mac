import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Switch between the two KI work areas (Foto-KI / Video-KI). Shown at the top of both rails.
struct KIAreaSwitcher: View {
    @EnvironmentObject private var app: AppModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            item(.aiStudio, String(localized: "Photo AI"), "photo")
            item(.videoAI, String(localized: "Video AI"), "film")
        }
        .padding(3)
        .background(Capsule().fill(DS.Palette.hover))
        .overlay(Capsule().strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
    }

    private func item(_ target: SidebarItem, _ title: String, _ symbol: String) -> some View {
        let on = app.sidebar == target
        return Button {
            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { app.sidebar = target }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? DS.Palette.textPrimary : DS.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if on {
                    Capsule().fill(DS.Palette.surfaceStrong)
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "ki-area", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Video AI work area

struct VideoAIView: View {
    @ObservedObject private var video = VideoAIModel.shared
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            VideoAIRail().frame(width: 214)
            ZStack(alignment: .top) {
                content
                    .id(video.section)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                VideoBanners().padding(.top, 58)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
        .padding(.bottom, DS.Space.m)
        .animation(DS.Motion.adaptive(DS.Motion.page), value: video.section)
        .onAppear { store.reload() }
    }

    @ViewBuilder private var content: some View {
        switch video.section {
        case .generate, .animate, .transform: VideoGenerateWorkspace()
        case .background: VideoBackgroundView()
        case .optimize: VideoOptimizeView()
        case .remove, .upscale: VideoUnavailableView(section: video.section)
        case .projects: VideoProjectsView()
        case .models: AIModelsView()
        }
    }
}

struct VideoAIRail: View {
    @ObservedObject private var video = VideoAIModel.shared
    @ObservedObject private var projects = VideoProjectStore.shared
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            KIAreaSwitcher().padding(.horizontal, DS.Space.xxs).padding(.top, DS.Space.xs).padding(.bottom, DS.Space.xs)
            ForEach(VideoAIModel.Section.allCases) { s in
                if s == .projects {
                    Rectangle().fill(DS.Palette.hairline).frame(height: 0.5).padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.s)
                }
                row(s)
            }
            Spacer(minLength: DS.Space.m)
            VStack(alignment: .leading, spacing: 4) {
                Label(String(localized: "100 % on this Mac"), systemImage: "lock.shield").font(DS.Font.caption).foregroundStyle(DS.Palette.success)
                Text("Videos and prompts never leave your Mac.").font(.system(size: 10.5)).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.s)
        }
        .padding(DS.Space.xs)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: DS.Radius.panel)
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: video.section)
    }

    private func available(_ s: VideoAIModel.Section) -> Bool { s != .remove && s != .upscale }

    private func row(_ s: VideoAIModel.Section) -> some View {
        let on = video.section == s
        return Button {
            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { video.section = s }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: s.symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(DS.Palette.textSecondary)).frame(width: 20)
                Text(s.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(available(s) ? DS.Palette.textPrimary : DS.Palette.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                if s == .projects, !projects.items.isEmpty {
                    Text("\(projects.items.count)").font(DS.Font.caption).monospacedDigit().foregroundStyle(DS.Palette.textTertiary)
                }
                if !available(s) {
                    Text("n/a").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
                        .help(String(localized: "Not available yet"))
                }
            }
            .padding(.horizontal, DS.Space.s).padding(.vertical, 8)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.surfaceStrong)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Palette.rim, lineWidth: 0.5))
                        .matchedGeometryEffect(id: "video-rail", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct VideoBanners: View {
    @ObservedObject private var video = VideoAIModel.shared
    var body: some View {
        VStack(spacing: DS.Space.xs) {
            if let e = video.errorMessage { banner(e, "exclamationmark.triangle.fill", DS.Palette.warning) { video.errorMessage = nil } }
            if let n = video.notice { banner(n, "info.circle.fill", DS.Palette.blue) { video.notice = nil } }
        }
        .frame(maxWidth: 720)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: video.errorMessage)
    }
    private func banner(_ text: String, _ symbol: String, _ tint: Color, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(GlassIconButtonStyle())
        }
        .padding(DS.Space.s)
        .glassCard(cornerRadius: DS.Radius.card)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Generate / animate / transform

struct VideoGenerateWorkspace: View {
    @ObservedObject private var video = VideoAIModel.shared
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var projects = VideoProjectStore.shared

    private var cap: AICapability { video.section.capability ?? .textToVideo }

    private static let examples = [
        "A black sports car driving along a winding coastal road in southern France at sunset, low side tracking shot, realistic reflections, smooth motion",
        "Waves rolling onto a sandy beach at golden hour, gentle camera dolly forward, natural light",
        "A modern villa with a pool at dusk, slow drone shot circling the house, warm interior lights",
        "Steam rising from a cup of coffee on a wooden table, morning window light, shallow depth of field"
    ]

    var body: some View {
        VStack(spacing: DS.Space.m) {
            header
            HStack(alignment: .top, spacing: DS.Space.l) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                VideoSettingsPanel(cap: cap).frame(width: 292)
            }
            .frame(maxHeight: .infinity)
            VideoPromptBar(cap: cap)
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: DS.Space.m) {
            Text(video.section.title).font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: DS.Space.s)
            let installed = video.installedModels(for: cap)
            if !installed.isEmpty {
                Menu {
                    ForEach(installed) { m in
                        Button { video.modelID = m.id } label: {
                            if m.id == video.activeModel(for: cap)?.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                        }
                    }
                } label: { Label(video.activeModel(for: cap)?.name ?? "–", systemImage: "cpu") }
                .menuStyle(.borderlessButton).fixedSize().font(DS.Font.callout)
                .padding(.horizontal, 10).padding(.vertical, 5).glass(.interactive, in: Capsule())
            }
        }
    }

    @ViewBuilder private var stage: some View {
        let kind: VideoCreation.Kind = cap == .imageToVideo ? .imageToVideo : cap == .videoToVideo ? .videoToVideo : .textToVideo
        if !video.ready(for: cap) {
            VideoSetupCard(cap: cap)
        } else if let p = video.progress {
            VideoProgressStage(progress: p)
        } else if let r = video.lastResult, r.kind == kind {
            VideoResultStage(creation: r)
        } else if cap == .imageToVideo {
            VideoImageSourceStage()
        } else if cap == .videoToVideo {
            VideoSourceStage()
        } else {
            VStack(spacing: DS.Space.l) {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "film").font(.system(size: 46, weight: .light)).foregroundStyle(DS.Palette.magic).symbolRenderingMode(.hierarchical)
                    Text("Which video should PhotoFlow create?").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                    Text("Describe scene, motion, camera and light. English prompts work best.")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: DS.Space.xs)], spacing: DS.Space.xs) {
                    ForEach(Self.examples, id: \.self) { e in
                        Button { video.prompt = e } label: {
                            Text(e).font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.s)
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

struct VideoProgressStage: View {
    let progress: VideoAIModel.Progress
    @ObservedObject private var video = VideoAIModel.shared

    var body: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                if let f = progress.fraction { ProgressRing(fraction: f, lineWidth: 6).frame(width: 84, height: 84) }
                else { ProgressView().controlSize(.large) }
                Image(systemName: "film").font(.system(size: 22, weight: .semibold)).foregroundStyle(DS.Palette.magic)
            }
            Text(progress.stage).font(DS.Font.title2).foregroundStyle(DS.Palette.textPrimary)
            if progress.total > 0 {
                Text(String(localized: "Step \(progress.step) of \(progress.total)") + (progress.variantCount > 1 ? " · " + String(localized: "Variant \(progress.variant) of \(progress.variantCount)") : ""))
                    .font(DS.Font.callout).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
            }
            if let r = progress.remaining {
                Text(String(localized: "About \(r.formattedDuration) remaining (measured on this Mac)")).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            Button(String(localized: "Cancel")) { video.cancel() }.buttonStyle(GlassButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
    }
}

struct VideoResultStage: View {
    let creation: VideoCreation
    @ObservedObject private var video = VideoAIModel.shared

    var body: some View {
        VStack(spacing: DS.Space.s) {
            VideoPlayerView(url: VideoProjectStore.shared.url(creation))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(creation.id)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            VideoMetaRow(creation: creation)
            HStack(spacing: DS.Space.xs) {
                VideoExportButton(creation: creation)
                Button { NSWorkspace.shared.activateFileViewerSelecting([VideoProjectStore.shared.url(creation)]) } label: {
                    Label(String(localized: "Show in Finder"), systemImage: "folder")
                }.buttonStyle(GlassButtonStyle(kind: .secondary))
                Spacer()
                Button { video.lastResult = nil } label: { Label(String(localized: "New video"), systemImage: "plus") }
                    .buttonStyle(GlassButtonStyle(kind: .plain))
            }
        }
    }
}

struct VideoMetaRow: View {
    let creation: VideoCreation
    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text("\(creation.width) × \(creation.height) · \(creation.frames) " + String(localized: "frames") + " · \(creation.fps) fps · " + String(format: "%.1f s", creation.duration))
            Text("·")
            Text(creation.modelName)
            if let s = creation.seed { Text("· Seed \(String(s))") }
            Text("· " + String(localized: "created in \(creation.seconds.formattedDuration)"))
            Spacer(minLength: 0)
        }
        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1).truncationMode(.middle)
    }
}

struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let p = AVPlayer(url: url)
                p.actionAtItemEnd = .none
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                    p.seek(to: .zero); p.play()
                }
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}

struct VideoExportButton: View {
    let creation: VideoCreation
    @ObservedObject private var video = VideoAIModel.shared
    @State private var codec: VideoIO.Codec = .h264
    @State private var busy = false

    var body: some View {
        Menu {
            ForEach(VideoIO.Codec.allCases) { c in
                Button(c.title) { export(c, scale: 1) }
            }
            Divider()
            Button(String(localized: "H.264 at double size")) { export(.h264, scale: 2) }
            Divider()
            Toggle(String(localized: "Visible “AI-generated” label"), isOn: $video.labelOnExport)
        } label: {
            Label(busy ? String(localized: "Exporting…") : String(localized: "Export"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glass(.interactive, in: Capsule())
        .disabled(busy)
    }

    private func export(_ c: VideoIO.Codec, scale: Double) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [c == .proRes422 ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = "PhotoFlow Video \(creation.createdAt.formatted(date: .numeric, time: .shortened)).\(c.fileExtension)"
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            do { try await video.export(creation, to: url, codec: c, scale: scale, label: video.labelOnExport) }
            catch { video.errorMessage = error.localizedDescription }
            busy = false
        }
    }
}

struct VideoImageSourceStage: View {
    @ObservedObject private var video = VideoAIModel.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let img = video.sourceImage {
                Image(decorative: img, scale: 1).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(video.sourceImageName).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            } else {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 46, weight: .light)).foregroundStyle(DS.Palette.magic)
                Text("Choose a photo to animate").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                Text("The composition of the photo is kept; the model develops plausible motion from it.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            HStack {
                Button { pickFile() } label: { Label(String(localized: "Choose file…"), systemImage: "folder") }
                    .buttonStyle(GlassButtonStyle(kind: .secondary))
                if let p = app.selectedPhotos.first {
                    Button { load(URL(fileURLWithPath: p.path), name: p.filename) } label: {
                        Label(String(localized: "Use selected photo"), systemImage: "photo")
                    }.buttonStyle(GlassButtonStyle(kind: .secondary))
                }
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in load(url, name: url.lastPathComponent) } }
            }
            return true
        }
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url else { return }
        load(u, name: u.lastPathComponent)
    }

    private func load(_ url: URL, name: String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            video.errorMessage = String(localized: "This file could not be opened as an image.")
            return
        }
        video.pickImage(cg, name: name)
    }
}

struct VideoSourceStage: View {
    @ObservedObject private var video = VideoAIModel.shared

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let u = video.sourceVideo {
                VideoPlayerView(url: u).id(u)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let i = video.sourceVideoInfo {
                    Text("\(u.lastPathComponent) · \(Int(i.size.width)) × \(Int(i.size.height)) · " + String(format: "%.1f s · %.0f fps", i.duration, i.fps) + (i.hasAudio ? " · " + String(localized: "with sound") : ""))
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            } else {
                Image(systemName: "film.stack").font(.system(size: 46, weight: .light)).foregroundStyle(DS.Palette.magic)
                Text("Choose a video").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                Text("MP4, MOV and ProRes. The original file is never changed – results are saved as new videos.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Button { pick() } label: { Label(String(localized: "Choose video…"), systemImage: "folder") }
                .buttonStyle(GlassButtonStyle(kind: .secondary))
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in video.pickVideo(url) } }
            }
            return true
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard p.runModal() == .OK, let u = p.url else { return }
        video.pickVideo(u)
    }
}

// MARK: - Settings

struct VideoSettingsPanel: View {
    let cap: AICapability
    @ObservedObject private var video = VideoAIModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let m = video.activeModel(for: cap) {
                    if cap == .textToVideo {
                        group(String(localized: "Format")) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                ForEach(VideoAspect.allCases) { a in chip(a.title, a.symbol, video.aspect == a) { video.aspect = a } }
                            }
                        }
                    }
                    if cap != .videoToVideo {
                        group(String(localized: "Length")) {
                            GlassSegmented(selection: $video.seconds, options: video.durations(for: m).map { .init(value: $0, title: String(format: "%.0f s", $0)) })
                            Text(String(localized: "Longer clips are created by extending a finished clip."))
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    group(String(localized: "Quality")) {
                        GlassSegmented(selection: $video.quality, options: VideoQuality.allCases.map { .init(value: $0, title: $0.title) })
                        let (w, h) = video.size(for: m, aspect: video.aspect)
                        let n = video.frames(for: m, seconds: video.seconds)
                        Text("\(w) × \(h) px · \(n) " + String(localized: "frames") + " · \(m.videoFPS) fps · \(video.quality.steps) " + String(localized: "steps"))
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                        let mem = video.memoryEstimate(model: m, width: w, height: h, frames: n)
                        Label(String(localized: "Memory needed: about \(Int(mem.rounded())) GB (this Mac: \(Int(AIHardware.current.memoryGB.rounded())) GB)"),
                              systemImage: "memorychip")
                            .font(DS.Font.caption)
                            .foregroundStyle(mem > AIHardware.current.memoryGB * 0.8 ? DS.Palette.warning : DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if cap == .imageToVideo {
                        group(String(localized: "Camera & motion")) {
                            Picker("", selection: $video.motion) {
                                ForEach(VideoMotion.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden()
                            Text("Added to the prompt as an instruction – the model has no numeric motion control.")
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if cap == .videoToVideo {
                        group(String(localized: "Change intensity")) {
                            FluidSlider(value: $video.strength, range: 0.2...0.9, step: 0.05).frame(height: 22)
                            Text(String(format: "%.0f %%", video.strength * 100) + " · " + String(localized: "low values keep motion, camera and composition; high values change more"))
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        group(String(localized: "Variants")) {
                            GlassSegmented(selection: $video.variants, options: [1, 2].map { .init(value: $0, title: "\($0)") })
                        }
                    }
                    DisclosureGroup(String(localized: "Advanced")) {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            ControlLabel(text: String(localized: "Seed"))
                            TextField(String(localized: "Random"), text: $video.seedText).textFieldStyle(.roundedBorder)
                            ControlLabel(text: String(localized: "Prompt guidance") + String(format: " %.1f", video.guidance))
                            FluidSlider(value: $video.guidance, range: 1...10, step: 0.5).frame(height: 22)
                            ControlLabel(text: String(localized: "Negative prompt"))
                            TextField("", text: $video.negativePrompt, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                        }
                        .padding(.top, DS.Space.xs)
                    }
                    .font(DS.Font.callout)
                }
            }
            .padding(DS.Space.m)
        }
        .glassCard(cornerRadius: DS.Radius.panel)
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) { ControlLabel(text: title); content() }
    }

    private func chip(_ title: String, _ symbol: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { action() } }) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).lineLimit(1)
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
    }
}

struct VideoPromptBar: View {
    let cap: AICapability
    @ObservedObject private var video = VideoAIModel.shared
    @FocusState private var focused: Bool

    private var placeholder: String {
        switch cap {
        case .imageToVideo: return String(localized: "Optional: describe the motion – e.g. the waves roll in, leaves move in the wind")
        case .videoToVideo: return String(localized: "Describe the change – e.g. the same scene in winter with snow")
        default: return String(localized: "Describe the video – scene, motion, camera, light")
        }
    }
    private var canRun: Bool {
        !video.isBusy && video.ready(for: cap) && (cap == .imageToVideo ? video.sourceImage != nil : !video.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            && (cap != .videoToVideo || video.sourceVideo != nil)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            TextField(placeholder, text: $video.prompt, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5).focused($focused).padding(.vertical, 9)
                .onSubmit { if canRun { video.start() } }
            Button { video.start() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 13, weight: .bold))
                    Text(cap == .videoToVideo ? String(localized: "Transform") : cap == .imageToVideo ? String(localized: "Animate") : String(localized: "Generate"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 36)
                .background(Capsule().fill(DS.Palette.brand)).opacity(canRun ? 1 : 0.45)
            }
            .buttonStyle(.plain).disabled(!canRun).keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, DS.Space.m).padding(.trailing, 6).padding(.vertical, 6)
        .glass(.floating, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(DS.Palette.magic, lineWidth: focused ? 1.6 : 0).opacity(focused ? 0.9 : 0).allowsHitTesting(false))
        .frame(maxWidth: 860)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: focused)
    }
}

/// What has to be installed before a video function works – with honest hardware status.
struct VideoSetupCard: View {
    let cap: AICapability
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var video = VideoAIModel.shared

    var body: some View {
        let hw = AIHardware.current
        let model = video.models(for: cap).first { hw.incompatibility(of: $0) == nil } ?? video.models(for: cap).first
        let parts = ([model?.id, "wan-umt5", VideoRuntime.id].compactMap { $0 }).compactMap(AIModelCatalog.model)
        let missing = parts.filter { !store.isInstalled($0.id) }
        let total = missing.reduce(Int64(0)) { $0 + $1.downloadSize }
        ScrollView {
            VStack(spacing: DS.Space.l) {
                Image(systemName: "arrow.down.circle").font(.system(size: 44, weight: .light)).foregroundStyle(DS.Palette.brand)
                VStack(spacing: DS.Space.xs) {
                    Text("Local video AI needs a one-time download").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary).multilineTextAlignment(.center)
                    Text("“\(cap.title)” runs entirely on this Mac. Total download: \(total.formattedBytes). Afterwards it works offline.")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 560)
                }
                if let m = model, let reason = hw.incompatibility(of: m) {
                    Label(reason, systemImage: "xmark.octagon").font(DS.Font.callout).foregroundStyle(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560)
                }
                ForEach(parts) { p in AIModelCard(model: p, compact: true).frame(maxWidth: 600) }
                Button { withAnimation(DS.Motion.adaptive(DS.Motion.page)) { video.section = .models } } label: {
                    Label(String(localized: "All models"), systemImage: "cpu")
                }.buttonStyle(GlassButtonStyle(kind: .secondary))
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
    }
}

/// Functions that are not reliable yet are shown as such – no decorative buttons.
struct VideoUnavailableView: View {
    let section: VideoAIModel.Section
    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: section.symbol).font(.system(size: 44, weight: .light)).foregroundStyle(DS.Palette.textTertiary)
            Text(section.title).font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
            Text("Not available yet").font(DS.Font.headline).foregroundStyle(DS.Palette.warning)
            Text(reason).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
    }

    private var reason: String {
        switch section {
        case .remove:
            return String(localized: "Removing objects from videos needs a mask that follows the object through every frame and a video model that fills the gap consistently over time. The model (Wan VACE) is in the catalog, but this function is only offered once it has passed the tests on real Apple Silicon hardware.")
        case .upscale:
            return String(localized: "Frame-by-frame upscaling flickers; a temporally consistent video upscaler with a suitable licence and Mac support has not been verified yet.")
        default:
            return ""
        }
    }
}

// MARK: - Projects

struct VideoProjectsView: View {
    @ObservedObject private var projects = VideoProjectStore.shared
    @ObservedObject private var video = VideoAIModel.shared
    @State private var selected: VideoCreation?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(VideoAIModel.Section.projects.title).font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary)
            if projects.items.isEmpty {
                Text("Generated and edited videos appear here.").font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let s = selected {
                VStack(spacing: DS.Space.s) {
                    HStack {
                        Button { selected = nil } label: { Label(String(localized: "All videos"), systemImage: "chevron.left") }.buttonStyle(GlassButtonStyle(kind: .plain))
                        Spacer()
                    }
                    VideoPlayerView(url: projects.url(s)).id(s.id)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VideoMetaRow(creation: s)
                    if !s.prompt.isEmpty { Text(s.prompt).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        VideoExportButton(creation: s)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([projects.url(s)]) } label: { Label(String(localized: "Show in Finder"), systemImage: "folder") }
                            .buttonStyle(GlassButtonStyle(kind: .secondary))
                        Spacer()
                        Button(role: .destructive) { projects.delete(s); selected = nil } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                            .buttonStyle(GlassButtonStyle(kind: .destructive))
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: DS.Space.s)], spacing: DS.Space.s) {
                        ForEach(projects.items) { c in
                            Button { selected = c } label: { VideoPosterCard(creation: c) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct VideoPosterCard: View {
    let creation: VideoCreation
    @State private var poster: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let p = poster { Image(decorative: p, scale: 1).resizable().scaledToFill() } else { DS.Palette.hover }
                Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
            }
            .frame(height: 140).clipped()
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            Text(creation.kind.title + String(format: " · %.1f s", creation.duration)).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
            Text(creation.prompt.isEmpty ? (creation.sourceName ?? "") : creation.prompt).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
        }
        .padding(DS.Space.xs)
        .glassCard(cornerRadius: DS.Radius.card, interactive: true)
        .task { poster = await VideoIO.poster(VideoProjectStore.shared.url(creation)) }
    }
}
