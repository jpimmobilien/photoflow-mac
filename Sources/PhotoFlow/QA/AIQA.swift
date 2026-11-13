import Foundation
import CoreGraphics
import ImageIO
import CoreML

/// Headless tests for AI Studio (real downloads, real inference – no mocks).
///
///     PhotoFlow --qa ai-info
///     PhotoFlow --qa ai-install <model-id> [pause]
///     PhotoFlow --qa ai-t2i <out.png> [steps] [repeat]
///     PhotoFlow --qa ai-i2i <in> <out.png> [steps]
///     PhotoFlow --qa ai-inpaint <in> <out.png> [steps]
///     PhotoFlow --qa ai-outpaint <in> <out.png> [steps]
///     PhotoFlow --qa ai-remove <in> <out.png>
///     PhotoFlow --qa ai-upscale <in> <out.png> <factor>
///     PhotoFlow --qa ai-enhance <in> <out.png> <kind>
///     PhotoFlow --qa ai-cancel
///     PhotoFlow --qa ai-memory [runs]
///     PhotoFlow --qa ai-metadata <out.png>
///     PhotoFlow --qa ai-subject <in> <out.png>
/// Models are read from PHOTOFLOW_MODELS_DIR when set.
enum AIQA {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func run(_ cmd: String, _ a: [String]) async throws -> Bool {
        func arg(_ i: Int) throws -> String {
            guard i < a.count else { throw Failure(description: "missing argument #\(i + 1)") }
            return (a[i] as NSString).expandingTildeInPath
        }
        switch cmd {
        case "ai-info": info()
        case "ai-install": try await install(try arg(0), pauseTest: a.count > 1 && a[1] == "pause")
        case "ai-t2i": try t2i(out: try arg(0), steps: Int(a.count > 1 ? a[1] : "12") ?? 12, repeatCheck: a.count > 2 && a[2] == "repeat")
        case "ai-i2i": try i2i(input: try arg(0), out: try arg(1), steps: Int(a.count > 2 ? a[2] : "12") ?? 12)
        case "ai-inpaint": try inpaint(input: try arg(0), out: try arg(1), steps: Int(a.count > 2 ? a[2] : "12") ?? 12)
        case "ai-outpaint": try outpaint(input: try arg(0), out: try arg(1), steps: Int(a.count > 2 ? a[2] : "12") ?? 12)
        case "ai-remove": try remove(input: try arg(0), out: try arg(1))
        case "ai-upscale": try upscale(input: try arg(0), out: try arg(1), factor: Int(try arg(2)) ?? 4)
        case "ai-enhance": try enhance(input: try arg(0), out: try arg(1), kind: try arg(2))
        case "ai-cancel": try cancelTest()
        case "ai-memory": try memoryTest(runs: Int(a.first ?? "3") ?? 3)
        case "ai-metadata": try metadataTest(out: try arg(0))
        case "ai-subject": try subject(input: try arg(0), out: try arg(1))
        case "ai-diag": try diagnose(try arg(0))
        default: return false
        }
        return true
    }

    // MARK: Info & install

    static func info() {
        let hw = AIHardware.current
        print("ai hardware: \(hw.summary)")
        print("ai tier: \(hw.tier.rawValue) backends: \(hw.backends) maxVariants: \(hw.maxVariants) free disk: \(hw.freeDiskBytes.formattedBytes)")
        print("ai recommended diffusion model: \(hw.recommendedDiffusionModelID)")
        print("ai prompt assistant (Apple Intelligence): \(PromptAssistant.languageModelAvailable)")
        print("ai models dir: \(ModelStore.rootURL.path)")
        let snap = ModelStoreSnapshot.current
        for m in AIModelCatalog.all {
            let ok = hw.incompatibility(of: m) ?? "ok"
            print("  \(m.id): \(m.downloadSize.formattedBytes), \(m.files.count) files, licence \(m.license.name), installed=\(snap.installedIDs.contains(m.id)), compatible=\(ok)")
        }
    }

