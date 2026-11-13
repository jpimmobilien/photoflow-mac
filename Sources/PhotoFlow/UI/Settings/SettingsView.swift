import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            ExportSettings().tabItem { Label(String(localized: "Export"), systemImage: "square.and.arrow.up") }
            PerformanceSettings().tabItem { Label(String(localized: "Performance"), systemImage: "speedometer") }
            DuplicateSettings().tabItem { Label(String(localized: "Duplicates"), systemImage: "square.on.square") }
            StorageSettings().tabItem { Label(String(localized: "Storage"), systemImage: "internaldrive") }
            PrivacySettings().tabItem { Label(String(localized: "Privacy"), systemImage: "lock.shield") }
        }
        .frame(width: 580)
        .padding(20)
        .tint(DS.Palette.blue)
    }
}

/// Brand header at the top of the General tab.
private struct SettingsBrandHeader: View {
    var body: some View {
        HStack(spacing: DS.Space.s) {
            BrandMark(size: 52)
                .shadow(color: DS.Palette.blue.opacity(0.25), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "PhotoFlow").font(DS.Font.title2)
                Text(String(localized: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")"))
                    .font(DS.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(String(localized: "100 % on-device"), systemImage: "lock.shield.fill")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.success)
        }
        .padding(.vertical, 4)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKeys.appearance) private var appearance = "system"
    @AppStorage(SettingsKeys.language) private var language = "system"
    @AppStorage(SettingsKeys.defaultStrength) private var strength = EnhanceStrength.balanced.rawValue
    @AppStorage(SettingsKeys.confirmDeletion) private var confirm = "always"
    @AppStorage(SettingsKeys.largeDeletionCount) private var largeCount = 10
    @AppStorage(SettingsKeys.validateOnLaunch) private var validate = true
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section { SettingsBrandHeader() }
            Picker(String(localized: "Appearance"), selection: $appearance) {
                Text(String(localized: "Automatic")).tag("system")
                Text(String(localized: "Light")).tag("light")
                Text(String(localized: "Dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            Picker(String(localized: "Language"), selection: Binding(get: { language }, set: { AppSettings.applyLanguage($0); language = $0; languageChanged = true })) {
                Text(String(localized: "System Default")).tag("system")
                Text("English").tag("en")
                Text("Deutsch").tag("de")
            }
            if languageChanged {
                Text(String(localized: "The new language is used after restarting PhotoFlow.")).font(.caption).foregroundStyle(.orange)
            }
            Picker(String(localized: "Default Auto Enhance strength"), selection: $strength) {
                ForEach(EnhanceStrength.allCases) { Text($0.localizedName).tag($0.rawValue) }
            }
            Picker(String(localized: "Confirm before moving to Trash"), selection: $confirm) {
                Text(String(localized: "Always")).tag("always")
                Text(String(localized: "Only for many photos")).tag("large")
                Text(String(localized: "Never")).tag("never")
            }
            if confirm == "large" {
                Stepper(String(localized: "Ask from \(largeCount) photos"), value: $largeCount, in: 2 ... 500)
            }
            Toggle(String(localized: "Check for moved or missing originals at launch"), isOn: $validate)
        }
        .formStyle(.grouped)
    }
}

private struct ExportSettings: View {
    @AppStorage(SettingsKeys.exportFormat) private var format = ExportFormat.jpeg.rawValue
    @AppStorage(SettingsKeys.exportQuality) private var quality = 0.9
    @AppStorage(SettingsKeys.exportDestination) private var destination = ""

