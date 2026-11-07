import Foundation
import CoreGraphics
import Vision

/// Per-photo analysis used by duplicate detection and keep recommendations. Persisted in the library's
/// `analysis` table and keyed by the file signature (size + modification date), so unchanged photos are
/// never analysed twice.
struct Fingerprint: Sendable {
    var photoID: Int64
    var signature: String
    var sha256: String?
    var hashes: PerceptualHash.Hashes?
    var feature: [Float]?
    var featureRevision: Int?
    var sharpness: Double?
    var exposureQuality: Double?
    var aesthetic: Double?
    var isUtility: Bool?

    init(photoID: Int64, signature: String) {
        self.photoID = photoID
        self.signature = signature
    }

    init(row: LibraryStore.AnalysisRow) {
        photoID = row.photoID
        signature = row.signature
        sha256 = row.sha256
        if let a = row.aHash, let d = row.dHash, let p = row.pHash { hashes = .init(a: a, d: d, p: p) }
        if let data = row.feature, !data.isEmpty {
            feature = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        featureRevision = row.featureRevision
        sharpness = row.sharpness
        exposureQuality = row.exposureScore
        aesthetic = row.aesthetic
        isUtility = row.isUtility
    }

    var row: LibraryStore.AnalysisRow {
        LibraryStore.AnalysisRow(
            photoID: photoID, signature: signature, sha256: sha256, aHash: hashes?.a, dHash: hashes?.d, pHash: hashes?.p,
            featureRevision: featureRevision,
            feature: feature.map { f in f.withUnsafeBufferPointer { Data(buffer: $0) } },
            sharpness: sharpness, exposureScore: exposureQuality, aesthetic: aesthetic, isUtility: isUtility)
    }

    var isVisuallyAnalyzed: Bool { hashes != nil && feature != nil }
}

enum FingerprintIndex {
    /// Size of the image used for visual analysis. Large enough for Vision, small enough to be fast.
    static let analysisPixels = 512

    /// Computes the visual part (hashes, feature print, sharpness, exposure, aesthetics) from one thumbnail decode.
    static func analyzeVisual(_ photo: PhotoRecord, into fp: inout Fingerprint) {
        autoreleasepool {
            guard let cg = ImageLoader.thumbnail(url: photo.url, maxPixel: analysisPixels, preferEmbedded: true) else { return }
            fp.hashes = PerceptualHash.compute(cg)
            if let f = VisionAnalyzer.featurePrint(cg) {
                fp.feature = f.vector
                fp.featureRevision = f.revision
            }
            if let px = PixelBuffer(cgImage: cg, maxSide: analysisPixels) {
                let s = ImageStatistics.compute(px)
                fp.sharpness = s.sharpness
                fp.exposureQuality = s.exposureQuality
            }
            if let ae = VisionAnalyzer.aesthetics(cg) {
                fp.aesthetic = ae.score
                fp.isUtility = ae.isUtility
            }
        }
    }

    /// Current Vision feature-print revision (a macOS update can change the model → cached vectors are recomputed).
    static let currentFeatureRevision: Int = VNGenerateImageFeaturePrintRequest().revision
}
