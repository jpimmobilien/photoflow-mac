import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// State for the non-generative video tools (background replacement, optimisation). They use Apple Vision and
/// Core Image and run on every Mac, Apple Silicon and Intel.
@MainActor
final class VideoToolsModel: ObservableObject {
    static let shared = VideoToolsModel()

    enum BackgroundChoice: String, CaseIterable, Identifiable {
        case image, video, blur, color
        var id: String { rawValue }
        var title: String {
            switch self {
            case .image: return String(localized: "Image")
            case .video: return String(localized: "Other video")
            case .blur: return String(localized: "Blur")
            case .color: return String(localized: "Colour")
            }
        }
    }

    @Published var source: URL?
    @Published var info: VideoIO.SourceInfo?
    @Published var bgChoice: BackgroundChoice = .image
    @Published var bgImage: CGImage?
    @Published var bgImageName = ""
    @Published var bgVideo: URL?
    @Published var bgColor = Color(red: 0.12, green: 0.45, blue: 0.85)
    @Published var blurRadius = 24.0
    @Published var subject: VideoBackgroundReplacer.Subject = .people
    @Published var stabilize = true
    @Published var color = true
    @Published var strength: EnhanceStrength = .balanced
    @Published var plan: VideoOptimizer.Plan?
    @Published private(set) var running: String?
    @Published private(set) var fraction = 0.0
    @Published var result: VideoCreation?
    private var cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable { var value = false }

    func pick(_ url: URL) {
        source = url; info = nil; plan = nil; result = nil
        Task { do { info = try await VideoIO.info(url) } catch { VideoAIModel.shared.errorMessage = error.localizedDescription; source = nil } }
    }

    func cancel() { cancelFlag.value = true }

    private func begin(_ title: String) -> CancelFlag {
        let f = CancelFlag()
        cancelFlag = f
        running = title
        fraction = 0
        result = nil
        return f
    }

    func replaceBackground() {
        guard let src = source, running == nil else { return }
        let bg: VideoBackgroundReplacer.Background
        switch bgChoice {
        case .image:
            guard let i = bgImage else { VideoAIModel.shared.errorMessage = String(localized: "Choose a background image."); return }
            bg = .image(CIImage(cgImage: i))
        case .video:
            guard let v = bgVideo else { VideoAIModel.shared.errorMessage = String(localized: "Choose a background video."); return }
            bg = .video(v)
        case .blur: bg = .blur(blurRadius)
        case .color:
            let ns = NSColor(bgColor).usingColorSpace(.sRGB) ?? .systemBlue
            bg = .color(CIColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent))
        }
        let flag = begin(VideoAIModel.Section.background.title)
        let subject = self.subject
        AIJobManager.shared.enqueue(VideoAIModel.Section.background.title) {
            let id = UUID()
            let dest = VideoProjectStore.folder.appendingPathComponent(id.uuidString + ".mp4")
            let started = Date()
            do {
                try await Task.detached {
                    try await VideoBackgroundReplacer.run(src, background: bg, subject: subject, to: dest,
                                                          isCancelled: { flag.value }) { f in Task { @MainActor in VideoToolsModel.shared.fraction = f } }
                }.value
                await self.finish(id: id, kind: .backgroundReplace, src: src, dest: dest, started: started, model: "Apple Vision")
            } catch {
                if !flag.value { VideoAIModel.shared.errorMessage = error.localizedDescription }
            }
            self.running = nil
        }
    }

    func optimize() {
        guard let src = source, running == nil else { return }
        let flag = begin(VideoAIModel.Section.optimize.title)
        let opts = VideoOptimizer.Options(color: color, stabilize: stabilize, strength: strength)
        AIJobManager.shared.enqueue(VideoAIModel.Section.optimize.title) {
            let id = UUID()
            let dest = VideoProjectStore.folder.appendingPathComponent(id.uuidString + ".mp4")
            let started = Date()
            do {
                let plan = try await Task.detached {
                    try await VideoOptimizer.analyze(src, options: opts, isCancelled: { flag.value }) { f in
                        Task { @MainActor in VideoToolsModel.shared.fraction = f * 0.3 }
                    }
                }.value
                self.plan = plan
                try await Task.detached {
                    try await VideoOptimizer.run(src, plan: plan, to: dest, isCancelled: { flag.value }) { f in
                        Task { @MainActor in VideoToolsModel.shared.fraction = 0.3 + f * 0.7 }
                    }
                }.value
                await self.finish(id: id, kind: .optimize, src: src, dest: dest, started: started, model: "PhotoFlow Auto Enhance")
            } catch {
                if !flag.value { VideoAIModel.shared.errorMessage = error.localizedDescription }
            }
            self.running = nil
        }
    }

    private func finish(id: UUID, kind: VideoCreation.Kind, src: URL, dest: URL, started: Date, model: String) async {
        let info = try? await VideoIO.info(dest)
        var c = VideoCreation(id: id, kind: kind, modelName: model)
        c.width = Int(info?.size.width ?? 0); c.height = Int(info?.size.height ?? 0)
        c.fps = Int((info?.fps ?? 30).rounded())
        c.frames = Int(((info?.duration ?? 0) * (info?.fps ?? 30)).rounded())
        c.seconds = Date().timeIntervalSince(started)
        c.sourceName = src.lastPathComponent
        c.sourcePath = src.path
        c.fileName = dest.lastPathComponent
        VideoProjectStore.shared.add(c)
        result = c
    }
}

