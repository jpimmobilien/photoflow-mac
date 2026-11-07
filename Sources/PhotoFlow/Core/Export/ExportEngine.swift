import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, jpeg, heic, png, tiff, webp
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return String(localized: "Same as Original")
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .webp: return "WebP"
        }
    }

    var utType: UTType? {
        switch self {
        case .original: return nil
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        case .tiff: return .tiff
        case .webp: return .webP
        }
    }

    var fileExtension: String {
        switch self {
        case .original: return ""
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .png: return "png"
        case .tiff: return "tif"
        case .webp: return "webp"
        }
    }

    var isLossy: Bool { self == .jpeg || self == .heic || self == .webp || self == .original }

    /// Whether ImageIO on this Mac can write the format (HEIC and WebP depend on the macOS version).
    var isSupported: Bool {
        guard let t = utType else { return true }
        return ExportFormat.writableTypes.contains(t.identifier)
    }

    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static var available: [ExportFormat] { allCases.filter(\.isSupported) }
}

enum ExportColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case sRGB, displayP3
    var id: String { rawValue }
    var displayName: String { self == .sRGB ? "sRGB" : "Display P3" }
    var cgColorSpace: CGColorSpace { self == .sRGB ? CIContextProvider.sRGB : CIContextProvider.displayP3 }
}

struct WatermarkOptions: Codable, Hashable, Sendable {
    enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottomRight, bottomLeft, topRight, topLeft, center
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .bottomRight: return String(localized: "Bottom Right")
            case .bottomLeft: return String(localized: "Bottom Left")
            case .topRight: return String(localized: "Top Right")
            case .topLeft: return String(localized: "Top Left")
            case .center: return String(localized: "Center")
            }
        }
    }
    var text: String = "© "
    var position: Position = .bottomRight
    var opacity: Double = 0.6
    var relativeSize: Double = 0.03   // text height as a fraction of the image's short side
}

struct ExportOptions: Codable, Hashable, Sendable {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.9
    var maxLongSide: Int?
    var destinationPath: String = ExportOptions.defaultDestination.path
    var filenamePattern: String = "{name}"
    var preserveMetadata: Bool = true
    var stripLocation: Bool = false
    var colorSpace: ExportColorSpace = .sRGB
    var applyEdits: Bool = true
    var watermark: WatermarkOptions?

    var destination: URL { URL(fileURLWithPath: destinationPath, isDirectory: true) }

    static var defaultDestination: URL {
        if let custom = UserDefaults.standard.string(forKey: SettingsKeys.exportDestination), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("Processed Photos", isDirectory: true)
    }

    /// Defaults from Settings.
    static var fromSettings: ExportOptions {
        var o = ExportOptions()
        let d = UserDefaults.standard
        if let f = d.string(forKey: SettingsKeys.exportFormat).flatMap(ExportFormat.init(rawValue:)), f.isSupported { o.format = f }
        let q = d.double(forKey: SettingsKeys.exportQuality)
        if q > 0 { o.quality = q }
        return o
    }

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case originalQuality, highQuality, webOptimized, smallFile, socialMedia
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .originalQuality: return String(localized: "Original Quality")
            case .highQuality: return String(localized: "High Quality")
            case .webOptimized: return String(localized: "Web Optimized")
            case .smallFile: return String(localized: "Small File Size")
            case .socialMedia: return String(localized: "Social Media")
            }
        }
        var detail: String {
            switch self {
            case .originalQuality: return String(localized: "Full resolution, maximum quality")
            case .highQuality: return String(localized: "Full resolution JPEG, 92 %")
            case .webOptimized: return String(localized: "2048 px, sRGB, no location data")
            case .smallFile: return String(localized: "1600 px, compact file")
            case .socialMedia: return String(localized: "2160 px, sRGB, no location data")
            }
        }
    }

    mutating func apply(_ p: Preset) {
        switch p {
        case .originalQuality:
            format = .original; quality = 1.0; maxLongSide = nil; preserveMetadata = true; stripLocation = false
        case .highQuality:
            format = .jpeg; quality = 0.92; maxLongSide = nil; preserveMetadata = true
        case .webOptimized:
            format = .jpeg; quality = 0.8; maxLongSide = 2048; colorSpace = .sRGB; stripLocation = true
        case .smallFile:
            format = ExportFormat.heic.isSupported ? .heic : .jpeg; quality = 0.62; maxLongSide = 1600
        case .socialMedia:
            format = .jpeg; quality = 0.88; maxLongSide = 2160; colorSpace = .sRGB; stripLocation = true
        }
    }
}

