import SwiftUI
import UniformTypeIdentifiers

/// AI Studio – local image generation and AI editing. Everything runs on this Mac.
struct AIStudioView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var studio = AIStudioModel.shared
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            AIStudioRail()
                .frame(width: 214)
            ZStack(alignment: .top) {
                content
                    .id(studio.section)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                AIBanners()
                    .padding(.top, 58)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
        .padding(.bottom, DS.Space.m)
        .animation(DS.Motion.adaptive(DS.Motion.page), value: studio.section)
        .onAppear { store.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch studio.section {
        case .generate: AIGenerateView()
        case .edit, .fill, .expand, .enhance, .upscale: AIEditWorkspace()
        case .creations: AICreationsView()
        case .models: AIModelsView()
        }
    }
}

// MARK: - Section rail

struct AIStudioRail: View {
    @ObservedObject private var studio = AIStudioModel.shared
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var creations = CreationStore.shared
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.Palette.magic)
                Text("AI Studio").font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xs)
            ForEach(AIStudioModel.Section.allCases) { s in
                if s == .creations {
                    Rectangle().fill(DS.Palette.hairline).frame(height: 0.5).padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.s)
                }
                row(s)
            }
            Spacer(minLength: DS.Space.m)
            privacyNote
        }
        .padding(DS.Space.xs)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: DS.Radius.panel)
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: studio.section)
    }

    private func row(_ s: AIStudioModel.Section) -> some View {
        let on = studio.section == s
        return Button {
            withAnimation(DS.Motion.adaptive(DS.Motion.page)) { studio.section = s }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: s.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(DS.Palette.textSecondary))
                    .frame(width: 20)
                Text(s.title)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if s == .creations, !creations.creations.isEmpty {
                    Text("\(creations.creations.count)").font(DS.Font.caption).monospacedDigit().foregroundStyle(DS.Palette.textTertiary)
                }
                if s == .models, store.states.values.contains(where: { if case .downloading = $0 { return true }; return false }) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.blue)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 8)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Palette.surfaceStrong)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Palette.rim, lineWidth: 0.5))
                        .matchedGeometryEffect(id: "ai-rail", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "100 % on this Mac"), systemImage: "lock.shield")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.success)
            Text("No cloud, no uploads. Prompts and images never leave your Mac.")
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.s)
    }
}

// MARK: - Banners (errors, notices)

struct AIBanners: View {
    @ObservedObject private var studio = AIStudioModel.shared

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            if let e = studio.errorMessage {
                banner(e, symbol: "exclamationmark.triangle.fill", tint: DS.Palette.warning) { studio.errorMessage = nil }
            }
            if let n = studio.notice {
                banner(n, symbol: "info.circle.fill", tint: DS.Palette.blue) { studio.notice = nil }
            }
        }
        .frame(maxWidth: 640)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: studio.errorMessage)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: studio.notice)
    }

    private func banner(_ text: String, symbol: String, tint: Color, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 14, weight: .semibold))
            Text(text).font(DS.Font.body).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.textTertiary)
                .help(String(localized: "Close"))
        }
        .padding(DS.Space.s)
        .glassCard(cornerRadius: DS.Radius.card)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Job status (real progress only)

