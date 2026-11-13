import SwiftUI

/// Duplicate Finder and Similar Photos (same engine, different thresholds).
/// Every group is a side-by-side comparison: the recommended version first, the others with their
/// similarity and highlighted differences; keep / delete is a single, reversible click.
struct DuplicatesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: DuplicatesModel
    @State private var compareGroup: DuplicateGroup?

    private var isDuplicates: Bool { model.kind == .duplicates }
    private var title: String { isDuplicates ? String(localized: "Duplicate Finder") : String(localized: "Similar Photos") }
    private var subtitle: String {
        isDuplicates
            ? String(localized: "Finds identical files and visually identical photos – even with different names, sizes or compression.")
            : String(localized: "Finds burst shots, near-identical pictures, crops and edited versions of the same photo.")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                PageHeader(title, subtitle: subtitle) {
                    if model.isScanning {
                        Button { model.cancel() } label: { Label(String(localized: "Stop"), systemImage: "stop.fill") }.softButton()
                    } else {
                        Button { model.scan(app) } label: {
                            Label(model.groups.isEmpty ? String(localized: "Scan Library") : String(localized: "Scan Again"), systemImage: "sparkle.magnifyingglass")
                        }
                        .prominentButton()
                        .disabled(app.photos.count < 2)
                    }
                }
                controls
                status
                content
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, ContentView.topBarHeight + DS.Space.xxs)
            .padding(.bottom, 120)
            .frame(maxWidth: 1680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .mask(TopFadeMask())
        .overlay(alignment: .bottom) {
            if !model.markedForDeletion.isEmpty {
                actionBar
                    .padding(.bottom, DS.Space.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.markedForDeletion.isEmpty)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: model.isScanning)
        .sheet(item: $compareGroup) { g in DuplicateCompareSheet(group: g, model: model) }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: DS.Space.s) {
            Menu {
                Button(String(localized: "Entire Library")) { model.scope = .library }
                Button(String(localized: "Selected Photos")) { model.scope = .selection }
                if !app.albums.isEmpty {
                    Divider()
                    ForEach(app.albums) { a in Button(String(localized: "Album: \(a.name)")) { model.scope = .album(a.id) } }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text(scopeName).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Palette.textTertiary)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, DS.Space.s)
            .disabled(model.isScanning)

            Rectangle().fill(DS.Palette.hairline).frame(width: 0.5, height: 18)

            HStack(spacing: DS.Space.xs) {
                Text(String(localized: "Sensitivity")).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Palette.textSecondary).fixedSize()
                FluidSlider(value: Binding(get: { model.sensitivity }, set: { model.sensitivity = $0.rounded() }),
                            range: isDuplicates ? 85 ... 99 : 70 ... 95, step: 1)
                    .frame(width: 150)
                    .disabled(model.isScanning)
                Text(String(localized: "≥ \(Int(model.sensitivity)) %")).font(DS.Font.number).foregroundStyle(DS.Palette.blue).fixedSize()
                    .contentTransitionNumeric()
            }
            .padding(.horizontal, DS.Space.xs)
            .help(String(localized: "Minimum similarity for photos to be grouped. Lower values find more, but less similar, photos."))

            if !model.groups.isEmpty {
                Rectangle().fill(DS.Palette.hairline).frame(width: 0.5, height: 18)
                Menu {
                    Button(String(localized: "All Groups")) { model.categoryFilter = nil }
                    ForEach(SimilarityCategory.allCases.reversed(), id: \.self) { c in
                        Button(c.displayName) { model.categoryFilter = c }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.categoryFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        Text(model.categoryFilter?.displayName ?? String(localized: "All Groups"))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, DS.Space.s)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, DS.Space.xxs)
        .glass(.floating, in: Capsule())
        .fixedSize()
    }

    private var scopeName: String {
        switch model.scope {
        case .library: return String(localized: "Entire Library")
        case .selection: return String(localized: "Selected Photos")
        case .album(let id): return String(localized: "Album: \(app.albums.first { $0.id == id }?.name ?? "")")
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.isScanning, let p = model.progress {
            HStack(spacing: DS.Space.l) {
                ZStack {
                    ProgressRing(fraction: p.total > 0 ? p.fraction : 0.05, lineWidth: 7)
                    Text(verbatim: p.total > 0 ? "\(Int((p.fraction * 100).rounded())) %" : "…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(DS.Palette.textPrimary)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Scanning…")).font(DS.Font.title3).foregroundStyle(DS.Palette.textPrimary)
                    Text(model.phaseText).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                }
                Spacer()
            }
            .padding(DS.Space.m)
            .glassCard(cornerRadius: DS.Radius.panel)
            .transition(.opacity)
        } else if let r = model.lastReport {
            HStack(spacing: DS.Space.s) {
                StatTile(symbol: "rectangle.stack.fill", value: "\(model.groups.count)", label: String(localized: "Groups"), tint: DS.Palette.sun)
                StatTile(symbol: "photo.stack.fill", value: "\(model.groups.reduce(0) { $0 + $1.members.count })", label: String(localized: "Photos involved"), tint: DS.Palette.blue)
                StatTile(symbol: "externaldrive.fill.badge.minus", value: model.potentialSavings.formattedBytes, label: String(localized: "Could be freed"), tint: DS.Palette.success)
                StatTile(symbol: "timer", value: String(format: "%.1f s", r.duration), label: String(localized: "\(r.reusedFromCache) from cache"), tint: DS.Palette.iris)
            }
        }
    }

    // MARK: Groups

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.groups.isEmpty {
            EmptyStateView(symbol: "sparkle.magnifyingglass", title: String(localized: "Scanning…"),
                           message: String(localized: "Photos are analyzed on this Mac. Results are cached, so the next scan is much faster."),
                           illustration: isDuplicates ? .duplicates : .similar)
                .frame(minHeight: 380)
        } else if model.lastReport == nil {
            EmptyStateView(symbol: isDuplicates ? "square.on.square" : "square.stack.3d.down.right",
                           title: isDuplicates ? String(localized: "Find Duplicates") : String(localized: "Find Similar Photos"),
                           message: String(localized: "PhotoFlow compares file contents and image content. Nothing is ever deleted automatically – you review every group and decide."),
                           actionTitle: String(localized: "Scan Library"), action: { model.scan(app) },
                           illustration: isDuplicates ? .duplicates : .similar)
                .frame(minHeight: 420)
        } else if model.visibleGroups.isEmpty {
            EmptyStateView(symbol: "checkmark.seal", title: String(localized: "Nothing Found"),
                           message: String(localized: "No groups at the current sensitivity. Lower the sensitivity to find less similar photos."),
                           illustration: .done)
                .frame(minHeight: 380)
        } else {
            HStack(spacing: DS.Space.xs) {
                Button { model.selectRecommended() } label: { Label(String(localized: "Select All Except Recommended"), systemImage: "checklist") }
                    .softButton()
                    .help(String(localized: "Marks every photo except the recommended best version of each group. Nothing is deleted until you confirm."))
                Button { model.clearMarks() } label: { Label(String(localized: "Keep All"), systemImage: "hand.raised") }
                    .softButton()
                    .disabled(model.markedForDeletion.isEmpty)
                Spacer()
            }
            LazyVStack(spacing: DS.Space.l) {
                ForEach(Array(model.visibleGroups.enumerated()), id: \.element.id) { i, g in
                    DuplicateGroupCard(group: g, model: model, onCompare: { compareGroup = g })
                        .reveal(index: i)
                }
            }
        }
    }

    // MARK: Floating action bar

    private var actionBar: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "trash.circle.fill").font(.system(size: 26)).foregroundStyle(.white, DS.Palette.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Selected for deletion: \(model.markedForDeletion.count)")).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary)
                    .contentTransitionNumeric()
                Text(String(localized: "\(model.markedBytes.formattedBytes) · moved to the macOS Trash, restorable")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            if model.groupsWithEverythingMarked > 0 {
                Label(String(localized: "In \(model.groupsWithEverythingMarked) groups every photo is selected – the recommended one will be kept."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.warning)
                    .frame(maxWidth: 260)
            }
            Button(String(localized: "Clear Selection")) { model.clearMarks() }.softButton()
            Button { model.trashMarked(app) } label: { Label(String(localized: "Move to Trash…"), systemImage: "trash") }
                .buttonStyle(GlassButtonStyle(kind: .destructive))
        }
        .padding(.leading, DS.Space.m)
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .glass(.floating, in: Capsule())
    }
}

