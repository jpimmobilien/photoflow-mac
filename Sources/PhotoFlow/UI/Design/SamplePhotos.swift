import SwiftUI

/// Built-in sample "photographs" (vector scenes drawn with Canvas) – visual fallbacks only, used when the
/// library has no photos yet. They share the icon's motif: sky, sun, blue mountains. `look` renders the
/// same scene as an unprocessed original (flat, cast, dull) or as the processed result.
struct SamplePhoto: View {
    enum Scene: CaseIterable { case landscape, lake, bright, alpine, portrait, tilted }
    enum Look { case before, after, bright, natural }

    var scene: Scene
    var look: Look = .after

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            draw(scene, in: &ctx, size: size)
        }
        .saturation(saturation)
        .contrast(contrast)
        .brightness(brightness)
        .colorMultiply(look == .before ? Color(red: 1.0, green: 0.95, blue: 0.84) : .white)
        .accessibilityHidden(true)
    }

    private var saturation: Double {
        switch look { case .before: return 0.6; case .after: return 1.12; case .bright: return 1.05; case .natural: return 0.98 }
    }
    private var contrast: Double {
        switch look { case .before: return 0.84; case .after: return 1.05; case .bright: return 0.98; case .natural: return 1.0 }
    }
    private var brightness: Double {
        switch look { case .before: return -0.07; case .after: return 0.0; case .bright: return 0.07; case .natural: return 0.01 }
    }

    // MARK: Drawing

    private func lin(_ colors: [Color], _ a: CGPoint, _ b: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: colors), startPoint: a, endPoint: b)
    }

    private func draw(_ scene: Scene, in ctx: inout GraphicsContext, size s: CGSize) {
        let w = s.width, h = s.height
        let rect = CGRect(origin: .zero, size: s)
        switch scene {
        case .landscape, .tilted, .lake, .bright, .alpine:
            // sky
            let sky: [Color]
            switch scene {
            case .bright: sky = [Color(red: 0.62, green: 0.84, blue: 1.0), Color(red: 0.93, green: 0.96, blue: 1.0)]
            case .alpine: sky = [Color(red: 0.16, green: 0.42, blue: 0.86), Color(red: 0.55, green: 0.76, blue: 0.98)]
            case .tilted: sky = [Color(red: 0.42, green: 0.66, blue: 0.98), Color(red: 0.88, green: 0.80, blue: 0.94), Color(red: 1.0, green: 0.78, blue: 0.60)]
            default: sky = [Color(red: 0.30, green: 0.62, blue: 0.99), Color(red: 0.78, green: 0.74, blue: 0.95), Color(red: 1.0, green: 0.76, blue: 0.58)]
            }
            ctx.fill(Path(rect), with: lin(sky, .zero, CGPoint(x: 0, y: h * 0.72)))
            // sun + glow
            let sun = CGPoint(x: w * 0.68, y: h * (scene == .alpine ? 0.22 : 0.34))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - h * 0.42, y: sun.y - h * 0.42, width: h * 0.84, height: h * 0.84)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.55).opacity(0.75), .clear]), center: sun, startRadius: 0, endRadius: h * 0.42))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - h * 0.075, y: sun.y - h * 0.075, width: h * 0.15, height: h * 0.15)),
                     with: lin([Color(red: 1, green: 0.88, blue: 0.5), Color(red: 1, green: 0.72, blue: 0.4)], CGPoint(x: sun.x, y: sun.y - h * 0.07), CGPoint(x: sun.x, y: sun.y + h * 0.07)))
            if scene == .alpine {
                for (cx, cy, r) in [(0.22, 0.18, 0.09), (0.3, 0.2, 0.07), (0.82, 0.12, 0.06)] as [(CGFloat, CGFloat, CGFloat)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: w * cx - h * r * 2, y: h * cy - h * r * 0.6, width: h * r * 4, height: h * r * 1.2)), with: .color(.white.opacity(0.55)))
                }
            }
        case .portrait:
            ctx.fill(Path(rect), with: lin([Color(red: 0.36, green: 0.40, blue: 0.62), Color(red: 0.62, green: 0.52, blue: 0.62)], .zero, CGPoint(x: w, y: h)))
            // bokeh
            for (cx, cy, r, c) in [(0.15, 0.25, 0.10, Color(red: 1, green: 0.8, blue: 0.55)), (0.85, 0.2, 0.08, Color(red: 0.6, green: 0.75, blue: 1)),
                                   (0.78, 0.7, 0.12, Color(red: 1, green: 0.7, blue: 0.6)), (0.1, 0.75, 0.07, Color(red: 0.7, green: 0.8, blue: 1))] as [(CGFloat, CGFloat, CGFloat, Color)] {
                ctx.fill(Path(ellipseIn: CGRect(x: w * cx - h * r, y: h * cy - h * r, width: h * r * 2, height: h * r * 2)), with: .color(c.opacity(0.35)))
            }
        }

        switch scene {
        case .landscape, .alpine:
            let far = Path { p in
                p.move(to: CGPoint(x: 0, y: h * 0.62)); p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.38)); p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.52))
                p.addLine(to: CGPoint(x: w * 0.56, y: h * 0.30)); p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.55)); p.addLine(to: CGPoint(x: w, y: h * 0.44))
                p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
            }
            ctx.fill(far, with: lin([Color(red: 0.35, green: 0.55, blue: 0.95), Color(red: 0.25, green: 0.42, blue: 0.82)], CGPoint(x: 0, y: h * 0.3), CGPoint(x: 0, y: h)))
            if scene == .alpine {
                for (px, py) in [(0.22, 0.38), (0.56, 0.30)] as [(CGFloat, CGFloat)] {
                    let cap = Path { p in
                        p.move(to: CGPoint(x: w * px, y: h * py)); p.addLine(to: CGPoint(x: w * px - w * 0.06, y: h * (py + 0.08))); p.addLine(to: CGPoint(x: w * px + w * 0.06, y: h * (py + 0.08))); p.closeSubpath()
                    }
                    ctx.fill(cap, with: .color(.white.opacity(0.92)))
                }
            }
            let near = Path { p in
                p.move(to: CGPoint(x: 0, y: h * 0.78)); p.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.7), control: CGPoint(x: w * 0.25, y: h * 0.64))
                p.addQuadCurve(to: CGPoint(x: w, y: h * 0.74), control: CGPoint(x: w * 0.78, y: h * 0.78))
                p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
            }
            ctx.fill(near, with: lin([Color(red: 0.30, green: 0.62, blue: 0.48), Color(red: 0.14, green: 0.38, blue: 0.32)], CGPoint(x: 0, y: h * 0.66), CGPoint(x: 0, y: h)))
        case .lake:
            let horizon = h * 0.58
            let mountains = Path { p in
                p.move(to: CGPoint(x: 0, y: horizon)); p.addLine(to: CGPoint(x: w * 0.2, y: h * 0.34)); p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.5))
                p.addLine(to: CGPoint(x: w * 0.62, y: h * 0.28)); p.addLine(to: CGPoint(x: w, y: h * 0.5)); p.addLine(to: CGPoint(x: w, y: horizon)); p.closeSubpath()
            }
            ctx.fill(mountains, with: lin([Color(red: 0.3, green: 0.5, blue: 0.92), Color(red: 0.2, green: 0.38, blue: 0.75)], CGPoint(x: 0, y: h * 0.28), CGPoint(x: 0, y: horizon)))
            ctx.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)),
                     with: lin([Color(red: 0.55, green: 0.66, blue: 0.95), Color(red: 0.18, green: 0.36, blue: 0.68)], CGPoint(x: 0, y: horizon), CGPoint(x: 0, y: h)))
            var mirror = ctx
            mirror.translateBy(x: 0, y: horizon * 2)
            mirror.scaleBy(x: 1, y: -1)
            mirror.opacity = 0.35
            mirror.fill(mountains, with: .color(Color(red: 0.2, green: 0.36, blue: 0.7)))
            for i in 0 ..< 6 {
                let y = horizon + CGFloat(i + 1) * (h - horizon) / 7
                ctx.fill(Path(CGRect(x: w * (0.15 + CGFloat(i % 3) * 0.2), y: y, width: w * 0.22, height: max(1, h * 0.006))), with: .color(.white.opacity(0.28)))
            }
        case .bright:
            let sea = h * 0.56
            ctx.fill(Path(CGRect(x: 0, y: sea, width: w, height: h * 0.16)), with: lin([Color(red: 0.25, green: 0.72, blue: 0.86), Color(red: 0.45, green: 0.85, blue: 0.9)], CGPoint(x: 0, y: sea), CGPoint(x: 0, y: sea + h * 0.16)))
            let sand = Path { p in
                p.move(to: CGPoint(x: 0, y: h * 0.74)); p.addQuadCurve(to: CGPoint(x: w, y: h * 0.7), control: CGPoint(x: w * 0.5, y: h * 0.66))
                p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
            }
            ctx.fill(sand, with: lin([Color(red: 0.98, green: 0.9, blue: 0.76), Color(red: 0.93, green: 0.8, blue: 0.64)], CGPoint(x: 0, y: h * 0.68), CGPoint(x: 0, y: h)))
            ctx.fill(Path(CGRect(x: 0, y: h * 0.71, width: w, height: max(1.5, h * 0.012))), with: .color(.white.opacity(0.8)))
        case .tilted:
            let horizon = h * 0.56
            ctx.fill(Path(CGRect(x: -w, y: horizon, width: w * 3, height: h)), with: lin([Color(red: 0.24, green: 0.48, blue: 0.86), Color(red: 0.12, green: 0.28, blue: 0.6)], CGPoint(x: 0, y: horizon), CGPoint(x: 0, y: h)))
            ctx.fill(Path(CGRect(x: w * 0.55, y: horizon + h * 0.04, width: w * 0.3, height: max(1, h * 0.01))), with: .color(Color(red: 1, green: 0.85, blue: 0.6).opacity(0.7)))
            let sail = Path { p in
                p.move(to: CGPoint(x: w * 0.3, y: horizon - h * 0.2)); p.addLine(to: CGPoint(x: w * 0.3, y: horizon - h * 0.02)); p.addLine(to: CGPoint(x: w * 0.38, y: horizon - h * 0.02)); p.closeSubpath()
            }
            ctx.fill(sail, with: .color(.white.opacity(0.95)))
            ctx.fill(Path(CGRect(x: w * 0.27, y: horizon - h * 0.02, width: w * 0.13, height: h * 0.025)), with: .color(Color(red: 0.2, green: 0.2, blue: 0.3)))
        case .portrait:
            let cx = w * 0.5
            let shoulders = Path { p in
                p.move(to: CGPoint(x: cx - h * 0.46, y: h)); p.addQuadCurve(to: CGPoint(x: cx + h * 0.46, y: h), control: CGPoint(x: cx, y: h * 0.56))
                p.closeSubpath()
            }
            ctx.fill(shoulders, with: lin([Color(red: 0.95, green: 0.62, blue: 0.5), Color(red: 0.78, green: 0.42, blue: 0.4)], CGPoint(x: 0, y: h * 0.7), CGPoint(x: 0, y: h)))
            ctx.fill(Path(CGRect(x: cx - h * 0.06, y: h * 0.56, width: h * 0.12, height: h * 0.14)), with: .color(Color(red: 0.88, green: 0.66, blue: 0.54)))
            let head = CGRect(x: cx - h * 0.15, y: h * 0.22, width: h * 0.3, height: h * 0.38)
            let hair = Path { p in
                p.addEllipse(in: head.insetBy(dx: -h * 0.03, dy: -h * 0.03).offsetBy(dx: 0, dy: -h * 0.01))
            }
            ctx.fill(hair, with: lin([Color(red: 0.32, green: 0.22, blue: 0.2), Color(red: 0.18, green: 0.12, blue: 0.12)], CGPoint(x: 0, y: head.minY), CGPoint(x: 0, y: head.maxY)))
            ctx.fill(Path(ellipseIn: head.offsetBy(dx: 0, dy: h * 0.02)),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.98, green: 0.8, blue: 0.68), Color(red: 0.86, green: 0.62, blue: 0.5)]),
                                           center: CGPoint(x: head.midX - h * 0.04, y: head.midY - h * 0.04), startRadius: 0, endRadius: h * 0.24))
            // soft key light
            ctx.fill(Path(ellipseIn: CGRect(x: head.minX - h * 0.2, y: head.minY - h * 0.15, width: h * 0.5, height: h * 0.5)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.18), .clear]), center: CGPoint(x: head.minX, y: head.minY), startRadius: 0, endRadius: h * 0.25))
        }
    }
}

