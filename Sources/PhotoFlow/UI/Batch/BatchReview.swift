import SwiftUI
import CoreImage

/// Controlled batch mode: PhotoFlow analyses every photo individually and proposes corrections and a crop;
/// the user reviews before/after, changes the crop or strength per photo, excludes photos, and only then applies.
/// Originals are never touched – recipes are saved non-destructively, exactly as in automatic mode.
@MainActor
final class BatchReviewModel: ObservableObject {
    struct Item: Identifiable {
        let id: Int64
        let filename: String
        var analysis: PhotoAnalysis
        var recipe: EditRecipe
        var notes: [String]
        var before: CGImage
        var after: CGImage?
        var include = true
        var crop: AutoCrop.Mode
        var strength: EnhanceStrength
    }

    @Published var items: [Item] = []
    @Published private(set) var analysing = false
    @Published private(set) var analysed = 0
    @Published private(set) var total = 0
    @Published var showBefore: Int64?
    private var task: Task<Void, Never>?
    private var workflow = BatchWorkflow.predefined[0]
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    var includedCount: Int { items.filter(\.include).count }

    func prepare(_ app: AppModel, workflow: BatchWorkflow, photos: [PhotoRecord]) {
        cancel()
        self.workflow = workflow
        items = []
        total = photos.count
        analysed = 0
        analysing = true
        let existing = app.recipes
        let presets = app.customPresets
        let limit = max(1, AppSettings.batchConcurrency)
        task = Task {
            await withTaskGroup(of: Item?.self) { group in
                var next = 0
                func add() {
                    guard next < photos.count else { return }
                    let p = photos[next]; next += 1
                    group.addTask {
                        guard let a = autoreleasepool(invoking: { PhotoAnalyzer.analyze(url: p.url, iso: p.iso) }) else { return nil }
                        let planned = BatchPlanner.recipe(workflow: workflow, analysis: a, base: existing[p.id], customPresets: presets)
                        let after = Self.render(planned.recipe, a.analysisImage)
                        return Item(id: p.id, filename: p.filename, analysis: a, recipe: planned.recipe, notes: planned.notes,
                                    before: a.analysisImage, after: after, crop: workflow.autoCrop, strength: workflow.strength)
                    }
                }
                for _ in 0..<min(limit, photos.count) { add() }
                while let r = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let r { items.append(r) }
                    analysed += 1
                    add()
                }
            }
            analysing = false
        }
    }

    func cancel() { task?.cancel(); task = nil; analysing = false }

    nonisolated static func render(_ r: EditRecipe, _ img: CGImage) -> CGImage? {
        let out = RenderPipeline.apply(r, to: CIImage(cgImage: img))
        return ctx.createCGImage(out, from: out.extent)
    }

    /// Re-plans one photo after the user changed its crop or strength (uses the cached analysis).
    func update(_ id: Int64, crop: AutoCrop.Mode? = nil, strength: EnhanceStrength? = nil, app: AppModel) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let crop { items[i].crop = crop }
        if let strength { items[i].strength = strength }
        var wf = workflow
        wf.autoCrop = items[i].crop
        wf.strength = items[i].strength
        let a = items[i].analysis
        let planned = BatchPlanner.recipe(workflow: wf, analysis: a, base: app.recipes[id], customPresets: app.customPresets)
        items[i].recipe = planned.recipe
        items[i].notes = planned.notes
        items[i].after = Self.render(planned.recipe, a.analysisImage)
    }

    /// Saves the reviewed recipes of the included photos (non-destructive) – same storage as automatic mode.
    func apply(_ app: AppModel) -> Int {
        guard let store = app.store else { return 0 }
        var done = 0
        for it in items where it.include {
            do {
                let edited = try store.saveRecipe(it.recipe, for: it.id)
                ThumbnailService.shared.invalidate(photoID: it.id)
                app.applyBatchResult(BatchItemResult(photoID: it.id, status: .done, recipe: it.recipe, editedAt: edited,
                                                     exportedURL: nil, exportedBytes: 0, duration: 0, notes: it.notes))
                done += 1
            } catch {
                continue
            }
        }
        app.refreshVisible()
        return done
    }
}

struct BatchReviewSheet: View {
    @ObservedObject var review: BatchReviewModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review suggestions").font(DS.Font.title1)
                    Text("Each photo was analysed individually. Hover a photo to see the original; change crop or strength per photo, or leave photos out.")
                        .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                if review.analysing {
                    ProgressView(value: Double(review.analysed), total: Double(max(1, review.total))).frame(width: 160)
                    Text("\(review.analysed) / \(review.total)").font(DS.Font.caption).monospacedDigit()
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: DS.Space.s)], spacing: DS.Space.s) {
                    ForEach(review.items) { it in cell(it) }
                }
            }
            HStack {
                Button(String(localized: "Cancel")) { review.cancel(); dismiss() }.buttonStyle(GlassButtonStyle(kind: .plain))
                Spacer()
                Text(String(localized: "\(review.includedCount) of \(review.items.count) photos selected")).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                Button {
                    let n = review.apply(app)
                    app.showToast(String(localized: "Applied to \(n) photos – originals unchanged"), symbol: "checkmark.seal.fill")
                    dismiss()
                } label: { Label(String(localized: "Apply to selected photos"), systemImage: "checkmark") }
                .buttonStyle(GlassButtonStyle(kind: .primary))
                .disabled(review.analysing || review.includedCount == 0)
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 920, minHeight: 640)
    }

    private func cell(_ it: BatchReviewModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                let showBefore = review.showBefore == it.id
                Image(decorative: (showBefore ? it.before : (it.after ?? it.before)), scale: 1)
                    .resizable().scaledToFit()
                    .frame(height: 170).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    .onHover { h in review.showBefore = h ? it.id : (review.showBefore == it.id ? nil : review.showBefore) }
                Text(showBefore ? String(localized: "Original") : String(localized: "Suggestion"))
                    .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule()).padding(6)
            }
            .opacity(it.include ? 1 : 0.4)
            HStack {
                Toggle(isOn: Binding(get: { it.include }, set: { v in if let i = review.items.firstIndex(where: { $0.id == it.id }) { review.items[i].include = v } })) {
                    Text(it.filename).font(DS.Font.caption).lineLimit(1).truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Menu {
                    ForEach(AutoCrop.Mode.choices, id: \.self) { m in Button(m.displayName) { review.update(it.id, crop: m, app: app) } }
                } label: { Label(it.crop.displayName, systemImage: "crop") }
                .menuStyle(.borderlessButton).fixedSize().font(DS.Font.caption)
                Menu {
                    ForEach(EnhanceStrength.allCases) { s in Button(s.localizedName) { review.update(it.id, strength: s, app: app) } }
                } label: { Label(it.strength.localizedName, systemImage: "wand.and.stars") }
                .menuStyle(.borderlessButton).fixedSize().font(DS.Font.caption)
            }
            Text(it.notes.prefix(3).joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(DS.Palette.textTertiary).lineLimit(2)
        }
        .padding(DS.Space.xs)
        .glassCard(cornerRadius: DS.Radius.card)
    }
}
