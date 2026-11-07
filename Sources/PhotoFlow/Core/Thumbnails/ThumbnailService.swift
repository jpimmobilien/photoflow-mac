import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Limits how many expensive operations run at once (e.g. decoding while the user scrolls a 10,000-photo grid).
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = max(1, limit) }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }

    func run<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { Task { await self.release() } }
        return try await work()
    }
}

/// Two-level thumbnail cache: memory (NSCache) + disk (JPEG files in ~/Library/Caches).
/// Thumbnails of edited photos are rendered with their recipe so the grid always shows the current state.
final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let memory = NSCache<NSString, CGImageBox>()
    private let directory: URL
    private let limiter = AsyncLimiter(limit: HardwareProfile.current.recommendedAnalysisConcurrency)

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ i: CGImage) { image = i }
    }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = caches.appendingPathComponent("de.photoflow.app/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 1500
        memory.totalCostLimit = 300 * 1024 * 1024
    }

    /// Pixel size for grid thumbnails, from the "Thumbnail quality" setting.
    static var gridPixelSize: Int {
        switch UserDefaults.standard.string(forKey: SettingsKeys.thumbnailQuality) ?? "standard" {
        case "high": return 640
        case "low": return 256
        default: return 420
        }
    }

    func cachedImage(for photo: PhotoRecord, recipe: EditRecipe?, pixelSize: Int) -> CGImage? {
        memory.object(forKey: key(photo, recipe, pixelSize) as NSString)?.image
    }

    func thumbnail(for photo: PhotoRecord, recipe: EditRecipe?, pixelSize: Int) async -> CGImage? {
        let k = key(photo, recipe, pixelSize)
        if let hit = memory.object(forKey: k as NSString) { return hit.image }
        return await limiter.run { [self] () -> CGImage? in
            if Task.isCancelled { return nil }
            if let hit = memory.object(forKey: k as NSString) { return hit.image }
            let file = directory.appendingPathComponent(k + ".jpg")
            if let disk = Self.load(file) {
                store(disk, key: k)
                return disk
            }
            guard let made = Self.make(photo: photo, recipe: recipe, pixelSize: pixelSize) else { return nil }
            store(made, key: k)
            Self.write(made, to: file)
            return made
        }
    }

    func invalidate(photoID: Int64) {
        // Memory entries are keyed by recipe hash, so stale entries simply stop being requested.
        // Remove disk files for this photo to reclaim space.
        let prefix = "\(photoID)-"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for f in files where f.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(f))
            }
        }
    }

    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func diskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    var cacheDirectory: URL { directory }

    // MARK: - Internals

    private func key(_ p: PhotoRecord, _ recipe: EditRecipe?, _ size: Int) -> String {
        let r = (recipe?.isIdentity ?? true) ? "o" : recipe!.cacheKey
        return "\(p.id)-\(p.fileSignature)-\(r)-\(size)"
    }

    private func store(_ image: CGImage, key: String) {
        memory.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    static func make(photo: PhotoRecord, recipe: EditRecipe?, pixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let recipe, !recipe.isIdentity else {
                return ImageLoader.thumbnail(url: photo.url, maxPixel: pixelSize, preferEmbedded: true)
            }
            // Render edits on a slightly larger base so geometry crops keep enough pixels.
            guard let base = ImageLoader.thumbnail(url: photo.url, maxPixel: Int(Double(pixelSize) * 1.3), preferEmbedded: true) else { return nil }
            let out = RenderPipeline.apply(recipe, to: CIImage(cgImage: base))
            let scale = Double(pixelSize) / Double(max(out.extent.width, out.extent.height))
            let final = scale < 1 ? out.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : out
            return CIContextProvider.shared.createCGImage(final, from: final.extent.integral, format: .RGBA8,
                                                          colorSpace: CIContextProvider.sRGB)
        }
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
