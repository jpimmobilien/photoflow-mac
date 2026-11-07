import Foundation
import Accelerate
import CoreGraphics

struct DuplicateMember: Identifiable, Hashable, Sendable {
    var id: Int64 { photo.id }
    var photo: PhotoRecord
    var similarity: Double          // to the recommended photo (100 for itself)
    var isExactCopy: Bool           // byte-identical to the recommended photo
    var qualityScore: Double
    var isRecommended: Bool
    var reasons: [String]
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    var id: String                  // stable: smallest photo id in the group
    var members: [DuplicateMember]
    var score: Double               // weakest member similarity
    var category: SimilarityCategory
    var recommendedID: Int64

    var potentialSavings: Int64 { members.filter { !$0.isRecommended }.reduce(0) { $0 + $1.photo.fileSize } }
}

/// Finds exact duplicates (SHA-256) and visually similar photos (perceptual hashes + Vision feature prints +
/// registration-based crop verification). Designed for 10,000+ photos:
/// - analysis runs on small thumbnails in parallel, results are cached per file signature;
/// - SHA-256 is only computed for files whose byte size collides with another file;
/// - candidate pairs come from a blocked matrix multiplication (Accelerate/BLAS) of normalized feature
///   vectors, so all-pairs comparison of 10,000 photos takes well under a second.
final class DuplicateEngine: @unchecked Sendable {
    struct Options: Sendable {
        var minimumScore: Double = 95
        var includeExact = true
        var includeVisual = true
        var verifyCrops = true
        var thresholds = SimilarityThresholds()
    }

    enum Phase: Sendable { case preparing, hashingFiles, analyzingImages, comparing, grouping }

    struct Progress: Sendable {
        var phase: Phase
        var completed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    struct Report: Sendable {
        var groups: [DuplicateGroup]
        var analyzedPhotos: Int
        var reusedFromCache: Int
        var comparisons: Int
        var duration: TimeInterval
    }

    private let store: LibraryStore

    init(store: LibraryStore) { self.store = store }