    var body: some View {
        Form {
            Picker(String(localized: "Default format"), selection: $format) {
                ForEach(ExportFormat.available) { Text($0.displayName).tag($0.rawValue) }
            }
            HStack {
                Text(String(localized: "Default quality"))
                Slider(value: $quality, in: 0.3 ... 1)
                Text(verbatim: "\(Int(quality * 100)) %").monospacedDigit().frame(width: 44)
            }
            HStack {
                Text(String(localized: "Destination"))
                Spacer()
                Text(ExportOptions.defaultDestination.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button(String(localized: "Choose…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { destination = url.path }
                }
                if !destination.isEmpty {
                    Button(String(localized: "Reset")) { destination = "" }
                }
            }
            Text(String(localized: "Supported on this Mac: \(ExportFormat.available.filter { $0 != .original }.map(\.displayName).joined(separator: ", "))"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceSettings: View {
    @AppStorage(SettingsKeys.concurrencyMode) private var mode = "auto"
    @AppStorage(SettingsKeys.manualConcurrency) private var manual = 2
    @AppStorage(SettingsKeys.forceCPU) private var forceCPU = false
    @AppStorage(SettingsKeys.thumbnailQuality) private var thumbQuality = "standard"
    private let hw = HardwareProfile.current

    var body: some View {
        Form {
            LabeledContent(String(localized: "This Mac"), value: hw.summary)
            LabeledContent(String(localized: "Model"), value: hw.modelIdentifier)
            Picker(String(localized: "Parallel processing"), selection: $mode) {
                Text(String(localized: "Automatic (\(hw.recommendedBatchConcurrency) at a time)")).tag("auto")
                Text(String(localized: "Manual")).tag("manual")
            }
            if mode == "manual" {
                Stepper(String(localized: "\(manual) photos at a time"), value: $manual, in: 1 ... 12)
                Text(String(localized: "Higher values are faster on powerful Macs but use more memory. Older Intel Macs work best with 1–2."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(String(localized: "Use CPU rendering instead of GPU (Metal)"), isOn: $forceCPU)
            Text(String(localized: "Only needed for troubleshooting graphics problems. Takes effect after restart."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(String(localized: "Thumbnail quality"), selection: $thumbQuality) {
                Text(String(localized: "Low (fastest)")).tag("low")
                Text(String(localized: "Standard")).tag("standard")
                Text(String(localized: "High")).tag("high")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DuplicateSettings: View {
    @AppStorage(SettingsKeys.duplicateSensitivity) private var dup = 95.0
    @AppStorage(SettingsKeys.similarSensitivity) private var sim = 80.0
    @AppStorage(SettingsKeys.thresholdVerySimilar) private var very = 95.0
    @AppStorage(SettingsKeys.thresholdSimilar) private var similar = 85.0
    @AppStorage(SettingsKeys.thresholdPossibly) private var possibly = 70.0

    var body: some View {
        Form {
            Section(String(localized: "Default sensitivity")) {
                sliderRow(String(localized: "Duplicate Finder"), $dup, 85 ... 99)
                sliderRow(String(localized: "Similar Photos"), $sim, 70 ... 95)
            }
            Section(String(localized: "Similarity categories")) {
                sliderRow(String(localized: "Very similar from"), $very, 90 ... 99)
                sliderRow(String(localized: "Similar from"), $similar, 75 ... 95)
                sliderRow(String(localized: "Possibly similar from"), $possibly, 55 ... 85)
                Text(String(localized: "Scores combine file hashes, perceptual hashes and Apple's on-device image feature prints. They are practical guides, not mathematical guarantees – always review groups before deleting."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
            Text(verbatim: "\(Int(value.wrappedValue)) %").monospacedDigit().frame(width: 44)
        }
    }
}

private struct StorageSettings: View {
    @EnvironmentObject private var app: AppModel
    @State private var cacheSize: Int64 = 0
    @State private var confirmClearAnalysis = false

    var body: some View {
        Form {
            LabeledContent(String(localized: "Library database"), value: app.store?.directory.path ?? "–")
            LabeledContent(String(localized: "Thumbnail cache"), value: cacheSize.formattedBytes)
            HStack {
                Button(String(localized: "Clear Thumbnail Cache")) {
                    ThumbnailService.shared.clearAll()
                    cacheSize = ThumbnailService.shared.diskUsage()
                }
                Button(String(localized: "Clear Analysis Cache…")) { confirmClearAnalysis = true }
                Button(String(localized: "Show in Finder")) {
                    if let dir = app.store?.directory { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
            }
            Text(String(localized: "Caches only contain previews and analysis results. Your original photos and edits are not affected."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { cacheSize = ThumbnailService.shared.diskUsage() }
        .confirmationDialog(String(localized: "Clear the analysis cache?"), isPresented: $confirmClearAnalysis) {
            Button(String(localized: "Clear"), role: .destructive) { try? app.store?.clearAnalysisCache() }
        } message: {
            Text(String(localized: "The next duplicate scan will analyze all photos again."))
        }
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Label(String(localized: "All image analysis runs locally on this Mac."), systemImage: "checkmark.shield.fill")
            Label(String(localized: "No photos or data are uploaded. No cloud AI services are used."), systemImage: "icloud.slash")
            Label(String(localized: "No account, no analytics, no tracking."), systemImage: "eye.slash")
            Label(String(localized: "Works completely offline."), systemImage: "wifi.slash")
            Text(String(localized: "PhotoFlow uses Apple's built-in on-device frameworks (Vision, Core Image, Core ML runtime, Accelerate). These models are part of macOS – PhotoFlow does not download any models. macOS may ask for permission when you open photos in protected folders such as Desktop, Documents or Downloads."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