/// Renders and writes exported photos. Originals are never touched: the engine refuses to write onto
/// an existing file and picks a unique name instead.
enum ExportEngine {
    enum ExportError: LocalizedError {
        case cannotCreate(String), writeFailed(String), sourceMissing(String), destinationIsOriginal
        var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return String(localized: "The destination “\(p)” could not be created.")
            case .writeFailed(let name): return String(localized: "“\(name)” could not be written.")
            case .sourceMissing(let name): return String(localized: "The original of “\(name)” is missing.")
            case .destinationIsOriginal: return String(localized: "Export would overwrite an original – skipped.")
            }
        }
    }

    struct Output: Sendable { var url: URL; var bytes: Int64 }

    static func prepareDestination(_ options: ExportOptions) throws {
        do {
            try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        } catch {
            throw ExportError.cannotCreate(options.destination.path)
        }
    }

    static func export(photo: PhotoRecord, recipe: EditRecipe?, options: ExportOptions, counter: Int) throws -> Output {
        let fm = FileManager.default
        guard fm.fileExists(atPath: photo.path) else { throw ExportError.sourceMissing(photo.filename) }
        let edits = options.applyEdits ? (recipe ?? .identity) : .identity

        var format = options.format
        let sourceExt = photo.url.pathExtension
        // Lossless pass-through copy when nothing changes.
        if format == .original && edits.isIdentity && options.maxLongSide == nil && options.watermark == nil
            && options.preserveMetadata && !options.stripLocation {
            let target = uniqueURL(for: photo, options: options, ext: sourceExt, counter: counter)
            try guardNotOriginal(target, photo)
            try fm.copyItem(at: photo.url, to: target)
            return Output(url: target, bytes: fileSize(target))
        }
        if format == .original {
            format = ExportFormat.from(uti: photo.uti) ?? .jpeg
        }
        if !format.isSupported { format = .jpeg }

        return try autoreleasepool { () throws -> Output in
            var image = try ImageLoader.full(url: photo.url, uti: photo.uti)
            image = RenderPipeline.apply(edits, to: image)
            if let m = options.maxLongSide {
                let long = max(image.extent.width, image.extent.height)
                if long > CGFloat(m) {
                    let s = CGFloat(m) / long
                    image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                    image = image.cropped(to: image.extent.integral).normalizedToOrigin()
                }
            }
            if let wm = options.watermark, !wm.text.trimmingCharacters(in: .whitespaces).isEmpty {
                image = Watermarker.apply(wm, to: image)
            }
            let sixteenBit = format == .tiff
            guard let cg = CIContextProvider.shared.createCGImage(
                image, from: image.extent.integral,
                format: sixteenBit ? .RGBA16 : .RGBA8,
                colorSpace: options.colorSpace.cgColorSpace) else {
                throw ExportError.writeFailed(photo.filename)
            }
            let target = uniqueURL(for: photo, options: options, ext: format.fileExtension, counter: counter)
            try guardNotOriginal(target, photo)
            guard let type = format.utType,
                  let dest = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
                throw ExportError.writeFailed(photo.filename)
            }
            var props = options.preserveMetadata ? MetadataReader.properties(of: photo.url) : [:]
            props = sanitize(props, stripLocation: options.stripLocation || !options.preserveMetadata, width: cg.width, height: cg.height)
            if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = options.quality }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                try? fm.removeItem(at: target)
                throw ExportError.writeFailed(photo.filename)
            }
            return Output(url: target, bytes: fileSize(target))
        }
    }

    /// Keeps EXIF/IPTC/TIFF metadata but resets orientation (pixels are already upright) and dimensions.
    static func sanitize(_ input: [CFString: Any], stripLocation: Bool, width: Int, height: Int) -> [CFString: Any] {
        var p = input
        p[kCGImagePropertyOrientation] = 1
        p.removeValue(forKey: kCGImagePropertyPixelWidth)
        p.removeValue(forKey: kCGImagePropertyPixelHeight)
        p.removeValue(forKey: kCGImagePropertyDepth)
        p.removeValue(forKey: kCGImagePropertyProfileName)
        p.removeValue(forKey: kCGImagePropertyColorModel)
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            tiff[kCGImagePropertyTIFFSoftware] = "PhotoFlow"
            p[kCGImagePropertyTIFFDictionary] = tiff
        } else {
            p[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFSoftware: "PhotoFlow"]
        }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            p[kCGImagePropertyExifDictionary] = exif
        }
        if stripLocation { p.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        // RAW-specific dictionaries do not apply to the rendered output.
        p.removeValue(forKey: kCGImagePropertyDNGDictionary)
        p.removeValue(forKey: kCGImagePropertyRawDictionary)
        return p
    }

    static func filename(for photo: PhotoRecord, pattern: String, counter: Int) -> String {
        let base = (photo.filename as NSString).deletingPathExtension
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var name = pattern.isEmpty ? "{name}" : pattern
        name = name.replacingOccurrences(of: "{name}", with: base)
        name = name.replacingOccurrences(of: "{date}", with: df.string(from: photo.displayDate))
        name = name.replacingOccurrences(of: "{counter}", with: String(format: "%04d", counter))
        name = name.replacingOccurrences(of: "{width}", with: String(photo.width))
        name = name.replacingOccurrences(of: "{height}", with: String(photo.height))
        // Remove characters that are invalid in file names
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? base : name
    }

    /// Never overwrites: "Name.jpg" → "Name (2).jpg" → "Name (3).jpg" …
    private static let nameLock = NSLock()
    nonisolated(unsafe) private static var reservedPaths = Set<String>()

    static func uniqueURL(for photo: PhotoRecord, options: ExportOptions, ext: String, counter: Int) -> URL {
        let base = filename(for: photo, pattern: options.filenamePattern, counter: counter)
        let fm = FileManager.default
        // Parallel batch workers: reserve names so two photos called "IMG_0001" never get the same target.
        nameLock.lock(); defer { nameLock.unlock() }
        var candidate = options.destination.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: candidate.path) || reservedPaths.contains(candidate.path) {
            candidate = options.destination.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        reservedPaths.insert(candidate.path)
        return candidate
    }

    private static func guardNotOriginal(_ target: URL, _ photo: PhotoRecord) throws {
        if target.standardizedFileURL.path == photo.url.standardizedFileURL.path { throw ExportError.destinationIsOriginal }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

extension ExportFormat {
    static func from(uti: String) -> ExportFormat? {
        switch uti {
        case "public.jpeg": return .jpeg
        case "public.heic", "public.heif": return .heic
        case "public.png": return .png
        case "public.tiff": return .tiff
        case "org.webmproject.webp": return .webp
        default: return nil   // RAW and others → caller falls back to JPEG
        }
    }
}

/// Text watermark rendered with Core Image's attributed-text generator.
enum Watermarker {
    static func apply(_ wm: WatermarkOptions, to image: CIImage) -> CIImage {
        let ext = image.extent
        let short = min(ext.width, ext.height)
        let fontSize = max(10, short * CGFloat(wm.relativeSize))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = fontSize * 0.12
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.04)
        let attr = NSAttributedString(string: wm.text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ])
        guard var text = CIFilter(name: "CIAttributedTextImageGenerator",
                                  parameters: ["inputText": attr, "inputScaleFactor": 1.0])?.outputImage else { return image }
        text = text.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(wm.opacity))
        ])
        let margin = short * 0.03
        let tw = text.extent.width, th = text.extent.height
        let origin: CGPoint
        switch wm.position {
        case .bottomRight: origin = CGPoint(x: ext.maxX - tw - margin, y: ext.minY + margin)
        case .bottomLeft: origin = CGPoint(x: ext.minX + margin, y: ext.minY + margin)
        case .topRight: origin = CGPoint(x: ext.maxX - tw - margin, y: ext.maxY - th - margin)
        case .topLeft: origin = CGPoint(x: ext.minX + margin, y: ext.maxY - th - margin)
        case .center: origin = CGPoint(x: ext.midX - tw / 2, y: ext.midY - th / 2)
        }
        let placed = text.transformed(by: CGAffineTransform(translationX: origin.x - text.extent.minX, y: origin.y - text.extent.minY))
        return placed.composited(over: image).cropped(to: ext)
    }
}
