import SwiftUI

/// Start page. The user's own photographs are the hero; statistics are shown as visuals; the main workflow
/// is told with real thumbnails instead of icons and sentences.
struct OverviewView: View {
    @EnvironmentObject private var app: AppModel

    private var heroPhotos: [PhotoRecord] {
        // Prefer recent, landscape, high-resolution photos for the mosaic
        let candidates = app.photos.filter { !$0.isMissing }.sorted {
            ($0.importedAt, $0.megapixels) > ($1.importedAt, $1.megapixels)
        }
        let landscape = candidates.filter { $0.width >= $0.height }
        return Array((landscape + candidates.filter { $0.width < $0.height }).prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                if app.photos.isEmpty {
                    welcome
                } else {
                    hero
                    stats
                    workflow
                    recent
                }
                privacyLine
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground(photo: heroPhotos.first, recipe: heroPhotos.first.flatMap { app.recipe(for: $0.id) }))
    }

    // MARK: - Welcome (empty library)

    private var welcome: some View {
        VStack(spacing: DS.Space.l) {
            Illustration(kind: .welcome, size: 300)
                .padding(.top, DS.Space.huge)
            Text(String(localized: "Welcome to PhotoFlow"))
                .font(DS.Font.display)
            Text(String(localized: "Better photos in a few clicks – entirely on your Mac."))
                .font(.title3).foregroundStyle(.secondary)
            HStack(spacing: DS.Space.s) {
                Button { app.showImportPanel() } label: {
                    Label(String(localized: "Import Photos"), systemImage: "square.and.arrow.down").padding(.horizontal, 6)
                }
                .prominentButton().controlSize(.large)
            }
            .padding(.top, DS.Space.xs)
            HStack(spacing: DS.Space.xl) {
                featureHint("wand.and.stars", String(localized: "One-click enhance"))
                featureHint("level", String(localized: "Straight horizons"))
                featureHint("square.on.square.dashed", String(localized: "No more duplicates"))
                featureHint("lock.shield", String(localized: "Private & offline"))
            }
            .padding(.top, DS.Space.l)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func featureHint(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(DS.Palette.brand)
                .frame(width: 44, height: 44)
                .glassCard(cornerRadius: 14)
            Text(text).font(DS.Font.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoMosaic(photos: heroPhotos)
                .frame(height: 340)
            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "PHOTOFLOW").font(.system(size: 11, weight: .bold)).tracking(2.5).foregroundStyle(.white.opacity(0.75))
                    Text(String(localized: "\(app.photos.count) photos, ready to shine."))
                        .font(DS.Font.display).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.7)
                    Text(heroSubtitle).font(.callout).foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: DS.Space.m)
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Button {
                        app.sidebar = .batch
                        app.batch.source = .allPhotos
                    } label: {
                        Label(String(localized: "Improve All"), systemImage: "wand.and.stars").padding(.horizontal, 4)
                    }
                    .magicButton()
                    .controlSize(.large)
                    Button { app.sidebar = .duplicates } label: {
                        Label(String(localized: "Find Duplicates"), systemImage: "square.on.square.dashed")
                    }
                    .softButton()
                    .environment(\.colorScheme, .dark)
                }
            }
            .padding(DS.Space.xl)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
    }

    private var heroSubtitle: String {
        let unedited = app.photos.count - app.editedCount
        return unedited > 0 ? String(localized: "\(unedited) not enhanced yet – PhotoFlow can analyze and improve each one individually.")
                            : String(localized: "Every photo has been enhanced. Export them or look for duplicates.")
    }

    // MARK: - Visual statistics

    private var stats: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) { statCards }
            VStack(spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) { editedCard; storageCard }
                HStack(spacing: DS.Space.m) { duplicatesCard; favoritesCard }
            }
        }
    }

    @ViewBuilder private var statCards: some View {
        editedCard
        storageCard
        duplicatesCard
        favoritesCard
    }

    private var editedCard: some View {
        let total = max(app.photos.count, 1)
        let fraction = Double(app.editedCount) / Double(total)
        return HStack(spacing: DS.Space.m) {
            ZStack {
                ProgressRing(fraction: fraction, lineWidth: 7)
                Text(verbatim: "\(Int((fraction * 100).rounded())) %").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(app.editedCount)").font(DS.Font.statNumber)
                Text(String(localized: "enhanced")).font(DS.Font.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .statCard()
    }

    private var storageCard: some View {
        let byFormat = Dictionary(grouping: app.photos, by: \.formatName).mapValues { $0.reduce(Int64(0)) { $0 + $1.fileSize } }
        let colors: [Color] = [DS.Palette.indigo, DS.Palette.cyan, DS.Palette.pink, DS.Palette.amber, DS.Palette.success, .gray]
        let segments = byFormat.sorted { $0.value > $1.value }.prefix(6).enumerated().map { i, kv in
            SegmentBar.Segment(label: kv.key, value: Double(kv.value), color: colors[i % colors.count])
        }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.totalBytes.formattedBytes).font(DS.Font.statNumber)
                Text(String(localized: "in \(app.photos.count) files")).font(DS.Font.caption).foregroundStyle(.secondary)
            }
            SegmentBar(segments: segments, height: 8)
        }
        .statCard()
    }

    private var duplicatesCard: some View {
        Button { app.sidebar = .duplicates } label: {
            HStack(spacing: DS.Space.m) {
                SymbolBadge(symbol: "square.on.square.dashed", colors: [DS.Palette.amber, DS.Palette.pink], size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    if app.duplicates.lastReport != nil {
                        Text(app.duplicates.potentialSavings.formattedBytes).font(DS.Font.statNumber)
                        Text(String(localized: "reclaimable in \(app.duplicates.groups.count) groups")).font(DS.Font.caption).foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Duplicates")).font(DS.Font.headline)
                        Text(String(localized: "Not checked yet – scan now")).font(DS.Font.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .statCard()
    }

    private var favoritesCard: some View {
        Button { app.sidebar = .favorites } label: {
            HStack(spacing: DS.Space.m) {
                SymbolBadge(symbol: "heart.fill", colors: [DS.Palette.pink, DS.Palette.amber], size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(app.favoriteCount)").font(DS.Font.statNumber)
                    Text(String(localized: "Favorites")).font(DS.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .statCard()
    }

    // MARK: - Workflow told with real photos

    private var workflow: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(String(localized: "From import to export")).font(DS.Font.title2)
            let sample = heroPhotos.first
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: DS.Space.m)], spacing: DS.Space.m) {
                WorkflowCard(title: String(localized: "Enhance"), subtitle: String(localized: "Each photo analyzed individually"),
                             symbol: "wand.and.stars", gradient: DS.Palette.magic) {
                    if let p = sample { BeforeAfterThumb(photo: p, after: app.recipe(for: p.id) ?? .illustrativeEnhancement) }
                } action: { app.sidebar = .allPhotos; app.selectAll() }
                WorkflowCard(title: String(localized: "Straighten"), subtitle: String(localized: "Horizons and converging lines"),
                             symbol: "level", gradient: DS.Palette.brand) {
                    if let p = heroPhotos.dropFirst().first ?? sample { StraightenThumb(photo: p) }
                } action: {
                    var wf = BatchWorkflow.predefined.first { $0.id == "straighten" } ?? BatchWorkflow.predefined[0]
                    wf.options = .everything
                    app.batch.workflow = wf
                    app.sidebar = .batch
                }
                WorkflowCard(title: String(localized: "Clean up"), subtitle: String(localized: "Exact and visual duplicates"),
                             symbol: "square.on.square.dashed", gradient: LinearGradient(colors: [DS.Palette.amber, DS.Palette.pink], startPoint: .topLeading, endPoint: .bottomTrailing)) {
                    if let p = heroPhotos.dropFirst(2).first ?? sample { DuplicateThumb(photo: p) }
                } action: { app.sidebar = .duplicates }
                WorkflowCard(title: String(localized: "Export"), subtitle: String(localized: "Web, social media or full quality"),
                             symbol: "square.and.arrow.up", gradient: LinearGradient(colors: [DS.Palette.success, DS.Palette.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)) {
                    if let p = heroPhotos.dropFirst(3).first ?? sample {
                        ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 420)
                    }
                } action: { app.sidebar = .allPhotos }
            }
        }
    }

    // MARK: - Recent

    private var recent: some View {
        let items = Array(app.photos.sorted { $0.importedAt > $1.importedAt }.prefix(16))
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Recently imported")).font(DS.Font.title2)
                Spacer()
                Button(String(localized: "Show All")) { app.sidebar = .recentImports }.buttonStyle(.link)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(items) { p in
                        HoverThumb(photo: p, recipe: app.recipe(for: p.id))
                            .frame(width: 168, height: 120)
                            .onTapGesture(count: 2) { app.openEditor(p.id) }
                            .contextMenu { PhotoContextMenu(clicked: p.id, explicitIDs: [p.id]) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var privacyLine: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "lock.shield.fill").foregroundStyle(DS.Palette.success)
            Text(String(localized: "Everything runs on this Mac – no uploads, no cloud, no account."))
                .font(DS.Font.caption).foregroundStyle(.secondary)
            Spacer()
            Text(HardwareProfile.current.summary).font(DS.Font.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Building blocks

extension EditRecipe {
    /// A typical, moderate enhancement used to *illustrate* Auto Enhance on photos that are not edited yet.
    static var illustrativeEnhancement: EditRecipe {
        EditRecipe(exposure: 0.15, contrast: 14, highlights: -20, shadows: 18, vibrance: 28, clarity: 12)
    }
}

/// Bento-style mosaic: one large photo plus up to four smaller ones.
struct PhotoMosaic: View {
    @EnvironmentObject private var app: AppModel
    var photos: [PhotoRecord]

    var body: some View {
        GeometryReader { g in
            let spacing: CGFloat = 4
            let small = Array(photos.dropFirst().prefix(4))
            HStack(spacing: spacing) {
                if let first = photos.first {
                    ThumbnailImage(photo: first, recipe: app.recipe(for: first.id), pixelSize: 1200)
                        .frame(width: small.isEmpty ? g.size.width : g.size.width * 0.58)
                }
                if !small.isEmpty {
                    let cols = small.count > 1 ? 2 : 1
                    let rows = Int(ceil(Double(small.count) / Double(cols)))
                    let cw = max(10, (g.size.width * 0.42 - spacing - CGFloat(cols - 1) * spacing) / CGFloat(cols))
                    let ch = max(10, (g.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cw), spacing: spacing), count: cols), spacing: spacing) {
                        ForEach(small) { p in
                            ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 600)
                                .frame(width: cw, height: ch)
                        }
                    }
                }
            }
        }
    }
}

/// Before/after split preview of one photo.
struct BeforeAfterThumb: View {
    var photo: PhotoRecord
    var after: EditRecipe

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                ThumbnailImage(photo: photo, recipe: after, pixelSize: 420)
                ThumbnailImage(photo: photo, recipe: nil, pixelSize: 420)
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width / 2) }
                Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width / 2 - 1).shadow(radius: 2)
            }
        }
    }
}

