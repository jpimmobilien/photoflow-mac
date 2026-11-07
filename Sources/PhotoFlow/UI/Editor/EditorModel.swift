import Foundation
import SwiftUI
import CoreImage

enum CompareMode: String, CaseIterable, Identifiable {
    case edited, original, split, sideBySide
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .edited: return String(localized: "Edited")
        case .original: return String(localized: "Original")
        case .split: return String(localized: "Slider")
        case .sideBySide: return String(localized: "Side by Side")
        }
    }
    var symbol: String {
        switch self {
        case .edited: return "photo"
        case .original: return "photo.badge.arrow.down"
        case .split: return "square.split.2x1"
        case .sideBySide: return "rectangle.split.2x1"
        }
    }
}

/// Editing session for one photo. Rendering runs off the main thread on a preview-sized copy;
/// full resolution is only decoded for 1:1 zoom and export.
@MainActor
final class EditorModel: ObservableObject {
    let photo: PhotoRecord
    @Published private(set) var recipe: EditRecipe
    @Published private(set) var edited: CGImage?
    @Published private(set) var original: CGImage?
    @Published private(set) var zoomedEdited: CGImage?
    @Published private(set) var zoomedOriginal: CGImage?
    @Published var mode: CompareMode = .edited
    @Published var split: CGFloat = 0.5
    @Published var zoom = false { didSet { if zoom { loadFullResolution() } } }
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isLoadingFull = false
    @Published var message: String?
    @Published var showGrid = false

    private var base: CIImage?
    private var analysis: PhotoAnalysis?
    private var renderTask: Task<Void, Never>?
    private var needsRender = false
    private var dragStart: EditRecipe?
    private var fullBase: CIImage?

    nonisolated static let previewSize = 2200

    init(photo: PhotoRecord, recipe: EditRecipe?, startInCompare: Bool = false) {
        self.photo = photo
        self.recipe = recipe ?? .identity
        if startInCompare { mode = .split }
        load()
    }

    private func load() {
        let url = photo.url
        Task {
            let cg = await Task.detached(priority: .userInitiated) { ImageLoader.thumbnail(url: url, maxPixel: EditorModel.previewSize) }.value
            guard let cg else {
                message = String(localized: "The original could not be opened.")
                return
            }
            original = cg
            base = CIImage(cgImage: cg)
            scheduleRender()
        }
    }

    // MARK: - Rendering

