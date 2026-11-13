import Foundation
import CoreML
import Metal
import StableDiffusion

/// What the AI Studio can do on this Mac. Built on `HardwareProfile`, extended with the details that
/// matter for local generative models (chip generation, Neural Engine, free disk space, OS features).
struct AIHardware: Sendable {
    enum Tier: String, Sendable {
        case intel            // Intel Macs and Macs without a usable GPU
        case appleSiliconBase // Apple Silicon with less than 16 GB memory
        case appleSiliconPro  // Apple Silicon with 16 GB memory or more

        var title: String {
            switch self {
            case .intel: return String(localized: "Intel Mac")
            case .appleSiliconBase: return String(localized: "Apple Silicon (compact)")
            case .appleSiliconPro: return String(localized: "Apple Silicon (high-end)")
            }
        }
    }

    let base: HardwareProfile
    let chip: String
    let appleSiliconGeneration: Int?   // 1 = M1, 2 = M2 …
    let hasNeuralEngine: Bool
    let metalFamily: String?
    let osVersion: OperatingSystemVersion
    let tier: Tier

    static let current = AIHardware()

    var freeDiskBytes: Int64 { AIHardware.freeDisk() }

    private init() {
        base = HardwareProfile.current
        chip = AIHardware.sysctlString("machdep.cpu.brand_string") ?? base.modelIdentifier
        if base.architecture == .appleSilicon, let r = chip.range(of: #"M(\d)"#, options: .regularExpression) {
            appleSiliconGeneration = Int(chip[r].dropFirst())
        } else {
            appleSiliconGeneration = nil
        }
        hasNeuralEngine = base.architecture == .appleSilicon
        if let device = MTLCreateSystemDefaultDevice() {
            if device.supportsFamily(.apple7) { metalFamily = "Apple 7+" }
            else if device.supportsFamily(.mac2) { metalFamily = "Mac 2" }
            else { metalFamily = "Metal" }
        } else {
            metalFamily = nil
        }
        osVersion = ProcessInfo.processInfo.operatingSystemVersion
        if base.architecture == .intel || !base.hasMetal {
            tier = .intel
        } else if base.memoryGB < 15 {
            tier = .appleSiliconBase
        } else {
            tier = .appleSiliconPro
        }
    }

    var isIntel: Bool { base.architecture == .intel }

    /// A real Metal GPU (virtual machines expose an "Apple Paravirtual device" that cannot run the models reliably).
    var hasUsableGPU: Bool {
        base.hasMetal && !(base.gpuName ?? "").localizedCaseInsensitiveContains("paravirtual")
            && !UserDefaults.standard.bool(forKey: "forceCPURendering")
    }
    var memoryGB: Double { base.memoryGB }
    var supportsSDXL: Bool { osAtLeast(14) && base.architecture == .appleSilicon && memoryGB >= 15 }