/// A slightly tilted photo with a level line – "straightening" as a picture.
struct StraightenThumb: View {
    var photo: PhotoRecord
    var body: some View {
        ZStack {
            ThumbnailImage(photo: photo, recipe: nil, pixelSize: 420)
                .rotationEffect(.degrees(-4))
                .scaleEffect(1.18)
            Rectangle().fill(.white.opacity(0.9)).frame(height: 1.5).shadow(color: .black.opacity(0.4), radius: 2)
            HStack {
                Image(systemName: "arrow.uturn.left").font(.caption.weight(.bold))
                Spacer()
                Image(systemName: "arrow.uturn.right").font(.caption.weight(.bold))
            }
            .foregroundStyle(.white).padding(.horizontal, 10).shadow(radius: 2)
        }
        .clipped()
    }
}

/// Two overlapping copies of a photo – "duplicates" as a picture.
struct DuplicateThumb: View {
    var photo: PhotoRecord
    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            ThumbnailImage(photo: photo, recipe: nil, pixelSize: 300)
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .rotationEffect(.degrees(-7)).offset(x: -26, y: 4)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            ThumbnailImage(photo: photo, recipe: nil, pixelSize: 300)
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .rotationEffect(.degrees(6)).offset(x: 26, y: -2)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            SymbolBadge(symbol: "equal", colors: [DS.Palette.amber, DS.Palette.pink], size: 30).offset(y: 34)
        }
    }
}