    func scan(photos input: [PhotoRecord], edited: Set<Int64>, options: Options,
              progress: @escaping @Sendable (Progress) -> Void) async throws -> Report {
        let start = Date()
        let photos = input.filter { !$0.isMissing }
        progress(Progress(phase: .preparing, completed: 0, total: photos.count))

        // 1. Load cache
        let cached = (try? store.analysisRows()) ?? [:]
        var fps: [Int64: Fingerprint] = [:]
        var reused = 0
        for p in photos {
            if let row = cached[p.id], row.signature == p.fileSignature {
                var fp = Fingerprint(row: row)
                if fp.featureRevision != nil && fp.featureRevision != FingerprintIndex.currentFeatureRevision { fp.feature = nil }
                if fp.isVisuallyAnalyzed { reused += 1 }
                fps[p.id] = fp
            } else {
                fps[p.id] = Fingerprint(photoID: p.id, signature: p.fileSignature)
            }
        }

        // 2. SHA-256 for size collisions only
        if options.includeExact {
            let bySize = Dictionary(grouping: photos, by: \.fileSize).values.filter { $0.count > 1 }
            let needHash = bySize.flatMap { $0 }.filter { fps[$0.id]?.sha256 == nil }
            var done = 0
            try await forEachConcurrently(needHash, limit: 4) { p -> HashResult in
                HashResult(id: p.id, sha: FileHasher.sha256(p.url))
            } onResult: { r in
                fps[r.id]?.sha256 = r.sha
                done += 1
                if done % 20 == 0 || done == needHash.count {
                    progress(Progress(phase: .hashingFiles, completed: done, total: needHash.count))
                }
            }
            try? store.saveAnalysis(needHash.compactMap { fps[$0.id]?.row })
        }

        // 3. Visual analysis (thumbnails → hashes + feature print + quality), cached
        var analyzed = 0
        if options.includeVisual {
            let todo = photos.filter { !(fps[$0.id]?.isVisuallyAnalyzed ?? false) }
            var pending: [LibraryStore.AnalysisRow] = []
            let limit = HardwareProfile.current.recommendedAnalysisConcurrency
            try await forEachConcurrently(todo, limit: limit) { p -> Fingerprint in
                var fp = Fingerprint(photoID: p.id, signature: p.fileSignature)
                FingerprintIndex.analyzeVisual(p, into: &fp)
                return fp
            } onResult: { fp in
                var merged = fp
                merged.sha256 = fps[fp.photoID]?.sha256
                fps[fp.photoID] = merged
                pending.append(merged.row)
                analyzed += 1
                if pending.count >= 50 { try? self.store.saveAnalysis(pending); pending.removeAll() }
                if analyzed % 5 == 0 || analyzed == todo.count {
                    progress(Progress(phase: .analyzingImages, completed: analyzed, total: todo.count))
                }
            }
            try? store.saveAnalysis(pending)
        }
        try Task.checkCancellation()

        // 4. Candidate pairs
        progress(Progress(phase: .comparing, completed: 0, total: 1))
        let index = photos.map(\.id)
        let pos = Dictionary(uniqueKeysWithValues: index.enumerated().map { ($1, $0) })
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var pairs: [PairKey: PairInfo] = [:]
        var comparisons = 0

        if options.includeExact {
            let bySha = Dictionary(grouping: photos.filter { fps[$0.id]?.sha256 != nil }, by: { fps[$0.id]!.sha256! })
            for group in bySha.values where group.count > 1 {
                for i in 0 ..< group.count {
                    for j in i + 1 ..< group.count {
                        pairs[PairKey(group[i].id, group[j].id)] = PairInfo(score: 100, exact: true)
                    }
                }
            }
        }

        if options.includeVisual {
            let minCos = Self.cosineFloor(forScore: max(50, options.minimumScore - 12))
            let featured = index.filter { fps[$0]?.feature != nil }
            if let dim = featured.first.flatMap({ fps[$0]?.feature?.count }), dim > 0 {
                let valid = featured.filter { fps[$0]?.feature?.count == dim }
                var matrix = [Float](repeating: 0, count: valid.count * dim)
                for (r, id) in valid.enumerated() {
                    let f = fps[id]!.feature!
                    matrix.withUnsafeMutableBufferPointer { m in
                        for c in 0 ..< dim { m[r * dim + c] = f[c] }
                    }
                }
                let found = Self.similarPairs(matrix: matrix, rows: valid.count, dim: dim, minCosine: minCos)
                comparisons += valid.count * (valid.count - 1) / 2
                for (i, j, c) in found {
                    let a = valid[i], b = valid[j]
                    let key = PairKey(a, b)
                    var info = pairs[key] ?? PairInfo(score: 0, exact: false)
                    info.cosine = c
                    pairs[key] = info
                }
            }
            try Task.checkCancellation()
            // Perceptual hash neighbours (catches pairs the embedding might rank lower, e.g. heavy colour edits)
            let hashed = index.compactMap { id in fps[id]?.hashes.map { (id, $0) } }
            for i in 0 ..< hashed.count {
                let (ia, ha) = hashed[i]
                for j in i + 1 ..< hashed.count {
                    let (ib, hb) = hashed[j]
                    if PerceptualHash.distance(ha.p, hb.p) <= 10, let hs = SimilarityScorer.hashScore(ha, hb) {
                        let key = PairKey(ia, ib)
                        var info = pairs[key] ?? PairInfo(score: 0, exact: false)
                        info.hash = hs
                        if info.cosine == nil, let fa = fps[ia]?.feature, let fb = fps[ib]?.feature, fa.count == fb.count {
                            info.cosine = Self.dot(fa, fb)
                        }
                        pairs[key] = info
                    }
                }
                if i % 500 == 0 { try Task.checkCancellation() }
            }
            comparisons += hashed.count * (hashed.count - 1) / 2

            // Score + optional crop verification for borderline pairs
            var verifications = 0
            for (key, var info) in pairs where !info.exact {
                info.score = SimilarityScorer.combined(hash: info.hash, cosine: info.cosine, registration: nil)
                if options.verifyCrops, verifications < 1500, info.score < 95, info.score >= options.minimumScore - 15,
                   (info.cosine ?? 0) >= 0.72, let pa = byID[key.a], let pb = byID[key.b], Self.framingDiffers(pa, pb) {
                    verifications += 1
                    if let r = Self.registrationScore(pa, pb) { info.registration = r; info.score = max(info.score, r) }
                }
                pairs[key] = info
            }
        }
        try Task.checkCancellation()

        // 5. Grouping
        progress(Progress(phase: .grouping, completed: 0, total: 1))
        let groups = buildGroups(pairs: pairs, photos: byID, positions: pos, fingerprints: fps, edited: edited, options: options)
        progress(Progress(phase: .grouping, completed: 1, total: 1))
        return Report(groups: groups, analyzedPhotos: analyzed, reusedFromCache: reused, comparisons: comparisons,
                      duration: Date().timeIntervalSince(start))
    }

