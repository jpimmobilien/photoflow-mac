import SwiftUI
import AppKit

/// PhotoFlow's four material levels (see DESIGN_SYSTEM.md › Materials).
///
/// | Level        | Used for                                         | macOS 26+                  | macOS 13–15 fallback                          |
/// |--------------|--------------------------------------------------|----------------------------|-----------------------------------------------|
/// | background   | sidebar, large interface regions                 | behind-window vibrancy     | behind-window vibrancy + warm tint             |
/// | floating     | toolbars, filters, popovers, selection bar        | Liquid Glass `.regular`     | ultra-thin material, rim light, soft shadow    |
/// | interactive  | buttons, segmented controls, toggles, fields      | Liquid Glass interactive    | thin material, inner highlight, hover states   |
/// | premium      | Auto Enhance, Export, Start, progress moments     | brand gradient + sheen      | brand gradient + sheen                         |
enum GlassLevel { case background, floating, interactive, premium }

enum Theme {
    static let accentGradient = DS.Palette.brand
    static let warmGradient = DS.Palette.sunrise
    static let cornerRadius: CGFloat = DS.Radius.card
    static let smallRadius: CGFloat = DS.Radius.control

    static func categoryColor(_ c: SimilarityCategory) -> Color {
        switch c {
        case .exact: return DS.Palette.danger
        case .verySimilar: return DS.Palette.warning
        case .similar: return DS.Palette.iris
        case .possiblySimilar: return DS.Palette.sky
        }
    }
}

extension View {
    /// Applies one of the four material levels in `shape`.
    func glass<S: Shape>(_ level: GlassLevel, in shape: S) -> some View {
        modifier(GlassSurface(level: level, shape: AnyShape(shape)))
    }

    /// A floating glass panel ("card").
    func glassCard(cornerRadius: CGFloat = DS.Radius.card, interactive: Bool = false) -> some View {
        glass(interactive ? .interactive : .floating, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Capsule-shaped floating glass (chips, floating controls).
    func glassCapsule() -> some View { glass(.floating, in: Capsule()) }

    /// Primary call to action (Import, Start, Scan).
    func prominentButton() -> some View { buttonStyle(GlassButtonStyle(kind: .primary)) }

    /// Premium moment (Auto Enhance, Export, Start Batch).
    func premiumButton() -> some View { buttonStyle(GlassButtonStyle(kind: .premium)) }

    /// Secondary action on interactive glass.
    func softButton() -> some View { buttonStyle(GlassButtonStyle(kind: .secondary)) }
}

struct GlassSurface: ViewModifier {
    var level: GlassLevel
    var shape: AnyShape
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch level {
        case .background:
            content.background(VisualEffectBackground(material: .sidebar).clipShape(shape))
        case .premium:
            content
                .background(shape.fill(DS.Palette.premium))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)], startPoint: .top, endPoint: .center)).allowsHitTesting(false))
                .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.8).allowsHitTesting(false))
                .shadow(color: DS.Palette.blue.opacity(scheme == .dark ? 0.45 : 0.32), radius: 16, y: 6)
        case .floating, .interactive:
            native(content)
        }
    }

    @ViewBuilder
    private func native(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(level == .interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        let dark = scheme == .dark
        let floating = level == .floating
        return content
            .background {
                ZStack {
                    shape.fill(floating ? .ultraThinMaterial : .thinMaterial)
                    shape.fill(DS.Palette.glassTint)
                    // refracted light: brighter at the top edge, like light passing through glass
                    shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.07 : 0.35), .clear], startPoint: .top, endPoint: .center))
                }
            }
            .overlay(
                shape.stroke(LinearGradient(colors: [DS.Palette.rim, Color.white.opacity(dark ? 0.03 : 0.2)], startPoint: .top, endPoint: .bottom),
                             lineWidth: 0.8)
                .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(dark ? (floating ? 0.42 : 0.25) : (floating ? 0.10 : 0.06)), radius: floating ? 22 : 8, y: floating ? 10 : 3)
            .shadow(color: .black.opacity(dark ? 0.3 : 0.04), radius: 1, y: 0.5)
    }
}