struct AIJobIndicator: View {
    let job: AIJobStatus
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ZStack {
                if let f = job.fraction {
                    ProgressRing(fraction: f, lineWidth: 4)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                Text(detail).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                    .contentTransitionNumeric()
            }
            Spacer(minLength: DS.Space.s)
            Button(String(localized: "Cancel"), action: onCancel)
                .buttonStyle(GlassButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        job.variantCount > 1 ? String(localized: "\(job.title) · image \(job.variant) of \(job.variantCount)") : job.title
    }

    private var detail: String {
        switch job.phase {
        case .loading:
            if DiffusionEngine.shared.isLoaded { return String(localized: "Preparing…") }
            if let m = AIStudioModel.shared.activeModel, m.backend == .neuralEngine, ModelValidation.record(m.id) == nil {
                return String(localized: "First start: macOS optimises the model for the Neural Engine – this can take a few minutes, once.")
            }
            return String(localized: "Loading model into memory…")
        case .steps(let s, let n, _):
            var t = String(localized: "Step \(s) of \(n)")
            if let r = job.remainingSeconds, r >= 1 { t += " · " + String(localized: "about \(r.formattedDuration) left") }
            return t
        case .fraction(let f):
            return "\(Int(f * 100)) %"
        case .finishing:
            return String(localized: "Finishing…")
        }
    }
}

// MARK: - Before / after

struct BeforeAfterView: View {
    let before: CGImage
    let after: CGImage
    @State private var split: CGFloat = 0.5
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let size = fitted(in: g.size)
            ZStack {
                Image(decorative: after, scale: 1).resizable().interpolation(.high)
                Image(decorative: before, scale: 1).resizable().interpolation(.high)
                    .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                Rectangle().fill(.white).frame(width: 2).shadow(color: .black.opacity(0.35), radius: 3)
                    .position(x: size.width * split, y: size.height / 2)
                Circle().fill(.ultraThinMaterial).frame(width: dragging ? 34 : 28, height: dragging ? 34 : 28)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 4)
                    .position(x: size.width * split, y: size.height / 2)
                VStack {
                    HStack {
                        Badge(text: String(localized: "Before"), color: .white, symbol: nil).background(Capsule().fill(.black.opacity(0.35)))
                        Spacer()
                        Badge(text: String(localized: "After"), color: .white, symbol: nil).background(Capsule().fill(.black.opacity(0.35)))
                    }
                    Spacer()
                }
                .padding(DS.Space.s)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = true; split = min(1, max(0, v.location.x / max(1, size.width))) }
                .onEnded { _ in withAnimation(DS.Motion.snappy) { dragging = false } })
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .accessibilityElement()
            .accessibilityLabel(Text("Before and after comparison"))
            .accessibilityValue(Text("\(Int(split * 100)) %"))
            .accessibilityAdjustableAction { d in split = min(1, max(0, split + (d == .increment ? 0.1 : -0.1))) }
        }
    }

    private func fitted(in s: CGSize) -> CGSize {
        let r = CGFloat(after.width) / CGFloat(max(1, after.height))
        return s.width / max(1, s.height) > r ? CGSize(width: s.height * r, height: s.height) : CGSize(width: s.width, height: s.width / r)
    }
}

/// Image fitted into the available space with the hero corner radius.
struct AIStageImage: View {
    let image: CGImage
    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

// MARK: - Result actions

struct AIResultActions: View {
    let result: AIResult
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var studio = AIStudioModel.shared
    @Binding var comparing: Bool
    @State private var newAlbumName = ""
    @State private var askNewAlbum = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if result.creation.kind == .textToImage {
                Button { studio.moreVariants(like: result) } label: { Label(String(localized: "More variants"), systemImage: "square.grid.2x2") }
                    .buttonStyle(GlassButtonStyle(kind: .secondary))
                    .disabled(studio.isBusy)
            }
            Menu {
                ForEach([AIStudioModel.Section.edit, .fill, .expand, .enhance, .upscale]) { s in
                    Button { studio.setSource(result: result, section: s) } label: { Label(s.title, systemImage: s.symbol) }
                }
            } label: { Label(String(localized: "Edit"), systemImage: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 6).glass(.interactive, in: Capsule())
            if result.before != nil {
                Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { comparing.toggle() } } label: {
                    Label(String(localized: "Compare"), systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(GlassButtonStyle(kind: comparing ? .primary : .secondary))
            }
            Spacer(minLength: DS.Space.s)
            Button { studio.export(result.creation) } label: { Label(String(localized: "Export"), systemImage: "square.and.arrow.up") }
                .buttonStyle(GlassButtonStyle(kind: .secondary))
            Button { studio.saveToLibrary(result.creation) } label: {
                Label(result.creation.libraryPath == nil ? String(localized: "Save to Library") : String(localized: "In Library"),
                      systemImage: result.creation.libraryPath == nil ? "photo.badge.plus" : "checkmark.circle")
            }
            .buttonStyle(GlassButtonStyle(kind: .primary))
            Menu {
                Button(String(localized: "Save and Open in Editor")) { studio.saveToLibrary(result.creation, thenEdit: true) }
                if !app.albums.isEmpty {
                    Menu(String(localized: "Add to Album")) {
                        ForEach(app.albums) { a in Button(a.name) { studio.saveToLibrary(result.creation, albumID: a.id) } }
                    }
                }
                Button(String(localized: "New Album…")) { askNewAlbum = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "More saving options"))
        }
        .font(DS.Font.body)
        .alert(String(localized: "New Album"), isPresented: $askNewAlbum) {
            TextField(String(localized: "Album name"), text: $newAlbumName)
            Button(String(localized: "Create")) { studio.saveToLibrary(result.creation, newAlbum: newAlbumName); newAlbumName = "" }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }
}

/// Short provenance line under a result: model, seed, time.
struct AIResultMeta: View {
    let creation: AICreation
    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Badge(text: creation.kind.isFullyGenerated ? String(localized: "AI-generated") : String(localized: "AI-edited"),
                  color: DS.Palette.iris, symbol: "sparkles")
            Text([creation.modelName, creation.settingsSummary, String(format: "%.0f s", creation.duration)].joined(separator: " · "))
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1).truncationMode(.middle)
            if let note = creation.note {
                Text("· \(note)").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
        }
    }
}

