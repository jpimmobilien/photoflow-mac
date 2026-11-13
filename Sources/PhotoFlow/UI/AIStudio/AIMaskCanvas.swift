import SwiftUI

/// Tool palette above the mask canvas.
struct AIMaskToolbar: View {
    @ObservedObject private var studio = AIStudioModel.shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 2) {
                ForEach(MaskDocument.Tool.allCases) { t in
                    Button { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { studio.tool = t } } label: {
                        Image(systemName: t.symbol)
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 30, active: studio.tool == t))
                    .help(t.title)
                    .accessibilityLabel(Text(t.title))
                }
            }
            if studio.tool == .brush || studio.tool == .eraser {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                    FluidSlider(value: $studio.brushSize, range: 0.01...0.2, step: 0.005).frame(width: 120, height: 22)
                    Image(systemName: "circle.fill").font(.system(size: 13))
                }
                .foregroundStyle(DS.Palette.textSecondary)
                .help(String(localized: "Brush size"))
            }
            Spacer(minLength: DS.Space.s)
            Button { studio.mask.inverted.toggle() } label: { Image(systemName: "circle.lefthalf.striped.horizontal.inverse") }
                .buttonStyle(GlassIconButtonStyle(size: 30, active: studio.mask.inverted))
                .help(String(localized: "Invert selection"))
            Button { studio.mask.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(GlassIconButtonStyle(size: 30))
                .disabled(studio.mask.operations.isEmpty && studio.mask.base == nil)
                .keyboardShortcut("z", modifiers: .command)
                .help(String(localized: "Undo"))
            Button { studio.mask.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(GlassIconButtonStyle(size: 30))
                .disabled(studio.mask.isEmpty)
                .help(String(localized: "Clear mask"))
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 6)
        .glass(.floating, in: Capsule())
    }
}

/// The photo with a semi-transparent selection overlay. Paint with the brush, erase, or drag rectangles
/// and ellipses. Coordinates are stored normalised, so the mask is rendered at full size for processing.
struct AIMaskCanvas: View {
    let image: CGImage
    @ObservedObject private var studio = AIStudioModel.shared
    @State private var current: MaskDocument.Operation?
    @State private var overlay: CGImage?
    @State private var hover: CGPoint?

    private var previewSize: (Int, Int) {
        let long = 900.0
        let s = min(1, long / Double(max(image.width, image.height)))
        return (max(1, Int(Double(image.width) * s)), max(1, Int(Double(image.height) * s)))
    }

    var body: some View {
        GeometryReader { g in
            let size = fitted(in: g.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                if let overlay {
                    Image(decorative: overlay, scale: 1).resizable().interpolation(.medium)
                        .allowsHitTesting(false)
                }
                if let hover, studio.tool == .brush || studio.tool == .eraser {
                    let d = studio.brushSize * Double(max(size.width, size.height))
                    Circle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 3))
                        .frame(width: d, height: d)
                        .position(hover)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .contentShape(Rectangle())
            .gesture(drag(size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .onAppear(perform: redraw)
        .onChange(of: studio.mask) { _ in redraw() }
        .onChange(of: current) { _ in redraw() }
        .accessibilityElement()
        .accessibilityLabel(Text("Selection mask. Paint over the area to change."))
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = CGPoint(x: min(1, max(0, v.location.x / size.width)), y: min(1, max(0, v.location.y / size.height)))
                hover = v.location
                if current == nil {
                    current = MaskDocument.Operation(tool: studio.tool, points: [p], size: CGFloat(studio.brushSize))
                } else if studio.tool == .brush || studio.tool == .eraser {
                    current?.points.append(p)
                } else {
                    current?.points = [current?.points.first ?? p, p]
                }
            }
            .onEnded { _ in
                if let op = current { studio.mask.operations.append(op) }
                current = nil
            }
    }

    private func redraw() {
        var doc = studio.mask
        if let current { doc.operations.append(current) }
        let (w, h) = previewSize
        guard let m = doc.render(width: w, height: h) else { overlay = nil; return }
        // Background mode: the subject is selected – show it in green; otherwise blue.
        overlay = studio.fillMode == .background
            ? AIImage.tintedOverlay(m, red: 0.24, green: 0.84, blue: 0.55, alpha: 0.42)
            : AIImage.tintedOverlay(m, red: 0.29, green: 0.58, blue: 1.0, alpha: 0.45)
    }

    private func fitted(in s: CGSize) -> CGSize {
        let r = CGFloat(image.width) / CGFloat(max(1, image.height))
        return s.width / max(1, s.height) > r ? CGSize(width: s.height * r, height: s.height) : CGSize(width: s.width, height: s.width / r)
    }
}

/// Outpainting canvas: the photo inside a larger frame. Drag the handles on the four edges outwards.
struct AIExpandCanvas: View {
    let image: CGImage
    @ObservedObject private var studio = AIStudioModel.shared
    @State private var dragStart: AIOperations.Expansion?

    var body: some View {
        GeometryReader { g in
            let W = Double(image.width), H = Double(image.height)
            let e = studio.expansion
            // Room for up to 100 % expansion on every side.
            let scale = min(g.size.width / (W * 1.9), g.size.height / (H * 1.9))
            let outerW = (W + Double(e.left + e.right)) * scale, outerH = (H + Double(e.top + e.bottom)) * scale
            let innerX = Double(e.left) * scale, innerY = Double(e.top) * scale
            let originX = (g.size.width - outerW) / 2, originY = (g.size.height - outerH) / 2
            ZStack(alignment: .topLeading) {
                // Preview of the new area: stretched, blurred edges (what the model starts from).
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: outerW, height: outerH)
                    .blur(radius: 24)
                    .opacity(0.55)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.blue, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: outerW, height: outerH)
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: W * scale, height: H * scale)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .offset(x: innerX, y: innerY)
                handle(.left, x: innerX, y: innerY + H * scale / 2, scale: scale)
                handle(.right, x: innerX + W * scale, y: innerY + H * scale / 2, scale: scale)
                handle(.top, x: innerX + W * scale / 2, y: innerY, scale: scale)
                handle(.bottom, x: innerX + W * scale / 2, y: innerY + H * scale, scale: scale)
            }
            .frame(width: outerW, height: outerH, alignment: .topLeading)
            .offset(x: originX, y: originY)
            .animation(dragStart == nil ? DS.Motion.adaptive(DS.Motion.smooth) : nil, value: studio.expansion)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Expansion canvas"))
    }

    enum Edge { case left, right, top, bottom }

    private func handle(_ edge: Edge, x: Double, y: Double, scale: Double) -> some View {
        let horizontal = edge == .left || edge == .right
        return Capsule()
            .fill(.white)
            .frame(width: horizontal ? 8 : 44, height: horizontal ? 44 : 8)
            .overlay(Capsule().strokeBorder(DS.Palette.blue, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 3)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .gesture(DragGesture()
                .onChanged { v in
                    if dragStart == nil { dragStart = studio.expansion }
                    guard let start = dragStart else { return }
                    var e = start
                    let maxW = image.width, maxH = image.height
                    switch edge {
                    case .left: e.left = clamp(start.left + Int(-v.translation.width / scale), maxW)
                    case .right: e.right = clamp(start.right + Int(v.translation.width / scale), maxW)
                    case .top: e.top = clamp(start.top + Int(-v.translation.height / scale), maxH)
                    case .bottom: e.bottom = clamp(start.bottom + Int(v.translation.height / scale), maxH)
                    }
                    studio.expansion = e
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityLabel(Text("Edge handle"))
    }

    private func clamp(_ v: Int, _ limit: Int) -> Int { min(limit, max(0, v)) }
}
