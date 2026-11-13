import Foundation

// MARK: - Model catalog
//
// Every model PhotoFlow can download. Nothing here is bundled with the app: the user downloads models
// from the original publisher (Hugging Face repositories of Apple / Stability AI) or from PhotoFlow's own
// GitHub release (Core ML conversions of the official Real-ESRGAN / LaMa weights, built by a public
// workflow in this repository). Every file is pinned to an exact revision and verified by SHA-256.

enum AIModelKind: String, Codable, Sendable {
    case diffusion      // text-to-image, image-to-image, inpainting, outpainting
    case upscaler       // Real-ESRGAN
    case inpainter      // LaMa (object removal)
}

enum DiffusionFamily: String, Codable, Sendable {
    case sd21           // Stable Diffusion 2.1 base, 512 px
    case sdxl           // Stable Diffusion XL base, 1024 px
}

enum AICapability: String, Codable, CaseIterable, Sendable {
    case textToImage, imageToImage, inpainting, outpainting, objectRemoval, upscaling, denoise

    var title: String {
        switch self {
        case .textToImage: return String(localized: "Text to image")
        case .imageToImage: return String(localized: "Image to image")
        case .inpainting: return String(localized: "Generative fill")
        case .outpainting: return String(localized: "Expand image")
        case .objectRemoval: return String(localized: "Object removal")
        case .upscaling: return String(localized: "Upscaling")
        case .denoise: return String(localized: "Noise reduction")
        }
    }
}

struct AILicense: Hashable, Sendable {
    var name: String
    var url: URL
    var privateUse: Bool
    var commercialUse: Bool
    /// Plain-language summary shown in model management.
    var summary: String
    var restrictions: String
}

struct AIModelFile: Codable, Hashable, Sendable {
    var path: String       // relative path inside the model folder (or archive name)
    var url: URL
    var size: Int64
    var sha256: String
}

struct AIModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let developer: String
    let kind: AIModelKind
    let family: DiffusionFamily?
    let license: AILicense
    let capabilities: [AICapability]
    let files: [AIModelFile]
    /// Files are zipped .mlpackage archives that are extracted and compiled after download.
    let isArchive: Bool
    let revision: String
    let version: String
    let sourcePage: URL
    /// Native square resolution in pixels (diffusion) or tile size (upscaler / inpainter).
    let resolution: Int
    /// Upscaling factor (upscalers only).
    let scale: Int
    let minMemoryGB: Double
    let recommendedMemoryGB: Double
    let minMacOS: OperatingSystemVersion
    /// Apple Silicon only (too slow / too much memory on Intel to be useful).
    let requiresAppleSilicon: Bool
    let hardwareNote: String
    let detail: String

    var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }
    /// Approximate space on disk once installed (archives are extracted and compiled).
    var installedSize: Int64 { isArchive ? downloadSize * 2 : downloadSize }

    static func == (a: AIModelDescriptor, b: AIModelDescriptor) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var macOSRequirementText: String {
        minMacOS.patchVersion > 0 ? "macOS \(minMacOS.majorVersion).\(minMacOS.minorVersion).\(minMacOS.patchVersion)"
            : minMacOS.minorVersion > 0 ? "macOS \(minMacOS.majorVersion).\(minMacOS.minorVersion)" : "macOS \(minMacOS.majorVersion)"
    }
}