/// Variant / history thumbnails under the stage.
struct AIResultStrip: View {
    @ObservedObject private var studio = AIStudioModel.shared
    var kinds: Set<AIOperationKind>?

    var body: some View {
        let list = studio.results.filter { kinds?.contains($0.creation.kind) ?? true }
        if list.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(list) { r in
                        let on = studio.selectedResult?.id == r.id
                        Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { studio.selectedResultID = r.id } } label: {
                            Image(decorative: r.image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                                    .strokeBorder(on ? DS.Palette.blue : DS.Palette.hairline, lineWidth: on ? 2.5 : 0.5))
                                .scaleEffect(on ? 1 : 0.94)
                        }
                        .buttonStyle(.plain)
                        .help(r.creation.prompt)
                    }
                }
                .padding(4)
            }
            .frame(height: 76)
        }
    }
}

// MARK: - Source picker (library or file)

struct AISourcePicker: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var studio = AIStudioModel.shared
    @State private var dropTargeted = false
    var message: String

    var body: some View {
        VStack(spacing: DS.Space.l) {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DS.Palette.brand)
                Text("Choose a photo").font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                Text(message).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            HStack(spacing: DS.Space.s) {
                Button { studio.chooseFile() } label: { Label(String(localized: "Choose File…"), systemImage: "folder") }
                    .buttonStyle(GlassButtonStyle(kind: .secondary, large: true))
                if let id = app.lastClicked ?? app.selection.first, let p = app.photo(id) {
                    Button { studio.setSource(photo: p) } label: { Label(String(localized: "Use “\(p.filename)”"), systemImage: "photo") }
                        .buttonStyle(GlassButtonStyle(kind: .primary, large: true))
                }
            }
            if !app.photos.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    GroupHeader(title: String(localized: "From your library"), detail: nil)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: DS.Space.xs)], spacing: DS.Space.xs) {
                            ForEach(app.photos.sorted { $0.importedAt > $1.importedAt }.prefix(120)) { p in
                                Button { studio.setSource(photo: p) } label: {
                                    ThumbnailImage(photo: p, recipe: app.recipe(for: p.id))
                                        .aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help(p.filename)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
                .frame(maxWidth: 760)
            }
            Label(String(localized: "Or drop an image here"), systemImage: "hand.draw")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous)
            .strokeBorder(dropTargeted ? DS.Palette.blue : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in AIStudioModel.shared.setSource(url: url) } }
            }
            return true
        }
    }
}
