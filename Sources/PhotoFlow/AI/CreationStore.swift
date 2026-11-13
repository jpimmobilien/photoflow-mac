import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum AIOperationKind: String, Codable, CaseIterable, Identifiable {
    case textToImage, imageToImage, fill, expand, remove, background, enhance, upscale
    var id: String { rawValue }
    var title: String {
        switch self {
        case .textToImage: return String(localized: "Generated")
        case .imageToImage: return String(localized: "Image to image")
        case .fill: return String(localized: "Generative fill")
        case .expand: return String(localized: "Expanded")
        case .remove: return String(localized: "Object removed")
        case .background: return String(localized: "New background")
        case .enhance: return String(localized: "Optimised")
        case .upscale: return String(localized: "Upscaled")
        }
    }
    var symbol: String {
        switch self {
        case .textToImage: return "sparkles"
        case .imageToImage: return "photo.on.rectangle"
        case .fill: return "paintbrush.pointed"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .remove: return "eraser"
        case .background: return "person.and.background.dotted"
        case .enhance: return "wand.and.stars"
        case .upscale: return "arrow.up.forward.square"
        }
    }
    /// Fully generated vs. a photo edited with AI (IPTC digital source type).
    var isFullyGenerated: Bool { self == .textToImage }
}

/// One AI result with everything needed to understand and reproduce it.
struct AICreation: Codable, Identifiable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var kind: AIOperationKind
    var prompt: String = ""
    var negativePrompt: String = ""
    var styleID: String?
    var modelID: String
    var modelName: String
    var seed: UInt32?
    var steps: Int?
    var guidance: Double?
    var strength: Double?
    var quality: String?
    var aspect: String?
    var width: Int
    var height: Int
    var sourceName: String?
    var sourcePhotoID: Int64?
    var parentID: UUID?
    var duration: Double
    var note: String?
    var fileName: String
    var libraryPath: String?

    var settingsSummary: String {
        var p: [String] = []
        if let seed { p.append("Seed \(seed)") }
        if let steps { p.append(String(localized: "\(steps) steps")) }
        if let guidance { p.append(String(format: "CFG %.1f", guidance)) }
        if let strength { p.append(String(format: String(localized: "Strength %d %%"), Int(strength * 100))) }
        p.append("\(width) × \(height)")
        return p.joined(separator: " · ")
    }
}

/// Persistent history of AI results ("My AI Creations"). Images are stored as PNG in
/// ~/Library/Application Support/PhotoFlow/AI Studio/; nothing leaves the Mac.
@MainActor
final class CreationStore: ObservableObject {
    static let shared = CreationStore()

