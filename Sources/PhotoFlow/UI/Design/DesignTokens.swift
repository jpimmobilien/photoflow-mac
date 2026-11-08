import SwiftUI

/// Design tokens – see DESIGN_SYSTEM.md. All screens use these instead of ad-hoc values.
enum DS {
    enum Space {
        static let xxs: CGFloat = 4, xs: CGFloat = 8, s: CGFloat = 12, m: CGFloat = 16
        static let l: CGFloat = 20, xl: CGFloat = 24, xxl: CGFloat = 32, huge: CGFloat = 48
    }

    enum Radius {
        static let chip: CGFloat = 8, control: CGFloat = 10, card: CGFloat = 16, panel: CGFloat = 20, hero: CGFloat = 28
    }

    enum Motion {
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
        static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.9)
        static let reveal = Animation.easeOut(duration: 0.35)
        static let celebrate = Animation.spring(response: 0.5, dampingFraction: 0.7)
    }

    enum Font {
        static let display = SwiftUI.Font.system(size: 40, weight: .bold, design: .rounded)
        static let title1 = SwiftUI.Font.system(size: 26, weight: .bold)
        static let title2 = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let statNumber = SwiftUI.Font.system(size: 28, weight: .bold, design: .rounded).monospacedDigit()
    }

    enum Palette {
        static let indigo = Color(red: 0.424, green: 0.298, blue: 1.0)      // #6C4CFF
        static let cyan = Color(red: 0.0, green: 0.714, blue: 1.0)          // #00B6FF
        static let violet = Color(red: 0.541, green: 0.361, blue: 1.0)      // #8A5CFF
        static let pink = Color(red: 1.0, green: 0.373, blue: 0.635)        // #FF5FA2
        static let amber = Color(red: 1.0, green: 0.702, blue: 0.278)       // #FFB347
        static let success = Color(red: 0.169, green: 0.714, blue: 0.451)
        static let warning = Color(red: 0.961, green: 0.620, blue: 0.043)
        static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)

        static let brand = LinearGradient(colors: [indigo, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let magic = LinearGradient(colors: [violet, pink, amber], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Ambient light from the user's own photos

/// A soft, heavily blurred glow sampled from a photo – the app's main atmospheric element.
/// Cross-fades when the photo changes; falls back to the brand colours when there is no photo.
struct AmbientBackground: View {
    var photo: PhotoRecord?
    var recipe: EditRecipe?
    var intensity: Double = 1
    @Environment(\.colorScheme) private var scheme
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                // Color.clear fixes the layout size; the filled image only draws inside it.
                Color.clear
                    .overlay {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 70, opaque: true)
                            .saturation(1.35)
                    }
                    .clipped()
                    .opacity((scheme == .dark ? 0.55 : 0.38) * intensity)
                    .transition(.opacity)
                    .id(photo?.id)
            } else {
                // Brand aurora when no photo is available
                Color.clear.overlay {
                    ZStack {
                        Circle().fill(DS.Palette.indigo.opacity(scheme == .dark ? 0.35 : 0.18)).frame(width: 700).blur(radius: 160).offset(x: -320, y: -260)
                        Circle().fill(DS.Palette.cyan.opacity(scheme == .dark ? 0.25 : 0.14)).frame(width: 600).blur(radius: 160).offset(x: 380, y: 220)
                    }
                }
                .clipped()
            }
            // Keeps text readable on top of the glow
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.25 : 0.45),
                                    Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.55 : 0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(DS.Motion.smooth, value: photo?.id)
        .task(id: photo?.id) {
            guard let photo else { image = nil; return }
            image = await ThumbnailService.shared.thumbnail(for: photo, recipe: recipe, pixelSize: 96)
        }
    }
}

// MARK: - Histogram

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
            withAnimation(DS.Motion.smooth) { data = d }
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
                withAnimation(DS.Motion.smooth) { data = d }
            }
    }
}

struct HistogramPlot: View {
    var data: HistogramView.HistogramData?
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(Color.black.opacity(0.25))
            if let d = data {
                HistogramShape(values: d.r).fill(Color.red.opacity(0.55)).blendMode(.plusLighter)
                HistogramShape(values: d.g).fill(Color.green.opacity(0.55)).blendMode(.plusLighter)
                HistogramShape(values: d.b).fill(Color.blue.opacity(0.6)).blendMode(.plusLighter)
                HistogramShape(values: d.l, closed: false).stroke(Color.white.opacity(0.85), lineWidth: 1)
            }
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
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

/// Smooth area shape for histogram values (0…1).
struct HistogramShape: Shape {
    var values: [Double]
    var closed = true
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        let pts = values.enumerated().map { CGPoint(x: rect.minX + CGFloat($0.offset) * step, y: rect.maxY - CGFloat($0.element) * rect.height * 0.92) }
        if closed { p.move(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: pts[0]) } else { p.move(to: pts[0]) }
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        if closed { p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.closeSubpath() }
        return p
    }
}

// MARK: - Visual statistics

/// Horizontal segmented bar (e.g. storage by format, edited vs. original).
struct SegmentBar: View {
    struct Segment: Identifiable { var id: String { label }; var label: String; var value: Double; var color: Color }
    var segments: [Segment]
    var height: CGFloat = 10

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
                        Text(s.label).font(DS.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Circular progress with gradient stroke.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 8
    var gradient: [Color] = [DS.Palette.indigo, DS.Palette.cyan, DS.Palette.indigo]

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(AngularGradient(colors: gradient, center: .center), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.smooth, value: fraction)
        }
    }
}
