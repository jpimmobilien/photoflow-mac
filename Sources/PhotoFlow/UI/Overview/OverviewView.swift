import SwiftUI

/// Start page – the visual heart of PhotoFlow. The user's own photographs are the stars: a dynamic bento
/// mosaic, statistics as visuals, workflows told with real (animated) previews, and the latest imports.
struct OverviewView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                if app.photos.isEmpty {
                    WelcomeView()
                } else {
                    PageHeader(String(localized: "Overview"), subtitle: headerSubtitle)
                    hero
                    stats
                    workflow
                    recent
                    privacyLine
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
            .padding(.bottom, 200)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .mask(TopFadeMask())
    }

    private var headerSubtitle: String {
        String(localized: "\(app.photos.count) photos") + " · " + app.totalBytes.formattedBytes + " · " + String(localized: "\(app.editedCount) enhanced")
    }

    // MARK: - Hero mosaic

    private var hero: some View {
        let photos = app.highlightPhotos
        return ZStack(alignment: .bottomLeading) {
            FeaturedMosaic(photos: photos)
                .frame(height: 400)
            // glass caption on the hero photo
            HStack(alignment: .bottom, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "\(app.photos.count) photos, ready to shine."))
                        .font(DS.Font.title1).foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Text(heroSubtitle).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.xs) {
                        Button {
                            app.batch.source = .allPhotos
                            app.sidebar = .batch
                        } label: { Label(String(localized: "Improve All"), systemImage: "wand.and.stars") }
                        .premiumButton()
                        Button { app.sidebar = .duplicates } label: { Label(String(localized: "Find Duplicates"), systemImage: "square.on.square") }
                            .softButton()
                    }
                    .padding(.top, DS.Space.xxs)
                }
                .padding(DS.Space.l)
                .frame(maxWidth: 400, alignment: .leading)
                .glass(.floating, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
        }
    }

    private var heroSubtitle: String {
        let unedited = app.photos.count - app.editedCount
        return unedited > 0 ? String(localized: "\(unedited) not enhanced yet – PhotoFlow can analyze and improve each one individually.")
                            : String(localized: "Every photo has been enhanced. Export them or look for duplicates.")
    }

    // MARK: - Visual statistics

    private var stats: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) { editedCard; storageCard; duplicatesCard; favoritesCard }
            VStack(spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) { editedCard; storageCard }
                HStack(spacing: DS.Space.m) { duplicatesCard; favoritesCard }
            }
        }
    }

    private var editedCard: some View {
        let total = max(app.photos.count, 1)
        let fraction = Double(app.editedCount) / Double(total)
        return HStack(spacing: DS.Space.m) {
            ZStack {
                ProgressRing(fraction: fraction, lineWidth: 6)
                Text(verbatim: "\(Int((fraction * 100).rounded())) %").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(app.editedCount)").font(DS.Font.statNumber).foregroundStyle(DS.Palette.textPrimary).contentTransitionNumeric()
                Text(String(localized: "enhanced")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .statCard()
    }

    private var storageCard: some View {
        let byFormat = Dictionary(grouping: app.photos, by: \.formatName).mapValues { $0.reduce(Int64(0)) { $0 + $1.fileSize } }
        let colors: [Color] = [DS.Palette.blue, DS.Palette.iris, DS.Palette.sky, DS.Palette.sun, DS.Palette.success, DS.Palette.textTertiary]
        let segments = byFormat.sorted { $0.value > $1.value }.prefix(6).enumerated().map { i, kv in
            SegmentBar.Segment(label: kv.key, value: Double(kv.value), color: colors[i % colors.count])
        }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.totalBytes.formattedBytes).font(DS.Font.statNumber).foregroundStyle(DS.Palette.textPrimary)
                Text(String(localized: "in \(app.photos.count) files")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            SegmentBar(segments: segments, height: 7)
        }
        .statCard()
    }

    private var duplicatesCard: some View {
        Button { app.sidebar = .duplicates } label: {
            HStack(spacing: DS.Space.m) {
                StatGlyph(symbol: "square.on.square", tint: DS.Palette.sun)
                VStack(alignment: .leading, spacing: 2) {
                    if app.duplicates.lastReport != nil {
                        Text(app.duplicates.potentialSavings.formattedBytes).font(DS.Font.statNumber).foregroundStyle(DS.Palette.textPrimary)
                        Text(String(localized: "reclaimable in \(app.duplicates.groups.count) groups")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    } else {
                        Text(String(localized: "Duplicates")).font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary)
                        Text(String(localized: "Not checked yet – scan now")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .statCard()
        .magneticHover(scale: 1.01, lift: 1)
    }

    private var favoritesCard: some View {
        Button { app.sidebar = .favorites } label: {
            HStack(spacing: DS.Space.m) {
                StatGlyph(symbol: "heart.fill", tint: DS.Palette.heart)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(app.favoriteCount)").font(DS.Font.statNumber).foregroundStyle(DS.Palette.textPrimary).contentTransitionNumeric()
                    Text(String(localized: "Favorites")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .statCard()
        .magneticHover(scale: 1.01, lift: 1)
    }

    // MARK: - Workflows told with real photos

    private var workflow: some View {
        let hp = app.highlightPhotos
        let sample = hp.first
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            GroupHeader(title: String(localized: "From import to export"), detail: nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DS.Space.l)], spacing: DS.Space.l) {
                WorkflowCard(title: String(localized: "Enhance"), subtitle: String(localized: "Each photo analyzed individually"),
                             symbol: "wand.and.stars", tint: DS.Palette.iris) {
                    if let p = sample { BeforeAfterThumb(photo: p, after: app.recipe(for: p.id) ?? .illustrativeEnhancement) }
                } action: { app.sidebar = .allPhotos; app.selectAll() }
                WorkflowCard(title: String(localized: "Straighten"), subtitle: String(localized: "Horizons and converging lines"),
                             symbol: "level", tint: DS.Palette.blue) {
                    if let p = hp.dropFirst().first ?? sample { StraightenThumb(photo: p) }
                } action: {
                    var wf = BatchWorkflow.predefined.first { $0.id == "straighten" } ?? BatchWorkflow.predefined[0]
                    wf.options = .everything
                    app.batch.workflow = wf
                    app.sidebar = .batch
                }
                WorkflowCard(title: String(localized: "Clean up"), subtitle: String(localized: "Exact and visual duplicates"),
                             symbol: "square.on.square", tint: DS.Palette.sun) {
                    if let p = hp.dropFirst(2).first ?? sample { DuplicateThumb(photo: p) }
                } action: { app.sidebar = .duplicates }
                WorkflowCard(title: String(localized: "Export"), subtitle: String(localized: "Web, social media or full quality"),
                             symbol: "square.and.arrow.up", tint: DS.Palette.sky) {
                    if let p = hp.dropFirst(3).first ?? sample { ExportThumb(photo: p) }
                } action: { app.sidebar = .allPhotos }
            }
        }
    }

    // MARK: - Recent

    private var recent: some View {
        let items = Array(app.photos.suffix(40).sorted { $0.importedAt > $1.importedAt }.prefix(16))
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                GroupHeader(title: String(localized: "Recently imported"), detail: nil)
                Button(String(localized: "Show All")) { app.sidebar = .recentImports }
                    .buttonStyle(GlassButtonStyle(kind: .plain))
                    .foregroundStyle(DS.Palette.blue)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                        GeometryReader { g in
                            HoverThumb(photo: p, recipe: app.recipe(for: p.id))
                                .onTapGesture(count: 2) { app.openViewer(p.id, from: g.frame(in: .named("root"))) }
                                .simultaneousGesture(TapGesture().onEnded { app.selection = [p.id]; app.lastClicked = p.id })
                        }
                        .frame(width: 176, height: 124)
                        .reveal(index: i)
                        .contextMenu { PhotoContextMenu(clicked: p.id, explicitIDs: [p.id]) }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
            }
        }
    }

    private var privacyLine: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "lock.shield.fill").foregroundStyle(DS.Palette.success)
            Text(String(localized: "Everything runs on this Mac – no uploads, no cloud, no account."))
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            Text(HardwareProfile.current.summary).font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

// MARK: - Welcome (empty library)

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Illustration(kind: .welcome, size: 320)
                .padding(.top, DS.Space.xxl)
            VStack(spacing: DS.Space.xs) {
                Text(String(localized: "Welcome to PhotoFlow"))
                    .font(DS.Font.display).foregroundStyle(DS.Palette.textPrimary)
                Text(String(localized: "Better photos in a few clicks – entirely on your Mac."))
                    .font(DS.Font.title3.weight(.regular)).foregroundStyle(DS.Palette.textSecondary)
            }
            Button { app.showImportPanel() } label: {
                Label(String(localized: "Import Photos"), systemImage: "square.and.arrow.down").padding(.horizontal, 10)
            }
            .buttonStyle(GlassButtonStyle(kind: .premium, large: true))
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .padding(.top, DS.Space.xxs)

            // drag & drop zone
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus").font(.system(size: 22, weight: .light)).foregroundStyle(DS.Palette.brand)
                Text(String(localized: "Drop photos or whole folders here")).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                Text(String(localized: "JPEG, HEIC, PNG, TIFF and RAW · originals are never changed"))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            .frame(maxWidth: 520)
            .padding(.vertical, DS.Space.l)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(dropHover || app.isDropTargeted ? DS.Palette.blue.opacity(0.08) : DS.Palette.hover))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(dropHover || app.isDropTargeted ? AnyShapeStyle(DS.Palette.brand) : AnyShapeStyle(DS.Palette.track),
                              style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
            .scaleEffect(dropHover && !DS.Motion.reduced ? 1.01 : 1)
            .onHover { h in withAnimation(DS.Motion.hover) { dropHover = h } }
            .onTapGesture { app.showImportPanel() }
            .padding(.top, DS.Space.xs)

            HStack(spacing: DS.Space.xl) {
                featureHint("wand.and.stars", String(localized: "One-click enhance"), DS.Palette.iris)
                featureHint("level", String(localized: "Straight horizons"), DS.Palette.blue)
                featureHint("square.on.square", String(localized: "No more duplicates"), DS.Palette.sun)
                featureHint("lock.shield", String(localized: "Private & offline"), DS.Palette.success)
            }
            .padding(.top, DS.Space.m)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func featureHint(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        VStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .glassCard(cornerRadius: 14)
            Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(width: 126)
    }
}

// MARK: - Building blocks

extension EditRecipe {
    /// A typical, moderate enhancement used to *illustrate* Auto Enhance on photos that are not edited yet.
    static var illustrativeEnhancement: EditRecipe {
        EditRecipe(exposure: 0.15, contrast: 14, highlights: -20, shadows: 18, vibrance: 28, clarity: 12)
    }
}

/// Dynamic bento mosaic – one large photo plus up to six smaller ones; adapts to the width.
struct FeaturedMosaic: View {
    @EnvironmentObject private var app: AppModel
    var photos: [PhotoRecord]

    var body: some View {
        GeometryReader { g in
            let s: CGFloat = 8
            let wide = g.size.width > 980
            let cols: CGFloat = wide ? 4 : 3
            let cw = (g.size.width - s * (cols - 1)) / cols
            let ch = (g.size.height - s) / 2
            let big = CGRect(x: 0, y: 0, width: cw * 2 + s, height: g.size.height)
            let smallRects: [CGRect] = (0 ..< Int(cols - 2) * 2).map { i in
                let c = CGFloat(i % Int(cols - 2)), r = CGFloat(i / Int(cols - 2))
                return CGRect(x: big.maxX + s + c * (cw + s), y: r * (ch + s), width: cw, height: ch)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(photos.prefix(1 + smallRects.count).enumerated()), id: \.element.id) { i, p in
                    let r = i == 0 ? big : smallRects[i - 1]
                    MosaicTile(photo: p, radius: i == 0 ? DS.Radius.hero : DS.Radius.card, pixelSize: i == 0 ? 1400 : 640)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .reveal(index: i)
                }
                // fill unused slots with soft placeholders – never an empty colour field
                if photos.count < 1 + smallRects.count {
                    ForEach(photos.count ..< 1 + smallRects.count, id: \.self) { i in
                        let r = i == 0 ? big : smallRects[i - 1]
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .fill(DS.Palette.hover)
                            .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(DS.Palette.textTertiary))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture { app.showImportPanel() }
                            .help(String(localized: "Import Photos"))
                    }
                }
            }
        }
    }
}

struct MosaicTile: View {
    let photo: PhotoRecord
    var radius: CGFloat
    var pixelSize: Int
    @EnvironmentObject private var app: AppModel
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            ThumbnailImage(photo: photo, recipe: app.recipe(for: photo.id), pixelSize: pixelSize)
                .scaleEffect(hovering && !DS.Motion.reduced ? 1.035 : 1)
                .frame(width: g.size.width, height: g.size.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .glassReflection(cornerRadius: radius)
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.10), radius: hovering ? 18 : 10, y: hovering ? 9 : 5)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onTapGesture(count: 2) { app.openViewer(photo.id, from: g.frame(in: .named("root"))) }
                .simultaneousGesture(TapGesture().onEnded { withAnimation(DS.Motion.snappy) { app.selection = [photo.id]; app.lastClicked = photo.id } })
                .contextMenu { PhotoContextMenu(clicked: photo.id, explicitIDs: [photo.id]) }
        }
        .animation(DS.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help(photo.filename)
        .accessibilityLabel(Text(photo.filename))
        .accessibilityAddTraits(.isButton)
    }
}

