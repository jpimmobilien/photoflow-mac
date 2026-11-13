import SwiftUI
import AppKit

// PhotoFlow 2.0 motion system – reusable effects so every screen moves the same way.
// All effects respect "Reduce Motion" (System Settings ▸ Accessibility ▸ Display).

// MARK: Effect 3 – Magnetic hover

struct MagneticHover: ViewModifier {
    var scale: CGFloat = 1.015
    var lift: CGFloat = 2
    var shadow = true
    var cornerRadius: CGFloat = DS.Radius.card
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let on = hovering && !DS.Motion.reduced
        content
            .scaleEffect(on ? scale : 1)
            .offset(y: on ? -lift : 0)
            .shadow(color: .black.opacity(shadow ? (on ? (scheme == .dark ? 0.4 : 0.14) : 0) : 0), radius: on ? 18 : 0, y: on ? 10 : 0)
            .animation(DS.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: Effect 2 – Liquid glass reflection (on hover only, never permanent)

struct GlassReflection: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false
    @State private var sweep = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5, height: g.size.height * 1.6)
                        .rotationEffect(.degrees(20))
                        .offset(x: sweep ? g.size.width * 1.1 : -g.size.width * 0.7, y: -g.size.height * 0.3)
                        .opacity(hovering ? 1 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            }
            .onHover { h in
                hovering = h
                guard h, !DS.Motion.reduced else { return }
                sweep = false
                withAnimation(.easeOut(duration: 0.9)) { sweep = true }
            }
    }
}

// MARK: Effect 7 – Photo reveal (staggered, limited)

struct RevealOnAppear: ViewModifier {
    var index: Int
    var enabled = true
    @State private var shown = false

    func body(content: Content) -> some View {
        let active = enabled && !DS.Motion.reduced
        content
            .opacity(shown || !active ? 1 : 0)
            .scaleEffect(shown || !active ? 1 : 0.94)
            .onAppear {
                guard active, !shown else { return }
                // Stagger only the first rows; later cells appear immediately – no "popcorn" effect.
                let delay = Double(min(index, 14)) * 0.028
                withAnimation(DS.Motion.reveal.delay(delay)) { shown = true }
            }
    }
}

// MARK: Effect 12 – Smart loading (only while something actually loads)

struct ShimmerBlock: View {
    var cornerRadius: CGFloat = DS.Radius.tile
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DS.Palette.hover)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .onAppear {
                guard !DS.Motion.reduced else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

// MARK: Effect 10 – Contextual tooltips (delayed glass tip with optional shortcut)

struct GlassTooltip: ViewModifier {
    var text: String
    var shortcut: String?
    var edge: VerticalEdge = .bottom
    @State private var hovering = false
    @State private var visible = false
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .onHover { h in
                hovering = h
                token += 1
                let t = token
                if h {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if hovering && token == t { withAnimation(DS.Motion.quick) { visible = true } }
                    }
                } else {
                    withAnimation(DS.Motion.quick) { visible = false }
                }
            }
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                if visible {
                    HStack(spacing: 6) {
                        Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.textPrimary)
                        if let shortcut { KeyCap(text: shortcut) }
                    }
                    .fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .glass(.floating, in: Capsule())
                    .offset(y: edge == .bottom ? 34 : -34)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: edge == .bottom ? .top : .bottom)))
                    .allowsHitTesting(false)
                    .zIndex(100)
                }
            }
            .accessibilityHint(Text(text))
    }
}

struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Palette.hover))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
    }
}

// MARK: Effect 11 – Focus depth (background recedes while a sheet/dialog is open)

struct FocusDepth: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active && !DS.Motion.reduced ? 0.985 : 1)
            .saturation(active ? 0.85 : 1)
            .brightness(active ? -0.03 : 0)
            .blur(radius: active ? 1.5 : 0)
            .animation(DS.Motion.smooth, value: active)
    }
}

extension View {
    func magneticHover(scale: CGFloat = 1.015, lift: CGFloat = 2, shadow: Bool = true) -> some View {
        modifier(MagneticHover(scale: scale, lift: lift, shadow: shadow))
    }
    func glassReflection(cornerRadius: CGFloat = DS.Radius.card) -> some View { modifier(GlassReflection(cornerRadius: cornerRadius)) }
    func reveal(index: Int, enabled: Bool = true) -> some View { modifier(RevealOnAppear(index: index, enabled: enabled)) }
    func tip(_ text: String, shortcut: String? = nil, edge: VerticalEdge = .bottom) -> some View {
        modifier(GlassTooltip(text: text, shortcut: shortcut, edge: edge))
    }
    func focusDepth(_ active: Bool) -> some View { modifier(FocusDepth(active: active)) }
}

// MARK: Window chrome helper

/// Transparent strip that moves the window when dragged (the title bar is hidden in PhotoFlow 2.0).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
