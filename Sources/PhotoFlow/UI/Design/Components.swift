import SwiftUI
import AppKit

/// Asynchronously loaded thumbnail (memory → disk → decode), cancelled automatically when scrolled away.
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
            } else {
                Rectangle().fill(Color.secondary.opacity(0.08))
                    .overlay {
                        if photo.isMissing {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small).opacity(0.5)
                        }
                    }
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
        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.18)) { image = loaded } }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.title2, design: .rounded).weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// Large empty-state placeholder (macOS 13 compatible).
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var illustration: Illustration.Kind?

    var body: some View {
        VStack(spacing: 14) {
            if let illustration {
                Illustration(kind: illustration, size: 230)
                    .padding(.bottom, 4)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(title).font(DS.Font.title1)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "plus") }
                    .prominentButton()
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatTile: View {
    var symbol: String
    var value: String
    var label: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
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
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// Slider row with label, value, double-click-to-reset and an editing callback (for undo grouping).
struct AdjustmentSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"
    var defaultValue: Double = 0
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
                if value != defaultValue {
                    Button {
                        onEditingChanged(true)
                        value = defaultValue
                        onEditingChanged(false)
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Reset"))
                }
            }
            // Continuous slider (stepped sliders draw tick marks on macOS); the value is rounded to `step`.
            Slider(value: Binding(get: { value }, set: { value = (($0 / step).rounded()) * step }), in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .tint(DS.Palette.indigo)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onEditingChanged(true)
            value = defaultValue
            onEditingChanged(false)
        }
    }
}

struct ToastView: View {
    var toast: Toast
    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCapsule()
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