struct DuplicateGroupCard: View {
    @EnvironmentObject private var app: AppModel
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel
    var onCompare: () -> Void

    private var best: DuplicateMember? { group.members.first { $0.isRecommended } ?? group.members.first }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.xs) {
                Badge(text: group.category.displayName, color: Theme.categoryColor(group.category), symbol: group.category.symbol)
                SimilarityMeter(value: group.category == .exact ? 100 : group.score, color: Theme.categoryColor(group.category))
                Text(group.category == .exact ? String(localized: "100 % identical") : String(localized: "\(Int(group.score.rounded())) % similar"))
                    .font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).monospacedDigit()
                Text(String(localized: "\(group.members.count) photos")).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button { onCompare() } label: { Label(String(localized: "Compare"), systemImage: "square.split.2x1") }.softButton()
                Menu {
                    Button(String(localized: "Select All Except Recommended")) { model.selectRecommended(in: group) }
                    Button(String(localized: "Keep All in This Group")) { model.keepAll(group) }
                    Button(String(localized: "Reveal All in Finder")) { app.reveal(group.members.map(\.id)) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 30, height: 30)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    ForEach(group.members) { m in
                        DuplicateMemberCell(member: m, best: best, group: group, model: model)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
        .padding(DS.Space.m)
        .glassCard(cornerRadius: DS.Radius.panel)
    }
}

