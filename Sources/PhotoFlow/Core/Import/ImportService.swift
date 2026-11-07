import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads file and image metadata without decoding pixels (ImageIO header parsing only).
enum MetadataReader {
    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func record(for url: URL, importedAt: Date = Date()) -> PhotoRecord? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src) as String? else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] ?? [:]
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        // Orientations 5–8 swap width and height for display.
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&width, &height) }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var capture: Date?
        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            capture = exifDateFormatter.date(from: s)
        }
        let isoValue = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first

        return PhotoRecord(
            id: 0, path: url.path, bookmark: bookmark(for: url), filename: url.lastPathComponent,
            fileSize: Int64(values.fileSize ?? 0), fileModified: values.contentModificationDate ?? Date(),
            width: width, height: height, uti: type, captureDate: capture, creationDate: values.creationDate,
            cameraMake: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            lensModel: exif[kCGImagePropertyExifLensModel] as? String,
            iso: isoValue,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            importedAt: importedAt, editedAt: nil, isFavorite: false, isMissing: false)
    }

    /// Bookmarks let PhotoFlow find files again after they were renamed or moved on the same volume.
    /// Inside the App Sandbox a security-scoped bookmark is required to regain access after relaunch.
    static func bookmark(for url: URL) -> Data? {
        let options: URL.BookmarkCreationOptions = Sandbox.isActive ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
        return try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Full metadata dictionary of the original (used for export metadata preservation and the info panel).
    static func properties(of url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }
}

enum Sandbox {
    static var isActive: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }
}

/// Imports files and folders into the library. Runs off the main thread; reports progress.
final class ImportService: @unchecked Sendable {
    struct Progress: Sendable {
        var scanned: Int
        var total: Int
        var imported: Int
        var skipped: Int
    }

    struct Result: Sendable {
        var imported: [PhotoRecord]
        var duplicatesSkipped: Int
        var unreadable: [String]
    }

    private let store: LibraryStore

    init(store: LibraryStore) { self.store = store }

    /// Expands folders recursively (skipping hidden files and packages such as .photoslibrary).
    static func collectImageURLs(from urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in e where PhotoFormat.isImportable(file) {
                    out.append(file.standardizedFileURL)
                }
            } else if PhotoFormat.isImportable(url) {
                out.append(url.standardizedFileURL)
            }
        }
        return out
    }

    func importItems(_ urls: [URL], progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        let files = Self.collectImageURLs(from: urls)
        let known = try store.knownPaths()
        let candidates = files.filter { !known.contains($0.path) }
        let skipped = files.count - candidates.count
        let importedAt = Date()
        var imported: [PhotoRecord] = []
        var unreadable: [String] = []
        progress(Progress(scanned: 0, total: candidates.count, imported: 0, skipped: skipped))

        // Metadata reading is I/O bound: process in parallel chunks, insert per chunk.
        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var index = 0
        for chunk in candidates.chunked(into: 64) {
            try Task.checkCancellation()
            let records: [(URL, PhotoRecord?)] = await withTaskGroup(of: (Int, URL, PhotoRecord?).self) { group in
                var results: [(Int, URL, PhotoRecord?)] = []
                var next = 0
                while next < min(workers, chunk.count) {
                    let i = next, url = chunk[i]
                    group.addTask { (i, url, MetadataReader.record(for: url, importedAt: importedAt)) }
                    next += 1
                }
                while let r = await group.next() {
                    results.append(r)
                    if next < chunk.count {
                        let i = next, url = chunk[i]
                        group.addTask { (i, url, MetadataReader.record(for: url, importedAt: importedAt)) }
                        next += 1
                    }
                }
                return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            }
            let valid = records.compactMap { $0.1 }
            unreadable += records.filter { $0.1 == nil }.map { $0.0.path }
            imported += try store.insert(valid)
            index += chunk.count
            progress(Progress(scanned: index, total: candidates.count, imported: imported.count, skipped: skipped))
        }
        return Result(imported: imported, duplicatesSkipped: skipped, unreadable: unreadable)
    }
}

/// Detects moved, renamed or deleted originals and repairs references using bookmarks.
enum LibraryValidator {
    struct Outcome: Sendable {
        var relocated: [(id: Int64, path: String)]
        var missing: [Int64]
        var found: [Int64]
        var changed: [Int64]
    }

    static func validate(_ photos: [PhotoRecord]) -> Outcome {
        var outcome = Outcome(relocated: [], missing: [], found: [], changed: [])
        let fm = FileManager.default
        for p in photos {
            if fm.fileExists(atPath: p.path) {
                if p.isMissing { outcome.found.append(p.id) }
                if let v = try? p.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   Int64(v.fileSize ?? 0) != p.fileSize ||
                    abs((v.contentModificationDate ?? p.fileModified).timeIntervalSince(p.fileModified)) > 1 {
                    outcome.changed.append(p.id)
                }
                continue
            }
            if let data = p.bookmark {
                var stale = false
                let options: URL.BookmarkResolutionOptions = Sandbox.isActive ? [.withSecurityScope, .withoutUI] : [.withoutUI, .withoutMounting]
                if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale),
                   fm.fileExists(atPath: url.path) {
                    outcome.relocated.append((p.id, url.path))
                    continue
                }
            }
            if !p.isMissing { outcome.missing.append(p.id) }
        }
        return outcome
    }
}
