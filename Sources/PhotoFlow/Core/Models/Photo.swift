import Foundation
import UniformTypeIdentifiers

/// A photograph referenced by the library. The original file is never copied or modified;
/// PhotoFlow only stores its location (path + bookmark) and metadata.
struct PhotoRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var path: String
    var bookmark: Data?
    var filename: String
    var fileSize: Int64
    var fileModified: Date
    var width: Int
    var height: Int
    var uti: String
    var captureDate: Date?
    var creationDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var exposureTime: Double?
    var fNumber: Double?
    var focalLength: Double?
    var importedAt: Date
    var editedAt: Date?
    var isFavorite: Bool
    var isMissing: Bool

    var url: URL { URL(fileURLWithPath: path) }

    /// The date most meaningful to users: when the picture was taken, falling back to file dates.
    var displayDate: Date { captureDate ?? creationDate ?? fileModified }

    var megapixels: Double { Double(width * height) / 1_000_000 }

    var isEdited: Bool { editedAt != nil }

    var formatName: String { PhotoFormat.displayName(forUTI: uti) }

    var isRAW: Bool { PhotoFormat.isRAW(uti) }

    /// Signature used to invalidate caches when the file changes on disk.
    var fileSignature: String { "\(fileSize)-\(Int64(fileModified.timeIntervalSince1970 * 1000))" }

    var cameraDescription: String? {
        let parts = [cameraMake, cameraModel].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // Avoid "Canon Canon EOS R5"
        if parts.count == 2, parts[1].lowercased().hasPrefix(parts[0].lowercased()) { return parts[1] }
        return parts.joined(separator: " ")
    }

    var exposureDescription: String? {
        var items: [String] = []
        if let f = fNumber { items.append(String(format: "ƒ/%.1f", f)) }
        if let t = exposureTime {
            items.append(t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))s")
        }
        if let iso { items.append("ISO \(iso)") }
        if let fl = focalLength { items.append(String(format: "%.0f mm", fl)) }
        return items.isEmpty ? nil : items.joined(separator: "  ·  ")
    }
}

enum PhotoFormat {
    static let rawUTIs: Set<String> = [
        "public.camera-raw-image", "com.adobe.raw-image", "com.canon.cr2-raw-image", "com.canon.cr3-raw-image",
        "com.canon.crw-raw-image", "com.nikon.raw-image", "com.nikon.nrw-raw-image", "com.sony.raw-image",
        "com.sony.arw-raw-image", "com.sony.sr2-raw-image", "com.fuji.raw-image", "com.olympus.raw-image",
        "com.olympus.or-raw-image", "com.panasonic.raw-image", "com.panasonic.rw2-raw-image", "com.pentax.raw-image",
        "com.leica.raw-image", "com.leica.rwl-raw-image", "com.hasselblad.3fr-raw-image", "com.hasselblad.fff-raw-image",
        "com.phaseone.raw-image", "com.samsung.raw-image", "com.sigma.raw-image", "com.apple.raw-image",
        "com.adobe.dng"
    ]

    static func isRAW(_ uti: String) -> Bool {
        if rawUTIs.contains(uti) { return true }
        if let t = UTType(uti), t.conforms(to: .rawImage) { return true }
        return false
    }

    static func displayName(forUTI uti: String) -> String {
        switch uti {
        case "public.jpeg": return "JPEG"
        case "public.png": return "PNG"
        case "public.tiff": return "TIFF"
        case "public.heic", "public.heif": return "HEIC"
        case "org.webmproject.webp": return "WebP"
        case "com.compuserve.gif": return "GIF"
        case "com.microsoft.bmp": return "BMP"
        case "com.adobe.dng": return "DNG"
        default:
            if isRAW(uti) { return "RAW" }
            return UTType(uti)?.preferredFilenameExtension?.uppercased() ?? "Image"
        }
    }

    /// File extensions PhotoFlow imports. ImageIO decides the final word when the file is opened.
    static let importableExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "tif", "tiff", "heic", "heif", "hif", "webp", "gif", "bmp",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
        "rwl", "3fr", "fff", "iiq", "srw", "x3f", "raw", "erf", "mos", "mrw"
    ]

    static func isImportable(_ url: URL) -> Bool {
        importableExtensions.contains(url.pathExtension.lowercased())
    }
}

/// User-created album. Membership is stored separately (many-to-many).
struct Album: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var createdAt: Date
    var photoCount: Int = 0
}

/// A record of a file PhotoFlow moved to the macOS Trash, so it can be restored later.
struct TrashEntry: Identifiable, Hashable, Sendable {
    var id: Int64
    var originalPath: String
    var trashPath: String
    var filename: String
    var fileSize: Int64
    var trashedAt: Date
    var photoID: Int64?
}

/// One completed export job (shown in Export History).
struct ExportHistoryEntry: Identifiable, Hashable, Sendable {
    var id: Int64
    var date: Date
    var destination: String
    var format: String
    var count: Int
    var failed: Int
    var totalBytes: Int64
    var source: String
}
