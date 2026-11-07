import SwiftUI

/// Start page: library status and the main workflow IMPORT → ANALYZE → OPTIMIZE → ORGANIZE → EXPORT.
struct OverviewView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    StatTile(symbol: "photo.on.rectangle.angled", value: "\(app.photos.count)", label: String(localized: "Photos in library"), tint: .blue)
                    StatTile(symbol: "slider.horizontal.3", value: "\(app.editedCount)", label: String(localized: "Edited"), tint: .purple)
                    StatTile(symbol: "heart.fill", value: "\(app.favoriteCount)", label: String(localized: "Favorites"), tint: .pink)
                    StatTile(symbol: "internaldrive.fill", value: app.totalBytes.formattedBytes, label: String(localized: "Total size"), tint: .teal)
                    if !app.duplicates.groups.isEmpty {
                        StatTile(symbol: "square.on.square.fill", value: app.duplicates.potentialSavings.formattedBytes,
                                 label: String(localized: "Reclaimable from duplicates"), tint: .orange)
                    }
                    if app.missingCount > 0 {
                        StatTile(symbol: "exclamationmark.triangle.fill", value: "\(app.missingCount)", label: String(localized: "Missing originals"), tint: .yellow)
                    }
                }
                workflow
                if !recent.isEmpty { recentStrip }
                privacy
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.accentGradient).frame(width: 84, height: 84)
                Image(systemName: "camera.aperture").font(.system(size: 42, weight: .medium)).foregroundStyle(.white)
            }
            .shadow(color: Color.blue.opacity(0.35), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("PhotoFlow").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(String(localized: "Intelligent Photo Studio – better photos in a few clicks, entirely on your Mac."))
                    .font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            Button { app.showImportPanel() } label: { Label(String(localized: "Import Photos"), systemImage: "square.and.arrow.down") }
                .prominentButton().controlSize(.large)
        }
    }

    private var workflow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Your Workflow")).font(.headline)
            HStack(spacing: 10) {
                step("square.and.arrow.down", String(localized: "Import"), String(localized: "Files & folders")) { app.showImportPanel() }
                arrow
                step("wand.and.stars", String(localized: "Enhance"), String(localized: "One click, per photo")) {
                    app.sidebar = .allPhotos
                    app.selectAll()
                }
                arrow
                step("level", String(localized: "Straighten"), String(localized: "Horizons & lines")) {
                    var wf = BatchWorkflow.predefined.first { $0.id == "straighten" } ?? BatchWorkflow.predefined[0]
                    wf.options = .everything
                    app.batch.workflow = wf
                    app.sidebar = .batch
                }
                arrow
                step("square.on.square.dashed", String(localized: "Find Duplicates"), String(localized: "Exact & similar")) { app.sidebar = .duplicates }
                arrow
                step("square.and.arrow.up", String(localized: "Export"), String(localized: "Or delete unwanted")) {
                    app.sidebar = .allPhotos
                }
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
    }

    private func step(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.accentGradient)
                    .frame(height: 30)
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(10)
            .glassCard(cornerRadius: 14, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var recent: [PhotoRecord] {
        Array(app.photos.sorted { $0.importedAt > $1.importedAt }.prefix(14))
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Recent Imports")).font(.headline)
                Spacer()
                Button(String(localized: "Show All")) { app.sidebar = .recentImports }.buttonStyle(.link)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recent) { p in
                        ThumbnailImage(photo: p, recipe: app.recipe(for: p.id), pixelSize: 300)
                            .frame(width: 130, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onTapGesture(count: 2) { app.openEditor(p.id) }
                            .contextMenu { PhotoContextMenu(clicked: p.id, explicitIDs: [p.id]) }
                    }
                }
            }
        }
    }

    private var privacy: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill").font(.title).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Private by design")).font(.headline)
                Text(String(localized: "All analysis – scene recognition, faces, horizon detection, duplicate detection – runs on this Mac with Apple's built-in frameworks. No uploads, no cloud, no account, works offline. \(HardwareProfile.current.summary)"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard()
    }
}