struct WorkflowCard<Preview: View>: View {
    var title: String
    var subtitle: String
    var symbol: String
    var gradient: LinearGradient
    @ViewBuilder var preview: () -> Preview
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview()
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipped()
                HStack(spacing: DS.Space.s) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(DS.Font.headline)
                        Text(subtitle).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .offset(x: hovering ? 3 : 0)
                }
                .padding(DS.Space.s)
            }
            .glassCard(cornerRadius: DS.Radius.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: 18, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.snappy) { hovering = h } }
    }
}

/// Thumbnail that lifts slightly on hover.
struct HoverThumb: View {
    var photo: PhotoRecord
    var recipe: EditRecipe?
    @State private var hovering = false
    var body: some View {
        ThumbnailImage(photo: photo, recipe: recipe, pixelSize: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .scaleEffect(hovering ? 1.04 : 1)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 12 : 4, y: hovering ? 6 : 2)
            .onHover { h in withAnimation(DS.Motion.snappy) { hovering = h } }
            .help(photo.filename)
    }
}

extension View {
    func statCard() -> some View {
        self.padding(DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            .glassCard(cornerRadius: DS.Radius.card)
    }

    /// The "magic" call to action – reserved for Auto Enhance / Improve.
    @ViewBuilder
    func magicButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(DS.Palette.violet)
        } else {
            self.buttonStyle(MagicButtonStyle())
        }
        #else
        self.buttonStyle(MagicButtonStyle())
        #endif
    }
}

struct MagicButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(DS.Palette.magic, in: Capsule())
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            .shadow(color: DS.Palette.pink.opacity(configuration.isPressed ? 0.15 : 0.4), radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
    }
}