    static func install(_ id: String, pauseTest: Bool) async throws {
        guard let m = AIModelCatalog.model(id) else { throw Failure(description: "unknown model \(id)") }
        if let r = AIHardware.current.incompatibility(of: m) { print("note: \(r)") }
        let started = Date()
        var lastPrint = Date.distantPast
        let report: (ModelInstallState) -> Void = { s in
            switch s {
            case .downloading(let p):
                if Date().timeIntervalSince(lastPrint) > 5 {
                    lastPrint = Date()
                    print(String(format: "  %.1f %% %@ / %@ speed=%@ eta=%@ file %d/%d", p.fraction * 100, p.received.formattedBytes, p.total.formattedBytes,
                                 p.bytesPerSecond.map { Int64($0).formattedBytes + "/s" } ?? "-", p.remainingSeconds.map { "\(Int($0))s" } ?? "-",
                                 p.fileIndex, p.fileCount))
                }
            case .verifying(let f): print("  verifying \(f)")
            case .installing: print("  installing")
            default: break
            }
        }
        if pauseTest {
            let control = DownloadControl()
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { print("  → pause requested"); control.requestPause() }
            do {
                _ = try await ModelInstaller(model: m, control: control, report: report).run()
                print("  (finished before pause)")
            } catch {
                print("  paused: \(type(of: error))")
                let partial = ModelStore.partialDirectory(for: m.id)
                let size = ModelInstaller.directorySize(partial)
                print("  partial bytes kept: \(size.formattedBytes)")
                guard FileManager.default.fileExists(atPath: partial.path) else { throw Failure(description: "partial download was not kept") }
            }
            print("  → resume")
        }
        let rec = try await ModelInstaller(model: m, control: DownloadControl(), report: report).run()
        print("installed \(rec.id) rev \(rec.revision.prefix(12)) size \(rec.bytes.formattedBytes) in \(Int(Date().timeIntervalSince(started))) s")
        // Re-verify one file of the installed copy (checksum test of the final location).
        if !m.isArchive, let f = m.files.max(by: { $0.size < $1.size }) {
            let sha = try ModelInstaller.sha256(of: ModelStore.directory(for: m.id).appendingPathComponent(f.path))
            guard sha == f.sha256 else { throw Failure(description: "checksum mismatch after install: \(f.path)") }
            print("checksum ok: \(f.path)")
        }
        // Corruption test on a copy of the smallest file: a damaged file must be rejected.
        if let f = m.files.min(by: { $0.size < $1.size }) {
            let src = m.isArchive ? nil : ModelStore.directory(for: m.id).appendingPathComponent(f.path)
            if let src, var data = try? Data(contentsOf: src), !data.isEmpty {
                data[data.count / 2] ^= 0xFF
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-corrupt-test")
                try data.write(to: tmp)
                let sha = try ModelInstaller.sha256(of: tmp)
                print("corrupted copy rejected: \(sha != f.sha256)")
                guard sha != f.sha256 else { throw Failure(description: "corruption not detected") }
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    // MARK: Helpers

    static func diffusionModel() throws -> AIModelDescriptor {
        let snap = ModelStoreSnapshot.current
        if let id = ProcessInfo.processInfo.environment["PHOTOFLOW_AI_MODEL"], let m = AIModelCatalog.model(id), snap.installedIDs.contains(id) { return m }
        guard let m = AIModelCatalog.diffusionModels.first(where: { snap.installedIDs.contains($0.id) && AIHardware.current.incompatibility(of: $0) == nil }) else {
            throw Failure(description: "no diffusion model installed")
        }
        return m
    }

    static func settings(_ prompt: String, steps: Int) throws -> GenerationSettings {
        GenerationSettings(model: try diffusionModel(), prompt: prompt, style: AIStyle.style("photo"), steps: steps)
    }

    static func load(_ path: String, maxPixel: Int = 1600) throws -> CGImage {
        try AIImage.load(url: URL(fileURLWithPath: path), maxPixel: maxPixel)
    }

    static func save(_ image: CGImage, _ path: String, kind: AIOperationKind, prompt: String, model: String, seed: UInt32?) throws {
        let c = AICreation(kind: kind, prompt: prompt, modelID: model, modelName: model, seed: seed, width: image.width, height: image.height,
                           duration: 0, fileName: "")
        guard let d = AIMetadata.png(image, for: c) else { throw Failure(description: "png encode failed") }
        try d.write(to: URL(fileURLWithPath: path))
    }

    static func stepLogger(_ label: String) -> (StepReport) -> Void {
        let start = Date()
        return { r in
            if r.step == 1 || r.step == r.stepCount || r.step % 4 == 0 {
                print(String(format: "  [%@] step %d/%d  %.1fs  sec/step=%@  footprint=%@", label, r.step, r.stepCount, Date().timeIntervalSince(start),
                             r.secondsPerStep.map { String(format: "%.2f", $0) } ?? "-", Int64(MemoryMonitor.footprintBytes()).formattedBytes))
            }
        }
    }

    /// Mean / std of luma and the fraction of near-black pixels.
    static func stats(_ img: CGImage) -> (mean: Double, std: Double, black: Double) {
        guard let pb = PixelBuffer(cgImage: img, maxSide: 256) else { return (0, 0, 1) }
        let l = pb.luma()
        let mean = Double(l.reduce(0, +)) / Double(l.count)
        let v = l.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(l.count)
        let black = Double(l.filter { $0 < 0.02 }.count) / Double(l.count)
        return (mean, sqrt(v), black)
    }

    static func checkPlausible(_ img: CGImage, _ label: String) throws {
        let s = stats(img)
        print(String(format: "  %@: %dx%d mean=%.3f std=%.3f black=%.3f", label, img.width, img.height, s.mean, s.std, s.black))
        guard s.std > 0.03, s.black < 0.9 else { throw Failure(description: "\(label): image looks empty or black") }
    }

    /// Mean absolute difference (0…1) inside / outside a region given in top-left pixel coordinates.
    static func diff(_ a: CGImage, _ b: CGImage, inside region: CGRect?) -> (inside: Double, outside: Double) {
        guard a.width == b.width, a.height == b.height,
              let pa = PixelBuffer(cgImage: a, maxSide: max(a.width, a.height)), let pb = PixelBuffer(cgImage: b, maxSide: max(b.width, b.height)) else { return (1, 1) }
        var si = 0.0, ni = 0.0, so = 0.0, no = 0.0
        for y in stride(from: 0, to: pa.height, by: 2) {
            for x in stride(from: 0, to: pa.width, by: 2) {
                let i = (y * pa.width + x) * 4
                let d = (abs(Double(pa.data[i]) - Double(pb.data[i])) + abs(Double(pa.data[i + 1]) - Double(pb.data[i + 1])) + abs(Double(pa.data[i + 2]) - Double(pb.data[i + 2]))) / (3 * 255)
                if let region, region.contains(CGPoint(x: x, y: y)) { si += d; ni += 1 } else { so += d; no += 1 }
            }
        }
        return (ni > 0 ? si / ni : 0, no > 0 ? so / no : 0)
    }

    static func rectMask(_ w: Int, _ h: Int, _ r: CGRect) -> CGImage? {
        AIImage.grayMask(width: w, height: h) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
        }
    }

    // MARK: Tests

    static func t2i(out: String, steps: Int, repeatCheck: Bool) throws {
        let s = try settings("a cozy wooden cabin by a mountain lake at sunset, warm light in the windows", steps: steps)
        print("t2i model=\(s.model.id) steps=\(steps) units=\(AIHardware.current.computeUnits(for: .current).rawValue)")
        let before = MemoryMonitor.footprintBytes()
        let t0 = Date()
        let img = try AIOperations.textToImage(s, aspect: .square, seed: 42, token: AICancelToken(), onStep: stepLogger("t2i"))
        print(String(format: "t2i done in %.1fs (incl. model load) footprint %@ → %@", Date().timeIntervalSince(t0),
                     Int64(before).formattedBytes, Int64(MemoryMonitor.footprintBytes()).formattedBytes))
        try checkPlausible(img, "t2i")
        guard img.width == s.model.resolution else { throw Failure(description: "unexpected size \(img.width)") }
        try save(img, out, kind: .textToImage, prompt: s.prompt, model: s.model.id, seed: 42)
        let wide = try AIOperations.textToImage(s, aspect: .wide16x9, seed: 42, token: AICancelToken(), onStep: { _ in })
        print("t2i 16:9 → \(wide.width)x\(wide.height)")
        guard abs(Double(wide.width) / Double(wide.height) - 16.0 / 9) < 0.02 else { throw Failure(description: "aspect crop wrong") }
        if repeatCheck {
            let again = try AIOperations.textToImage(s, aspect: .square, seed: 42, token: AICancelToken(), onStep: { _ in })
            let d = diff(img, again, inside: nil).outside
            print(String(format: "t2i reproducibility (same seed): mean diff %.5f", d))
            guard d < 0.01 else { throw Failure(description: "same seed did not reproduce the image") }
            let other = try AIOperations.textToImage(s, aspect: .square, seed: 7, token: AICancelToken(), onStep: { _ in })
            let d2 = diff(img, other, inside: nil).outside
            print(String(format: "t2i different seed: mean diff %.4f", d2))
            guard d2 > 0.03 else { throw Failure(description: "different seeds gave the same image") }
        }
        print("t2i OK")
    }

    static func i2i(input: String, out: String, steps: Int) throws {
        let src = try load(input)
        let s = try settings("the same scene in winter, snow on the ground, overcast sky", steps: steps)
        let img = try AIOperations.imageToImage(src, s, strength: 0.55, seed: 3, token: AICancelToken(), onStep: stepLogger("i2i"))
        try checkPlausible(img, "i2i")
        let r = Double(src.width) / Double(src.height), r2 = Double(img.width) / Double(img.height)
        print(String(format: "i2i aspect source %.3f result %.3f", r, r2))
        guard abs(r - r2) < 0.03 else { throw Failure(description: "aspect ratio not preserved") }
        try save(img, out, kind: .imageToImage, prompt: s.prompt, model: s.model.id, seed: 3)
        print("i2i OK")
    }

    static func inpaint(input: String, out: String, steps: Int) throws {
        let src = try load(input)
        let r = CGRect(x: src.width / 3, y: src.height / 3, width: src.width / 3, height: src.height / 3)
        guard let mask = rectMask(src.width, src.height, r) else { throw Failure(description: "mask") }
        let s = try settings("a large green potted plant", steps: steps)
        let img = try AIOperations.generativeFill(src, mask: mask, s, feather: 8, seed: 11, token: AICancelToken(), onStep: stepLogger("inpaint"))
        let d = diff(src, img, inside: r.insetBy(dx: -24, dy: -24))
        let inner = diff(src, img, inside: r.insetBy(dx: 12, dy: 12)).inside
        print(String(format: "inpaint: changed inside %.4f, outside (excluding 24 px band) %.5f", inner, d.outside))
        guard inner > 0.02 else { throw Failure(description: "masked area did not change") }
        guard d.outside < 0.002 else { throw Failure(description: "pixels outside the mask changed") }
        try save(img, out, kind: .fill, prompt: s.prompt, model: s.model.id, seed: 11)
        print("inpaint OK")
    }

    static func outpaint(input: String, out: String, steps: Int) throws {
        let src = try load(input, maxPixel: 1024)
        let e = AIOperations.Expansion(left: src.width / 4, top: 0, right: src.width / 4, bottom: src.height / 8)
        let s = try settings("seamless natural continuation of the scene", steps: steps)
        let img = try AIOperations.expand(src, by: e, s, seed: 5, token: AICancelToken(), onStep: stepLogger("outpaint"))
        print("outpaint \(src.width)x\(src.height) → \(img.width)x\(img.height)")
        guard img.width == src.width + e.left + e.right, img.height == src.height + e.top + e.bottom else { throw Failure(description: "wrong size") }
        // Original area (minus the blend band) must be unchanged.
        let band = Double(max(img.width, img.height)) * 0.015 * 1.6
        let inner = CGRect(x: Double(e.left) + band, y: Double(e.top) + band, width: Double(src.width) - 2 * band, height: Double(src.height) - 2 * band)
        guard let crop = AIImage.crop(img, CGRect(x: e.left, y: e.top, width: src.width, height: src.height)) else { throw Failure(description: "crop") }
        let shifted = CGRect(x: inner.minX - Double(e.left), y: inner.minY - Double(e.top), width: inner.width, height: inner.height)
        let d = diff(src, crop, inside: shifted).inside
        print(String(format: "outpaint original area diff %.5f", d))
        guard d < 0.002 else { throw Failure(description: "original pixels changed") }
        guard let newArea = AIImage.crop(img, CGRect(x: 0, y: 0, width: e.left, height: img.height)) else { throw Failure(description: "crop") }
        try checkPlausible(newArea, "outpaint new area")
        try save(img, out, kind: .expand, prompt: s.prompt, model: s.model.id, seed: 5)
        print("outpaint OK")
    }

    static func remove(input: String, out: String) throws {
        let src = try load(input)
        let r = CGRect(x: src.width * 2 / 5, y: src.height * 2 / 5, width: src.width / 5, height: src.height / 5)
        guard let mask = rectMask(src.width, src.height, r) else { throw Failure(description: "mask") }
        let t0 = Date()
        let res = try AIOperations.removeObject(src, mask: mask, token: AICancelToken(), fallback: nil, onStep: { _ in })
        let d = diff(src, res.image, inside: r.insetBy(dx: -CGFloat(src.width) / 10, dy: -CGFloat(src.width) / 10))
        print(String(format: "remove (LaMa) %.1fs, inside changed %.4f, outside %.5f", Date().timeIntervalSince(t0), d.inside, d.outside))
        guard !res.usedDiffusionFallback, d.inside > 0.005, d.outside < 0.002 else { throw Failure(description: "removal check failed") }
        try save(res.image, out, kind: .remove, prompt: "", model: "lama", seed: nil)
        print("remove OK")
    }

    static func upscale(input: String, out: String, factor: Int) throws {
        let src = try load(input, maxPixel: 600)
        let t0 = Date()
        let img = try AIOperations.upscale(src, factor: factor, token: AICancelToken()) { _ in }
        print(String(format: "upscale %dx: %dx%d → %dx%d in %.1fs", factor, src.width, src.height, img.width, img.height, Date().timeIntervalSince(t0)))
        guard img.width == src.width * factor, img.height == src.height * factor else { throw Failure(description: "wrong output size") }
        // Downscaled result must match the input closely (structure preserved, no tile seams/shifts).
        guard let back = AIImage.resize(img, width: src.width, height: src.height) else { throw Failure(description: "resize") }
        let d = diff(src, back, inside: nil).outside
        print(String(format: "upscale consistency: mean diff %.4f", d))
        guard d < 0.05 else { throw Failure(description: "upscaled image deviates from the input") }
        try checkPlausible(img, "upscale")
        try save(img, out, kind: .upscale, prompt: "", model: "realesrgan", seed: nil)
        print("upscale OK")
    }

    static func enhance(input: String, out: String, kind: String) throws {
        guard let k = AIOperations.EnhanceKind(rawValue: kind) else { throw Failure(description: "unknown kind") }
        let src = try load(input, maxPixel: 1200)
        let img = try AIOperations.enhance(src, kind: k, amount: 1, token: AICancelToken()) { _ in }
        guard img.width == src.width, img.height == src.height else { throw Failure(description: "size changed") }
        print(String(format: "enhance %@: diff to source %.4f", kind, diff(src, img, inside: nil).outside))
        try save(img, out, kind: .enhance, prompt: "", model: kind, seed: nil)
        print("enhance OK")
    }

    static func subject(input: String, out: String) throws {
        let src = try load(input)
        let m = try AIOperations.subjectMask(src)
        print(String(format: "subject coverage %.3f", AIImage.maskCoverage(m)))
        guard let d = AIImage.pngData(m) else { throw Failure(description: "encode") }
        try d.write(to: URL(fileURLWithPath: out))
        print("subject OK")
    }

    /// Loads every sub-model of a diffusion model with each compute-unit setting and runs one prediction
    /// with neutral inputs – shows which backend works on this Mac.
    static func diagnose(_ id: String) throws {
        let dir = ModelStore.directory(for: id)
        let parts = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.hasSuffix(".mlmodelc") }.sorted()
        let unitSets: [(String, MLComputeUnits)] = [("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU), ("all", .all)]
        for p in parts {
            for (name, units) in unitSets {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = units
                let t0 = Date()
                do {
                    let m = try MLModel(contentsOf: dir.appendingPathComponent(p), configuration: cfg)
                    var dict: [String: MLFeatureValue] = [:]
                    for (k, d) in m.modelDescription.inputDescriptionsByName {
                        if let c = d.multiArrayConstraint {
                            let a = try MLMultiArray(shape: c.shape, dataType: c.dataType == .float16 ? .float16 : .float32)
                            for i in 0..<a.count { a[i] = 0.01 }
                            dict[k] = MLFeatureValue(multiArray: a)
                        }
                    }
                    let tl = Date().timeIntervalSince(t0)
                    let t1 = Date()
                    _ = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: dict))
                    print(String(format: "diag %@ %@: OK load %.1fs predict %.2fs", p, name, tl, Date().timeIntervalSince(t1)))
                } catch {
                    print("diag \(p) \(name): FAIL \(String(describing: error).prefix(160))")
                }
            }
        }
    }

    static func cancelTest() throws {
        let s = try settings("a lighthouse on a cliff in a storm", steps: 30)
        let token = AICancelToken()
        var cancelledAt: Date?
        var lastStep = 0
        let t0 = Date()
        do {
            _ = try AIOperations.textToImage(s, aspect: .square, seed: 1, token: token) { r in
                lastStep = r.step
                if r.step == 2 && cancelledAt == nil { cancelledAt = Date(); token.cancel() }
            }
            throw Failure(description: "generation was not cancelled")
        } catch AIError.cancelled {
            let latency = Date().timeIntervalSince(cancelledAt ?? t0)
            print(String(format: "cancel: stopped after step %d, %.2fs after the request (total %.1fs)", lastStep, latency, Date().timeIntervalSince(t0)))
            guard lastStep <= 4 else { throw Failure(description: "cancellation too slow") }
        }
        // The engine must still work after a cancellation.
        let img = try AIOperations.textToImage(s.with(steps: 8), aspect: .square, seed: 2, token: AICancelToken(), onStep: { _ in })
        try checkPlausible(img, "after cancel")
        print("cancel OK")
    }

    static func memoryTest(runs: Int) throws {
        let s = try settings("a bowl of fresh fruit on a wooden table", steps: 8)
        let base = MemoryMonitor.footprintBytes()
        print("memory: start \(Int64(base).formattedBytes) (physical \(Int64(ProcessInfo.processInfo.physicalMemory).formattedBytes))")
        var peaks: [UInt64] = []
        for i in 0..<runs {
            var peak: UInt64 = 0
            _ = try AIOperations.textToImage(s, aspect: .square, seed: UInt32(100 + i), token: AICancelToken()) { _ in
                peak = max(peak, MemoryMonitor.footprintBytes())
            }
            peaks.append(peak)
            print("memory: run \(i + 1) peak \(Int64(peak).formattedBytes) after \(Int64(MemoryMonitor.footprintBytes()).formattedBytes)")
        }
        let sem = DispatchSemaphore(value: 0)
        DiffusionEngine.shared.unload()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { sem.signal() }
        sem.wait()
        let after = MemoryMonitor.footprintBytes()
        print("memory: after unload \(Int64(after).formattedBytes)")
        if peaks.count >= 2 {
            let growth = Double(peaks.last!) - Double(peaks[1])
            print(String(format: "memory: growth between run 2 and run %d: %.0f MB", peaks.count, growth / 1e6))
            guard growth < 400e6 else { throw Failure(description: "memory keeps growing between runs") }
        }
        guard after < (peaks.max() ?? after) else { throw Failure(description: "memory was not released after unloading") }
        print("memory OK")
    }

    static func metadataTest(out: String) throws {
        guard let img = AIImage.draw(width: 64, height: 64, { $0.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }) else { return }
        try save(img, out, kind: .textToImage, prompt: "metadata test", model: "sd21-fp16", seed: 9)
        let t = AIMetadata.digitalSourceType(of: URL(fileURLWithPath: out))
        print("metadata DigitalSourceType: \(t ?? "nil")")
        guard t?.hasSuffix("trainedAlgorithmicMedia") == true else { throw Failure(description: "AI provenance missing") }
        print("metadata OK")
    }
}

extension GenerationSettings {
    func with(steps: Int) -> GenerationSettings { var s = self; s.steps = steps; return s }
}
