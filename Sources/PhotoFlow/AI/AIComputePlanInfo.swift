import Foundation
import CoreML

/// Where Core ML actually places a model's operations (CPU / GPU / Neural Engine), read from `MLComputePlan`
/// (macOS 14.4+). This answers "does it really run on Metal?" instead of trusting the requested compute units.
enum AIComputePlanInfo {
    struct Usage: Codable, CustomStringConvertible {
        var cpu = 0, gpu = 0, neuralEngine = 0
        var total: Int { cpu + gpu + neuralEngine }
        var description: String {
            guard total > 0 else { return "no ops" }
            func pct(_ v: Int) -> Int { Int((Double(v) / Double(total) * 100).rounded()) }
            return "GPU \(pct(gpu)) %, Neural Engine \(pct(neuralEngine)) %, CPU \(pct(cpu)) % of \(total) ops"
        }
    }

    /// Synchronous wrapper (call off the main thread).
    static func usage(modelAt url: URL, units: MLComputeUnits) -> Usage? {
        guard #available(macOS 14.4, *) else { return nil }
        final class Box: @unchecked Sendable { var value: Usage? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await load(url, units)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 600)
        return box.value
    }

    @available(macOS 14.4, *)
    private static func load(_ url: URL, _ units: MLComputeUnits) async -> Usage? {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        guard let plan = try? await MLComputePlan.load(contentsOf: url, configuration: cfg) else { return nil }
        guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else { return nil }
        var u = Usage()
        func visit(_ ops: [MLModelStructure.Program.Operation]) {
            for op in ops {
                if let d = plan.deviceUsage(for: op) {
                    switch d.preferred {
                    case .cpu: u.cpu += 1
                    case .gpu: u.gpu += 1
                    case .neuralEngine: u.neuralEngine += 1
                    @unknown default: u.cpu += 1
                    }
                }
                for b in op.blocks { visit(b.operations) }
            }
        }
        visit(main.block.operations)
        return u
    }

    /// Placement of the UNet (the expensive part) for a diffusion model with the plan PhotoFlow uses.
    static func unetSummary(for model: AIModelDescriptor) -> String {
        let url = ModelStore.directory(for: model.id).appendingPathComponent("Unet.mlmodelc")
        let plan = AIHardware.current.diffusionPlan(for: model)
        let units = plan.overrides[.unet] ?? plan.base
        guard let u = usage(modelAt: url, units: units) else { return "compute plan unavailable (macOS 14.4+)" }
        return "UNet: " + u.description
    }
}