    @Published private(set) var creations: [AICreation] = []

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoFlow/AI Studio", isDirectory: true)
    }
    nonisolated static var imagesFolder: URL { folder.appendingPathComponent("Images", isDirectory: true) }
    private var indexURL: URL { Self.folder.appendingPathComponent("creations.json") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.imagesFolder, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL), let list = try? JSONDecoder.iso.decode([AICreation].self, from: d) {
            creations = list.filter { FileManager.default.fileExists(atPath: Self.imagesFolder.appendingPathComponent($0.fileName).path) }
        }
    }

    nonisolated static func imageURL(_ c: AICreation) -> URL { imagesFolder.appendingPathComponent(c.fileName) }

    /// Stores the image (PNG with AI metadata) and records the creation.
    @discardableResult
    func add(_ image: CGImage, _ creation: AICreation) throws -> AICreation {
        var c = creation
        c.fileName = c.id.uuidString + ".png"
        c.width = image.width
        c.height = image.height
        guard let data = AIMetadata.png(image, for: c) else { throw AIError.failed(String(localized: "The image could not be saved.")) }
        try data.write(to: Self.imageURL(c), options: .atomic)
        creations.insert(c, at: 0)
        persist()
        return c
    }

    func update(_ c: AICreation) {
        guard let i = creations.firstIndex(where: { $0.id == c.id }) else { return }
        creations[i] = c
        persist()
    }

    func delete(_ ids: Set<UUID>) {
        for c in creations where ids.contains(c.id) { try? FileManager.default.removeItem(at: Self.imageURL(c)) }
        creations.removeAll { ids.contains($0.id) }
        persist()
    }

    func image(_ c: AICreation) -> CGImage? { AIImage.loadPNG(Self.imageURL(c)) }

    var totalBytes: Int64 {
        creations.reduce(0) { acc, c in
            acc + ((try? FileManager.default.attributesOfItem(atPath: Self.imageURL(c).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func persist() {
        if let d = try? JSONEncoder.iso.encode(creations) { try? d.write(to: indexURL, options: .atomic) }
    }
}

/// Writes the AI provenance into the file: IPTC Digital Source Type (trainedAlgorithmicMedia for generated
/// images, compositeWithTrainedAlgorithmicMedia for AI edits), description, software, and PhotoFlow's own
/// XMP fields (model, prompt, seed, settings, source).
enum AIMetadata {
    static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString
    static let pfNS = "https://photoflow.app/ns/ai/1.0/" as CFString

    static func metadata(for c: AICreation) -> CGImageMetadata {
        let m = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(m, iptcExt, "Iptc4xmpExt" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(m, pfNS, "photoflow" as CFString, nil)
        func set(_ ns: CFString, _ prefix: String, _ name: String, _ value: String) {
            guard let tag = CGImageMetadataTagCreate(ns, prefix as CFString, name as CFString, .string, value as CFString) else { return }
            CGImageMetadataSetTagWithPath(m, nil, "\(prefix):\(name)" as CFString, tag)
        }
        let source = c.kind.isFullyGenerated
            ? "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
            : "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
        set(iptcExt, "Iptc4xmpExt", "DigitalSourceType", source)
        set(kCGImageMetadataNamespaceXMPBasic, "xmp", "CreatorTool", "PhotoFlow AI Studio · \(c.modelName)")
        set(kCGImageMetadataNamespaceXMPBasic, "xmp", "CreateDate", ISO8601DateFormatter().string(from: c.createdAt))
        let desc = c.prompt.isEmpty ? c.kind.title : c.prompt
        if let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "description" as CFString,
                                              .alternateText, ["x-default": desc] as CFDictionary) {
            CGImageMetadataSetTagWithPath(m, nil, "dc:description" as CFString, tag)
        }
        set(pfNS, "photoflow", "Operation", c.kind.rawValue)
        set(pfNS, "photoflow", "Model", "\(c.modelName) (\(c.modelID))")
        if !c.prompt.isEmpty { set(pfNS, "photoflow", "Prompt", c.prompt) }
        if !c.negativePrompt.isEmpty { set(pfNS, "photoflow", "NegativePrompt", c.negativePrompt) }
        if let s = c.styleID, s != "none" { set(pfNS, "photoflow", "Style", s) }
        if let seed = c.seed { set(pfNS, "photoflow", "Seed", String(seed)) }
        set(pfNS, "photoflow", "Settings", c.settingsSummary)
        if let src = c.sourceName { set(pfNS, "photoflow", "Source", src) }
        set(pfNS, "photoflow", "Local", "true")
        return m
    }

    static func png(_ image: CGImage, for c: AICreation) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(dest, image, metadata(for: c), nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func jpeg(_ image: CGImage, for c: AICreation, quality: Double = 0.92) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(dest, image, metadata(for: c),
                                              [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Reads back the digital source type (QA).
    static func digitalSourceType(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return nil }
        guard let m = CGImageMetadataCreateMutableCopy(md) else { return nil }
        CGImageMetadataRegisterNamespaceForPrefix(m, iptcExt, "Iptc4xmpExt" as CFString, nil)
        return CGImageMetadataCopyStringValueWithPath(m, nil, "Iptc4xmpExt:DigitalSourceType" as CFString) as String?
    }

    /// Folder for AI images added to the library.
    static var libraryFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoFlow AI", isDirectory: true)
    }

    static func libraryFileName(for c: AICreation) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let words = (c.prompt.isEmpty ? (c.sourceName ?? c.kind.title) : c.prompt)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(6).joined(separator: " ")
        let base = "\(f.string(from: c.createdAt)) \(words.isEmpty ? "AI" : words)"
        return String(base.prefix(80)) + ".png"
    }
}