// MARK: - Before / after comparison (effect 8)

/// Vertical divider with a subtle glow and an elegant handle.
struct CompareDivider: View {
    var height: CGFloat
    var compact = false
    var active = false

    var body: some View {
        let handle: CGFloat = compact ? 18 : (active ? 34 : 30)
        ZStack {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white, .white, .white.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                .frame(width: compact ? 1.5 : 2, height: height)
                .shadow(color: DS.Palette.sky.opacity(0.85), radius: compact ? 3 : 6)
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.white.opacity(0.55)))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                .overlay(
                    HStack(spacing: compact ? 1 : 2) {
                        Image(systemName: "chevron.left"); Image(systemName: "chevron.right")
                    }
                    .font(.system(size: compact ? 6 : 9, weight: .bold))
                    .foregroundStyle(Color(red: 0.2, green: 0.25, blue: 0.4))
                )
                .frame(width: handle, height: handle)
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                .shadow(color: DS.Palette.blue.opacity(active ? 0.6 : 0.0), radius: 10)
        }
        .frame(width: max(22, handle))
        .animation(DS.Motion.hover, value: active)
        .allowsHitTesting(false)
    }
}

/// Interactive before/after comparison with a draggable, glowing divider.
struct BeforeAfterSlider<Before: View, After: View>: View {
    var beforeLabel = String(localized: "Original")
    var afterLabel = String(localized: "Edited")
    @ViewBuilder var before: () -> Before
    @ViewBuilder var after: () -> After
    @State private var position: CGFloat = 0.5
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                after().frame(width: w, height: h).clipped()
                before().frame(width: w, height: h).clipped()
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * position)) }
                CompareDivider(height: h, active: dragging)
                    .offset(x: w * position - 17)
                HStack {
                    label(beforeLabel)
                    Spacer()
                    label(afterLabel)
                }
                .padding(DS.Space.s)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    position = min(max(v.location.x / max(w, 1), 0.02), 0.98)
                }
                .onEnded { _ in dragging = false })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(String(localized: "Before/after comparison")))
        .accessibilityValue(Text(verbatim: "\(Int(position * 100)) %"))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: position = min(0.98, position + 0.1)
            case .decrement: position = max(0.02, position - 0.1)
            @unknown default: break
            }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(DS.Font.caption).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.32), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}
