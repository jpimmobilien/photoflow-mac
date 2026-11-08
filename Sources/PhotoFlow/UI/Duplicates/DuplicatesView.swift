import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: DuplicatesModel
    @State private var compareGroup: DuplicateGroup?

    private var title: String { model.kind == .duplicates ? String(localized: "Duplicate Finder") : String(localized: "Similar Photos") }
    private var subtitle: String {
        model.kind == .duplicates
            ? String(localized: "Finds identical files and visually identical photos – even with different names, sizes or compression.")
            : String(localized: "Finds burst shots, near-identical pictures, crops and edited versions of the same photo.")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            if !model.markedForDeletion.isEmpty { actionBar }
        }
        .sheet(item: $compareGroup) { g in DuplicateCompareSheet(group: g, model: model) }
    }

    // MARK: - Header with scan controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                SectionHeader(title: title, subtitle: subtitle)
                Spacer()
                if model.isScanning {
                    Button(role: .cancel) { model.cancel() } label: { Label(String(localized: "Stop"), systemImage: "stop.fill") }.softButton()
                } else {
                    Button { model.scan(app) } label: {
                        Label(model.groups.isEmpty ? String(localized: "Scan Library") : String(localized: "Scan Again"), systemImage: "sparkle.magnifyingglass")
                    }
                    .prominentButton()
                    .controlSize(.large)
                    .disabled(app.photos.count < 2)
                }
            }
            HStack(spacing: 14) {
                Picker(String(localized: "Scope"), selection: $model.scope) {
                    Text(String(localized: "Entire Library")).tag(DuplicatesModel.Scope.library)
                    Text(String(localized: "Selected Photos")).tag(DuplicatesModel.Scope.selection)
                    ForEach(app.albums) { a in Text(String(localized: "Album: \(a.name)")).tag(DuplicatesModel.Scope.album(a.id)) }
                }
                .fixedSize()
                .disabled(model.isScanning)

                HStack(spacing: 8) {
                    Text(String(localized: "Sensitivity")).foregroundStyle(.secondary).fixedSize()
                    Slider(value: $model.sensitivity, in: model.kind == .duplicates ? 85 ... 99 : 70 ... 95, step: 1)
                        .frame(width: 160)
                        .disabled(model.isScanning)
                    Text(String(localized: "≥ \(Int(model.sensitivity)) %")).monospacedDigit().fixedSize()
                }
                .help(String(localized: "Minimum similarity for photos to be grouped. Lower values find more, but less similar, photos."))

                Spacer()
                if !model.groups.isEmpty {
                    Picker(String(localized: "Show"), selection: $model.categoryFilter) {
                        Text(String(localized: "All Groups")).tag(SimilarityCategory?.none)
                        ForEach(SimilarityCategory.allCases.reversed(), id: \.self) { c in
                            Text(c.displayName).tag(SimilarityCategory?.some(c))
                        }
                    }
                    .fixedSize()
                }
            }
            if model.isScanning, let p = model.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.total > 0 ? p.fraction : nil)
                    Text(model.phaseText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let r = model.lastReport {
                HStack(spacing: 14) {
                    StatTile(symbol: "rectangle.stack.fill", value: "\(model.groups.count)", label: String(localized: "Groups"), tint: .orange)
                    StatTile(symbol: "photo.stack.fill", value: "\(model.groups.reduce(0) { $0 + $1.members.count })", label: String(localized: "Photos involved"), tint: .blue)
                    StatTile(symbol: "externaldrive.fill.badge.minus", value: model.potentialSavings.formattedBytes, label: String(localized: "Could be freed"), tint: .green)
                    StatTile(symbol: "timer", value: String(format: "%.1f s", r.duration), label: String(localized: "\(r.reusedFromCache) from cache"), tint: .purple)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Groups

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.groups.isEmpty {
            EmptyStateView(symbol: "sparkle.magnifyingglass", title: String(localized: "Scanning…"),
                           message: String(localized: "Photos are analyzed on this Mac. Results are cached, so the next scan is much faster."),
                           illustration: model.kind == .duplicates ? .duplicates : .similar)
        } else if model.lastReport == nil {
            EmptyStateView(symbol: model.kind == .duplicates ? "square.on.square.dashed" : "rectangle.3.group",
                           title: model.kind == .duplicates ? String(localized: "Find Duplicates") : String(localized: "Find Similar Photos"),
                           message: String(localized: "PhotoFlow compares file contents and image content. Nothing is ever deleted automatically – you review every group and decide."),
                           actionTitle: String(localized: "Scan Library"), action: { model.scan(app) },
                           illustration: model.kind == .duplicates ? .duplicates : .similar)
        } else if model.visibleGroups.isEmpty {
            EmptyStateView(symbol: "checkmark.seal", title: String(localized: "Nothing Found"),
                           message: String(localized: "No groups at the current sensitivity. Lower the sensitivity to find less similar photos."),
                           illustration: .done)
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    HStack {
                        Button { model.selectRecommended() } label: {
                            Label(String(localized: "Select All Except Recommended"), systemImage: "checklist")
                        }
                        .softButton()
                        .help(String(localized: "Marks every photo except the recommended best version of each group. Nothing is deleted until you confirm."))
                        Button { model.clearMarks() } label: { Label(String(localized: "Keep All"), systemImage: "hand.raised") }
                            .softButton()
                            .disabled(model.markedForDeletion.isEmpty)
                        Spacer()
                    }
                    ForEach(model.visibleGroups) { g in
                        DuplicateGroupCard(group: g, model: model, onCompare: { compareGroup = g })
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Bottom action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.circle.fill").font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "\(model.markedForDeletion.count) photos selected for deletion")).font(.headline)
                Text(String(localized: "\(model.markedBytes.formattedBytes) · moved to the macOS Trash, restorable")).font(.caption).foregroundStyle(.secondary)
            }
            if model.groupsWithEverythingMarked > 0 {
                Label(String(localized: "In \(model.groupsWithEverythingMarked) groups every photo is selected – the recommended one will be kept."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button(String(localized: "Clear Selection")) { model.clearMarks() }.softButton()
            Button(role: .destructive) { model.trashMarked(app) } label: {
                Label(String(localized: "Move to Trash…"), systemImage: "trash")
            }
            .prominentButton()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .transition(.move(edge: .bottom))
    }
}

struct DuplicateGroupCard: View {
    @EnvironmentObject private var app: AppModel
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel
    var onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Badge(text: group.category.displayName, color: Theme.categoryColor(group.category), symbol: group.category.symbol)
                Text(group.category == .exact ? String(localized: "100 % identical") : String(localized: "\(Int(group.score.rounded())) % similar"))
                    .font(.callout.weight(.semibold)).monospacedDigit()
                Text(String(localized: "\(group.members.count) photos")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { onCompare() } label: { Label(String(localized: "Compare"), systemImage: "square.split.2x1") }.softButton()
                Menu {
                    Button(String(localized: "Select All Except Recommended")) { model.selectRecommended(in: group) }
                    Button(String(localized: "Keep All in This Group")) { model.keepAll(group) }
                    Button(String(localized: "Reveal All in Finder")) { app.reveal(group.members.map(\.id)) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.members) { m in memberCell(m) }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(16)
        .glassCard()
    }

    private func memberCell(_ m: DuplicateMember) -> some View {
        let marked = model.markedForDeletion.contains(m.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ThumbnailImage(photo: m.photo, recipe: app.recipe(for: m.id), pixelSize: 420)
                    .frame(width: 200, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(marked ? Color.red : (m.isRecommended ? Color.green : .clear), lineWidth: 2.5))
                    .opacity(marked ? 0.55 : 1)
                    .onTapGesture(count: 2) { app.quickLook(m.id) }
                if m.isRecommended {
                    Label(String(localized: "Best Version to Keep"), systemImage: "star.fill")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.green, in: Capsule())
                        .padding(6)
                } else {
                    Text(m.isExactCopy ? String(localized: "Identical") : "\(Int(m.similarity.rounded())) %")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
                if marked {
                    Image(systemName: "trash.circle.fill").font(.title).foregroundStyle(.white, .red)
                        .frame(width: 200, height: 150)
                }
            }
            Text(m.photo.filename).font(.caption.weight(.semibold)).lineLimit(1)
            Text(verbatim: "\(m.photo.width) × \(m.photo.height) · \(m.photo.fileSize.formattedBytes) · \(m.photo.formatName)")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            Text(m.photo.displayDate.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            Text((m.photo.path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .help(m.photo.path)
            if m.isRecommended, !m.reasons.isEmpty {
                Text(m.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(.green).lineLimit(3)
            }
            HStack(spacing: 6) {
                Button { if marked { model.toggleMark(m.id) } } label: {
                    Label(String(localized: "Keep"), systemImage: marked ? "circle" : "checkmark.circle.fill")
                }
                .foregroundStyle(marked ? Color.secondary : Color.green)
                Button { if !marked { model.toggleMark(m.id) } } label: {
                    Label(String(localized: "Delete"), systemImage: marked ? "trash.fill" : "trash")
                }
                .foregroundStyle(marked ? Color.red : Color.secondary)
                Spacer()
                Button { app.reveal([m.id]) } label: { Image(systemName: "folder") }.help(String(localized: "Open original location"))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .frame(width: 200)
        .contextMenu {
            Button(String(localized: "Keep This Photo Only")) { model.keepOnly(m.id, in: group) }
            Button(marked ? String(localized: "Keep") : String(localized: "Select for Deletion")) { model.toggleMark(m.id) }
            Divider()
            Button(String(localized: "Quick Look")) { app.quickLook(m.id) }
            Button(String(localized: "Reveal in Finder")) { app.reveal([m.id]) }
            Button(String(localized: "Get Information")) { app.infoTarget = m.photo }
        }
    }
}

/// Side-by-side comparison of two members of a group (with quick switching).
struct DuplicateCompareSheet: View {
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var left = 0
    @State private var right = 1

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(String(localized: "Compare")).font(.title3.weight(.semibold))
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 14) {
                side($left)
                side($right)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 640)
    }

    private func side(_ index: Binding<Int>) -> some View {
        let m = group.members[min(index.wrappedValue, group.members.count - 1)]
        let marked = model.markedForDeletion.contains(m.id)
        return VStack(spacing: 10) {
            Picker("", selection: index) {
                ForEach(group.members.indices, id: \.self) { i in
                    Text(group.members[i].photo.filename + (group.members[i].isRecommended ? " ★" : "")).tag(i)
                }
            }
            .labelsHidden()
            ThumbnailImage(photo: m.photo, recipe: nil, pixelSize: 1600, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            PhotoMetadataGrid(photo: m.photo)
            HStack {
                if m.isRecommended { Badge(text: String(localized: "Best Version to Keep"), color: .green, symbol: "star.fill") }
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
        VStack(spacing: 14) {
            HStack {
                Text(String(localized: "Compare")).font(.title3.weight(.semibold))
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 14) {
                ForEach(app.records(ids)) { p in
                    VStack(spacing: 10) {
                        ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 1600, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        Text(p.filename).font(.headline)
                        PhotoMetadataGrid(photo: p)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 640)
    }
}
