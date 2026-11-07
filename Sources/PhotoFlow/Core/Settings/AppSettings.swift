import Foundation

/// UserDefaults keys (also used with @AppStorage in the UI).
enum SettingsKeys {
    static let appearance = "appearance"                     // system | light | dark
    static let language = "languageOverride"                 // system | en | de
    static let exportFormat = "exportFormat"
    static let exportQuality = "exportQuality"
    static let exportDestination = "exportDestination"
    static let concurrencyMode = "concurrencyMode"           // auto | manual
    static let manualConcurrency = "manualConcurrency"
    static let forceCPU = "forceCPURendering"
    static let duplicateSensitivity = "duplicateSensitivity" // minimum similarity score, 70…99
    static let similarSensitivity = "similarSensitivity"
    static let thresholdVerySimilar = "thresholdVerySimilar"
    static let thresholdSimilar = "thresholdSimilar"
    static let thresholdPossibly = "thresholdPossibly"
    static let confirmDeletion = "confirmDeletion"           // always | large | never
    static let largeDeletionCount = "largeDeletionCount"
    static let thumbnailQuality = "thumbnailQuality"         // low | standard | high
    static let defaultStrength = "defaultEnhanceStrength"
    static let validateOnLaunch = "validateLibraryOnLaunch"
}

enum AppSettings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.appearance: "system",
            SettingsKeys.language: "system",
            SettingsKeys.exportFormat: ExportFormat.jpeg.rawValue,
            SettingsKeys.exportQuality: 0.9,
            SettingsKeys.concurrencyMode: "auto",
            SettingsKeys.manualConcurrency: HardwareProfile.current.recommendedBatchConcurrency,
            SettingsKeys.forceCPU: false,
            SettingsKeys.duplicateSensitivity: 95.0,
            SettingsKeys.similarSensitivity: 80.0,
            SettingsKeys.thresholdVerySimilar: 95.0,
            SettingsKeys.thresholdSimilar: 85.0,
            SettingsKeys.thresholdPossibly: 70.0,
            SettingsKeys.confirmDeletion: "always",
            SettingsKeys.largeDeletionCount: 10,
            SettingsKeys.thumbnailQuality: "standard",
            SettingsKeys.defaultStrength: EnhanceStrength.balanced.rawValue,
            SettingsKeys.validateOnLaunch: true
        ])
    }

    static var batchConcurrency: Int {
        let d = UserDefaults.standard
        if d.string(forKey: SettingsKeys.concurrencyMode) == "manual" {
            return max(1, min(16, d.integer(forKey: SettingsKeys.manualConcurrency)))
        }
        return HardwareProfile.current.recommendedBatchConcurrency
    }

    static var defaultStrength: EnhanceStrength {
        EnhanceStrength(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.defaultStrength) ?? "") ?? .balanced
    }

    static var similarityThresholds: SimilarityThresholds {
        let d = UserDefaults.standard
        return SimilarityThresholds(verySimilar: d.double(forKey: SettingsKeys.thresholdVerySimilar),
                                    similar: d.double(forKey: SettingsKeys.thresholdSimilar),
                                    possibly: d.double(forKey: SettingsKeys.thresholdPossibly))
    }

    /// Applies the language override (takes effect on next launch).
    static func applyLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: SettingsKeys.language)
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }
}
