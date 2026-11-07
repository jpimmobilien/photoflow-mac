import Foundation
import Metal
import CoreImage

/// Describes the Mac PhotoFlow runs on and derives safe processing limits from it.
/// Intel Macs (e.g. MacBook Pro 2017) get fewer parallel jobs and smaller memory budgets than Apple Silicon.
struct HardwareProfile: Sendable {
    enum Architecture: String, Sendable { case appleSilicon = "Apple Silicon", intel = "Intel" }

    let architecture: Architecture
    let runningUnderRosetta: Bool
    let physicalMemory: UInt64
    let activeCores: Int
    let gpuName: String?
    let hasMetal: Bool
    let modelIdentifier: String

    static let current = HardwareProfile()

    private init() {
        #if arch(arm64)
        let native = Architecture.appleSilicon
        #else
        let native = Architecture.intel
        #endif
        let translated = HardwareProfile.sysctlInt("sysctl.proc_translated") == 1
        // A Rosetta-translated x86_64 process is still running on Apple Silicon hardware.
        architecture = translated ? .appleSilicon : native
        runningUnderRosetta = translated
        physicalMemory = ProcessInfo.processInfo.physicalMemory
        activeCores = ProcessInfo.processInfo.activeProcessorCount
        let device = MTLCreateSystemDefaultDevice()
        hasMetal = device != nil
        gpuName = device?.name
        modelIdentifier = HardwareProfile.sysctlString("hw.model") ?? "Mac"
    }

    var memoryGB: Double { Double(physicalMemory) / 1_073_741_824 }

    /// Number of photos processed in parallel during batch operations ("Automatic" setting).
    var recommendedBatchConcurrency: Int {
        let byCores: Int
        switch architecture {
        case .appleSilicon: byCores = max(2, min(6, activeCores / 2))
        case .intel: byCores = max(1, min(3, activeCores / 3))
        }
        // Rough budget: ~1.2 GB per in-flight full-resolution render.
        let byMemory = max(1, Int(memoryGB / 4))
        return max(1, min(byCores, byMemory))
    }

    /// Parallel workers for lightweight analysis (thumbnails, hashes, feature prints).
    var recommendedAnalysisConcurrency: Int {
        switch architecture {
        case .appleSilicon: return max(2, min(8, activeCores - 2))
        case .intel: return max(2, min(4, activeCores / 2))
        }
    }

    /// Memory budget (bytes) for full-resolution images decoded at the same time.
    var renderMemoryBudget: UInt64 { physicalMemory / 4 }

    var summary: String {
        var s = "\(architecture.rawValue) · \(activeCores) cores · \(String(format: "%.0f", memoryGB)) GB"
        if let gpuName { s += " · \(gpuName)" }
        if runningUnderRosetta { s += " · Rosetta" }
        return s
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Shared Core Image contexts. CIContext is thread-safe and expensive to create, so we keep one per purpose.
enum CIContextProvider {
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// GPU (Metal) when available, otherwise Core Image's CPU renderer – works on every supported Mac.
    static let shared: CIContext = makeContext(software: !HardwareProfile.current.hasMetal || UserDefaults.standard.bool(forKey: "forceCPURendering"))

    /// CPU context for analysis code that reads pixels back (avoids GPU round-trips for tiny images).
    static let cpu: CIContext = makeContext(software: true)

    private static func makeContext(software: Bool) -> CIContext {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: workingSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ]
        if software {
            options[.useSoftwareRenderer] = true
            return CIContext(options: options)
        }
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        options[.useSoftwareRenderer] = true
        return CIContext(options: options)
    }
}

/// Resident memory of this process (used for QA reports and adaptive throttling).
enum MemoryMonitor {
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