// MARK: - Views

struct VideoToolSource: View {
    @ObservedObject private var tools = VideoToolsModel.shared

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if let r = tools.result {
                VideoPlayerView(url: VideoProjectStore.shared.url(r)).id(r.id)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Label(String(localized: "Result – saved in AI Video Projects"), systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                    Spacer()
                    VideoExportButton(creation: r)
                    Button(String(localized: "Show original")) { tools.result = nil }.buttonStyle(GlassButtonStyle(kind: .plain))
                }
                .font(DS.Font.callout)
            } else if let u = tools.source {
                VideoPlayerView(url: u).id(u)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let i = tools.info {
                    Text("\(u.lastPathComponent) · \(Int(i.size.width)) × \(Int(i.size.height)) · " + String(format: "%.1f s · %.0f fps", i.duration, i.fps) + (i.hasAudio ? " · " + String(localized: "with sound") : ""))
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            } else {
                Spacer()
                Image(systemName: "film.stack").font(.system(size: 46, weight: .light)).foregroundStyle(DS.Palette.magic)
                Text("Choose a video").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                Text("MP4, MOV and ProRes. The original is never changed – the result is saved as a new video with its sound.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Spacer()
            }
            if let r = tools.running {
                HStack(spacing: DS.Space.s) {
                    ProgressRing(fraction: tools.fraction, lineWidth: 4).frame(width: 28, height: 28)
                    Text(r + " · " + String(format: "%.0f %%", tools.fraction * 100)).font(DS.Font.callout).monospacedDigit()
                    Spacer()
                    Button(String(localized: "Cancel")) { tools.cancel() }.buttonStyle(GlassButtonStyle(kind: .secondary))
                }
                .padding(DS.Space.s).glassCard(cornerRadius: DS.Radius.card)
            }
            Button { pick() } label: { Label(String(localized: "Choose video…"), systemImage: "folder") }
                .buttonStyle(GlassButtonStyle(kind: .secondary)).disabled(tools.running != nil)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: DS.Radius.hero)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in VideoToolsModel.shared.pick(url) } }
            }
            return true
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard p.runModal() == .OK, let u = p.url else { return }
        tools.pick(u)
    }
}