/// Before/after split preview of one photo; the divider drifts gently to show the change.
struct BeforeAfterThumb: View {
    var photo: PhotoRecord
    var after: EditRecipe
    var animated = true
    @State private var phase: CGFloat = 0.42

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                ThumbnailImage(photo: photo, recipe: after, pixelSize: 480)
                ThumbnailImage(photo: photo, recipe: nil, pixelSize: 480)
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * phase) }
                CompareDivider(height: g.size.height, compact: true)
                    .offset(x: g.size.width * phase - 11)
            }
        }
        .loopAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: phase)
        .onAppear {
            guard animated, !DS.Motion.reduced else { return }
            DispatchQueue.main.async { phase = 0.62 }
        }
    }
}

/// A tilted photo that settles level, with a glowing horizon line – "straightening" as a picture.
struct StraightenThumb: View {
    var photo: PhotoRecord?
    var sample: SamplePhoto.Scene = .tilted
    @State private var level = false

    var body: some View {
        ZStack {
            Group {
                if let photo { ThumbnailImage(photo: photo, recipe: nil, pixelSize: 480) } else { SamplePhoto(scene: sample) }
            }
            .rotationEffect(.degrees(level ? 0 : -4.5))
            .scaleEffect(1.18)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1.5)
                .shadow(color: DS.Palette.sky.opacity(0.9), radius: 4)
                .opacity(level ? 0.95 : 0.6)
            HStack {
                Image(systemName: "chevron.left.2").font(.system(size: 9, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right.2").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white).padding(.horizontal, 10).shadow(radius: 2)
        }
        .clipped()
        .loopAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: level)
        .onAppear {
            guard !DS.Motion.reduced else { level = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { level = true }
        }
    }
}

/// Two overlapping copies of a photo – "duplicates" as a picture.
struct DuplicateThumb: View {
    var photo: PhotoRecord
    var body: some View {
        ZStack {
            ThumbnailImage(photo: photo, recipe: nil, pixelSize: 96).blur(radius: 18).opacity(0.5)
            ThumbnailImage(photo: photo, recipe: nil, pixelSize: 300)
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .rotationEffect(.degrees(-7)).offset(x: -28, y: 4)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            ThumbnailImage(photo: photo, recipe: nil, pixelSize: 300)
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .rotationEffect(.degrees(6)).offset(x: 28, y: -2)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            Text(verbatim: "98 %")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(DS.Palette.sunrise, in: Capsule())
                .offset(y: 46)
        }
        .clipped()
    }
}

/// Photo with resolution / format chips – "export" as a picture.
struct ExportThumb: View {
    var photo: PhotoRecord?
    var sample: SamplePhoto.Scene = .lake
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let photo { ThumbnailImage(photo: photo, recipe: AppModel.shared.recipe(for: photo.id), pixelSize: 480) } else { SamplePhoto(scene: sample) }
            }
            HStack(spacing: 4) {
                chip("2048 px"); chip("JPEG · 85 %"); chip("sRGB")
            }
            .padding(8)
        }
        .clipped()
    }
    private func chip(_ t: String) -> some View {
        Text(verbatim: t).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }
}

