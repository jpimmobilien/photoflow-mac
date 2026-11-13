import Foundation
import AppKit
import SwiftUI
import ObjectiveC

/// Automated visual review: launches the real UI, walks through every screen, performs real mouse and
/// keyboard input (synthesized NSEvents posted to the app's event queue – the same path as hardware input)
/// and saves window screenshots.
///
///     PHOTOFLOW_LIBRARY_DIR=/tmp/lib PHOTOFLOW_TOUR_PHOTOS=/path/to/photos \
///     PHOTOFLOW_TOUR_SIZE=1440x900 PHOTOFLOW_TOUR_SET=full|sizes \
///       PhotoFlow --ui-tour /tmp/shots [-appearance dark] [-AppleLanguages "(de)"]
@MainActor
enum UITour {
    static var outDir = URL(fileURLWithPath: "/tmp/photoflow-shots")
    static var prefix = "light"
    static var checks: [(String, Bool)] = []

    static func startIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-tour") else { return }
        if i + 1 < args.count { outDir = URL(fileURLWithPath: args[i + 1]) }
        prefix = UserDefaults.standard.string(forKey: SettingsKeys.appearance) == "dark" ? "dark" : "light"
        if let lang = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first, lang.hasPrefix("de") { prefix += "-de" }
        if let s = ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_SIZE"], s != "1440x900" { prefix += "-\(s)" }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run()
            report()
            NSApp.terminate(nil)
        }
        // Safety net: never hang a CI job.
        let limit: Double = ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_AI_GENERATE"] == "1" ? 4200 : 1500
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { report(); exit(3) }
    }

    private static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 600 && $0.contentView != nil && $0.title != "Settings" }
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { await pause(0.25) }
    }

    private static func check(_ name: String, _ ok: Bool) {
        checks.append((name, ok))
        print("UITOUR-CHECK: \(ok ? "PASS" : "FAIL") \(name)")
    }

    private static func report() {
        let passed = checks.filter(\.1).count
        print("UITOUR-SUMMARY: \(passed)/\(checks.count) interaction checks passed")
    }

    static func run() async {
        await pause(2.5)
        guard let window = mainWindow else { print("UITOUR: no window"); return }
        let screen = window.screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var size = NSSize(width: 1440, height: 900)
        if let s = ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_SIZE"]?.split(separator: "x"), s.count == 2,
           let w = Double(s[0]), let h = Double(s[1]) { size = NSSize(width: w, height: h) }
        // The CI display is only 1024×768: allow windows larger than the screen for the review (tour only).
        unconstrainWindows()
        window.setFrame(NSRect(x: screen.minX, y: screen.maxY - size.height, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        print("UITOUR: screen \(Int(screen.width))x\(Int(screen.height)) window \(Int(window.frame.width))x\(Int(window.frame.height))")
        let app = AppModel.shared
        let sizesOnly = ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_SET"] == "sizes"
        await pause(1.5)

        // ---------- Empty library ----------
        if app.photos.isEmpty {
            app.sidebar = .overview
            await pause(1.5)
            shot("01-overview-empty")
            if !sizesOnly {
                app.sidebar = .allPhotos; await pause(1); shot("02-library-empty")
                app.sidebar = .batch; await pause(2.5); shot("03-batch-empty-samples")
                for wf in BatchWorkflow.predefined.prefix(7) where wf.id == "portrait" || wf.id == "straighten" {
                    app.batch.workflow = wf; await pause(1.2); shot("03-batch-empty-\(wf.id)")
                }
                app.batch.workflow = BatchWorkflow.predefined[0]
                app.sidebar = .duplicates; await pause(1); shot("04-duplicates-empty")
                app.sidebar = .albums; await pause(1); shot("05-albums-empty")
                app.sidebar = .trash; await pause(1); shot("06-trash-empty")
                app.sidebar = .exportHistory; await pause(1); shot("07-export-history-empty")
                app.sidebar = .overview
                app.isDropTargeted = true; await pause(1); shot("08-import-drop-target")
                app.isDropTargeted = false
            }
            if let dir = ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_PHOTOS"] {
                app.importItems([URL(fileURLWithPath: dir)])
                await pause(0.6)
                if !sizesOnly { shot("09-importing") }
                await waitUntil(180) { app.activity == nil }
            }
        }
        guard !app.photos.isEmpty else { print("UITOUR: no photos"); return }
        await pause(2)

        // ---------- Overview & library ----------
        app.sidebar = .overview
        await pause(3.5)
        shot("10-overview")
        if sizesOnly {
            await sizeTour(app)
            return
        }

        app.sidebar = .allPhotos
        app.selection = []
        app.viewMode = .mosaic
        await pause(4)
        shot("11-all-photos-mosaic")

        // Real mouse input: single click on the first tile selects it, double click opens the viewer.
        let gridPoint = CGPoint(x: (app.sidebarVisible ? 236 : 0) + 28 + 50, y: 300)
        click(window, at: gridPoint)
        await pause(1.2)
        check("mouse click on a photo tile selects it", app.selection.count == 1)
        shot("12-library-selection-inspector")
        await pause(4)
        shot("12-library-selection-inspector-after-4s")
        click(window, at: gridPoint, count: 2)
        await pause(1.5)
        check("double click opens the photo viewer", app.viewerPhotoID != nil)
        if app.viewerPhotoID != nil {
            shot("13-viewer")
            key(window, code: 124)   // →
            await pause(1.2)
            shot("14-viewer-next")
            key(window, code: 53)    // esc
            await pause(1)
            check("Esc closes the viewer", app.viewerPhotoID == nil)
        }
        // Space opens the viewer for the selected photo
        if let f = app.visiblePhotos.first?.id { app.selection = [f]; app.lastClicked = f }
        key(window, code: 49)
        await pause(1.2)
        check("Space opens the viewer", app.viewerPhotoID != nil)
        key(window, code: 49)
        await pause(1)
        check("Space closes the viewer", app.viewerPhotoID == nil)

        // Cmd-click adds to the selection
        click(window, at: CGPoint(x: gridPoint.x + 330, y: gridPoint.y), flags: .command)
        await pause(1)
        check("⌘-click extends the selection", app.selection.count >= 2)
        app.selection = Set(app.visiblePhotos.prefix(6).map(\.id))
        await pause(2)
        shot("15-library-multiselect")

        app.selection = []
        app.viewMode = .grid
        await pause(3)
        shot("16-all-photos-grid")
        app.viewMode = .compact
        await pause(3)
        shot("16b-all-photos-compact")
        app.viewMode = .list
        await pause(2.5)
        shot("17-all-photos-list")
        app.viewMode = .mosaic

        // favourites, edits, albums so every page has content
        app.toggleFavorite(Array(app.photos.prefix(5).map(\.id)))
        app.createAlbum(named: "Summer", with: Array(app.photos.prefix(8).map(\.id)))
        app.createAlbum(named: "Architecture", with: Array(app.photos.dropFirst(8).prefix(6).map(\.id)))
        app.sidebar = .recentImports; await pause(3); shot("18-recent-imports")
        app.sidebar = .favorites; await pause(3); shot("19-favorites")
        app.sidebar = .albums; await pause(3); shot("20-albums")
        if let a = app.albums.first { app.sidebar = .album(a.id); await pause(3); shot("21-album") }

        // ---------- Editor ----------
        let first = app.photos.first!.id
        app.openEditor(first)
        await pause(4)
        shot("22-editor-original")
        if let editor = app.activeEditor {
            await editor.autoEnhance(.balanced)
            await pause(3)
            shot("23-editor-enhanced")
            let before = editor.recipe
            key(window, code: 6, flags: .command)   // ⌘Z
            await pause(1.5)
            check("⌘Z undoes Auto Enhance in the editor", editor.recipe != before)
            key(window, code: 6, flags: [.command, .shift])   // ⇧⌘Z
            await pause(1.5)
            if editor.recipe != before {
                key(window, code: 6, flags: [.command, .shift], chars: "z")
                await pause(1.5)
            }
            check("⇧⌘Z redoes it", editor.recipe == before)
            editor.mode = .split
            await pause(2)
            shot("24-editor-split")
            editor.mode = .edited
            for (i, g) in ["color", "geometry", "crop", "effects"].enumerated() {
                UserDefaults.standard.set(g, forKey: "editorToolGroup")
                await pause(1.5)
                shot("25-editor-\(i + 1)-\(g)")
            }
            UserDefaults.standard.set("light", forKey: "editorToolGroup")
        }
        key(window, code: 53)   // esc → back
        await pause(1.5)
        check("Esc leaves the editor", app.editorPhotoID == nil)
        app.editorPhotoID = nil
        await pause(1)
        app.autoEnhance(Array(app.photos.dropFirst().prefix(4).map(\.id)))
        await waitUntil(120) { app.activity == nil }
        app.sidebar = .recentlyEdited; await pause(3); shot("26-recently-edited")

        // ---------- Batch: every workflow individually ----------
        app.sidebar = .batch
        app.batch.source = .allPhotos
        await pause(4)
        shot("27-batch-setup")
        await pause(4)
        shot("27-batch-setup-after-4s")
        for (i, wf) in BatchWorkflow.predefined.enumerated() {
            app.batch.workflow = wf
            await pause(3)
            shot("28-batch-workflow-\(i + 1)-\(wf.id)")
        }
        app.batch.workflow = BatchWorkflow.predefined[0]
        app.selection = Set(app.photos.prefix(12).map(\.id))
        app.batch.source = .selection
        await pause(1)
        app.batch.start(app)
        await pause(2.5)
        shot("29-batch-running")
        await waitUntil(240) { !app.batch.isRunning }
        await pause(3)
        shot("30-batch-finished")
        app.batch.reset()

        // ---------- Duplicates & similar ----------
        app.sidebar = .duplicates
        await pause(1.5)
        shot("31-duplicates-start")
        app.duplicates.scan(app)
        await pause(2)
        shot("32-duplicates-scanning")
        await waitUntil(300) { !app.duplicates.isScanning }
        await pause(4)
        shot("33-duplicates-results")
        if let g = app.duplicates.groups.first { app.duplicates.selectRecommended(in: g) }
        await pause(1.5)
        shot("34-duplicates-marked")
        app.duplicates.clearMarks()

        app.sidebar = .similar
        app.similar.scan(app)
        await waitUntil(300) { !app.similar.isScanning }
        await pause(4)
        shot("35-similar-results")

        // ---------- Export (real export into a temp folder → history), trash ----------
        var opts = ExportOptions.fromSettings
        opts.destinationPath = NSTemporaryDirectory() + "photoflow-tour-export"
        try? FileManager.default.createDirectory(atPath: opts.destinationPath, withIntermediateDirectories: true)
        app.runExport(Array(app.photos.prefix(3).map(\.id)), options: opts, source: "UI tour")
        await waitUntil(60) { app.activity == nil }
        await pause(2)
        // the export reveals its folder in Finder – hide Finder again so it does not cover later screenshots
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.hide()
        NSApp.activate(ignoringOtherApps: true)
        await pause(1)
        app.sidebar = .exportHistory
        await pause(2)
        shot("36-export-history")
        if let victim = app.photos.last { app.performTrash([victim.id]) }
        await pause(1.5)
        app.sidebar = .trash
        await pause(2.5)
        shot("37-trash")

        app.sidebar = .allPhotos
        await pause(1)
        app.exportRequest = Array(app.photos.prefix(3).map(\.id))
        await pause(3)
        shot("38-export-dialog", includeSheets: true)
        app.exportRequest = nil
        await pause(1)

        // Sidebar hidden via the keyboard shortcut path (menu command)
        // Optional full sidebar (⌃⌘S) – shown with the library and the tab bar
        app.sidebarVisible = true
        app.sidebar = .allPhotos
        if let f = app.visiblePhotos.first?.id { app.selection = [f]; app.lastClicked = f }
        await pause(2.5)
        shot("39-library-with-sidebar")
        app.sidebarVisible = false
        app.selection = []
        await pause(1)

        // Settings window
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        await pause(2)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) && $0.frame.width > 300 }) {
            shot("40-settings", window: settings)
            settings.close()
        }
        await aiTour(app, full: true)
        print("UITOUR: done → \(outDir.path)")
    }

    /// AI Studio: every section, real model download progress and – when a diffusion model is installed and
    /// PHOTOFLOW_TOUR_AI_GENERATE=1 – a real generation (progress + result). Nothing is staged.
    private static func aiTour(_ app: AppModel, full: Bool) async {
        let studio = AIStudioModel.shared
        let store = ModelStore.shared
        app.selection = []
        app.sidebar = .aiStudio
        store.reload()
        studio.section = .generate
        await pause(2.5); shot("41-ai-generate")
        check("AI Studio opens", app.sidebar == .aiStudio)
        studio.prompt = "bright scandinavian living room with large windows, oak floor, plants, morning light"
        studio.styleID = "realestate"
        studio.showAdvanced = true
        await pause(1.5); shot("42-ai-generate-prompt")
        studio.showAdvanced = false
        if ProcessInfo.processInfo.environment["PHOTOFLOW_TOUR_AI_GENERATE"] == "1", studio.activeModel != nil {
            studio.quality = .draft
            studio.variants = 1
            studio.generate()
            await waitUntil(240) { if case .steps(let s, _, _) = studio.job?.phase { return s >= 2 } else { return studio.job == nil } }
            shot("43-ai-generating")
            await waitUntil(1800) { studio.job == nil }
            await pause(2)
            shot("44-ai-result")
            check("AI generation produced a result", !studio.results.isEmpty)
        }
        if full {
            studio.prompt = "haus am see bei sonnenuntergang"
            studio.assist(.improve)
            await waitUntil(30) { studio.suggestion != nil }
            await pause(1); shot("45-ai-prompt-assistant")
            studio.suggestion = nil
        }

        studio.section = .models
        await pause(2.5); shot("46-ai-models")
        if full, let lama = AIModelCatalog.model("lama"), !store.isInstalled("lama") {
            store.download(lama)
            await waitUntil(120) { if case .downloading(let p) = store.state("lama") { return p.received > 20_000_000 } else { return false } }
            shot("47-ai-model-downloading")
            await waitUntil(900) { !store.state("lama").isBusy }
            check("Model download + verification", store.isInstalled("lama"))
            await pause(1); shot("47b-ai-model-installed")
        }

        if let p = app.photos.first(where: { $0.filename.hasPrefix("kodim23") }) ?? app.photos.first {
            studio.setSource(photo: p)
            await waitUntil(20) { studio.source != nil }
            studio.section = .fill
            studio.fillMode = .fill
            studio.mask.clear()
            studio.mask.operations.append(MaskDocument.Operation(tool: .brush, points: [CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.5, y: 0.46), CGPoint(x: 0.58, y: 0.42)], size: 0.08))
            studio.mask.operations.append(MaskDocument.Operation(tool: .ellipse, points: [CGPoint(x: 0.15, y: 0.6), CGPoint(x: 0.3, y: 0.85)], size: 0))
            await pause(2.5); shot("48-ai-fill-mask")
            studio.fillMode = .remove
            await pause(1.5); shot("49-ai-remove")
            if full && store.isInstalled("lama") {
                studio.runFill()
                await waitUntil(600) { studio.job == nil }
                await pause(2); shot("50-ai-remove-result")
                check("Object removal produced a result", studio.results.contains { $0.creation.kind == .remove })
            }
            studio.mask.clear()
            studio.fillMode = .background
            studio.selectSubject()
            await waitUntil(60) { studio.job == nil }
            await pause(2); shot("51-ai-background-subject")
            studio.section = .expand
            studio.expansion = AIEditWorkspace.toAspect(16.0 / 9, studio.source!.image)
            await pause(2.5); shot("52-ai-expand")
            studio.section = .enhance
            studio.enhanceKind = .backgroundBlur
            await pause(2); shot("53-ai-enhance")
            if full {
                studio.runEnhance()
                await waitUntil(120) { studio.job == nil }
                await pause(2); shot("54-ai-enhance-result")
            }
            studio.section = .upscale
            await pause(2); shot("55-ai-upscale")
            studio.section = .edit
            await pause(2); shot("56-ai-edit")
        }
        studio.section = .creations
        await pause(2.5); shot("57-ai-creations")
        studio.section = .generate
    }

    /// Reduced set for additional window sizes.
    private static func sizeTour(_ app: AppModel) async {
        app.sidebar = .allPhotos; await pause(3.5); shot("11-all-photos-mosaic")
        if let f = app.visiblePhotos.first?.id {
            app.selection = [f]; app.lastClicked = f
            await pause(2); shot("12-library-selection-inspector")
            app.openViewer(f); await pause(2); shot("13-viewer")
            app.viewerPhotoID = nil; await pause(1)
            app.openEditor(f); await pause(4); shot("22-editor-original")
            app.editorPhotoID = nil; await pause(1)
        }
        app.selection = []
        app.sidebar = .batch; await pause(4); shot("27-batch-setup")
        app.sidebar = .duplicates; app.duplicates.scan(app)
        await waitUntil(300) { !app.duplicates.isScanning }
        await pause(3); shot("33-duplicates-results")
        await aiTour(app, full: false)
        print("UITOUR: done → \(outDir.path)")
    }

    /// NSWindow keeps windows inside the visible screen; the CI display (1024×768) is smaller than the window
    /// sizes we must review, so the constraint is lifted for the tour process only.
    private static func unconstrainWindows() {
        guard let a = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))),
              let b = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.pf_tourConstrainFrameRect(_:to:))) else { return }
        method_exchangeImplementations(a, b)
    }

    // MARK: - Synthesized input (posted to the event queue like hardware events)

    /// `point` is in window coordinates with the origin at the top-left.
    static func click(_ window: NSWindow, at point: CGPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let h = window.contentView?.frame.height ?? window.frame.height
        let loc = NSPoint(x: point.x, y: h - point.y)
        for n in 1 ... count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
    }

    static func key(_ window: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags = [], chars override: String? = nil) {
        var chars: String
        switch code {
        case 49: chars = " "
        case 53: chars = "\u{1b}"
        case 124: chars = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case 123: chars = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case 6: chars = flags.contains(.shift) ? "Z" : "z"
        default: chars = ""
        }
        if let override { chars = override }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    // MARK: - Capture

    static func shot(_ name: String, window: NSWindow? = nil, includeSheets: Bool = false) {
        guard let w = window ?? mainWindow else { return }
        var image: CGImage?
        let fitsScreen = (w.screen ?? NSScreen.main).map { $0.frame.contains(w.frame) } ?? false
        // Screen-area capture includes sheets and the real compositor result (materials, glass) – used when
        // the window is fully on screen; otherwise capture the window itself (works beyond the display size).
        if fitsScreen || includeSheets, let screen = w.screen ?? NSScreen.main {
            let screenH = screen.frame.maxY
            var frame = w.frame
            if includeSheets, let sheet = w.attachedSheet { frame = frame.union(sheet.frame) }
            let rect = CGRect(x: frame.minX, y: screenH - frame.maxY, width: frame.width, height: frame.height)
            image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }
        if image == nil || isBlank(image!) {
            image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        }
        if includeSheets, !fitsScreen, let sheet = w.attachedSheet,
           let sheetImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            save(sheetImage, name: name + "-sheet")
        }
        if image == nil, let view = w.contentView?.superview ?? w.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep.cgImage
        }
        guard let cg = image else { print("UITOUR: capture failed \(name)"); return }
        save(cg, name: name)
    }

    private static func save(_ cg: CGImage, name: String) {
        let url = outDir.appendingPathComponent("\(prefix)-\(name).png")
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("UITOUR: \(url.lastPathComponent) \(cg.width)x\(cg.height)")
    }

    private static func isBlank(_ img: CGImage) -> Bool {
        img.width < 10 || img.height < 10
    }
}

extension NSWindow {
    @objc func pf_tourConstrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
