import SwiftUI

/// Vector illustrations for empty states and onboarding. Drawn in SwiftUI so they stay crisp at any size,
/// adapt to light/dark mode and share the app icon's visual language (tilted photo cards, sparkles).
struct Illustration: View {
    enum Kind { case welcome, duplicates, similar, batch, trash, favorites, search, exports, album, edited, enhance, done }
    var kind: Kind
    var size: CGFloat = 220
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // soft halo
            Circle()
                .fill(RadialGradient(colors: [DS.Palette.indigo.opacity(0.28), DS.Palette.cyan.opacity(0.08), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.55))
                .frame(width: size * 1.15, height: size * 1.15)
            content
        }
        .frame(width: size, height: size * 0.8)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(DS.Motion.smooth.delay(0.05)) { appeared = true } }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        let u = size / 220
        switch kind {
        case .welcome:
            ZStack {
                PhotoCard(palette: .dusk).frame(width: 120 * u, height: 92 * u).rotationEffect(.degrees(-12)).offset(x: -44 * u, y: 10 * u)
                PhotoCard(palette: .ocean).frame(width: 120 * u, height: 92 * u).rotationEffect(.degrees(9)).offset(x: 44 * u, y: 6 * u)
                PhotoCard(palette: .sunset).frame(width: 132 * u, height: 100 * u).offset(y: -6 * u)
                Sparkle(size: 34 * u).offset(x: 62 * u, y: -54 * u)
                Sparkle(size: 16 * u).offset(x: 86 * u, y: -24 * u)
            }
        case .duplicates:
            ZStack {
                PhotoCard(palette: .ocean).frame(width: 112 * u, height: 86 * u).rotationEffect(.degrees(-8)).offset(x: -30 * u)
                PhotoCard(palette: .ocean).frame(width: 112 * u, height: 86 * u).rotationEffect(.degrees(6)).offset(x: 30 * u, y: 4 * u)
                SymbolBadge(symbol: "equal", colors: [DS.Palette.amber, DS.Palette.pink], size: 44 * u).offset(x: 0, y: 46 * u)
            }
        case .similar:
            ZStack {
                PhotoCard(palette: .forest).frame(width: 96 * u, height: 74 * u).rotationEffect(.degrees(-10)).offset(x: -52 * u, y: 8 * u)
                PhotoCard(palette: .forest, sunOffset: 0.15).frame(width: 96 * u, height: 74 * u).offset(y: -4 * u)
                PhotoCard(palette: .forest, sunOffset: 0.3).frame(width: 96 * u, height: 74 * u).rotationEffect(.degrees(10)).offset(x: 52 * u, y: 8 * u)
                SymbolBadge(symbol: "sparkle.magnifyingglass", colors: [DS.Palette.indigo, DS.Palette.cyan], size: 44 * u).offset(y: 48 * u)
            }
        case .batch:
            ZStack {
                ForEach(0 ..< 4, id: \.self) { i in
                    PhotoCard(palette: [.dusk, .ocean, .forest, .sunset][i])
                        .frame(width: 118 * u, height: 88 * u)
                        .offset(x: CGFloat(i) * 14 * u - 21 * u, y: CGFloat(i) * -10 * u + 15 * u)
                }
                SymbolBadge(symbol: "wand.and.stars", colors: [DS.Palette.violet, DS.Palette.pink], size: 46 * u).offset(x: 70 * u, y: 44 * u)
            }
        case .trash:
            ZStack {
                RoundedRectangle(cornerRadius: 22 * u, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22 * u, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .frame(width: 120 * u, height: 100 * u)
                Image(systemName: "trash").font(.system(size: 44 * u, weight: .light)).foregroundStyle(DS.Palette.brand)
                Sparkle(size: 24 * u).offset(x: 60 * u, y: -48 * u)
            }
        case .favorites:
            ZStack {
                PhotoCard(palette: .sunset).frame(width: 128 * u, height: 96 * u).rotationEffect(.degrees(-5))
                SymbolBadge(symbol: "heart.fill", colors: [DS.Palette.pink, DS.Palette.amber], size: 50 * u).offset(x: 56 * u, y: -40 * u)
            }
        case .search:
            ZStack {
                PhotoCard(palette: .dusk).frame(width: 110 * u, height: 84 * u).rotationEffect(.degrees(-6)).offset(x: -18 * u)
                SymbolBadge(symbol: "magnifyingglass", colors: [DS.Palette.indigo, DS.Palette.cyan], size: 56 * u).offset(x: 46 * u, y: 30 * u)
            }
        case .exports:
            ZStack {
                PhotoCard(palette: .ocean).frame(width: 118 * u, height: 90 * u).rotationEffect(.degrees(4))
                SymbolBadge(symbol: "square.and.arrow.up", colors: [DS.Palette.success, DS.Palette.cyan], size: 50 * u).offset(x: 56 * u, y: 40 * u)
            }
        case .album:
            ZStack {
                PhotoCard(palette: .forest).frame(width: 112 * u, height: 86 * u).rotationEffect(.degrees(-9)).offset(x: -16 * u, y: 6 * u)
                PhotoCard(palette: .sunset).frame(width: 112 * u, height: 86 * u).rotationEffect(.degrees(7)).offset(x: 16 * u)
                SymbolBadge(symbol: "plus", colors: [DS.Palette.indigo, DS.Palette.cyan], size: 44 * u).offset(x: 62 * u, y: 42 * u)
            }
        case .edited, .enhance:
            ZStack {
                PhotoCard(palette: .dusk, muted: true).frame(width: 110 * u, height: 84 * u).rotationEffect(.degrees(-8)).offset(x: -40 * u, y: 8 * u)
                PhotoCard(palette: .sunset).frame(width: 118 * u, height: 90 * u).rotationEffect(.degrees(5)).offset(x: 34 * u, y: -4 * u)
                SymbolBadge(symbol: "wand.and.stars", colors: [DS.Palette.violet, DS.Palette.pink, DS.Palette.amber], size: 44 * u).offset(y: 48 * u)
            }
        case .done:
            ZStack {
                Circle().fill(DS.Palette.success.gradient).frame(width: 96 * u, height: 96 * u)
                    .shadow(color: DS.Palette.success.opacity(0.4), radius: 20 * u, y: 8 * u)
                Image(systemName: "checkmark").font(.system(size: 44 * u, weight: .bold)).foregroundStyle(.white)
                Sparkle(size: 26 * u).offset(x: 58 * u, y: -44 * u)
                Sparkle(size: 14 * u).offset(x: -62 * u, y: 30 * u)
            }
        }
    }
}

