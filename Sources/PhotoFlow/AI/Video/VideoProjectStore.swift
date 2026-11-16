import Foundation
import AppKit

/// One finished video (generated or AI-edited). Stored in ~/Library/Application Support/PhotoFlow/AI Studio/Videos/.
struct VideoCreation: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case textToVideo, imageToVideo, videoToVideo, objectRemoval, backgroundReplace, optimize, upscale, extend

        var title: String {
            switch self {
            case .textToVideo: return String(localized: "Text to video")
            case .imageToVideo: return String(localized: "Animated photo")
            case .videoToVideo: return String(localized: "Video to video")
            case .objectRemoval: return String(localized: "Object removed")
            case .backgroundReplace: return String(localized: "Background replaced")
            case .optimize: return String(localized: "Optimised")
            case .upscale: return String(localized: "Upscaled")
            case .extend: return String(localized: "Extended")
            }
        }
        var generated: Bool { self == .textToVideo || self == .imageToVideo || self == .extend }
    }

    var id = UUID()
    var createdAt = Date()
    var kind: Kind
    var prompt: String = ""
    var negativePrompt: String = ""
    var modelID: String = ""
    var modelName: String = ""
    var seed: UInt32?
    var steps: Int = 0
    var width: Int = 0
    var height: Int = 0
    var frames: Int = 0
    var fps: Int = 0
    var seconds: Double = 0          // generation time
    var peakMemoryGB: Double?
    var sourceName: String?
    var sourcePath: String?
    var strength: Double?
    var fileName: String = ""
    var validation: String = ""      // summary of the content check

    var duration: Double { fps > 0 ? Double(frames) / Double(fps) : 0 }
}

@MainActor
final class VideoProjectStore: ObservableObject {
    static let shared = VideoProjectStore()
    @Published private(set) var items: [VideoCreation] = []

    nonisolated static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoFlow/AI Studio/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    nonisolated static var workFolder: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlowVideoJobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private var indexURL: URL { Self.folder.appendingPathComponent("videos.json") }

    private init() {
        if let d = try? Data(contentsOf: indexURL), let v = try? JSONDecoder.iso.decode([VideoCreation].self, from: d) {
            items = v.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.fileName).path) }
        }
    }

    func url(_ c: VideoCreation) -> URL { Self.folder.appendingPathComponent(c.fileName) }

    func add(_ c: VideoCreation) {
        items.insert(c, at: 0)
        save()
    }

    func delete(_ c: VideoCreation) {
        try? FileManager.default.removeItem(at: url(c))
        items.removeAll { $0.id == c.id }
        save()
    }

    private func save() {
        try? JSONEncoder.iso.encode(items).write(to: indexURL, options: .atomic)
    }
}