enum AIModelCatalog {
    static let openRAIL = AILicense(
        name: "CreativeML Open RAIL++-M",
        url: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-2-1-base/blob/main/LICENSE.md")!,
        privateUse: true, commercialUse: true,
        summary: String(localized: "Private and commercial use of the model and of generated images is allowed. You own the images you create."),
        restrictions: String(localized: "Use-based restrictions apply (no illegal content, no harassment, no deception, no medical advice, no exploitation of minors …). Redistributing the weights requires passing on the same licence."))
    static let openRAILXL = AILicense(
        name: "CreativeML Open RAIL++-M",
        url: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/main/LICENSE.md")!,
        privateUse: true, commercialUse: true,
        summary: openRAIL.summary, restrictions: openRAIL.restrictions)
    static let bsd3 = AILicense(
        name: "BSD 3-Clause",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE")!,
        privateUse: true, commercialUse: true,
        summary: String(localized: "Permissive licence: private and commercial use allowed."),
        restrictions: String(localized: "Keep the copyright notice when redistributing the model."))
    static let apache2 = AILicense(
        name: "Apache 2.0",
        url: URL(string: "https://github.com/advimman/lama/blob/main/LICENSE")!,
        privateUse: true, commercialUse: true,
        summary: String(localized: "Permissive licence: private and commercial use allowed."),
        restrictions: String(localized: "Keep the licence and notices when redistributing the model."))

