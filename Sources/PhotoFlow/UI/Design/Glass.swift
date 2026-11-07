import SwiftUI

/// PhotoFlow's visual language.
/// - macOS 26+: Apple's Liquid Glass (`glassEffect`, `.glass` button styles).
/// - macOS 13–15: a coherent fallback built from native materials, hairline highlights and soft shadows.
enum Theme {
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.42, green: 0.36, blue: 1.0), Color(red: 0.0, green: 0.70, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warmGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.55, blue: 0.25), Color(red: 1.0, green: 0.32, blue: 0.48)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cornerRadius: CGFloat = 14
    static let smallRadius: CGFloat = 9

    static func categoryColor(_ c: SimilarityCategory) -> Color {
        switch c {
        case .exact: return .red
        case .verySimilar: return .orange
        case .similar: return .yellow
        case .possiblySimilar: return .teal
        }
    }
}

extension View {
    /// A translucent panel ("card").
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Theme.cornerRadius, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.modifier(FallbackGlass(cornerRadius: cornerRadius))
        }
        #else
        self.modifier(FallbackGlass(cornerRadius: cornerRadius))
        #endif
    }

    /// Capsule-shaped glass (chips, floating controls).
    @ViewBuilder
    func glassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.modifier(FallbackGlassCapsule())
        }
        #else
        self.modifier(FallbackGlassCapsule())
        #endif
    }

    /// Prominent call-to-action style (Auto Enhance, Start, Scan).
    @ViewBuilder
    func prominentButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(GradientButtonStyle())
        }
        #else
        self.buttonStyle(GradientButtonStyle())
        #endif
    }

    /// Secondary button style.
    @ViewBuilder
    func softButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(SoftButtonStyle())
        }
        #else
        self.buttonStyle(SoftButtonStyle())
        #endif
    }
}

private struct FallbackGlass: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.7), Color.white.opacity(scheme == .dark ? 0.04 : 0.15)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 14, x: 0, y: 6)
    }
}

private struct FallbackGlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.18 : 0.6), lineWidth: 0.6))
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 8, x: 0, y: 3)
    }
}

struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.accentGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6))
            .shadow(color: Color(red: 0.3, green: 0.4, blue: 1).opacity(configuration.isPressed ? 0.15 : 0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Window background behind content areas on older systems (on macOS 26 the system provides the material).
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: scheme == .dark
                           ? [Color(red: 0.13, green: 0.12, blue: 0.2).opacity(0.6), .clear]
                           : [Color(red: 0.9, green: 0.92, blue: 1.0).opacity(0.7), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}
