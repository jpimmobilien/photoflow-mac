import SwiftUI
import AppKit

/// PhotoFlow 2.0 design tokens – see DESIGN_SYSTEM.md. Every screen uses these instead of ad-hoc values.
/// Colours are derived from the app icon: sky blue (#378CF7), light sky (#5CB4FE), the periwinkle/iris glow,
/// the warm sun (#FECF6E → #FDB887) and the lavender-white glass body (#EDF5FE → #EBE6F8).
enum DS {
    enum Space {
        static let xxs: CGFloat = 4, xs: CGFloat = 8, s: CGFloat = 12, m: CGFloat = 16
        static let l: CGFloat = 20, xl: CGFloat = 24, xxl: CGFloat = 32, huge: CGFloat = 48
        /// Horizontal page margin of content areas.
        static let page: CGFloat = 28
    }

    /// One radius scale for the whole app (continuous corners everywhere).
    enum Radius {
        static let xs: CGFloat = 6
        static let chip: CGFloat = 8
        static let control: CGFloat = 10
        static let tile: CGFloat = 12      // photo thumbnails
        static let card: CGFloat = 18      // cards, workflow tiles
        static let panel: CGFloat = 22     // floating panels, inspector, sheets
        static let hero: CGFloat = 28      // hero media, previews
    }

    enum Motion {
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
        static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.9)
        static let gentle = Animation.spring(response: 0.6, dampingFraction: 0.92)
        static let hover = Animation.spring(response: 0.22, dampingFraction: 0.8)
        static let page = Animation.spring(response: 0.5, dampingFraction: 0.88)
        static let reveal = Animation.easeOut(duration: 0.35)
        static let quick = Animation.easeOut(duration: 0.15)
        static let celebrate = Animation.spring(response: 0.5, dampingFraction: 0.7)
        static let ambient = Animation.easeInOut(duration: 0.9)

        /// System "Reduce Motion" setting – motion is replaced by short cross-fades when on.
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        /// Returns `animation`, or a short fade when Reduce Motion is enabled.
        static func adaptive(_ animation: Animation) -> Animation { reduced ? .easeInOut(duration: 0.12) : animation }
    }

    /// SF Pro hierarchy (system font). Sizes follow the macOS type ramp; no oversized headings.
    enum Font {
        static let largeTitle = SwiftUI.Font.system(size: 30, weight: .bold)
        static let display = SwiftUI.Font.system(size: 34, weight: .bold)
        static let title1 = SwiftUI.Font.system(size: 22, weight: .bold)
        static let title2 = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let title3 = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let micro = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let sectionLabel = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let statNumber = SwiftUI.Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
        static let number = SwiftUI.Font.system(size: 13, weight: .medium).monospacedDigit()
    }

    enum Palette {
        // MARK: Surfaces (light: warm very light grey · dark: deep anthracite)
        static let canvas = Color.dynamic(light: 0xF4F3F1, dark: 0x1B1C20)
        static let canvasDeep = Color.dynamic(light: 0xECEAE7, dark: 0x151619)
        static let surface = Color.dynamic(light: 0xFFFFFF, lightAlpha: 0.72, dark: 0x2A2B31, darkAlpha: 0.62)
        static let surfaceStrong = Color.dynamic(light: 0xFFFFFF, lightAlpha: 0.94, dark: 0x303138, darkAlpha: 0.92)
        static let glassTint = Color.dynamic(light: 0xFFFFFF, lightAlpha: 0.38, dark: 0x26272D, darkAlpha: 0.42)
        static let stage = Color.dynamic(light: 0xE9E8E6, dark: 0x121316)   // behind photos in viewer/editor
        static let hairline = Color.dynamic(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.08)
        static let track = Color.dynamic(light: 0x000000, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.16)
        static let rim = Color.dynamic(light: 0xFFFFFF, lightAlpha: 0.85, dark: 0xFFFFFF, darkAlpha: 0.16)

        // MARK: Text
        static let textPrimary = Color.dynamic(light: 0x1C1D22, dark: 0xF2F2F5)
        static let textSecondary = Color.dynamic(light: 0x5E606A, dark: 0xA9ABB5)
        static let textTertiary = Color.dynamic(light: 0x8E9099, dark: 0x75777F)

        // MARK: Accents from the icon
        static let blue = Color.dynamic(light: 0x2F7BF5, dark: 0x4A93FF)       // sky blue of the mountains
        static let sky = Color.dynamic(light: 0x1FA2EE, dark: 0x5CC2FF)        // light sky / cyan
        static let iris = Color.dynamic(light: 0x6E5CF0, dark: 0x8C7DFF)       // periwinkle glow
        static let sun = Color(nsColor: NSColor(hex: 0xFDB54E))                // the sun – premium highlights only
        static let peach = Color(nsColor: NSColor(hex: 0xFD9F7A))              // warm sky glow
        static let heart = Color.dynamic(light: 0xF2456A, dark: 0xFF6B86)

        // MARK: Semantic
        static let primaryAction = blue
        static let secondaryAction = textPrimary
        static let success = Color.dynamic(light: 0x23A866, dark: 0x3DD68C)
        static let warning = Color.dynamic(light: 0xE08A12, dark: 0xF5B342)
        static let danger = Color.dynamic(light: 0xE5484D, dark: 0xFF6369)
        static let selection = blue
        static let hover = Color.dynamic(light: 0x000000, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.06)
        static let focus = blue.opacity(0.55)
        static let disabled = textTertiary.opacity(0.55)

        // MARK: Gradients
        static let brand = LinearGradient(colors: [blue, iris], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let magic = LinearGradient(colors: [sky, blue, iris], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let sunrise = LinearGradient(colors: [sun, peach], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let premium = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x3D8DFB)), Color(nsColor: NSColor(hex: 0x6C63F2)), Color(nsColor: NSColor(hex: 0x8E78F5))],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)

        // MARK: Legacy names (kept so every screen maps onto the new palette)
        static let indigo = iris
        static let cyan = sky
        static let violet = iris
        static let pink = heart
        static let amber = sun
    }

    enum Shadow {
        static func floating(_ scheme: ColorScheme) -> (Color, CGFloat, CGFloat) {
            (Color.black.opacity(scheme == .dark ? 0.42 : 0.10), 22, 10)
        }
    }
}