/// Tiny bar that visualises a similarity percentage.
struct SimilarityMeter: View {
    var value: Double
    var color: Color
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(DS.Palette.track)
            Capsule().fill(color.gradient).frame(width: 44 * CGFloat(max(0, min(100, value)) / 100))
        }
        .frame(width: 44, height: 5)
        .accessibilityHidden(true)
    }
}

struct DuplicateMemberCell: View {
    @EnvironmentObject private var app: AppModel
    let member: DuplicateMember
    let best: DuplicateMember?
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel
    @State private var hovering = false

    var body: some View {
        let m = member
        let marked = model.markedForDeletion.contains(m.id)
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                ThumbnailImage(photo: m.photo, recipe: app.recipe(for: m.id), pixelSize: 480)
                    .frame(width: 220, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                    .saturation(marked ? 0.2 : 1)
                    .opacity(marked ? 0.6 : 1)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(marked ? DS.Palette.danger : (m.isRecommended ? DS.Palette.success : Color.clear), lineWidth: 2.5))
                    .scaleEffect(hovering && !DS.Motion.reduced ? 1.02 : 1)
                    .onTapGesture(count: 2) { app.quickLook(m.id) }
                if m.isRecommended {
                    Label(String(localized: "Best Version to Keep"), systemImage: "star.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(DS.Palette.success.gradient, in: Capsule())
                        .padding(8)
                } else {
                    Text(m.isExactCopy ? String(localized: "Identical") : "\(Int(m.similarity.rounded())) %")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
                if marked {
                    Image(systemName: "trash.circle.fill").font(.system(size: 34)).foregroundStyle(.white, DS.Palette.danger)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .frame(width: 220, height: 160)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            Text(m.photo.filename).font(DS.Font.headline).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
            // facts – values that are better than the other version are highlighted
            VStack(alignment: .leading, spacing: 2) {
                fact("aspectratio", "\(m.photo.width) × \(m.photo.height)", better: best.map { m.photo.width * m.photo.height > $0.photo.width * $0.photo.height } ?? false,
                     worse: best.map { m.photo.width * m.photo.height < $0.photo.width * $0.photo.height } ?? false)
                fact("internaldrive", "\(m.photo.fileSize.formattedBytes) · \(m.photo.formatName)", better: false, worse: false)
                fact("calendar", m.photo.displayDate.formatted(date: .abbreviated, time: .shortened), better: false, worse: false)
                fact("folder", (m.photo.path as NSString).deletingLastPathComponent, better: false, worse: false)
                    .help(m.photo.path)
            }
            if m.isRecommended, !m.reasons.isEmpty {
                Text(m.reasons.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(DS.Palette.success).lineLimit(3)
                    .frame(width: 220, alignment: .leading)
            }
            GlassSegmented(selection: Binding(get: { marked }, set: { want in if want != marked { model.toggleMark(m.id) } }),
                           options: [.init(value: false, title: String(localized: "Keep"), symbol: "checkmark"),
                                     .init(value: true, title: String(localized: "Delete"), symbol: "trash")])
                .frame(width: 220)
        }
        .frame(width: 220)
        .animation(DS.Motion.adaptive(DS.Motion.snappy), value: marked)
        .animation(DS.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(String(localized: "Keep This Photo Only")) { model.keepOnly(m.id, in: group) }
            Button(marked ? String(localized: "Keep") : String(localized: "Select for Deletion")) { model.toggleMark(m.id) }
            Divider()
            Button(String(localized: "Quick Look")) { app.quickLook(m.id) }
            Button(String(localized: "Reveal in Finder")) { app.reveal([m.id]) }
            Button(String(localized: "Get Information")) { app.infoTarget = m.photo }
        }
    }

    private func fact(_ symbol: String, _ text: String, better: Bool, worse: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5)).frame(width: 13)
            Text(text).font(.system(size: 10.5)).monospacedDigit().lineLimit(1).truncationMode(.middle)
            if better { Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold)) }
            if worse { Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(better ? DS.Palette.success : (worse ? DS.Palette.warning : DS.Palette.textSecondary))
        .frame(width: 220, alignment: .leading)
    }
}