    private static let v13_1 = OperatingSystemVersion(majorVersion: 13, minorVersion: 1, patchVersion: 0)
    private static let v13 = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
    private static let v14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    static let all: [AIModelDescriptor] = {
        let data = AIModelCatalogData.decoded
        func files(_ id: String) -> (String, [AIModelFile]) {
            guard let e = data[id] else { return ("", []) }
            return (e.revision, e.files)
        }
        let diffusionCaps: [AICapability] = [.textToImage, .imageToImage, .inpainting, .outpainting]
        var list: [AIModelDescriptor] = []

        let (r1, f1) = files("sd21-fp16")
        list.append(AIModelDescriptor(
            id: "sd21-fp16", name: "Stable Diffusion 2.1", developer: "Stability AI · Core ML by Apple",
            kind: .diffusion, family: .sd21, license: openRAIL, capabilities: diffusionCaps, files: f1, isArchive: false,
            revision: r1, version: "2.1 base · float16",
            sourcePage: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base")!,
            resolution: 512, scale: 1, minMemoryGB: 8, recommendedMemoryGB: 16, minMacOS: v13_1,
            requiresAppleSilicon: false,
            hardwareNote: String(localized: "Runs on Apple Silicon and Intel. On Intel Macs generation takes several minutes per image."),
            detail: String(localized: "The most compatible model: 512 × 512 pixels, works on macOS 13.1 and on Intel Macs.")))

        let (r2, f2) = files("sd21-palettized")
        list.append(AIModelDescriptor(
            id: "sd21-palettized", name: "Stable Diffusion 2.1 Compact", developer: "Stability AI · Core ML by Apple",
            kind: .diffusion, family: .sd21, license: openRAIL, capabilities: diffusionCaps, files: f2, isArchive: false,
            revision: r2, version: "2.1 base · 6-bit palettized",
            sourcePage: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized")!,
            resolution: 512, scale: 1, minMemoryGB: 6, recommendedMemoryGB: 8, minMacOS: v14,
            requiresAppleSilicon: false,
            hardwareNote: String(localized: "Smallest download. Best for Apple Silicon Macs with 8 GB memory."),
            detail: String(localized: "Same model as Stable Diffusion 2.1 with compressed weights: less than half the download and memory.")))

        let (r3, f3) = files("sdxl-mbp")
        list.append(AIModelDescriptor(
            id: "sdxl-mbp", name: "Stable Diffusion XL", developer: "Stability AI · Core ML by Apple",
            kind: .diffusion, family: .sdxl, license: openRAILXL, capabilities: diffusionCaps, files: f3, isArchive: false,
            revision: r3, version: "1.0 base · 4.5-bit mixed palettization",
            sourcePage: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization")!,
            resolution: 1024, scale: 1, minMemoryGB: 16, recommendedMemoryGB: 16, minMacOS: v14,
            requiresAppleSilicon: true,
            hardwareNote: String(localized: "Apple Silicon with at least 16 GB memory. Not offered on Intel Macs (far too slow)."),
            detail: String(localized: "High-quality 1024 × 1024 images with much better detail and composition. Recommended for M-series Macs.")))

        let (r4, f4) = files("sdxl-fp16")
        list.append(AIModelDescriptor(
            id: "sdxl-fp16", name: "Stable Diffusion XL (full precision)", developer: "Stability AI · Core ML by Apple",
            kind: .diffusion, family: .sdxl, license: openRAILXL, capabilities: diffusionCaps, files: f4, isArchive: false,
            revision: r4, version: "1.0 base · float16",
            sourcePage: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-xl-base")!,
            resolution: 1024, scale: 1, minMemoryGB: 24, recommendedMemoryGB: 32, minMacOS: v14,
            requiresAppleSilicon: true,
            hardwareNote: String(localized: "Apple Silicon with 32 GB memory or more."),
            detail: String(localized: "Uncompressed SDXL weights – maximum quality for high-end Macs.")))

        let release = "https://github.com/jpimmobilien/photoflow-mac/releases/download/ai-models-v1/"
        let esrganPage = URL(string: "https://github.com/xinntao/Real-ESRGAN")!
        for (id, name, scale, caps, detail) in [
            ("realesrgan-x4plus", "Real-ESRGAN x4plus", 4, [AICapability.upscaling],
             String(localized: "Photo-realistic 4× upscaling with reconstructed detail.")),
            ("realesrgan-x2plus", "Real-ESRGAN x2plus", 2, [AICapability.upscaling],
             String(localized: "Photo-realistic 2× upscaling; also used to restore detail.")),
            ("realesr-general-x4v3", "Real-ESRGAN General v3", 4, [AICapability.upscaling, .denoise],
             String(localized: "Small, fast model for upscaling and removing noise and compression artefacts."))
        ] {
            guard let e = data[id] else { continue }
            list.append(AIModelDescriptor(
                id: id, name: name, developer: "Xintao Wang et al. · Core ML conversion by PhotoFlow",
                kind: .upscaler, family: nil, license: bsd3, capabilities: caps,
                files: e.files.map { AIModelFile(path: $0.path, url: URL(string: release + $0.path)!, size: $0.size, sha256: $0.sha256) },
                isArchive: true, revision: e.revision, version: "Core ML · tile 256", sourcePage: esrganPage,
                resolution: 256, scale: scale, minMemoryGB: 4, recommendedMemoryGB: 8, minMacOS: v13,
                requiresAppleSilicon: false,
                hardwareNote: String(localized: "Runs on every supported Mac."), detail: detail))
        }
        if let e = data["lama"] {
            list.append(AIModelDescriptor(
                id: "lama", name: "LaMa (Big-LaMa)", developer: "Samsung AI Center · Core ML conversion by PhotoFlow",
                kind: .inpainter, family: nil, license: apache2, capabilities: [.objectRemoval],
                files: e.files.map { AIModelFile(path: $0.path, url: URL(string: release + $0.path)!, size: $0.size, sha256: $0.sha256) },
                isArchive: true, revision: e.revision, version: "Big-LaMa · Core ML 800 px",
                sourcePage: URL(string: "https://github.com/advimman/lama")!,
                resolution: 800, scale: 1, minMemoryGB: 4, recommendedMemoryGB: 8, minMacOS: v13,
                requiresAppleSilicon: false,
                hardwareNote: String(localized: "Runs on every supported Mac."),
                detail: String(localized: "Specialised model that removes objects and fills the gap with matching surroundings.")))
        }
        return list.filter { !$0.files.isEmpty }
    }()

    static func model(_ id: String) -> AIModelDescriptor? { all.first { $0.id == id } }
    static var diffusionModels: [AIModelDescriptor] { all.filter { $0.kind == .diffusion } }
    static var upscalers: [AIModelDescriptor] { all.filter { $0.kind == .upscaler } }
}

/// Decoded form of the embedded catalog JSON (`AIModelCatalogData.json`).
struct AIModelCatalogEntry: Codable {
    var revision: String
    var files: [AIModelFile]
}

extension AIModelCatalogData {
    static let decoded: [String: AIModelCatalogEntry] = {
        guard let d = json.data(using: .utf8),
              let v = try? JSONDecoder().decode([String: AIModelCatalogEntry].self, from: d) else { return [:] }
        return v
    }()
}