// MARK: - Colour helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A colour that resolves per appearance (light / dark), like an asset-catalog colour.
    static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

// MARK: - Dynamic Ambient Light (effect 1)

/// Dominant colours of a photo, computed once from a tiny thumbnail and cached.
actor DominantColorCache {
    static let shared = DominantColorCache()
    private var cache: [String: [RGB]] = [:]

    struct RGB: Hashable, Sendable { var r: Double, g: Double, b: Double
        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    }

    func colors(for photo: PhotoRecord, recipe: EditRecipe?) async -> [RGB] {
        let key = "\(photo.id)-\(photo.fileSignature)-\(recipe?.cacheKey ?? "o")"
        if let c = cache[key] { return c }
        guard let cg = await ThumbnailService.shared.thumbnail(for: photo, recipe: recipe, pixelSize: 96) else { return [] }
        let c = Self.analyze(cg)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = c
        return c
    }

    /// Hue histogram weighted by saturation·brightness → the two strongest hues plus the mean tone,
    /// softened so the glow never dominates the interface.
    nonisolated static func analyze(_ cg: CGImage) -> [RGB] {
        guard let px = PixelBuffer(cgImage: cg, maxSide: 48) else { return [] }
        let n = px.width * px.height
        guard n > 0 else { return [] }
        var bins = [(w: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 12)
        var mr = 0.0, mg = 0.0, mb = 0.0
        for i in 0 ..< n {
            let r = Double(px.data[i * 4]) / 255, g = Double(px.data[i * 4 + 1]) / 255, b = Double(px.data[i * 4 + 2]) / 255
            mr += r; mg += g; mb += b
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            guard d > 0.04 else { continue }
            var h: Double
            if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h = (h / 6).truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
            let w = (d / max(mx, 0.001)) * mx
            let k = min(11, Int(h * 12))
            bins[k].w += w; bins[k].r += r * w; bins[k].g += g * w; bins[k].b += b * w
        }
        func soften(_ c: RGB) -> RGB {
            // limit saturation and keep a mid brightness – a light reflex, not a colour field
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            let l = (mx + mn) / 2, sat = 0.6
            func f(_ v: Double) -> Double { min(1, max(0, l + (v - l) * sat) * 0.5 + 0.32) }
            return RGB(r: f(c.r), g: f(c.g), b: f(c.b))
        }
        let ranked = bins.enumerated().filter { $0.element.w > 0 }.sorted { $0.element.w > $1.element.w }
        var out: [RGB] = ranked.prefix(2).map { b in soften(RGB(r: b.element.r / b.element.w, g: b.element.g / b.element.w, b: b.element.b / b.element.w)) }
        out.append(soften(RGB(r: mr / Double(n), g: mg / Double(n), b: mb / Double(n))))
        while out.count < 3 { out.append(out.last ?? RGB(r: 0.5, g: 0.6, b: 0.9)) }
        return out
    }
}

/// The app's atmospheric layer: the canvas colour with a very soft light reflex taken from the current
/// photo's cached dominant colours. Cross-fades on change; falls back to the icon's sky/iris light.
struct AmbientBackground: View {
    var photo: PhotoRecord?
    var recipe: EditRecipe?
    var intensity: Double = 1
    var base: Color = DS.Palette.canvas
    @Environment(\.colorScheme) private var scheme
    @State private var colors: [DominantColorCache.RGB] = []

    var body: some View {
        ZStack {
            base
            AmbientGlow(colors: colors.map(\.color), strength: (scheme == .dark ? 0.30 : 0.24) * intensity)
                .id(colors)
                .transition(.opacity)
        }
        .animation(DS.Motion.ambient, value: colors)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: "\(photo?.id ?? -1)-\(recipe?.cacheKey ?? "o")") {
            guard let photo else { colors = []; return }
            let c = await DominantColorCache.shared.colors(for: photo, recipe: recipe)
            if !Task.isCancelled { colors = c }
        }
    }
}