    func osAtLeast(_ major: Int, _ minor: Int = 0) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
    }

    /// Whether a model can run here; nil = yes, otherwise the reason it cannot.
    func incompatibility(of model: AIModelDescriptor) -> String? {
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(model.minMacOS) {
            return String(localized: "Requires \(model.macOSRequirementText).")
        }
        if model.requiresAppleSilicon && base.architecture != .appleSilicon {
            return String(localized: "Requires a Mac with Apple Silicon.")
        }
        if model.kind == .diffusion && !base.hasMetal {
            return String(localized: "Requires a Metal graphics processor – Core ML cannot run this model correctly on the CPU alone.")
        }
        if memoryGB + 0.5 < model.minMemoryGB && ProcessInfo.processInfo.environment["PHOTOFLOW_IGNORE_MEMORY_LIMIT"] != "1" {
            return String(localized: "Requires at least \(Int(model.minMemoryGB)) GB memory (this Mac has \(Int(memoryGB.rounded())) GB).")
        }
        return nil
    }

    /// Soft warning for a model that runs, but not comfortably.
    func warning(for model: AIModelDescriptor) -> String? {
        if incompatibility(of: model) != nil { return nil }
        if model.kind == .diffusion && isIntel {
            return String(localized: "Intel Macs have no Neural Engine – expect several minutes per image.")
        }
        if memoryGB + 0.5 < model.recommendedMemoryGB {
            return String(localized: "Below the recommended \(Int(model.recommendedMemoryGB)) GB memory – close other apps while generating.")
        }
        return nil
    }

    /// The diffusion model recommended for this Mac.
    var recommendedDiffusionModelID: String {
        switch tier {
        case .intel: return "sd21-fp16"
        case .appleSiliconBase: return osAtLeast(14) ? "sd21-palettized" : "sd21-fp16"
        case .appleSiliconPro: return supportsSDXL ? "sdxl-mbp" : (osAtLeast(14) ? "sd21-palettized" : "sd21-fp16")
        }
    }

    /// How the diffusion pipeline is spread over CPU and GPU.
    struct DiffusionPlan: Equatable {
        var base: MLComputeUnits
        var overrides: [PipelineComponent: MLComputeUnits]
        var signature: String { "\(base.rawValue)-" + overrides.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ",") }
    }

    /// The catalog ships "original" attention variants, which Apple runs on the GPU (`.cpuAndGPU`).
    /// Measured with `--qa ai-diag` / `ai-t2i` on macOS 15: Core ML's CPU path cannot run these float16 models
    /// correctly (x86: the UNet fails, the VAE returns wrong values; Apple Silicon VM: noise instead of an image),
    /// so diffusion never falls back to the CPU – it needs a Metal GPU. On Intel the text encoder (numerically
    /// verified) runs on the CPU to leave GPU memory to the UNet.
    func diffusionPlan(safe: Bool) -> DiffusionPlan {
        if !base.hasMetal { return DiffusionPlan(base: .cpuOnly, overrides: [:]) }
        if isIntel { return DiffusionPlan(base: .cpuAndGPU, overrides: [.textEncoder: .cpuOnly]) }
        return DiffusionPlan(base: .cpuAndGPU, overrides: [:])
    }

    /// Low-memory mode loads model parts one after another instead of keeping all of them resident.
    func reduceMemory(for model: AIModelDescriptor, profile: AIPerformanceProfile) -> Bool {
        if profile == .energySaving { return true }
        if profile == .maximumSpeed && memoryGB >= model.recommendedMemoryGB * 1.5 { return false }
        return memoryGB < model.recommendedMemoryGB * 1.5
    }

    /// Upper limit for variants per run.
    var maxVariants: Int {
        switch tier {
        case .intel: return 2
        case .appleSiliconBase: return 2
        case .appleSiliconPro: return 4
        }
    }

    var summary: String {
        var parts = [chip, String(format: "%.0f GB", memoryGB)]
        if hasNeuralEngine { parts.append(String(localized: "Neural Engine")) }
        if let metalFamily { parts.append("Metal (\(metalFamily))") } else { parts.append(String(localized: "no Metal GPU")) }
        parts.append("macOS \(osVersion.majorVersion).\(osVersion.minorVersion)")
        return parts.joined(separator: " · ")
    }

    var backends: String {
        var b = ["Core ML (CPU)"]
        if base.hasMetal { b.append("Core ML (GPU)") }
        if hasNeuralEngine { b.append("Neural Engine") }
        return b.joined(separator: ", ")
    }

    static func freeDisk() -> Int64 {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, v > 0 {
            return v
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// User-selectable performance profile for AI work.
enum AIPerformanceProfile: String, CaseIterable, Identifiable, Sendable {
    case energySaving, balanced, maximumQuality, maximumSpeed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .energySaving: return String(localized: "Energy saving")
        case .balanced: return String(localized: "Balanced")
        case .maximumQuality: return String(localized: "Maximum quality")
        case .maximumSpeed: return String(localized: "Maximum speed")
        }
    }

    var detail: String {
        switch self {
        case .energySaving: return String(localized: "Fewer steps, low memory, one image at a time. Gentle on battery.")
        case .balanced: return String(localized: "Good quality at a reasonable speed.")
        case .maximumQuality: return String(localized: "More steps for finer detail. Takes longer.")
        case .maximumSpeed: return String(localized: "Fewer steps and models kept in memory.")
        }
    }

    /// Multiplier applied to the step count of the chosen quality level.
    var stepFactor: Double {
        switch self {
        case .energySaving: return 0.75
        case .balanced: return 1
        case .maximumQuality: return 1.25
        case .maximumSpeed: return 0.7
        }
    }

    static var current: AIPerformanceProfile {
        AIPerformanceProfile(rawValue: UserDefaults.standard.string(forKey: "aiPerformanceProfile") ?? "") ?? .balanced
    }
}