/// Behind-window vibrancy (Material 1 – Background Glass).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

// MARK: - Buttons (Material 3 / 4)

struct GlassButtonStyle: ButtonStyle {
    enum Kind { case primary, premium, secondary, destructive, plain }
    var kind: Kind
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, kind: kind, large: large)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: GlassButtonStyle.Kind
    let large: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var sheen = false

    private var isLarge: Bool { large || controlSize == .large }

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(isLarge ? .system(size: 14, weight: .semibold) : .system(size: 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? 8 : (isLarge ? 20 : 14))
            .padding(.vertical, isLarge ? 10 : 6.5)
            .background { background }
            .overlay {
                // Liquid-glass reflection sweeping across on hover (effect 2)
                if kind == .primary || kind == .premium {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.38), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.45)
                            .rotationEffect(.degrees(18))
                            .offset(x: sheen ? g.size.width * 1.2 : -g.size.width * 0.6)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            // Magnetic hover (effect 3) + press (microinteraction)
            .scaleEffect(pressed ? 0.965 : (hovering && isEnabled && !DS.Motion.reduced ? 1.025 : 1))
            .offset(y: hovering && isEnabled && !DS.Motion.reduced && kind != .plain ? -0.5 : 0)
            .brightness(hovering && isEnabled ? (scheme == .dark ? 0.05 : 0.03) : 0)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(DS.Motion.hover, value: hovering)
            .animation(DS.Motion.hover, value: pressed)
            .onHover { h in
                hovering = h
                guard h, isEnabled, !DS.Motion.reduced, kind == .primary || kind == .premium else { return }
                sheen = false
                withAnimation(.easeOut(duration: 0.75)) { sheen = true }
            }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .premium, .destructive: return .white
        case .secondary, .plain: return DS.Palette.textPrimary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            Capsule().fill(DS.Palette.brand)
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.7))
                .shadow(color: DS.Palette.blue.opacity(hovering ? 0.42 : 0.28), radius: hovering ? 12 : 8, y: hovering ? 5 : 3)
        case .premium:
            Capsule().fill(DS.Palette.premium)
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [DS.Palette.sun.opacity(0.75), .white.opacity(0.25), DS.Palette.sky.opacity(0.5)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .shadow(color: DS.Palette.iris.opacity(hovering ? 0.5 : 0.32), radius: hovering ? 16 : 10, y: hovering ? 6 : 4)
        case .destructive:
            Capsule().fill(DS.Palette.danger.gradient)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.7))
                .shadow(color: DS.Palette.danger.opacity(0.25), radius: 8, y: 3)
        case .secondary:
            Color.clear.glass(.interactive, in: Capsule())
        case .plain:
            Capsule().fill(hovering ? DS.Palette.hover : .clear)
        }
    }
}

/// Round icon button on interactive glass (toolbars, floating bars).
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var active = false
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        GlassIconBody(configuration: configuration, size: size, active: active, tint: tint)
    }
}

private struct GlassIconBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let active: Bool
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(active ? Color.white : (tint ?? DS.Palette.textPrimary))
            .frame(width: size, height: size)
            .background {
                if active {
                    Circle().fill(DS.Palette.brand)
                        .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)))
                } else {
                    Circle().fill(hovering ? DS.Palette.hover : .clear)
                }
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : (hovering && isEnabled && !DS.Motion.reduced ? 1.06 : 1))
            .opacity(isEnabled ? 1 : 0.38)
            .animation(DS.Motion.hover, value: hovering)
            .animation(DS.Motion.hover, value: configuration.isPressed)
            .animation(DS.Motion.snappy, value: active)
            .onHover { hovering = $0 }
    }
}

/// Kept for source compatibility (pre-2.0 call sites).
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { GlassButtonStyle(kind: .primary).makeBody(configuration: configuration) }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { GlassButtonStyle(kind: .secondary).makeBody(configuration: configuration) }
}

/// Window background: warm light grey / anthracite canvas.
struct AppBackground: View {
    var body: some View {
        DS.Palette.canvas.ignoresSafeArea()
    }
}
