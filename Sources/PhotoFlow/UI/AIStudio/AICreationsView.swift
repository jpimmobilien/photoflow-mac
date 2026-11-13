import SwiftUI

/// "My AI Creations": every result, persisted with prompt, model, seed and settings.
struct AICreationsView: View {
    @ObservedObject private var store = CreationStore.shared
    @ObservedObject private var studio = AIStudioModel.shared
    @State private var search = ""
    @State private var kind: AIOperationKind?
    @State private var newestFirst = true
    @State private var selected: UUID?
    @State private var confirmDelete: AICreation?

    private var filtered: [AICreation] {
        var list = store.creations
        if let kind { list = list.filter { $0.kind == kind } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.prompt.lowercased().contains(q) || $0.modelName.lowercased().contains(q) || ($0.sourceName ?? "").lowercased().contains(q) }
        }
        return list.sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .lastTextBaseline) {
                Text(AIStudioModel.Section.creations.title).font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text("\(store.creations.count) · \(store.totalBytes.formattedBytes)").font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            HStack(spacing: DS.Space.s) {
                GlassSearchField(text: $search, prompt: String(localized: "Search prompts and models"))
                    .frame(maxWidth: 360)
                Menu {
                    Button(String(localized: "All")) { kind = nil }
                    Divider()
                    ForEach(AIOperationKind.allCases) { k in Button { kind = k } label: { Label(k.title, systemImage: k.symbol) } }
                } label: {
                    Label(kind?.title ?? String(localized: "All"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 6).glass(.interactive, in: Capsule())
                Button { newestFirst.toggle() } label: {
                    Label(newestFirst ? String(localized: "Newest first") : String(localized: "Oldest first"), systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(GlassButtonStyle(kind: .secondary))
                Spacer()
            }
            if store.creations.isEmpty {
                EmptyStateView(symbol: "sparkles", title: String(localized: "No AI creations yet"),
                               message: String(localized: "Everything you generate or edit in AI Studio is kept here with its prompt, model and settings."),
                               actionTitle: String(localized: "Generate an Image"),
                               action: { withAnimation(DS.Motion.adaptive(DS.Motion.page)) { studio.section = .generate } })
            } else {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: DS.Space.s)], spacing: DS.Space.s) {
                            ForEach(filtered) { c in tile(c) }
                        }
                        .padding(4)
                    }
                    if let c = filtered.first(where: { $0.id == selected }) ?? filtered.first {
                        detail(c).frame(width: 320)
                    }
                }
            }
        }
        .alert(String(localized: "Delete this creation?"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(String(localized: "Delete"), role: .destructive) { if let c = confirmDelete { store.delete([c.id]) }; confirmDelete = nil }
            Button(String(localized: "Cancel"), role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Copies already saved to your library are not affected.")
        }
    }

    private func tile(_ c: AICreation) -> some View {
        let on = (selected ?? filtered.first?.id) == c.id
        return Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { selected = c.id } } label: {
            VStack(alignment: .leading, spacing: 6) {
                CreationThumb(creation: c)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(on ? DS.Palette.blue : DS.Palette.hairline, lineWidth: on ? 2.5 : 0.5))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: c.kind.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(5).background(Circle().fill(.black.opacity(0.4))).padding(6)
                    }
                Text(c.prompt.isEmpty ? c.kind.title : c.prompt).font(DS.Font.caption).foregroundStyle(DS.Palette.textPrimary).lineLimit(2)
                Text(c.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "Save to Library")) { studio.saveToLibrary(c) }
            Button(String(localized: "Export…")) { studio.export(c) }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) { confirmDelete = c }
        }
    }

    private func detail(_ c: AICreation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                CreationThumb(creation: c, pixel: 640)
                    .aspectRatio(CGFloat(c.width) / CGFloat(max(1, c.height)), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                HStack {
                    Badge(text: c.kind.title, color: DS.Palette.iris, symbol: c.kind.symbol)
                    Spacer()
                    Text(c.createdAt.formatted(date: .abbreviated, time: .shortened)).font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                }
                if !c.prompt.isEmpty { field(String(localized: "Prompt"), c.prompt, selectable: true) }
                if !c.negativePrompt.isEmpty { field(String(localized: "Negative prompt"), c.negativePrompt, selectable: true) }
                field(String(localized: "Model"), c.modelName)
                field(String(localized: "Settings"), c.settingsSummary)
                if let s = c.styleID, s != "none" { field(String(localized: "Style"), AIStyle.style(s).title) }
                if let src = c.sourceName { field(String(localized: "Source"), src) }
                if let n = c.note { field(String(localized: "Note"), n) }
                field(String(localized: "Duration"), String(format: "%.0f s", c.duration))
                if c.libraryPath != nil {
                    Label(String(localized: "In your library"), systemImage: "checkmark.circle.fill").font(DS.Font.caption).foregroundStyle(DS.Palette.success)
                }
                VStack(spacing: 6) {
                    if c.kind == .textToImage {
                        action(String(localized: "Generate again (same seed)"), "arrow.clockwise") { studio.regenerate(c) }
                        action(String(localized: "Variants"), "square.grid.2x2") {
                            if let img = CreationStore.shared.image(c) {
                                withAnimation(DS.Motion.adaptive(DS.Motion.page)) { studio.section = .generate }
                                studio.moreVariants(like: AIResult(image: img, creation: c, before: nil))
                            }
                        }
                    }
                    action(String(localized: "Edit"), "slider.horizontal.3") { studio.openFromCreations(c, section: .edit) }
                    action(String(localized: "Generative Fill"), "paintbrush.pointed") { studio.openFromCreations(c, section: .fill) }
                    action(String(localized: "Upscale"), "arrow.up.forward.square") { studio.openFromCreations(c, section: .upscale) }
                    action(String(localized: "Save to Library"), "photo.badge.plus") { studio.saveToLibrary(c) }
                    action(String(localized: "Export…"), "square.and.arrow.up") { studio.export(c) }
                    action(String(localized: "Delete"), "trash", destructive: true) { confirmDelete = c }
                }
            }
            .padding(DS.Space.m)
        }
        .glassCard(cornerRadius: DS.Radius.panel)
    }

    private func field(_ title: String, _ value: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ControlLabel(text: title)
            if selectable {
                Text(value).font(DS.Font.body).foregroundStyle(DS.Palette.textPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(value).font(DS.Font.body).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, destructive: Bool = false, _ run: @escaping () -> Void) -> some View {
        InspectorAction(title: title, symbol: symbol, destructive: destructive, action: run)
    }
}

/// Thumbnail of a stored creation (decoded off the main thread).
struct CreationThumb: View {
    let creation: AICreation
    var pixel = 360
    @State private var image: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill).transition(.opacity)
                } else {
                    Rectangle().fill(DS.Palette.hover)
                }
            }
            .clipped()
            .task(id: "\(creation.id)-\(pixel)") {
                let url = CreationStore.imageURL(creation)
                let px = pixel
                image = await Task.detached(priority: .utility) { AIImage.thumbnail(url, maxPixel: px) }.value
            }
    }
}