    // MARK: - Grouping

    struct HashResult: Sendable { var id: Int64; var sha: String? }

    struct PairKey: Hashable, Sendable {
        let a: Int64, b: Int64
        init(_ x: Int64, _ y: Int64) { a = min(x, y); b = max(x, y) }
    }

    struct PairInfo: Sendable {
        var score: Double
        var exact: Bool
        var cosine: Float?
        var hash: Double?
        var registration: Double?
    }

    private func buildGroups(pairs: [PairKey: PairInfo], photos: [Int64: PhotoRecord], positions: [Int64: Int],
                             fingerprints: [Int64: Fingerprint], edited: Set<Int64>, options: Options) -> [DuplicateGroup] {
        let accepted = pairs.filter { $0.value.exact ? options.includeExact : $0.value.score >= options.minimumScore }
        // Union-find
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        for key in accepted.keys {
            if parent[key.a] == nil { parent[key.a] = key.a }
            if parent[key.b] == nil { parent[key.b] = key.b }
            let ra = find(key.a), rb = find(key.b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var components: [Int64: [Int64]] = [:]
        for id in parent.keys { components[find(id), default: []].append(id) }

        func pairScore(_ x: Int64, _ y: Int64) -> (Double, Bool) {
            if x == y { return (100, true) }
            if let info = pairs[PairKey(x, y)] { return (info.score, info.exact) }
            // Not a candidate pair: compute directly
            var cos: Float?
            if let fa = fingerprints[x]?.feature, let fb = fingerprints[y]?.feature, fa.count == fb.count { cos = Self.dot(fa, fb) }
            var hs: Double?
            if let ha = fingerprints[x]?.hashes, let hb = fingerprints[y]?.hashes { hs = SimilarityScorer.hashScore(ha, hb) }
            return (SimilarityScorer.combined(hash: hs, cosine: cos, registration: nil), false)
        }

        var result: [DuplicateGroup] = []
        var queue = Array(components.values)
        var safety = 0
        while let comp = queue.popLast(), safety < 100_000 {
            safety += 1
            guard comp.count > 1 else { continue }
            let members = comp.compactMap { photos[$0] }
            let ranking = KeepRecommender.rank(members, fingerprints: fingerprints, edited: edited)
            let anchor = ranking.best
            // Members must be similar to the anchor itself (prevents long A~B~C~D chains).
            var keep: [DuplicateMember] = []
            var rest: [Int64] = []
            for m in members {
                let (s, exact) = pairScore(anchor, m.id)
                if m.id == anchor || exact || s >= options.minimumScore {
                    keep.append(DuplicateMember(photo: m, similarity: m.id == anchor ? 100 : s, isExactCopy: exact && m.id != anchor,
                                                qualityScore: ranking.scores[m.id] ?? 0, isRecommended: m.id == anchor,
                                                reasons: ranking.reasons[m.id] ?? []))
                } else {
                    rest.append(m.id)
                }
            }
            if rest.count > 1 { queue.append(rest) }
            guard keep.count > 1 else { continue }
            let others = keep.filter { !$0.isRecommended }
            let allExact = others.allSatisfy(\.isExactCopy)
            let minScore = others.map(\.similarity).min() ?? 100
            let category = options.thresholds.category(for: minScore, exact: allExact) ?? .possiblySimilar
            let sorted = keep.sorted { a, b in
                if a.isRecommended != b.isRecommended { return a.isRecommended }
                return a.similarity > b.similarity
            }
            result.append(DuplicateGroup(id: String(keep.map(\.photo.id).min() ?? 0), members: sorted,
                                         score: allExact ? 100 : minScore, category: category, recommendedID: anchor))
        }
        return result.sorted { a, b in
            if a.category != b.category { return a.category > b.category }
            if a.members.count != b.members.count { return a.members.count > b.members.count }
            return a.score > b.score
        }
    }

    // MARK: - Math helpers

    /// Smallest cosine whose mapped score reaches `score`.
    static func cosineFloor(forScore score: Double) -> Float {
        var c: Float = 0
        while c < 1 {
            if SimilarityScorer.featureScore(c) >= score { return c }
            c += 0.005
        }
        return 0.99
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }

    /// Blocked A·Aᵀ via BLAS; returns pairs (i < j) with cosine ≥ minCosine.
    static func similarPairs(matrix: [Float], rows n: Int, dim: Int, minCosine: Float) -> [(Int, Int, Float)] {
        guard n > 1 else { return [] }
        var out: [(Int, Int, Float)] = []
        let block = 512
        var c = [Float](repeating: 0, count: block * n)
        matrix.withUnsafeBufferPointer { m in
            var start = 0
            while start < n {
                let rows = min(block, n - start)
                c.withUnsafeMutableBufferPointer { cp in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(n), Int32(dim), 1,
                                m.baseAddress! + start * dim, Int32(dim), m.baseAddress!, Int32(dim), 0, cp.baseAddress!, Int32(n))
                }
                for r in 0 ..< rows {
                    let i = start + r
                    let rowBase = r * n
                    var j = i + 1
                    while j < n {
                        let v = c[rowBase + j]
                        if v >= minCosine { out.append((i, j, min(1, v))) }
                        j += 1
                    }
                }
                start += rows
            }
        }
        return out
    }

    /// True when two photos differ in aspect ratio or size – a hint that one may be a crop of the other.
    static func framingDiffers(_ a: PhotoRecord, _ b: PhotoRecord) -> Bool {
        let ra = Double(a.width) / Double(max(1, a.height)), rb = Double(b.width) / Double(max(1, b.height))
        return abs(ra - rb) / max(ra, rb) > 0.03 || abs(Double(a.width * a.height) / Double(max(1, b.width * b.height)) - 1) > 0.15
    }

    static func registrationScore(_ a: PhotoRecord, _ b: PhotoRecord) -> Double? {
        autoreleasepool {
            guard let ia = ImageLoader.thumbnail(url: a.url, maxPixel: CropVerifier.workingSize, preferEmbedded: true),
                  let ib = ImageLoader.thumbnail(url: b.url, maxPixel: CropVerifier.workingSize, preferEmbedded: true),
                  let m = CropVerifier.verify(ia, ib) else { return nil }
            if m.correlation > 0.92 && m.overlap > 0.5 { return 95 }
            if m.correlation > 0.85 && m.overlap > 0.3 { return 90 }
            return nil
        }
    }

    /// Runs `work` for every element with bounded parallelism; `onResult` is called serially.
    private func forEachConcurrently<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, work: @escaping @Sendable (T) -> R, onResult: (R) -> Void
    ) async throws {
        guard !items.isEmpty else { return }
        try await withThrowingTaskGroup(of: R.self) { group in
            var next = 0
            let initial = min(max(1, limit), items.count)
            while next < initial {
                let item = items[next]
                group.addTask { try Task.checkCancellation(); return work(item) }
                next += 1
            }
            while let r = try await group.next() {
                onResult(r)
                if next < items.count {
                    let item = items[next]
                    group.addTask { try Task.checkCancellation(); return work(item) }
                    next += 1
                }
            }
        }
    }
}
