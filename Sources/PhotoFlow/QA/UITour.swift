import Foundation
import AppKit
import SwiftUI

/// Automated visual review: launches the real UI, walks through every screen and saves window screenshots.
///
///     PHOTOFLOW_LIBRARY_DIR=/tmp/lib PHOTOFLOW_TOUR_PHOTOS=/path/to/photos \
///       PhotoFlow --ui-tour /tmp/shots [-appearance dark] [-AppleLanguages "(de)"]
///
/// Used in CI to review layout, light/dark mode and localisation without a person at the screen.
@MainActor
enum UITour {
    static var outDir = URL(fileURLWithPath: "/tmp/photoflow-shots")
    static var prefix = "light"

    static func startIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-tour") else { return }
        if i + 1 < args.count { outDir = URL(fileURLWithPath: args[i + 1]) }
        prefix = UserDefaults.standard.string(forKey: SettingsKeys.appearance) == "dark" ? "dark" : "light"
        if let lang = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first, lang.hasPrefix("de") { prefix += "-de" }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run()
            NSApp.terminate(nil)
        }
        // Safety net: never hang a CI job.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { exit(3) }
    }

    private static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.frame.width > 600 }
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { await pause(0.25) }
    }

    static func run() async {
        await pause(2.5)
        guard let window = mainWindow else { print("UITOUR: no window"); return }
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1440, screen.width), height: min(900, screen.height))
        window.setFrame(NSRect(x: screen.minX + (screen.width - size.width) / 2, y: screen.minY + (screen.height - size.height) / 2,
                               width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let app = AppModel.shared
        await pause(1.5)

        if app.photos.isEmpty {
            app.sidebar = .allPhotos
            await pause(1)
            shot("01-empty-library")
            app.sidebar = .overview
            await pause(1)
            shot("02-overview-empty")
            if let dir = ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_PHOTOS"] {
                app.importItems([URL(fileURLWithPath: dir)])
                await pause(1)
                await waitUntil(120) { app.activity == nil }
            }
        }
        guard !app.photos.isEmpty else { print("UITOUR: no photos"); return }

        app.sidebar = .overview
        await pause(3)
        shot("03-overview")

        app.sidebar = .allPhotos
        app.selection = []
        await pause(4)
        shot("04-library-grid")

        let first = app.visiblePhotos.first!.id
        app.selection = [first]
        app.lastClicked = first
        await pause(2.5)
        shot("05-library-inspector")

        app.selection = Set(app.visiblePhotos.prefix(6).map(\.id))
        await pause(2)
        shot("06-library-multiselect")

        app.viewMode = .list
        await pause(2.5)
        shot("07-library-list")
        app.viewMode = .grid

        app.thumbnailSize = 260
        await pause(3)
        shot("08-library-large")
        app.thumbnailSize = 170

        // Editor
        app.openEditor(first)
        await pause(4)
        shot("09-editor-original")
        if let editor = app.activeEditor {
            await editor.autoEnhance(.balanced)
            await pause(3)
            shot("10-editor-enhanced")
            editor.mode = .split
            await pause(2)
            shot("11-editor-split")
            editor.mode = .sideBySide
            await pause(2)
            shot("12-editor-side-by-side")
            editor.mode = .edited
        }
        app.editorPhotoID = nil
        await pause(1)

        // Batch
        app.sidebar = .batch
        await pause(2)
        shot("13-batch-setup")
        app.selection = Set(app.photos.prefix(12).map(\.id))
        app.batch.source = .selection
        app.batch.start(app)
        await pause(2)
        shot("14-batch-running")
        await waitUntil(180) { !app.batch.isRunning }
        await pause(3)
        shot("15-batch-results")
        app.batch.reset()

        // Duplicates
        app.sidebar = .duplicates
        await pause(1.5)
        shot("16-duplicates-start")
        app.duplicates.scan(app)
        await pause(2)
        shot("17-duplicates-scanning")
        await waitUntil(300) { !app.duplicates.isScanning }
        await pause(4)
        shot("18-duplicates-results")
        if let g = app.duplicates.groups.first { app.duplicates.selectRecommended(in: g) }
        await pause(1.5)
        shot("19-duplicates-marked")
        app.duplicates.clearMarks()

        app.sidebar = .similar
        app.similar.scan(app)
        await waitUntil(300) { !app.similar.isScanning }
        await pause(4)
        shot("20-similar-results")

        app.sidebar = .exportHistory
        await pause(1.5)
        shot("21-export-history")
        app.sidebar = .trash
        await pause(1.5)
        shot("22-trash")

        // Export sheet
        app.sidebar = .allPhotos
        await pause(1)
        app.exportRequest = Array(app.photos.prefix(3).map(\.id))
        await pause(2)
        shot("23-export-sheet", includeSheets: true)
        app.exportRequest = nil
        await pause(1)

        // Settings window
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        await pause(2)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) }) {
            shot("24-settings", window: settings)
            settings.close()
        }
        print("UITOUR: done → \(outDir.path)")
    }

    // MARK: - Capture

    static func shot(_ name: String, window: NSWindow? = nil, includeSheets: Bool = false) {
        guard let w = window ?? mainWindow else { return }
        var image: CGImage?
        // Screen-area capture includes sheets and the real compositor result (materials, glass).
        if let screen = w.screen ?? NSScreen.main {
            let screenH = screen.frame.maxY
            var frame = w.frame
            if includeSheets, let sheet = w.attachedSheet { frame = frame.union(sheet.frame) }
            let rect = CGRect(x: frame.minX, y: screenH - frame.maxY, width: frame.width, height: frame.height)
            image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }
        if image == nil || isBlank(image!) {
            image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        }
        if image == nil, let view = w.contentView?.superview ?? w.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep.cgImage
        }
        guard let cg = image else { print("UITOUR: capture failed \(name)"); return }
        let url = outDir.appendingPathComponent("\(prefix)-\(name).png")
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("UITOUR: \(url.lastPathComponent) \(cg.width)x\(cg.height)")
    }

    private static func isBlank(_ img: CGImage) -> Bool {
        img.width < 10 || img.height < 10
    }
}
