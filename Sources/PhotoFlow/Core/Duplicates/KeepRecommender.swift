import Foundation

/// Ranks the members of a duplicate group and explains which version is best to keep.
/// It only *recommends* – PhotoFlow never deletes anything automatically.
enum KeepRecommender {
    struct Ranking: Sendable {
        var scores: [Int64: Double]
        var best: Int64
        var reasons: [Int64: [String]]
    }

    static func rank(_ photos: [PhotoRecord], fingerprints: [Int64: Fingerprint], edited: Set<Int64>) -> Ranking {
        guard let first = photos.first else { return Ranking(scores: [:], best: 0, reasons: [:]) }
        func norm(_ values: [Int64: Double]) -> [Int64: Double] {
            let mx = values.values.max() ?? 0, mn = values.values.min() ?? 0
            guard mx - mn > 1e-9 else { return values.mapValues { _ in 1 } }
            return values.mapValues { ($0 - mn) / (mx - mn) }
        }
        var res: [Int64: Double] = [:], sharp: [Int64: Double] = [:], expo: [Int64: Double] = [:]
        var size: [Int64: Double] = [:], fmt: [Int64: Double] = [:], meta: [Int64: Double] = [:], aest: [Int64: Double] = [:]
        var naming: [Int64: Double] = [:]
        for p in photos {
            let fp = fingerprints[p.id]
            res[p.id] = log2(max(1, Double(p.width * p.height)))
            sharp[p.id] = log(1 + (fp?.sharpness ?? 0) * 1000)
            expo[p.id] = fp?.exposureQuality ?? 0.5
            // Bytes per pixel – at equal resolution, the larger file is usually less compressed.
            size[p.id] = Double(p.fileSize) / Double(max(1, p.width * p.height))
            fmt[p.id] = formatScore(p)
            var m = 0.0
            if p.captureDate != nil { m += 1 }
            if p.cameraModel != nil { m += 1 }
            if p.lensModel != nil { m += 0.5 }
            if p.exposureTime != nil { m += 0.5 }
            meta[p.id] = m
            if let a = fp?.aesthetic { aest[p.id] = a }
            naming[p.id] = looksDerived(p.filename) ? 0 : 1
        }
        let nRes = norm(res), nSharp = norm(sharp), nExpo = norm(expo), nSize = norm(size), nFmt = norm(fmt), nMeta = norm(meta)
        let nAest = aest.count == photos.count ? norm(aest) : [:]
        let hasAesthetics = !nAest.isEmpty

        var scores: [Int64: Double] = [:]
        for p in photos {
            let a: Double = 0.28 * (nRes[p.id] ?? 0) + 0.20 * (nSharp[p.id] ?? 0)
            let b: Double = 0.12 * (nExpo[p.id] ?? 0) + 0.10 * (nFmt[p.id] ?? 0)
            let c: Double = 0.08 * (nSize[p.id] ?? 0) + 0.08 * (nMeta[p.id] ?? 0)
            let d: Double = 0.06 * (naming[p.id] ?? 0)
            var s = a + b + c + d
            s += hasAesthetics ? 0.08 * (nAest[p.id] ?? 0) : 0.08 * (nExpo[p.id] ?? 0)
            if edited.contains(p.id) { s += 0.04 }   // the user already invested work in this version
            scores[p.id] = s
        }
        let best = scores.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key ?? first.id

        // Explanations for the recommended photo (relative to the others)
        var reasons: [Int64: [String]] = [:]
        if let bp = photos.first(where: { $0.id == best }) {
            var r: [String] = []
            let others = photos.filter { $0.id != best }
            if others.allSatisfy({ $0.width * $0.height < bp.width * bp.height }) { r.append(String(localized: "Highest resolution")) }
            if let bs = fingerprints[best]?.sharpness, others.allSatisfy({ (fingerprints[$0.id]?.sharpness ?? 0) < bs * 0.95 }) {
                r.append(String(localized: "Sharpest image"))
            }
            if (nExpo[best] ?? 0) >= 0.99 && others.count > 0 && Set(expo.values).count > 1 { r.append(String(localized: "Best exposure")) }
            if bp.isRAW && others.contains(where: { !$0.isRAW }) { r.append(String(localized: "Original RAW file")) }
            if (nMeta[best] ?? 0) >= 0.99 && Set(meta.values).count > 1 { r.append(String(localized: "Most complete metadata")) }
            if (naming[best] ?? 0) == 1 && others.contains(where: { looksDerived($0.filename) }) {
                r.append(String(localized: "Original file name (others look like copies)"))
            }
            if hasAesthetics && (nAest[best] ?? 0) >= 0.99 { r.append(String(localized: "Best overall quality (on-device aesthetics model)")) }
            if r.isEmpty { r.append(String(localized: "Best overall combination of quality factors")) }
            reasons[best] = r
        }
        return Ranking(scores: scores, best: best, reasons: reasons)
    }

    static func formatScore(_ p: PhotoRecord) -> Double {
        if p.isRAW { return 1.0 }
        switch p.uti {
        case "public.tiff", "public.png": return 0.8
        case "public.heic", "public.heif": return 0.7
        case "public.jpeg": return 0.6
        case "org.webmproject.webp": return 0.5
        default: return 0.4
        }
    }

    /// "IMG_001 copy.jpg", "IMG_001 Kopie.jpg", "IMG_001 (1).jpg", "IMG_001-edited.jpg", "IMG_001-1.jpg" …
    static func looksDerived(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let markers = [" copy", " kopie", "-copy", "_copy", "edited", "bearbeitet", "-1", "_1", "(1)", "(2)", "(3)", " 2", "-export", "_export", "-small", "_small", "-web", "_web"]
        return markers.contains { base.hasSuffix($0) || base.contains($0 + " ") || base.contains($0 + ".") }
            || base.range(of: #"\(\d+\)$"#, options: .regularExpression) != nil
    }
}
