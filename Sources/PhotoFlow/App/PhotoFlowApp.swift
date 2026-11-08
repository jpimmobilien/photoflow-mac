import SwiftUI
import AppKit

@main
struct PhotoFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(SettingsKeys.appearance) private var appearance = "system"

    init() {
        // Command-line QA harness: `PhotoFlow --qa <command> …` runs tests headless and exits.
        if CommandLine.arguments.contains("--qa") {
            QARunner.runAndExit(arguments: CommandLine.arguments)
        }
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("PhotoFlow", id: "main") {
            ContentView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { PhotoFlowCommands(model: AppModel.shared) }

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        Task { @MainActor in UITour.startIfRequested() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon or opened via "Open With → PhotoFlow".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.importItems(urls) }
    }
}

struct PhotoFlowCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Import Photos…")) { model.showImportPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(String(localized: "New Album")) { model.newAlbumRequest = Array(model.selection) }
                .keyboardShortcut("n", modifiers: [.command])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(String(localized: "Undo")) {
                if let e = model.activeEditor, e.canUndo { e.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z", modifiers: [.command])
            Button(String(localized: "Redo")) {
                if let e = model.activeEditor, e.canRedo { e.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(String(localized: "Select All Photos")) { model.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button(String(localized: "Copy Adjustments")) {
                if let id = model.selection.first { model.copyAdjustments(from: id) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.selection.count != 1)
            Button(String(localized: "Paste Adjustments")) { model.pasteAdjustments(to: Array(model.selection)) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model.selection.isEmpty)
        }
        CommandMenu(String(localized: "Photo")) {
            Button(String(localized: "Auto Enhance")) { model.autoEnhance(Array(model.selection)) }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(model.selection.isEmpty)
            Menu(String(localized: "Auto Enhance Strength")) {
                ForEach(EnhanceStrength.allCases) { s in
                    Button(s.localizedName) { model.autoEnhance(Array(model.selection), strength: s) }
                }
            }
            .disabled(model.selection.isEmpty)
            Button(String(localized: "Edit")) { if let id = model.selection.first { model.openEditor(id) } }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selection.count != 1)
            Button(String(localized: "Compare")) { model.compare(Array(model.selection)) }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(model.selection.isEmpty)
            Button(String(localized: "Restore Original")) { model.revertToOriginal(Array(model.selection)) }
                .disabled(model.selection.isEmpty)
            Divider()
            Button(String(localized: "Add to Favorites")) { model.toggleFavorite(Array(model.selection)) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            Button(String(localized: "Quick Look")) { model.quickLook(model.selection.first) }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(model.selection.isEmpty)
            Button(String(localized: "Reveal in Finder")) { model.reveal(Array(model.selection)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            Divider()
            Button(String(localized: "Export…")) { model.exportRequest = Array(model.selection) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            Divider()
            Button(String(localized: "Move to Trash")) { model.requestTrash(Array(model.selection)) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selection.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Button(String(localized: "PhotoFlow Privacy")) {
                model.alert = AppAlert(title: String(localized: "Your photos stay on your Mac"),
                                       message: String(localized: "PhotoFlow analyzes and edits photos entirely on this Mac using Apple's built-in frameworks. Nothing is uploaded, no account is required and there is no tracking."))
            }
        }
    }
}
