import SwiftUI
import AppKit

/// Asynchronously loaded thumbnail (memory → disk → decode), cancelled automatically when scrolled away.
/// Shows a shimmer skeleton only while it is really loading.
struct ThumbnailImage: View {
    let photo: PhotoRecord
    let recipe: EditRecipe?
    var pixelSize: Int = ThumbnailService.gridPixelSize
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?

    private var key: String { "\(photo.id)-\(photo.fileSignature)-\(recipe?.cacheKey ?? "o")-\(pixelSize)" }

    var body: some View {
        // Color.clear defines the frame; the image fills it and is clipped – never overflows its cell.
        Color.clear
            .overlay { content }
            .clipped()
            .task(id: key) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if photo.isMissing {
                Rectangle().fill(DS.Palette.hover)
                    .overlay(Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.Palette.warning))
            } else {
                ShimmerBlock(cornerRadius: 0)
            }
        }
    }

    private func load() async {
        if let cached = ThumbnailService.shared.cachedImage(for: photo, recipe: recipe, pixelSize: pixelSize) {
            image = cached
            return
        }
        guard !photo.isMissing else { image = nil; return }
        let loaded = await ThumbnailService.shared.thumbnail(for: photo, recipe: recipe, pixelSize: pixelSize)
        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = loaded } }
    }
}

/// The binding PhotoFlow 2.0 icon artwork (Resources/BrandMark.png), used for welcome, About and empty states.
struct BrandMark: View {
    var size: CGFloat = 96
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
        return NSApp?.applicationIconImage
    }()

    var body: some View {
        Group {
            if let img = Self.image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(DS.Palette.brand)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Headers

/// Large page title with a count line – the top of every content screen.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Font.largeTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).monospacedDigit().lineLimit(1)
                        .contentTransitionNumeric()
                }
            }
            .layoutPriority(2)
            Spacer(minLength: DS.Space.s)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) { self.init(title, subtitle: subtitle) { EmptyView() } }
}

/// Group header with a hairline (month sections, import sessions, …).
struct GroupHeader: View {
    var title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(title).font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary)
            if let detail { Text(detail).font(DS.Font.callout).foregroundStyle(DS.Palette.textTertiary).monospacedDigit() }
            Rectangle().fill(DS.Palette.hairline).frame(height: 0.5).padding(.leading, DS.Space.xs)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Font.title2).foregroundStyle(DS.Palette.textPrimary)
            if let subtitle { Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary) }
        }
    }
}

/// Small uppercase label above control groups.
struct ControlLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.micro).tracking(0.6)
            .foregroundStyle(DS.Palette.textTertiary)
    }
}