/// Large, cheap radial light fields (no blur pass needed).
struct AmbientGlow: View {
    var colors: [Color]
    var strength: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, r = max(w, h)
            let c = colors.isEmpty ? [DS.Palette.sky, DS.Palette.iris, DS.Palette.blue] : colors
            ZStack {
                RadialGradient(colors: [c[0].opacity(strength), .clear], center: UnitPoint(x: 0.18, y: 0.0), startRadius: 0, endRadius: r * 0.62)
                RadialGradient(colors: [c[min(1, c.count - 1)].opacity(strength * 0.85), .clear], center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: r * 0.55)
                RadialGradient(colors: [c[min(2, c.count - 1)].opacity(strength * 0.45), .clear], center: UnitPoint(x: 0.7, y: 0.25), startRadius: 0, endRadius: r * 0.4)
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: - Histogram (effect 9 – real data, animated)

/// RGB + luminance histogram (computed from a small thumbnail) – shows exposure at a glance.
struct HistogramView: View {
    let photo: PhotoRecord
    var recipe: EditRecipe?
    @State private var data: HistogramData?

    struct HistogramData: Equatable {
        var r: [Double], g: [Double], b: [Double], l: [Double]
    }

    var body: some View {
        HistogramPlot(data: data)
        .task(id: "\(photo.id)-\(recipe?.cacheKey ?? "o")") {
            let p = photo, r = recipe
            let cg = await ThumbnailService.shared.thumbnail(for: p, recipe: r, pixelSize: 256)
            guard let cg else { return }
            let d = await Task.detached(priority: .utility) { HistogramView.compute(cg) }.value
            withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { data = d }
        }
    }
}

/// Histogram of an already rendered image (live in the editor – no thumbnail cache involved).
struct ImageHistogramView: View {
    var image: CGImage?
    @State private var data: HistogramView.HistogramData?
    var body: some View {
        HistogramPlot(data: data)
            .task(id: image.map { ObjectIdentifier($0) }) {
                guard let image else { return }
                let d = await Task.detached(priority: .utility) { HistogramView.compute(image) }.value
                withAnimation(DS.Motion.adaptive(DS.Motion.smooth)) { data = d }
            }
    }
}

struct HistogramPlot: View {
    var data: HistogramView.HistogramData?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(Color.black.opacity(scheme == .dark ? 0.28 : 0.06))
            // quarter grid
            HStack(spacing: 0) {
                ForEach(0 ..< 4, id: \.self) { i in
                    Rectangle().fill(.clear).overlay(alignment: .trailing) {
                        if i < 3 { Rectangle().fill(DS.Palette.hairline).frame(width: 0.5) }
                    }
                }
            }
            if let d = data {
                Group {
                    HistogramShape(values: d.r).fill(Color(red: 1, green: 0.35, blue: 0.4).opacity(0.5))
                    HistogramShape(values: d.g).fill(Color(red: 0.3, green: 0.85, blue: 0.5).opacity(0.5))
                    HistogramShape(values: d.b).fill(Color(red: 0.3, green: 0.55, blue: 1).opacity(0.55))
                }
                .blendMode(scheme == .dark ? .plusLighter : .multiply)
                HistogramShape(values: d.l, closed: false).stroke(DS.Palette.textPrimary.opacity(0.75), lineWidth: 1)
            } else {
                ShimmerBlock(cornerRadius: DS.Radius.control)
            }
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
        .accessibilityLabel(Text(String(localized: "Histogram")))
    }
}

extension HistogramView {

