import Foundation
import CoreGraphics

/// Non-destructive edit description. The original file is never modified; a recipe is stored in the
/// library database and applied on the fly for previews, thumbnails and exports.
///
/// Units (chosen to match the UI sliders):
/// - `exposure`: EV stops (−3…+3)
/// - most tonal/colour controls: −100…+100 (0 = unchanged)
/// - `sharpness`, `noiseReduction`: 0…100
/// - `rotation`: degrees (−45…+45), positive = counter-clockwise; `quarterTurns`: multiples of 90° CCW
/// - `perspectiveVertical` / `perspectiveHorizontal`: −100…+100 (keystone strength)
struct EditRecipe: Codable, Equatable, Hashable, Sendable {
    // Light
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    // Colour
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    // Detail
    var sharpness: Double = 0
    var noiseReduction: Double = 0
    var clarity: Double = 0
    // Effects
    var monochrome: Bool = false
    // Geometry
    var rotation: Double = 0
    var quarterTurns: Int = 0
    var perspectiveVertical: Double = 0
    var perspectiveHorizontal: Double = 0
    /// Optional crop in normalized coordinates of the geometry-corrected image (origin top-left).
    var crop: NormalizedRect?
    /// Document rectification: 4 corners (TL, TR, BR, BL) as normalized x,y pairs, origin bottom-left,
    /// in the coordinates of the oriented original. When set, the document is cut out and rectified first.
    var documentCorners: [Double]?

    /// Information about the last automatic analysis (for display only).
    var auto: AutoEnhanceInfo?

    static let identity = EditRecipe()

    var isIdentity: Bool {
        var copy = self
        copy.auto = nil
        return copy == EditRecipe.identity
    }

    var hasGeometry: Bool {
        rotation != 0 || quarterTurns % 4 != 0 || perspectiveVertical != 0 || perspectiveHorizontal != 0
            || crop != nil || documentCorners != nil
    }

    /// Only the tonal/colour part (used by presets and for "copy adjustments").
    var adjustmentsOnly: EditRecipe {
        var r = self
        r.rotation = 0; r.quarterTurns = 0; r.perspectiveVertical = 0; r.perspectiveHorizontal = 0
        r.crop = nil; r.documentCorners = nil
        return r
    }

    mutating func adoptGeometry(from other: EditRecipe) {
        rotation = other.rotation
        quarterTurns = other.quarterTurns
        perspectiveVertical = other.perspectiveVertical
        perspectiveHorizontal = other.perspectiveHorizontal
        crop = other.crop
        documentCorners = other.documentCorners
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> EditRecipe? { try? JSONDecoder().decode(EditRecipe.self, from: data) }

    /// Stable hash used for cache keys of rendered thumbnails.
    var cacheKey: String {
        var copy = self
        copy.auto = nil
        let data = (try? JSONEncoder.sorted.encode(copy)) ?? Data()
        var h: UInt64 = 1469598103934665603
        for b in data { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}

struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool { abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6 }
}

enum EnhanceStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    case subtle, balanced, strong
    var id: String { rawValue }

    var factor: Double {
        switch self {
        case .subtle: return 0.55
        case .balanced: return 1.0
        case .strong: return 1.4
        }
    }

    var localizedName: String {
        switch self {
        case .subtle: return String(localized: "Subtle")
        case .balanced: return String(localized: "Balanced")
        case .strong: return String(localized: "Strong")
        }
    }
}

/// What the automatic engine found and decided – shown to the user so "AI" is never a black box.
struct AutoEnhanceInfo: Codable, Equatable, Hashable, Sendable {
    var strength: EnhanceStrength
    var analyzedAt: Date
    var sceneLabels: [String]
    var faceCount: Int
    var notes: [String]
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
