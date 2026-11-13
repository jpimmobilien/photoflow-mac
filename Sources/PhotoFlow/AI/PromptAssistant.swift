import Foundation
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

/// Optional help for writing prompts. Uses Apple's on-device language model (macOS 26 with Apple
/// Intelligence) when it is available; otherwise transparent rule-based templates – labelled as such in
/// the UI. Generation never depends on it.
enum PromptAssistant {
    enum Mode: String, CaseIterable, Identifiable {
        case improve, details, photorealism, cameraLight, creative, shorten
        var id: String { rawValue }
        var title: String {
            switch self {
            case .improve: return String(localized: "Improve prompt")
            case .details: return String(localized: "Add details")
            case .photorealism: return String(localized: "More photorealistic")
            case .cameraLight: return String(localized: "Camera & light")
            case .creative: return String(localized: "More creative")
            case .shorten: return String(localized: "Shorten")
            }
        }
        var symbol: String {
            switch self {
            case .improve: return "wand.and.rays"
            case .details: return "text.badge.plus"
            case .photorealism: return "camera.aperture"
            case .cameraLight: return "light.max"
            case .creative: return "paintpalette"
            case .shorten: return "scissors"
            }
        }
        fileprivate var instruction: String {
            switch self {
            case .improve: return "Improve it into a clear, well-structured prompt: subject, setting, composition, light, mood."
            case .details: return "Add concrete visual details (materials, textures, colours, background elements) without changing the subject."
            case .photorealism: return "Make it describe a realistic photograph: natural light, realistic proportions, real materials."
            case .cameraLight: return "Add photographic camera and lighting details: lens, focal length, aperture, light direction and quality."
            case .creative: return "Make it more creative and surprising while keeping the main subject."
            case .shorten: return "Shorten it to the essential visual keywords (max. 25 words)."
            }
        }
    }

    struct Suggestion: Equatable {
        var text: String
        /// true = written by Apple's on-device language model, false = rule-based template.
        var byLanguageModel: Bool
    }

    static var languageModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static func suggest(_ prompt: String, mode: Mode) async -> Suggestion {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable, !trimmed.isEmpty {
            do {
                let session = LanguageModelSession(instructions: """
                    You rewrite prompts for a Stable Diffusion image generator. Always answer in English (translate if \
                    needed), as one line of comma-separated phrases, without quotes, explanations or lists.
                    """)
                let response = try await session.respond(to: "\(mode.instruction)\nPrompt: \(trimmed)")
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
                if !text.isEmpty { return Suggestion(text: text, byLanguageModel: true) }
            } catch {
                // fall through to templates
            }
        }
        #endif
        return Suggestion(text: template(trimmed, mode: mode), byLanguageModel: false)
    }

    /// Deterministic rule-based rewriting (no AI).
    static func template(_ prompt: String, mode: Mode) -> String {
        var parts = prompt.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func add(_ extra: [String]) {
            let lower = Set(parts.map { $0.lowercased() })
            for e in extra where !lower.contains(e.lowercased()) { parts.append(e) }
        }
        switch mode {
        case .improve: add(["well composed", "balanced light", "high detail", "professional photograph"])
        case .details: add(["intricate details", "fine textures", "rich background details", "sharp focus"])
        case .photorealism: add(["photorealistic", "natural lighting", "realistic proportions", "real materials", "high resolution photo"])
        case .cameraLight: add(["shot on a full-frame camera", "50mm lens", "f/2.8", "soft directional light", "natural shadows"])
        case .creative: add(["unexpected perspective", "dramatic atmosphere", "bold colour palette", "storytelling composition"])
        case .shorten:
            var seen = Set<String>()
            let filler: Set<String> = ["very", "really", "beautiful", "amazing", "a", "an", "the", "of", "with", "and"]
            parts = parts.compactMap { p in
                let words = p.split(separator: " ").filter { !filler.contains($0.lowercased()) }
                let s = words.joined(separator: " ")
                guard !s.isEmpty, seen.insert(s.lowercased()).inserted else { return nil }
                return s
            }
            parts = Array(parts.prefix(8))
        }
        return parts.joined(separator: ", ")
    }
}
