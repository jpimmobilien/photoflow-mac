import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Headless QA harness built into the app binary so tests run against the exact shipping code.
///
///     PhotoFlow --qa info
///     PhotoFlow --qa selftest
///     PhotoFlow --qa gen <seed-folder> <out-folder> [max-seeds]
///     PhotoFlow --qa eval-dup <dataset-folder>
///     PhotoFlow --qa eval-straighten <dataset-folder>
///     PhotoFlow --qa eval-wb <dataset-folder>
///     PhotoFlow --qa eval-perspective <dataset-folder>
///     PhotoFlow --qa batch <folder> <count> [concurrency]
///     PhotoFlow --qa enhance <image> <out.jpg>
enum QARunner {
    static func runAndExit(arguments: [String]) -> Never {
        let args = Array(arguments.drop { $0 != "--qa" }.dropFirst())
        let sem = DispatchSemaphore(value: 0)
        let code = CodeBox()
        Task.detached {
            do {
                try await run(args)
                code.value = 0
            } catch {
                print("QA FAILED: \(error)")
                code.value = 1
            }
            sem.signal()
        }
        sem.wait()
        exit(code.value)
    }

    final class CodeBox: @unchecked Sendable { var value: Int32 = 1 }

    struct QAError: Error, CustomStringConvertible { var description: String }