/// Side-by-side comparison of two members of a group, plus an overlay slider to spot differences.
struct DuplicateCompareSheet: View {
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var left = 0
    @State private var right = 1
    @State private var overlay = false

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack {
                Text(String(localized: "Compare")).font(DS.Font.title2)
                Spacer()
                GlassSegmented(selection: $overlay, options: [.init(value: false, title: String(localized: "Side by Side"), symbol: "rectangle.split.2x1"),
                                                              .init(value: true, title: String(localized: "Overlay"), symbol: "square.split.diagonal.2x2")])
                    .frame(width: 260)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction).prominentButton()
            }
            if overlay {
                let a = group.members[min(left, group.members.count - 1)], b = group.members[min(right, group.members.count - 1)]
                BeforeAfterSlider(beforeLabel: a.photo.filename, afterLabel: b.photo.filename) {
                    ThumbnailImage(photo: a.photo, recipe: nil, pixelSize: 1600, contentMode: .fit)
                } after: {
                    ThumbnailImage(photo: b.photo, recipe: nil, pixelSize: 1600, contentMode: .fit)
                }
                .background(DS.Palette.stage, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                HStack { picker($left); picker($right) }
            } else {
                HStack(spacing: DS.Space.m) {
                    side($left)
                    side($right)
                }
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 980, minHeight: 660)
        .animation(DS.Motion.adaptive(DS.Motion.smooth), value: overlay)
    }

    private func picker(_ index: Binding<Int>) -> some View {
        Picker("", selection: index) {
            ForEach(group.members.indices, id: \.self) { i in
                Text(group.members[i].photo.filename + (group.members[i].isRecommended ? " ★" : "")).tag(i)
            }
        }
        .labelsHidden()
    }

    private func side(_ index: Binding<Int>) -> some View {
        let m = group.members[min(index.wrappedValue, group.members.count - 1)]
        let marked = model.markedForDeletion.contains(m.id)
        return VStack(spacing: DS.Space.s) {
            picker(index)
            ThumbnailImage(photo: m.photo, recipe: nil, pixelSize: 1600, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Palette.stage, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            PhotoMetadataGrid(photo: m.photo)
            HStack {
                if m.isRecommended { Badge(text: String(localized: "Best Version to Keep"), color: DS.Palette.success, symbol: "star.fill") }
                Spacer()
                Button(marked ? String(localized: "Keep") : String(localized: "Select for Deletion")) { model.toggleMark(m.id) }
                    .softButton()
            }
        }
    }
}

/// Compares two different library photos side by side (toolbar "Compare" with two selected).
struct ComparePhotosSheet: View {
    let ids: [Int64]
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack {
                Text(String(localized: "Compare")).font(DS.Font.title2)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction).prominentButton()
            }
            HStack(spacing: DS.Space.m) {
                ForEach(app.records(ids)) { p in
                    VStack(spacing: DS.Space.s) {
                        ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 1600, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(DS.Palette.stage, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        Text(p.filename).font(DS.Font.headline)
                        PhotoMetadataGrid(photo: p)
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 980, minHeight: 640)
    }
}