struct VideoBackgroundView: View {
    @ObservedObject private var tools = VideoToolsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(VideoAIModel.Section.background.title).font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary)
            HStack(alignment: .top, spacing: DS.Space.l) {
                VideoToolSource()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            ControlLabel(text: String(localized: "Subject"))
                            GlassSegmented(selection: $tools.subject, options: VideoBackgroundReplacer.Subject.allCases.map { .init(value: $0, title: $0.title) })
                            Text(tools.subject == .people
                                 ? String(localized: "Apple Vision person segmentation, frame by frame, smoothed over time.")
                                 : String(localized: "Apple Vision subject segmentation (macOS 14 or later); slower."))
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            ControlLabel(text: String(localized: "New background"))
                            GlassSegmented(selection: $tools.bgChoice, options: VideoToolsModel.BackgroundChoice.allCases.map { .init(value: $0, title: $0.title) })
                            switch tools.bgChoice {
                            case .image:
                                if let i = tools.bgImage {
                                    Image(decorative: i, scale: 1).resizable().scaledToFit().frame(maxHeight: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                                }
                                Button(String(localized: "Choose image…")) { pickImage() }.buttonStyle(GlassButtonStyle(kind: .secondary))
                                Text("Tip: create a background with Photo AI ▸ Generate Image and save it.")
                                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                            case .video:
                                if let v = tools.bgVideo { Text(v.lastPathComponent).font(DS.Font.caption) }
                                Button(String(localized: "Choose video…")) { pickBGVideo() }.buttonStyle(GlassButtonStyle(kind: .secondary))
                            case .blur:
                                FluidSlider(value: $tools.blurRadius, range: 6...60, step: 1).frame(height: 22)
                            case .color:
                                ColorPicker(String(localized: "Colour"), selection: $tools.bgColor, supportsOpacity: false)
                            }
                        }
                        Text("Hair, transparent objects and fast motion blur are the hardest cases; the mask edge is softened and smoothed over time, and a little of the new background's light is wrapped around the subject.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        Button { tools.replaceBackground() } label: {
                            Label(String(localized: "Replace background"), systemImage: "person.and.background.dotted").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                        .disabled(tools.source == nil || tools.running != nil)
                    }
                    .padding(DS.Space.m)
                }
                .frame(width: 292)
                .glassCard(cornerRadius: DS.Radius.panel)
            }
        }
    }

    private func pickImage() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url, let s = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3840,
                                                                  kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
        tools.bgImage = cg; tools.bgImageName = u.lastPathComponent
    }
    private func pickBGVideo() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie]
        guard p.runModal() == .OK, let u = p.url else { return }
        tools.bgVideo = u
    }
}

struct VideoOptimizeView: View {
    @ObservedObject private var tools = VideoToolsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(VideoAIModel.Section.optimize.title).font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary)
            HStack(alignment: .top, spacing: DS.Space.l) {
                VideoToolSource()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        Toggle(String(localized: "Exposure, contrast & colour"), isOn: $tools.color)
                        Text("Scene cuts are detected; every 2 seconds a frame is analysed by PhotoFlow's enhancement engine and the corrections are blended smoothly between them – no flicker from frames corrected independently.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if tools.color {
                            GlassSegmented(selection: $tools.strength, options: EnhanceStrength.allCases.map { .init(value: $0, title: $0.localizedName) })
                        }
                        Toggle(String(localized: "Stabilise (camera shake)"), isOn: $tools.stabilize)
                        Text("Measures the shift between frames (Apple Vision), keeps the smooth camera motion and removes the shake; the frame is enlarged slightly (at most 15 %) to hide the moving edges.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if let p = tools.plan {
                            VStack(alignment: .leading, spacing: 4) {
                                ControlLabel(text: String(localized: "Analysis"))
                                Text(String(localized: "\(p.cuts.count) scene cuts · \(p.recipes.count) keyframes") + (p.zoom > 1.001 ? " · " + String(format: String(localized: "zoom %.0f %%"), (p.zoom - 1) * 100) : ""))
                                    .font(DS.Font.caption)
                                ForEach(p.notes.prefix(5), id: \.self) { Text("• " + $0).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                            }
                        }
                        Button { tools.optimize() } label: {
                            Label(String(localized: "Optimise video"), systemImage: "dial.medium").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                        .disabled(tools.source == nil || tools.running != nil || (!tools.color && !tools.stabilize))
                    }
                    .font(DS.Font.callout)
                    .padding(DS.Space.m)
                }
                .frame(width: 292)
                .glassCard(cornerRadius: DS.Radius.panel)
            }
        }
    }
}