    static func run(_ args: [String]) async throws {
        guard let cmd = args.first else { throw QAError(description: "missing command") }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "info": info()
        case "selftest": try selfTest()
        case "gen": try generate(seedFolder: arg(rest, 0), out: arg(rest, 1), maxSeeds: Int(rest.count > 2 ? rest[2] : "40") ?? 40)
        case "eval-dup": try await evalDuplicates(folder: arg(rest, 0))
        case "eval-straighten": try evalStraighten(folder: arg(rest, 0))
        case "eval-wb": try evalWB(folder: arg(rest, 0))
        case "eval-perspective": try evalPerspective(folder: arg(rest, 0))
        case "batch": try await batch(folder: arg(rest, 0), count: Int(arg(rest, 1)) ?? 100, concurrency: rest.count > 2 ? Int(rest[2]) : nil)
        case "enhance": try enhanceOne(input: arg(rest, 0), output: arg(rest, 1))
        default:
            if try await AIQA.run(cmd, rest) { return }
            throw QAError(description: "unknown command \(cmd)")
        }
    }

    private static func arg(_ a: [String], _ i: Int) throws -> String {
        guard i < a.count else { throw QAError(description: "missing argument #\(i + 1)") }
        return (a[i] as NSString).expandingTildeInPath
    }

    // MARK: - info

    static func info() {
        let hw = HardwareProfile.current
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        print("binary architecture: \(arch)")
        print("hardware: \(hw.summary) model=\(hw.modelIdentifier) rosetta=\(hw.runningUnderRosetta)")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("metal: \(hw.hasMetal) gpu=\(hw.gpuName ?? "-")")
        print("batch concurrency: \(hw.recommendedBatchConcurrency) analysis concurrency: \(hw.recommendedAnalysisConcurrency)")
        print("export formats: \(ExportFormat.available.map(\.rawValue).joined(separator: ","))")
        print("feature print revision: \(FingerprintIndex.currentFeatureRevision)")
    }

    // MARK: - selftest (deterministic unit checks)

    static func selfTest() throws {
        var failures: [String] = []
        func check(_ cond: Bool, _ name: String) { print((cond ? "PASS " : "FAIL ") + name); if !cond { failures.append(name) } }

        // Geometry: pure rotation inscribed rect equals the analytic formula
        for deg in [1.0, 3.0, 7.5, 15.0] {
            let size = CGSize(width: 4000, height: 3000)
            let r = GeometryModel(rotationDegrees: deg).inscribedRect(size: size)
            let t = deg * .pi / 180
            let expected = min(4000 / (4000 * cos(t) + 3000 * sin(t)), 3000 / (4000 * sin(t) + 3000 * cos(t)))
            check(abs(Double(r.width) / 4000 - expected) < 0.002, "inscribed rect rotation \(deg)°")
        }
        let persp = GeometryModel(rotationDegrees: 0, cv: 0.2, ch: 0)
        let rr = persp.inscribedRect(size: CGSize(width: 3000, height: 4000))
        check(GeometryModel.rect(rr, inside: persp.quad(size: CGSize(width: 3000, height: 4000))) && rr.width > 2000, "inscribed rect perspective")

        // White balance slider mapping round-trip
        for (t, m) in [(30.0, 0.0), (-45.0, 20.0), (10.0, -35.0)] {
            let g = WhiteBalanceModel.gains(temperature: t, tint: m)
            let back = WhiteBalanceModel.sliders(forGains: g.r, g.g, g.b)
            check(abs(back.temperature - t) < 0.01 && abs(back.tint - m) < 0.01, "white balance mapping \(t),\(m)")
        }

        // Tone curve monotonic for extreme settings
        for c in [-100.0, 100.0] {
            var r = EditRecipe(); r.contrast = c; r.brightness = c; r.blacks = -c; r.whites = c
            let p = ToneCurve(recipe: r).points
            check(zip(p, p.dropFirst()).allSatisfy { $0.y <= $1.y + 1e-9 }, "tone curve monotonic \(c)")
        }

        // Synthetic image: render pipeline + hashes stable under resize
        let img = syntheticImage(width: 1200, height: 800)
        let small = CIContextProvider.shared.createCGImage(CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)),
                                                           from: CGRect(x: 0, y: 0, width: 600, height: 400))!
        if let h1 = PerceptualHash.compute(img), let h2 = PerceptualHash.compute(small) {
            check(PerceptualHash.distance(h1.p, h2.p) <= 4, "pHash stable under 50% resize (d=\(PerceptualHash.distance(h1.p, h2.p)))")
        }

        // Tilt detection on a synthetic rotated scene
        for deg in [-4.0, 2.5, 6.0] {
            let rotated = rotatedCrop(img, degrees: deg)
            if let a = PhotoAnalyzer.analyze(image: rotated) {
                check(abs(a.straighten.tilt - deg) < 0.4, "tilt \(deg)° detected as \(String(format: "%.2f", a.straighten.tilt))° conf \(String(format: "%.2f", a.straighten.confidence))")
            }
        }

        // Library + file safety in a temporary folder
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlowQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let photoURL = tmp.appendingPathComponent("Sample.jpg")
        try writeJPEG(img, to: photoURL, quality: 0.9)
        let originalHash = FileHasher.sha256(photoURL)
        let store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        let rec = try store.insert([MetadataReader.record(for: photoURL)!])
        check(rec.count == 1, "library insert")
        var recipe = EditRecipe(); recipe.exposure = 0.5; recipe.rotation = 2
        try store.saveRecipe(recipe, for: rec[0].id)
        check(try store.recipe(for: rec[0].id) == recipe, "recipe round-trip")
        var opts = ExportOptions(); opts.destinationPath = tmp.appendingPathComponent("out").path
        try ExportEngine.prepareDestination(opts)
        let out1 = try ExportEngine.export(photo: rec[0], recipe: recipe, options: opts, counter: 1)
        let out2 = try ExportEngine.export(photo: rec[0], recipe: recipe, options: opts, counter: 2)
        check(out1.url != out2.url && FileManager.default.fileExists(atPath: out2.url.path), "export never overwrites (\(out2.url.lastPathComponent))")
        check(FileHasher.sha256(photoURL) == originalHash, "original untouched after export")
        var sameFolder = opts; sameFolder.destinationPath = tmp.path; sameFolder.format = .jpeg
        let out3 = try ExportEngine.export(photo: rec[0], recipe: recipe, options: sameFolder, counter: 3)
        check(out3.url.path != photoURL.path && FileHasher.sha256(photoURL) == originalHash, "export into original folder keeps original")
        // Trash + restore
        let trash = FileOperations.moveToTrash([rec[0]])
        check(trash.trashed.count == 1 && !FileManager.default.fileExists(atPath: photoURL.path), "move to Trash")
        if let t = trash.trashed.first {
            let entry = TrashEntry(id: 1, originalPath: t.originalPath, trashPath: t.trashPath, filename: "Sample.jpg", fileSize: t.size, trashedAt: Date(), photoID: t.photoID)
            let restored = try FileOperations.restore(entry)
            check(restored.path == photoURL.path && FileHasher.sha256(restored) == originalHash, "restore from Trash (identical bytes)")
        }
        print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST: \(failures.count) failure(s)")
        if !failures.isEmpty { throw QAError(description: failures.joined(separator: "; ")) }
    }

    // MARK: - Dataset generation

    /// Creates labelled variants of seed photos: `<seed>__<variant>.<ext>`.
    static func generate(seedFolder: String, out: String, maxSeeds: Int) throws {
        let seeds = ImportService.collectImageURLs(from: [URL(fileURLWithPath: seedFolder)]).prefix(maxSeeds)
        let outURL = URL(fileURLWithPath: out)
        for sub in ["dup", "tilt", "wb", "persp"] {
            try FileManager.default.createDirectory(at: outURL.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var n = 0
        for (i, url) in seeds.enumerated() {
            try autoreleasepool {
                guard let cg = ImageLoader.thumbnail(url: url, maxPixel: 2400) else { return }
                let name = String(format: "s%03d", i)
                let ci = CIImage(cgImage: cg)
                let dup = outURL.appendingPathComponent("dup")
                // exact copy (same bytes, different name)
                try writeJPEG(cg, to: dup.appendingPathComponent("\(name)__orig.jpg"), quality: 0.92)
                try FileManager.default.copyItem(at: dup.appendingPathComponent("\(name)__orig.jpg"), to: dup.appendingPathComponent("\(name)__exactcopy.jpg"))
                try writeJPEG(render(ci.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))), to: dup.appendingPathComponent("\(name)__resized50.jpg"), quality: 0.9)
                try writeJPEG(cg, to: dup.appendingPathComponent("\(name)__recompressed.jpg"), quality: 0.45)
                try writeJPEG(render(ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.6])), to: dup.appendingPathComponent("\(name)__brighter.jpg"), quality: 0.9)
                try writeJPEG(render(ci.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 5000, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)])), to: dup.appendingPathComponent("\(name)__colorshift.jpg"), quality: 0.9)
                let e = ci.extent
                try writeJPEG(render(ci.cropped(to: e.insetBy(dx: e.width * 0.1, dy: e.height * 0.1))), to: dup.appendingPathComponent("\(name)__crop80.jpg"), quality: 0.9)
                try writeJPEG(render(ci.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width * 0.65, height: e.height * 0.65))), to: dup.appendingPathComponent("\(name)__crop65.jpg"), quality: 0.9)
                try writeJPEG(render(ci.applyingFilter("CIPhotoEffectMono")), to: dup.appendingPathComponent("\(name)__mono.jpg"), quality: 0.9)
                if let png = ImageLoader.thumbnail(url: url, maxPixel: 1600) { try writePNG(png, to: dup.appendingPathComponent("\(name)__png.png")) }

                // Straightening ground truth
                let tilt = [-6.0, -3.0, -1.2, 0.0, 0.8, 2.0, 4.5][i % 7]
                try writeJPEG(rotatedCrop(cg, degrees: tilt), to: outURL.appendingPathComponent("tilt/\(name)__tilt\(String(format: "%+.1f", tilt)).jpg"), quality: 0.9)
                try writeJPEG(cg, to: outURL.appendingPathComponent("tilt/\(name)__tilt+0.0ref.jpg"), quality: 0.9)

                // White balance ground truth (linear channel gains)
                let casts: [(Double, Double)] = [(1.25, 0.8), (0.8, 1.25), (1.0, 1.0), (1.1, 0.75), (0.9, 1.15)]
                let (gr, gb) = casts[i % casts.count]
                let cast = ci.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gr, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gb, w: 0)])
                try writeJPEG(render(cast), to: outURL.appendingPathComponent(String(format: "wb/\(name)__cast%.2f_%.2f.jpg", gr, gb)), quality: 0.92)

                // Perspective ground truth: apply the inverse of a known keystone (cv)
                let cv = [0.0, 0.08, 0.15, -0.1][i % 4]
                let model = GeometryModel(rotationDegrees: 0, cv: -cv, ch: 0)
                let q = model.quad(size: e.size)
                let off = CGPoint(x: e.width / 2, y: e.height / 2)
                func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x + off.x, y: p.y + off.y) }
                let warped = ci.applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputTopLeft": v(q[0]), "inputTopRight": v(q[1]), "inputBottomRight": v(q[2]), "inputBottomLeft": v(q[3])])
                let rect = model.inscribedRect(size: e.size).offsetBy(dx: off.x, dy: off.y)
                try writeJPEG(render(warped.cropped(to: rect)), to: outURL.appendingPathComponent(String(format: "persp/\(name)__key%+.2f.jpg", cv)), quality: 0.9)
                n += 1
            }
        }
        print("generated variants for \(n) seeds in \(out)")
    }

    // MARK: - Duplicate evaluation

    static func evalDuplicates(folder: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlowQA-dup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try LibraryStore(directory: tmp)
        let imported = try await ImportService(store: store).importItems([URL(fileURLWithPath: folder)]) { _ in }.imported
        print("imported \(imported.count) files")
        func seed(_ p: PhotoRecord) -> String { String(p.filename.split(separator: "_").first ?? "") }
        func variant(_ p: PhotoRecord) -> String {
            let base = (p.filename as NSString).deletingPathExtension
            return base.components(separatedBy: "__").last ?? base
        }
        let engine = DuplicateEngine(store: store)
        for threshold in [95.0, 85.0, 70.0] {
            var opts = DuplicateEngine.Options()
            opts.minimumScore = threshold
            let start = Date()
            let report = try await engine.scan(photos: imported, edited: [], options: opts) { _ in }
            // pairwise evaluation against ground truth
            var groupOf: [Int64: String] = [:]
            for g in report.groups { for m in g.members { groupOf[m.id] = g.id } }
            var tp = 0, fp = 0, fn = 0
            var perVariant: [String: (found: Int, total: Int)] = [:]
            let bySeed = Dictionary(grouping: imported, by: seed)
            for (_, members) in bySeed {
                guard let orig = members.first(where: { variant($0) == "orig" }) else { continue }
                for m in members where m.id != orig.id {
                    let same = groupOf[m.id] != nil && groupOf[m.id] == groupOf[orig.id]
                    var e = perVariant[variant(m)] ?? (0, 0)
                    e.total += 1
                    if same { e.found += 1; tp += 1 } else { fn += 1 }
                    perVariant[variant(m)] = e
                }
            }
            for g in report.groups {
                let seeds = Set(g.members.map { seed($0.photo) })
                if seeds.count > 1 { fp += g.members.count - (Dictionary(grouping: g.members, by: { seed($0.photo) }).values.map(\.count).max() ?? 0) }
            }
            print(String(format: "threshold %.0f: groups=%d recall=%.3f falsePositivePhotos=%d time=%.2fs (cache reuse %d)",
                         threshold, report.groups.count, Double(tp) / Double(max(1, tp + fn)), fp, Date().timeIntervalSince(start), report.reusedFromCache))
            for (k, v) in perVariant.sorted(by: { $0.key < $1.key }) {
                print(String(format: "   %-14@ %d/%d", k as NSString, v.found, v.total))
            }
        }
        // Raw score distributions for calibration
        let rows = try store.analysisRows()
        var same: [Float] = [], diff: [Float] = []
        let fps = imported.compactMap { p -> (PhotoRecord, [Float])? in
            guard let d = rows[p.id]?.feature else { return nil }
            return (p, d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        }
        for i in 0 ..< fps.count {
            for j in i + 1 ..< fps.count {
                let c = DuplicateEngine.dot(fps[i].1, fps[j].1)
                if seed(fps[i].0) == seed(fps[j].0) { same.append(c) } else { diff.append(c) }
            }
        }
        func pct(_ a: [Float], _ q: Double) -> Float { let s = a.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        print(String(format: "feature cosine SAME seed: p05=%.3f p25=%.3f p50=%.3f  (n=%d)", pct(same, 0.05), pct(same, 0.25), pct(same, 0.5), same.count))
        print(String(format: "feature cosine DIFF seed: p50=%.3f p95=%.3f p99=%.3f p99.9=%.3f max=%.3f (n=%d)", pct(diff, 0.5), pct(diff, 0.95), pct(diff, 0.99), pct(diff, 0.999), pct(diff, 1), diff.count))
    }

    // MARK: - Straighten / WB / perspective evaluation

    static func evalStraighten(folder: String) throws {
        struct Row { var seed: String; var truth: Double; var isRef: Bool; var r: StraightenEngine.Result }
        var rows: [Row] = []
        for url in ImportService.collectImageURLs(from: [URL(fileURLWithPath: folder)]) {
            let base = url.deletingPathExtension().lastPathComponent
            guard let r = base.range(of: "__tilt") else { continue }
            let tag = String(base[r.upperBound...])
            let isRef = tag.hasSuffix("ref")
            let truth = Double(tag.replacingOccurrences(of: "ref", with: "")) ?? 0
            guard let a = PhotoAnalyzer.analyze(url: url) else { continue }
            let st = a.straighten
            rows.append(Row(seed: String(base[..<r.lowerBound]), truth: truth, isRef: isRef, r: st))
            print(String(format: "%@ truth=%+.1f tilt=%+.2f conf=%.2f apply=%@ src=%@ | h=%+.2f(%.2f) v=%+.2f(%.2f) all=%+.2f(%.2f) vision=%@",
                         base, truth, st.tilt, st.confidence, st.shouldApply ? "yes" : "no", st.source,
                         st.horizontal.angle, st.horizontal.confidence, st.vertical.angle, st.vertical.confidence,
                         st.combined.angle, st.combined.confidence, st.vision.map { String(format: "%+.2f", $0) } ?? "-"))
        }
        // Decision quality: refs (originals) should not be rotated; tilted variants should be corrected
        // relative to their own original (the original may itself be slightly tilted).
        let refs = Dictionary(grouping: rows.filter(\.isRef), by: \.seed).compactMapValues(\.first)
        var falseCorr = 0, refCount = 0, applied = 0, appliedGood = 0, variants = 0, precision: [Double] = []
        for row in rows {
            if row.isRef {
                refCount += 1
                if row.r.shouldApply { falseCorr += 1 }
                continue
            }
            guard abs(row.truth) > 0.05, let ref = refs[row.seed] else { continue }
            variants += 1
            let refTilt = ref.r.shouldApply ? ref.r.tilt : 0
            let expected = row.truth + refTilt
            if row.r.shouldApply {
                applied += 1
                if abs(row.r.tilt - expected) <= 0.5 { appliedGood += 1 }
            }
            precision.append(abs((row.r.combined.angle - ref.r.combined.angle) - row.truth))
        }
        let p = precision.sorted()
        print(String(format: "STRAIGHTEN: originals=%d rotated-without-need=%d (%.0f%%) | tilted variants=%d auto-corrected=%d correct(±0.5°)=%d | edge precision vs. own original: median %.2f° p75 %.2f°",
                     refCount, falseCorr, Double(falseCorr) * 100 / Double(max(1, refCount)), variants, applied, appliedGood,
                     p.isEmpty ? 0 : p[p.count / 2], p.isEmpty ? 0 : p[Int(Double(p.count - 1) * 0.75)]))
    }

    static func evalWB(folder: String) throws {
        var before: [Double] = [], after: [Double] = []
        for url in ImportService.collectImageURLs(from: [URL(fileURLWithPath: folder)]) {
            let base = url.deletingPathExtension().lastPathComponent
            guard let r = base.range(of: "__cast") else { continue }
            let parts = base[r.upperBound...].split(separator: "_").compactMap { Double($0) }
            guard parts.count == 2, let a = PhotoAnalyzer.analyze(url: url) else { continue }
            // Truth: the cast added relative to the seed's own (unknown) illuminant; compare the *change* the
            // engine applies to the known cast direction.
            let truth = (log(parts[0]), log(parts[1]))
            let est = (a.whiteBalance.logRG, a.whiteBalance.logBG)
            let out = AutoEnhanceEngine.enhance(a, strength: .balanced, options: AutoEnhanceOptions(tone: false, color: false, whiteBalance: true, straighten: false, perspective: false, detail: false)).recipe
            let g = WhiteBalanceModel.gains(temperature: out.temperature, tint: out.tint)
            let residual = (truth.0 + log(g.r / g.g), truth.1 + log(g.b / g.g))
            before.append(angle(truth.0, truth.1)); after.append(angle(residual.0, residual.1))
            print(String(format: "%@ cast(lnR,lnB)=(%+.2f,%+.2f) est=(%+.2f,%+.2f) conf=%.2f -> temp=%+.0f tint=%+.0f residual=%.1f°",
                         url.lastPathComponent, truth.0, truth.1, est.0, est.1, a.whiteBalance.confidence, out.temperature, out.tint, after.last!))
        }
        let m0 = before.sorted(), m1 = after.sorted()
        print(String(format: "WHITE BALANCE: n=%d cast median %.1f° -> residual median %.1f° (mean %.1f° -> %.1f°)",
                     m0.count, m0.isEmpty ? 0 : m0[m0.count / 2], m1.isEmpty ? 0 : m1[m1.count / 2],
                     before.reduce(0, +) / Double(max(1, before.count)), after.reduce(0, +) / Double(max(1, after.count))))
    }

    private static func angle(_ lr: Double, _ lb: Double) -> Double {
        let v = (exp(lr), 1.0, exp(lb))
        let d = (v.0 + v.1 + v.2) / (sqrt(3) * sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2))
        return acos(min(1, max(-1, d))) * 180 / .pi
    }

    static func evalPerspective(folder: String) throws {
        var errs: [Double] = []
        for url in ImportService.collectImageURLs(from: [URL(fileURLWithPath: folder)]) {
            let base = url.deletingPathExtension().lastPathComponent
            guard let r = base.range(of: "__key"), let truth = Double(base[r.upperBound...]), let a = PhotoAnalyzer.analyze(url: url) else { continue }
            let p = a.perspective
            let measured = p.vertical / PerspectiveEngine.naturalStrength
            errs.append(abs(measured - truth))
            print(String(format: "%@ truth cv=%+.3f measured=%+.3f conf=%.2f structure=%.2f apply=%@", url.lastPathComponent, truth, measured,
                         p.verticalConfidence, p.structureFraction, p.applyVertical ? "yes" : "no"))
        }
        let s = errs.sorted()
        print(String(format: "PERSPECTIVE: n=%d MAE=%.3f median=%.3f", s.count, errs.reduce(0, +) / Double(max(1, s.count)), s.isEmpty ? 0 : s[s.count / 2]))
    }

    // MARK: - Batch benchmark

    static func batch(folder: String, count: Int, concurrency: Int?) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlowQA-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try LibraryStore(directory: tmp.appendingPathComponent("lib"))
        var photos = try await ImportService(store: store).importItems([URL(fileURLWithPath: folder)]) { _ in }.imported
        guard !photos.isEmpty else { throw QAError(description: "no photos in \(folder)") }
        // Reach the requested count by cycling (each entry is processed independently)
        var list: [PhotoRecord] = []
        while list.count < count { list.append(contentsOf: photos.prefix(count - list.count)) }
        photos = list
        let hashesBefore = Dictionary(Set(photos.map(\.path)).map { ($0, FileHasher.sha256(URL(fileURLWithPath: $0)) ?? "") }, uniquingKeysWith: { a, _ in a })
        var wf = BatchWorkflow.predefined[0]
        wf.exportEnabled = true
        wf.export = ExportOptions()
        wf.export.format = .jpeg
        wf.export.quality = 0.85
        wf.export.destinationPath = tmp.appendingPathComponent("out").path
        let conc = concurrency ?? HardwareProfile.current.recommendedBatchConcurrency
        let runner = BatchRunner(store: store)
        let results = ResultBox()
        let monitor = PeakMonitor()
        monitor.start()
        let usageStart = cpuSeconds()
        let start = Date()
        await runner.run(photos, workflow: wf, existing: [:], customPresets: [], concurrency: conc, onStart: { _ in }) { r in results.add(r) }
        let wall = Date().timeIntervalSince(start)
        let cpu = cpuSeconds() - usageStart
        monitor.stop()
        let rs = results.all
        let ok = rs.filter { $0.status == .done }.count
        let failed = rs.count - ok
        var unchanged = 0
        for (path, h) in hashesBefore where FileHasher.sha256(URL(fileURLWithPath: path)) == h { unchanged += 1 }
        var metaKept = 0
        for r in rs.prefix(30) {
            if let u = r.exportedURL {
                let p = MetadataReader.properties(of: u)
                if (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] != nil { metaKept += 1 }
            }
        }
        let withDate = photos.prefix(30).filter { $0.captureDate != nil }.count
        print(String(format: "BATCH n=%d concurrency=%d ok=%d failed=%d wall=%.1fs (%.2fs/photo) cpu=%.1fs (avg %.0f%% of one core) peakMemory=%.0f MB",
                     photos.count, conc, ok, failed, wall, wall / Double(photos.count), cpu, cpu / wall * 100, Double(monitor.peak) / 1_048_576))
        print("originals unchanged: \(unchanged)/\(hashesBefore.count)  capture date preserved in sampled exports: \(metaKept)/\(min(30, rs.count)) (sources with date: \(withDate))")
        for r in rs where r.status != .done { if case .failed(let m) = r.status { print("  failed: \(m)") } }
    }

    final class ResultBox: @unchecked Sendable {
        private var items: [BatchItemResult] = []
        private let lock = NSLock()
        func add(_ r: BatchItemResult) { lock.lock(); items.append(r); lock.unlock() }
        var all: [BatchItemResult] { lock.lock(); defer { lock.unlock() }; return items }
    }

    final class PeakMonitor: @unchecked Sendable {
        private(set) var peak: UInt64 = 0
        private var timer: DispatchSourceTimer?
        func start() {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now(), repeating: .milliseconds(200))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.peak = max(self.peak, MemoryMonitor.footprintBytes())
            }
            t.resume()
            timer = t
        }
        func stop() { timer?.cancel(); timer = nil }
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    // MARK: - Single enhance (visual check)

    static func enhanceOne(input: String, output: String) throws {
        let url = URL(fileURLWithPath: input)
        guard let a = PhotoAnalyzer.analyze(url: url) else { throw QAError(description: "cannot analyze") }
        let out = AutoEnhanceEngine.enhance(a, strength: .balanced, options: .everything)
        print("scene: \(a.scene.topLabels.joined(separator: ", ")) faces=\(a.scene.faces.count)")
        print(String(format: "stats: p50=%.2f std=%.2f clipHi=%.3f sat=%.2f noise=%.4f cast=%.1f° conf=%.2f", a.stats.p50, a.stats.stdLuma,
                     a.stats.clippedHighlights, a.stats.meanSaturation, a.stats.noiseSigma, a.whiteBalance.castDegrees, a.whiteBalance.confidence))
        print("recipe: \(String(data: out.recipe.adjustmentsOnly.encoded(), encoding: .utf8) ?? "")")
        print("geometry: rotation=\(out.recipe.rotation) persp=\(out.recipe.perspectiveVertical),\(out.recipe.perspectiveHorizontal)")
        out.notes.forEach { print(" • \($0)") }
        var opts = ExportOptions()
        let o = URL(fileURLWithPath: output)
        opts.destinationPath = o.deletingLastPathComponent().path
        opts.filenamePattern = o.deletingPathExtension().lastPathComponent
        try ExportEngine.prepareDestination(opts)
        let rec = MetadataReader.record(for: url)!
        let res = try ExportEngine.export(photo: rec, recipe: out.recipe, options: opts, counter: 1)
        print("written: \(res.url.path)")
    }

    // MARK: - Image helpers

    static func render(_ ci: CIImage) -> CGImage {
        let img = ci.normalizedToOrigin()
        return CIContextProvider.shared.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: CIContextProvider.sRGB)!
    }

    static func writeJPEG(_ cg: CGImage, to url: URL, quality: Double) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw QAError(description: "jpeg") }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw QAError(description: "jpeg write") }
    }

    static func writePNG(_ cg: CGImage, to url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw QAError(description: "png") }
        CGImageDestinationAddImage(d, cg, nil)
        guard CGImageDestinationFinalize(d) else { throw QAError(description: "png write") }
    }

    /// Rotates by `degrees` (visual CCW) and crops to the inscribed rectangle – like a crooked photo.
    static func rotatedCrop(_ cg: CGImage, degrees: Double) -> CGImage {
        let ci = CIImage(cgImage: cg)
        guard degrees != 0 else { return cg }
        let model = GeometryModel(rotationDegrees: degrees)
        return render(ci.applyingGeometry(model, crop: nil))
    }

    /// Simple synthetic test scene (sky, horizon, posts, coloured patches).
    static func syntheticImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CIContextProvider.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.45, blue: 0.25, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1))
        for i in 0 ..< 9 { ctx.fill(CGRect(x: 60 + i * width / 10, y: height / 4, width: 10, height: height / 2)) }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.9, 0.8, 0.2), (0.2, 0.3, 0.8), (0.5, 0.5, 0.5)]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 100 + i * 150, y: 60, width: 110, height: 80))
        }
        return ctx.makeImage()!
    }
}