/// A stylised "photo": gradient sky, mountains, sun, white frame.
struct PhotoCard: View {
    enum Palette {
        case sunset, ocean, forest, dusk
        var sky: [Color] {
            switch self {
            case .sunset: return [Color(red: 1.0, green: 0.76, blue: 0.47), Color(red: 1.0, green: 0.47, blue: 0.59)]
            case .ocean: return [Color(red: 0.55, green: 0.85, blue: 1.0), Color(red: 0.25, green: 0.55, blue: 0.95)]
            case .forest: return [Color(red: 0.78, green: 0.93, blue: 0.85), Color(red: 0.42, green: 0.75, blue: 0.62)]
            case .dusk: return [Color(red: 0.64, green: 0.56, blue: 1.0), Color(red: 0.34, green: 0.30, blue: 0.75)]
            }
        }
        var hills: (Color, Color) {
            switch self {
            case .sunset: return (Color(red: 0.36, green: 0.28, blue: 0.78), Color(red: 0.18, green: 0.47, blue: 0.9))
            case .ocean: return (Color(red: 0.10, green: 0.30, blue: 0.62), Color(red: 0.05, green: 0.52, blue: 0.75))
            case .forest: return (Color(red: 0.13, green: 0.45, blue: 0.35), Color(red: 0.24, green: 0.6, blue: 0.4))
            case .dusk: return (Color(red: 0.2, green: 0.15, blue: 0.45), Color(red: 0.45, green: 0.25, blue: 0.65))
            }
        }
    }
    var palette: Palette
    var sunOffset: CGFloat = 0
    var muted = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, inset = min(w, h) * 0.07
            ZStack {
                RoundedRectangle(cornerRadius: min(w, h) * 0.12, style: .continuous).fill(.white)
                ZStack {
                    LinearGradient(colors: palette.sky, startPoint: .top, endPoint: .bottom)
                    Circle().fill(.white.opacity(0.9)).frame(width: h * 0.2)
                        .position(x: w * (0.68 + sunOffset * 0.3), y: h * (0.3 + sunOffset * 0.2))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.42)); p.addLine(to: CGPoint(x: w * 0.62, y: h))
                    }.fill(palette.hills.0)
                    Path { p in
                        p.move(to: CGPoint(x: w * 0.35, y: h)); p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.52))
                        p.addLine(to: CGPoint(x: w, y: h * 0.75)); p.addLine(to: CGPoint(x: w, y: h))
                    }.fill(palette.hills.1)
                }
                .saturation(muted ? 0.25 : 1)
                .brightness(muted ? -0.05 : 0)
                .clipShape(RoundedRectangle(cornerRadius: min(w, h) * 0.07, style: .continuous))
                .padding(inset)
            }
            .shadow(color: .black.opacity(0.18), radius: min(w, h) * 0.08, y: min(w, h) * 0.05)
        }
    }
}

struct Sparkle: View {
    var size: CGFloat
    var body: some View {
        SparkleShape()
            .fill(LinearGradient(colors: [.white, Color(red: 0.85, green: 0.9, blue: 1)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .shadow(color: DS.Palette.cyan.opacity(0.6), radius: size * 0.3)
    }
}

struct SparkleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2, k = R * 0.28
        for i in 0 ..< 8 {
            let a = Double(i) * .pi / 4 - .pi / 2
            let rad = i % 2 == 0 ? R : k
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Round gradient badge with an SF Symbol.
struct SymbolBadge: View {
    var symbol: String
    var colors: [Color]
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1)
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: colors.first?.opacity(0.45) ?? .clear, radius: size * 0.25, y: size * 0.1)
    }
}