struct WorkflowCard<Preview: View>: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    @ViewBuilder var preview: () -> Preview
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview()
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card - 4, style: .continuous))
                    .padding(6)
                HStack(spacing: DS.Space.s) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                        Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
                        .offset(x: hovering ? 3 : 0)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.top, 4)
                .padding(.bottom, DS.Space.s)
            }
            .glassCard(cornerRadius: DS.Radius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .magneticHover(scale: 1.015, lift: 2)
        .onHover { h in withAnimation(DS.Motion.hover) { hovering = h } }
    }
}

/// Thumbnail that lifts slightly on hover.
struct HoverThumb: View {
    var photo: PhotoRecord
    var recipe: EditRecipe?
    @State private var hovering = false
    var body: some View {
        ThumbnailImage(photo: photo, recipe: recipe, pixelSize: 360)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .glassReflection(cornerRadius: DS.Radius.tile)
            .scaleEffect(hovering && !DS.Motion.reduced ? 1.04 : 1)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.08), radius: hovering ? 12 : 4, y: hovering ? 6 : 2)
            .animation(DS.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
            .help(photo.filename)
    }
}

struct StatGlyph: View {
    var symbol: String
    var tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

extension View {
    func statCard() -> some View {
        self.padding(DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .glassCard(cornerRadius: DS.Radius.card)
    }

    /// The "magic" call to action – reserved for Auto Enhance / Improve (Premium Glass).
    func magicButton() -> some View { buttonStyle(GlassButtonStyle(kind: .premium)) }
}