    nonisolated static func compute(_ cg: CGImage) -> HistogramData? {
        guard let px = PixelBuffer(cgImage: cg, maxSide: 256) else { return nil }
        var r = [Double](repeating: 0, count: 64), g = r, b = r, l = r
        let n = px.width * px.height
        for i in 0 ..< n {
            let R = Int(px.data[i * 4]), G = Int(px.data[i * 4 + 1]), B = Int(px.data[i * 4 + 2])
            r[R >> 2] += 1; g[G >> 2] += 1; b[B >> 2] += 1
            let y = (2126 * R + 7152 * G + 722 * B) / 10000
            l[min(63, y >> 2)] += 1
        }
        func norm(_ a: [Double]) -> [Double] {
            // square-root scaling keeps small populations visible
            let s = a.map { $0.squareRoot() }
            let m = max(s.max() ?? 1, 1)
            return s.map { $0 / m }
        }
        return HistogramData(r: norm(r), g: norm(g), b: norm(b), l: norm(l))
    }
}

/// Smooth area shape for histogram values (0…1). Animatable, so changes morph instead of jumping.
struct HistogramShape: Shape {
    var values: [Double]
    var closed = true

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: values) }
        set { values = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        let pts = values.enumerated().map { CGPoint(x: rect.minX + CGFloat($0.offset) * step, y: rect.maxY - CGFloat($0.element) * rect.height * 0.9) }
        if closed { p.move(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: pts[0]) } else { p.move(to: pts[0]) }
        // Catmull-Rom → smooth curve through the real bin values
        for i in 0 ..< pts.count - 1 {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(rect.maxY, p1.y + (p2.y - p0.y) / 6))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(rect.maxY, p2.y - (p3.y - p1.y) / 6))
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.closeSubpath() }
        return p
    }
}

/// Vector of doubles that SwiftUI can interpolate (for morphing histograms).
struct AnimatableVector: VectorArithmetic {
    var values: [Double]
    static var zero: AnimatableVector { AnimatableVector(values: []) }
    private static func combine(_ a: AnimatableVector, _ b: AnimatableVector, _ op: (Double, Double) -> Double) -> AnimatableVector {
        let n = max(a.values.count, b.values.count)
        return AnimatableVector(values: (0 ..< n).map { op($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0) })
    }
    static func + (a: AnimatableVector, b: AnimatableVector) -> AnimatableVector { combine(a, b, +) }
    static func - (a: AnimatableVector, b: AnimatableVector) -> AnimatableVector { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

// MARK: - Visual statistics

/// Horizontal segmented bar (e.g. storage by format, edited vs. original).
struct SegmentBar: View {
    struct Segment: Identifiable { var id: String { label }; var label: String; var value: Double; var color: Color }
    var segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.value > 0 }) { s in
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .fill(s.color.gradient)
                            .frame(width: max(height, (geo.size.width - CGFloat(segments.count) * 2) * CGFloat(s.value / total)))
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: DS.Space.s) {
                ForEach(segments.filter { $0.value > 0 }) { s in
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(s.label).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            }
        }
    }
}

/// Premium progress ring (effect 6): fluid stroke, soft glow at the leading tip, brief pulse at 100 %.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 8
    var gradient: [Color] = [DS.Palette.sky, DS.Palette.blue, DS.Palette.iris]
    @State private var completedPulse = false

    var body: some View {
        let f = max(0.001, min(1, fraction))
        ZStack {
            Circle().stroke(DS.Palette.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: f)
                .stroke(AngularGradient(colors: gradient + [gradient[0]], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * f)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // glowing tip
            GeometryReader { g in
                let r = min(g.size.width, g.size.height) / 2
                let a = Angle.degrees(360 * f - 90).radians
                Circle()
                    .fill(Color.white)
                    .frame(width: lineWidth * 0.9, height: lineWidth * 0.9)
                    .shadow(color: (gradient.last ?? .blue).opacity(0.9), radius: lineWidth * 0.9)
                    .position(x: g.size.width / 2 + CGFloat(cos(a)) * r, y: g.size.height / 2 + CGFloat(sin(a)) * r)
                    .opacity(f > 0.02 && f < 0.999 ? 0.9 : 0)
            }
        }
        .scaleEffect(completedPulse ? 1.04 : 1)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: fraction)
        .onChange(of: fraction >= 0.999) { done in
            guard done, !DS.Motion.reduced else { return }
            withAnimation(DS.Motion.celebrate) { completedPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(DS.Motion.smooth) { completedPulse = false } }
        }
    }
}