    private func scheduleRender() {
        needsRender = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while true {
                guard let self, self.needsRender, let base = self.base else { break }
                self.needsRender = false
                let r = self.recipe
                let img = await Task.detached(priority: .userInitiated) { EditorModel.render(r, base: base) }.value
                self.edited = img
                if self.zoom { self.zoomedEdited = nil; self.renderFull() }
            }
            self?.renderTask = nil
        }
    }

    nonisolated static func render(_ r: EditRecipe, base: CIImage) -> CGImage? {
        let out = RenderPipeline.apply(r, to: base)
        return CIContextProvider.shared.createCGImage(out, from: out.extent.integral, format: .RGBA8, colorSpace: CIContextProvider.displayP3)
    }

    private func loadFullResolution() {
        guard fullBase == nil else { renderFull(); return }
        isLoadingFull = true
        let url = photo.url, uti = photo.uti
        Task {
            let base = await Task.detached(priority: .userInitiated) { () -> CIImage? in
                guard let img = try? ImageLoader.full(url: url, uti: uti) else { return nil }
                // Cap at 6000 px to keep memory reasonable on older Macs.
                let long = max(img.extent.width, img.extent.height)
                guard long > 6000 else { return img }
                let s = 6000 / long
                return img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }.value
            fullBase = base
            if let base {
                zoomedOriginal = await Task.detached(priority: .userInitiated) {
                    CIContextProvider.shared.createCGImage(base, from: base.extent.integral, format: .RGBA8, colorSpace: CIContextProvider.displayP3)
                }.value
            }
            renderFull()
        }
    }

    private func renderFull() {
        guard let base = fullBase else { return }
        let r = recipe
        isLoadingFull = true
        Task {
            let img = await Task.detached(priority: .userInitiated) { EditorModel.render(r, base: base) }.value
            if r == recipe { zoomedEdited = img }
            isLoadingFull = false
        }
    }

    // MARK: - Editing with undo/redo

    private var undoStack: [(recipe: EditRecipe, name: String)] = []
    private var redoStack: [(recipe: EditRecipe, name: String)] = []
    @Published private(set) var undoName: String?
    @Published private(set) var redoName: String?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Applies a change as one undoable step and saves it.
    func change(_ name: String, _ body: (inout EditRecipe) -> Void) {
        var new = recipe
        body(&new)
        set(new, name: name)
    }

    func set(_ new: EditRecipe, name: String) {
        let old = recipe
        guard new != old else { return }
        recipe = new
        pushUndo(old, name: name)
        scheduleRender()
        persist()
    }

    private func pushUndo(_ old: EditRecipe, name: String) {
        undoStack.append((old, name))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateNames()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((recipe, last.name))
        recipe = last.recipe
        updateNames()
        scheduleRender()
        persist()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((recipe, next.name))
        recipe = next.recipe
        updateNames()
        scheduleRender()
        persist()
    }

    private func updateNames() {
        undoName = undoStack.last?.name
        redoName = redoStack.last?.name
    }

    /// Live slider updates (render only); the undo step is recorded when the drag ends.
    func binding(_ key: WritableKeyPath<EditRecipe, Double>) -> Binding<Double> {
        Binding(get: { self.recipe[keyPath: key] },
                set: { v in
                    if self.dragStart == nil { self.dragStart = self.recipe; self.pendingCommit = true }
                    self.recipe[keyPath: key] = v
                    self.scheduleRender()
                    self.scheduleCommit()
                })
    }

    private var pendingCommit = false
    private var dragName = ""
    private var commitTask: Task<Void, Never>?

    func dragChanged(_ editing: Bool, name: String) {
        dragName = name
        if editing {
            if dragStart == nil { dragStart = recipe }
            if name == String(localized: "Straighten") { showGrid = true }
        } else {
            showGrid = false
            commitDrag()
        }
    }

    /// Keyboard/scroll changes do not send "editing ended" – commit after a short pause instead.
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.commitDrag()
        }
    }

    private func commitDrag() {
        commitTask?.cancel()
        if let start = dragStart, start != recipe {
            pushUndo(start, name: dragName.isEmpty ? String(localized: "Adjustment") : dragName)
            persist()
        }
        dragStart = nil
        pendingCommit = false
    }

    private func persist() {
        AppModel.shared.saveRecipe(recipe, for: photo.id)
    }

    // MARK: - Automatic tools

    private func ensureAnalysis() async -> PhotoAnalysis? {
        if let analysis { return analysis }
        guard let cg = original else { return nil }
        isAnalyzing = true
        let iso = photo.iso
        let a = await Task.detached(priority: .userInitiated) { () -> PhotoAnalysis? in
            // Analyse a 768 px copy (same as batch processing, so results are identical)
            let ci = CIImage(cgImage: cg)
            let s = CGFloat(PhotoAnalyzer.analysisSize) / max(ci.extent.width, ci.extent.height)
            let small = s < 1 ? ci.transformed(by: CGAffineTransform(scaleX: s, y: s)) : ci
            guard let scg = CIContextProvider.shared.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CIContextProvider.sRGB) else { return nil }
            return PhotoAnalyzer.analyze(image: scg, iso: iso)
        }.value
        isAnalyzing = false
        analysis = a
        return a
    }

    func autoEnhance(_ strength: EnhanceStrength) async {
        guard let a = await ensureAnalysis() else { return }
        var base = recipe
        base.monochrome = recipe.monochrome
        let outcome = AutoEnhanceEngine.enhance(a, base: base, strength: strength, options: .enhanceOnly)
        set(outcome.recipe, name: String(localized: "Auto Enhance"))
        message = outcome.notes.isEmpty ? String(localized: "This photo already looks well balanced – only minimal changes were made.") : nil
    }

    func autoWhiteBalance() async {
        guard let a = await ensureAnalysis() else { return }
        var opts = AutoEnhanceOptions()
        opts.tone = false; opts.color = false; opts.detail = false; opts.whiteBalance = true
        var r = AutoEnhanceEngine.enhance(a, base: recipe, strength: .balanced, options: opts).recipe
        r.auto = recipe.auto
        let changed = r.temperature != recipe.temperature || r.tint != recipe.tint
        set(r, name: String(localized: "Auto White Balance"))
        message = changed ? nil : String(localized: "No color cast detected – white balance left unchanged.")
    }

    func autoStraighten() async {
        guard let a = await ensureAnalysis() else { return }
        let st = a.straighten
        if st.shouldApply {
            change(String(localized: "Auto Straighten")) { $0.rotation = (st.correction * 100).rounded() / 100 }
            message = String(localized: "Rotated by \(String(format: "%.1f", st.correction))°.")
        } else if abs(st.tilt) < StraightenEngine.minAutoAngle && st.confidence >= 0.3 {
            message = String(localized: "The horizon is already straight.")
        } else {
            message = String(localized: "No clear horizon or straight lines found. Use the slider to straighten manually.")
        }
    }

    func autoPerspective() async {
        guard let a = await ensureAnalysis() else { return }
        let p = a.perspective
        if p.applyVertical || p.applyHorizontal {
            change(String(localized: "Auto Perspective")) { r in
                r.documentCorners = nil
                if p.applyVertical { r.perspectiveVertical = p.verticalSlider.rounded() }
                if p.applyHorizontal { r.perspectiveHorizontal = p.horizontalSlider.rounded() }
                if a.straighten.shouldApply && r.rotation == 0 { r.rotation = (a.straighten.correction * 100).rounded() / 100 }
            }
            message = nil
        } else {
            message = String(localized: "PhotoFlow could not confidently detect converging lines. Use the Vertical and Horizontal sliders to adjust manually.")
        }
    }

    func documentMode() async {
        guard let cg = original else { return }
        isAnalyzing = true
        let corners = await Task.detached(priority: .userInitiated) { PerspectiveEngine.documentCorners(in: cg) }.value
        isAnalyzing = false
        if let corners {
            change(String(localized: "Rectify Document")) { $0.documentCorners = corners; $0.perspectiveVertical = 0; $0.perspectiveHorizontal = 0 }
            message = nil
        } else {
            message = String(localized: "No document edges found.")
        }
    }

    func applyPreset(_ preset: Preset) async {
        var start = recipe
        if preset.adaptive, let a = await ensureAnalysis() {
            start = AutoEnhanceEngine.enhance(a, base: recipe, strength: .subtle, options: .enhanceOnly).recipe
        }
        var r = preset.apply(to: start)
        r.adoptGeometry(from: recipe)
        set(r, name: String(localized: "Preset"))
    }

    func rotate90(clockwise: Bool) {
        change(String(localized: "Rotate")) { $0.quarterTurns = ($0.quarterTurns + (clockwise ? 3 : 1)) % 4; $0.crop = nil }
    }

    func resetAll() {
        set(.identity, name: String(localized: "Reset All"))
        message = nil
    }

    func resetGeometry() {
        change(String(localized: "Reset Geometry")) { r in
            r.rotation = 0; r.perspectiveVertical = 0; r.perspectiveHorizontal = 0; r.documentCorners = nil; r.crop = nil
        }
    }

    var retainedArea: Double {
        guard let o = original else { return 1 }
        return GeometryModel(recipe: recipe).retainedArea(size: CGSize(width: o.width, height: o.height))
    }
}
