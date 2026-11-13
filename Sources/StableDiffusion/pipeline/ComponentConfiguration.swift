// PhotoFlow addition (not part of apple/ml-stable-diffusion).
// Lets the app choose compute units per pipeline component, e.g. UNet on the GPU and the VAE on the CPU.

import CoreML
import Foundation

public enum PipelineComponent: String, Sendable {
    case textEncoder, unet, vaeDecoder, vaeEncoder
}

public enum ComponentConfiguration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [PipelineComponent: MLComputeUnits] = [:]

    /// Compute units to use for individual components; components not listed use the pipeline configuration.
    public static func set(_ map: [PipelineComponent: MLComputeUnits]) {
        lock.lock(); overrides = map; lock.unlock()
    }

    static func resolve(_ component: PipelineComponent, _ base: MLModelConfiguration) -> MLModelConfiguration {
        lock.lock(); let units = overrides[component]; lock.unlock()
        guard let units, units != base.computeUnits, let copy = base.copy() as? MLModelConfiguration else { return base }
        copy.computeUnits = units
        return copy
    }
}