// MARK: - Empty states

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var illustration: Illustration.Kind?
    var hint: String?

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let illustration {
                Illustration(kind: illustration, size: 240)
                    .padding(.bottom, DS.Space.xxs)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(DS.Palette.brand)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: DS.Space.xs) {
                Text(title).font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary).multilineTextAlignment(.center)
                Text(message).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "plus") }
                    .buttonStyle(GlassButtonStyle(kind: .primary, large: true))
                    .padding(.top, DS.Space.xxs)
            }
            if let hint {
                Label(hint, systemImage: "hand.draw").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stats & badges

struct StatTile: View {
    var symbol: String
    var value: String
    var label: String
    var tint: Color = DS.Palette.blue

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(DS.Palette.textPrimary)
                    .contentTransitionNumeric()
                Text(label).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.s)
        .glassCard()
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Controls (Material 3 – Interactive Glass)

/// Fluid slider: the fill grows from the neutral point, the thumb enlarges while dragging,
/// double-click resets. Fully VoiceOver-adjustable.
struct FluidSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var neutral: Double? = nil
    var tint: AnyShapeStyle = AnyShapeStyle(DS.Palette.brand)
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, thumb: CGFloat = dragging ? 19 : (hovering ? 17 : 15)
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / max(span, 0.0001))
            let anchor = CGFloat(((neutral ?? range.lowerBound) - range.lowerBound) / max(span, 0.0001))
            let x = thumb / 2 + frac * (w - thumb)
            let ax = thumb / 2 + anchor * (w - thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.track).frame(height: 4)
                Capsule().fill(tint)
                    .frame(width: max(4, abs(x - ax)), height: 4)
                    .offset(x: min(x, ax))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: dragging ? 5 : 2.5, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: x - thumb / 2)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let f = Double(min(max((d.location.x - thumb / 2) / max(w - thumb, 1), 0), 1))
                        value = ((range.lowerBound + f * span) / step).rounded() * step
                    }
                    .onEnded { _ in dragging = false; onEditingChanged(false) }
            )
            .animation(DS.Motion.hover, value: dragging)
            .animation(DS.Motion.hover, value: hovering)
        }
        .frame(height: 22)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: String(format: step < 1 ? "%.2f" : "%.0f", value)))
        .accessibilityAdjustableAction { dir in
            onEditingChanged(true)
            let inc = max(step, (range.upperBound - range.lowerBound) / 50)
            switch dir {
            case .increment: value = min(range.upperBound, value + inc)
            case .decrement: value = max(range.lowerBound, value - inc)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}

/// Slider row with label, animated value, reset and an editing callback (for undo grouping).
struct AdjustmentSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"
    var defaultValue: Double = 0
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(DS.Font.callout).foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                if value != defaultValue {
                    Button {
                        onEditingChanged(true)
                        withAnimation(DS.Motion.snappy) { value = defaultValue }
                        onEditingChanged(false)
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .help(String(localized: "Reset"))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                Text(String(format: format, value))
                    .font(DS.Font.number)
                    .foregroundStyle(value == defaultValue ? DS.Palette.textTertiary : DS.Palette.blue)
                    .contentTransitionNumeric()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .animation(DS.Motion.snappy, value: value == defaultValue)
            FluidSlider(value: $value, range: range, step: step,
                        neutral: range.contains(defaultValue) ? defaultValue : nil, onEditingChanged: onEditingChanged)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onEditingChanged(true)
            withAnimation(DS.Motion.snappy) { value = defaultValue }
            onEditingChanged(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

/// Glass switch with a soft, precise knob motion.
struct GlassSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.s) {
            configuration.label
            Spacer(minLength: DS.Space.xs)
            GlassSwitchKnob(isOn: configuration.isOn) { withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { configuration.isOn.toggle() } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(configuration.isOn ? String(localized: "On") : String(localized: "Off")))
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

private struct GlassSwitchKnob: View {
    var isOn: Bool
    var toggle: () -> Void
    @State private var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(DS.Palette.track))
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(isOn ? 0.25 : 0.1), .clear], startPoint: .top, endPoint: .bottom)))
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                .frame(width: pressed ? 22 : 18, height: 18)
                .padding(2)
        }
        .frame(width: 38, height: 22)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture(perform: toggle)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { withAnimation(DS.Motion.hover) { pressed = true } } }
            .onEnded { _ in withAnimation(DS.Motion.hover) { pressed = false } })
    }
}

extension ToggleStyle where Self == GlassSwitchStyle {
    static var glassSwitch: GlassSwitchStyle { GlassSwitchStyle() }
}

/// Segmented control with a softly gliding selection indicator.
struct GlassSegmented<T: Hashable>: View {
    struct Option: Identifiable { var id: T { value }; var value: T; var title: String; var symbol: String? = nil }
    @Binding var selection: T
    var options: [Option]
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                let on = o.value == selection
                Button {
                    withAnimation(DS.Motion.adaptive(DS.Motion.snappy)) { selection = o.value }
                } label: {
                    HStack(spacing: 5) {
                        if let s = o.symbol { Image(systemName: s).font(.system(size: 11, weight: .semibold)) }
                        if !compact || o.symbol == nil { Text(o.title).lineLimit(1) }
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                    .padding(.horizontal, compact ? 9 : 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .background {
                        if on {
                            Capsule().fill(DS.Palette.surfaceStrong)
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .overlay(Capsule().strokeBorder(DS.Palette.rim, lineWidth: 0.5))
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(o.title)
                .accessibilityLabel(Text(o.title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(DS.Palette.hover))
        .overlay(Capsule().strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
    }
}

/// Wide glass search field.
struct GlassSearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Palette.textTertiary) }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 8)
        .glass(.interactive, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Palette.focus, lineWidth: focused ? 2 : 0).allowsHitTesting(false))
        .animation(DS.Motion.quick, value: focused)
        .animation(DS.Motion.quick, value: text.isEmpty)
    }
}

// MARK: - Success feedback (effect 13)

struct ToastView: View {
    var toast: Toast
    @State private var pop = false
    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: toast.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.symbol.contains("exclamation") ? DS.Palette.warning : DS.Palette.success)
                .scaleEffect(pop ? 1 : 0.4)
                .opacity(pop ? 1 : 0)
            Text(toast.message).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Palette.textPrimary)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 10)
        .glass(.floating, in: Capsule())
        .onAppear { withAnimation(DS.Motion.adaptive(DS.Motion.celebrate).delay(0.08)) { pop = true } }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Numeric text transition on macOS 14+, nothing on 13.
    @ViewBuilder
    func contentTransitionNumeric() -> some View {
        if #available(macOS 14.0, *) { self.contentTransition(.numericText()) } else { self }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension TimeInterval {
    var formattedDuration: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: self) ?? ""
    }
}
