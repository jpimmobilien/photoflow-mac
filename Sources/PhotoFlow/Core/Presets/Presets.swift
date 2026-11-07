import Foundation

/// A look that can be applied to one photo or a whole batch.
/// *Adaptive* presets first run the automatic analysis for each photo and then add the preset's style on top,
/// so "Bright" brightens a dark photo more than an already bright one.
struct Preset: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var recipe: EditRecipe      // style offsets (tonal/colour only)
    var adaptive: Bool
    var isBuiltIn: Bool
    var symbol: String = "camera.filters"

    var localizedName: String { isBuiltIn ? String(localized: String.LocalizationValue(name)) : name }

    /// Applies the preset to an existing (possibly auto-enhanced) recipe, keeping geometry.
    func apply(to base: EditRecipe) -> EditRecipe {
        var r = base
        let s = recipe
        r.exposure = clamp(base.exposure + s.exposure, -3, 3)
        r.brightness = clamp(base.brightness + s.brightness)
        r.contrast = clamp(base.contrast + s.contrast)
        r.highlights = clamp(base.highlights + s.highlights)
        r.shadows = clamp(base.shadows + s.shadows)
        r.whites = clamp(base.whites + s.whites)
        r.blacks = clamp(base.blacks + s.blacks)
        r.temperature = clamp(base.temperature + s.temperature)
        r.tint = clamp(base.tint + s.tint)
        r.saturation = clamp(base.saturation + s.saturation)
        r.vibrance = clamp(base.vibrance + s.vibrance)
        r.sharpness = clamp(base.sharpness + s.sharpness, 0, 100)
        r.noiseReduction = clamp(max(base.noiseReduction, s.noiseReduction), 0, 100)
        r.clarity = clamp(base.clarity + s.clarity)
        r.monochrome = base.monochrome || s.monochrome
        return r
    }

    private func clamp(_ v: Double, _ lo: Double = -100, _ hi: Double = 100) -> Double { min(hi, max(lo, v)) }

    // MARK: - Built-in presets (names are localization keys)

    static let builtIn: [Preset] = [
        Preset(id: "natural", name: "Natural", recipe: EditRecipe(vibrance: 4), adaptive: true, isBuiltIn: true, symbol: "leaf"),
        Preset(id: "bright", name: "Bright", recipe: EditRecipe(exposure: 0.25, brightness: 12, shadows: 15, whites: 10), adaptive: true, isBuiltIn: true, symbol: "sun.max"),
        Preset(id: "warm", name: "Warm", recipe: EditRecipe(temperature: 14, tint: 3, vibrance: 6), adaptive: true, isBuiltIn: true, symbol: "flame"),
        Preset(id: "cool", name: "Cool", recipe: EditRecipe(temperature: -14, tint: -2), adaptive: true, isBuiltIn: true, symbol: "snowflake"),
        Preset(id: "vivid", name: "Vivid", recipe: EditRecipe(contrast: 12, saturation: 10, vibrance: 25, clarity: 8), adaptive: true, isBuiltIn: true, symbol: "paintpalette"),
        Preset(id: "landscape", name: "Landscape", recipe: EditRecipe(contrast: 8, highlights: -15, vibrance: 18, clarity: 18), adaptive: true, isBuiltIn: true, symbol: "mountain.2"),
        Preset(id: "portrait", name: "Portrait", recipe: EditRecipe(brightness: 5, contrast: -4, shadows: 10, temperature: 4, vibrance: -4, clarity: -8), adaptive: true, isBuiltIn: true, symbol: "person.crop.square"),
        Preset(id: "bw", name: "Black and White", recipe: EditRecipe(contrast: 18, whites: 8, blacks: -8, clarity: 10, monochrome: true), adaptive: true, isBuiltIn: true, symbol: "circle.lefthalf.filled"),
        Preset(id: "clean", name: "Professional Clean", recipe: EditRecipe(brightness: 6, contrast: 6, highlights: -10, whites: 8, blacks: -6, vibrance: 6, sharpness: 10), adaptive: true, isBuiltIn: true, symbol: "sparkles"),
        Preset(id: "soft", name: "Soft Contrast", recipe: EditRecipe(contrast: -14, highlights: -12, shadows: 14, blacks: 8, clarity: -6), adaptive: true, isBuiltIn: true, symbol: "cloud")
    ]

    static func preset(id: String, custom: [Preset] = []) -> Preset? {
        builtIn.first { $0.id == id } ?? custom.first { $0.id == id }
    }
}

// Localization keys for built-in preset names (extracted by the strings checker).
private let _presetNameKeys: [String.LocalizationValue] = [
    "Natural", "Bright", "Warm", "Cool", "Vivid", "Landscape", "Portrait", "Black and White", "Professional Clean", "Soft Contrast"
]
