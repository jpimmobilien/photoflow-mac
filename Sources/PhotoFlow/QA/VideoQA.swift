import Foundation
import AVFoundation
import CoreImage
import Vision

/// Command-line tests for the Video-KI (real models, real inference, no mocks):
///     PhotoFlow --qa video-install <model-id>            runtime + text encoder + model, verified
///     PhotoFlow --qa video-engine                        starts the engine, prints versions and device
///     PhotoFlow --qa video-t2v <out.mp4> [w h frames steps]
///     PhotoFlow --qa video-i2v <image> <out.mp4> [w h frames steps]
///     PhotoFlow --qa video-v2v <in.mp4> <out.mp4> [strength steps]
///     PhotoFlow --qa video-clip <image> <out.mp4> [seconds]   test clip (slow pan over a photo)
///     PhotoFlow --qa video-background <in.mp4> <out.mp4> [blur|<image>]
///     PhotoFlow --qa video-optimize <in.mp4> <out.mp4> [stabilize]
///     PhotoFlow --qa video-acceptance [--model id] [--out dir] [--runs n]
enum VideoQA {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func run(_ cmd: String, _ a: [String]) async throws -> Bool {
        func arg(_ i: Int) throws -> String {
            guard i < a.count else { throw Failure(description: "missing argument #\(i + 1)") }
            return (a[i] as NSString).expandingTildeInPath
        }
        func int(_ i: Int, _ d: Int) -> Int { i < a.count ? Int(a[i]) ?? d : d }
        switch cmd {
        case "video-install": try await install(try arg(0))
        case "video-engine": try await engineCheck()
        case "video-t2v":
            let r = try await generate("t2v", out: URL(fileURLWithPath: try arg(0)), image: nil, video: nil,
                                       w: int(1, 480), h: int(2, 288), frames: int(3, 25), steps: int(4, 12))
            try check(r)
        case "video-i2v":
            let r = try await generate("i2v", out: URL(fileURLWithPath: try arg(1)), image: URL(fileURLWithPath: try arg(0)), video: nil,
                                       w: int(2, 512), h: int(3, 288), frames: int(4, 25), steps: int(5, 12))
            try check(r)
        case "video-v2v":
            let r = try await generate("v2v", out: URL(fileURLWithPath: try arg(1)), image: nil, video: URL(fileURLWithPath: try arg(0)),
                                       w: 480, h: 288, frames: 25, steps: int(3, 12), strength: Double(a.count > 2 ? a[2] : "0.6") ?? 0.6)
            try check(r)
        case "video-clip": try await makeClip(image: URL(fileURLWithPath: try arg(0)), out: URL(fileURLWithPath: try arg(1)), seconds: Double(a.count > 2 ? a[2] : "3") ?? 3)
        case "video-background": try await background(URL(fileURLWithPath: try arg(0)), URL(fileURLWithPath: try arg(1)), bg: a.count > 2 ? a[2] : "blur")
        case "video-optimize": try await optimize(URL(fileURLWithPath: try arg(0)), URL(fileURLWithPath: try arg(1)), stabilize: a.count > 2 && a[2] == "stabilize")
        case "video-acceptance": try await acceptance(a)
        case "video-sheet": try await sheet(URL(fileURLWithPath: try arg(0)), URL(fileURLWithPath: try arg(1)))
        default: return false
        }
        VideoEngineClient.shared.stop()
        return true
    }

    // MARK: Install / engine

    static func install(_ id: String) async throws {
        guard let m = AIModelCatalog.model(id) else { throw Failure(description: "unknown model \(id)") }
        for dep in m.dependencies + [m.id] where !ModelStoreSnapshot.current.installedIDs.contains(dep) {
            print("== install \(dep)")
            try await AIQA.install(dep, pauseTest: false)
        }
        if m.kind == .video || m.kind == .runtime { try await engineCheck() }
    }

    static func engineCheck() async throws {
        let t = Date()
        let ev = try await VideoEngineClient.shared.hello()
        print("video engine: \(ev.json.filter { $0.key != "id" && $0.key != "event" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")) start \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
    }

    static func videoModel(_ cap: AICapability) throws -> AIModelDescriptor {
        let snap = ModelStoreSnapshot.current
        if let id = ProcessInfo.processInfo.environment["PHOTOFLOW_VIDEO_MODEL"], let m = AIModelCatalog.model(id), snap.installedIDs.contains(id), m.capabilities.contains(cap) { return m }
        guard let m = AIModelCatalog.videoModels.first(where: { $0.capabilities.contains(cap) && snap.installedIDs.contains($0.id) }) else {
            throw Failure(description: "no installed video model for \(cap.rawValue)")
        }
        return m
    }

    struct GenResult {
        var event: VideoEngineClient.Event
        var out: URL
        var seconds: Double
        var secondsPerStep: Double?
        var model: AIModelDescriptor
    }

    static func generate(_ cmd: String, out: URL, image: URL?, video: URL?, w: Int, h: Int, frames: Int, steps: Int,
                         strength: Double = 0.6, seed: Int = 42, prompt: String? = nil, cancelAfter: Int? = nil) async throws -> GenResult {
        let cap: AICapability = cmd == "i2v" ? .imageToVideo : cmd == "v2v" ? .videoToVideo : .textToVideo
        let model = try videoModel(cap)
        let engine = VideoEngineClient.shared
        try await engine.load(model)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pf-video-qa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        var args: [String: Any] = ["prompt": prompt ?? "A red vintage car driving along a coastal road at sunset, the camera follows from the side, realistic lighting, smooth motion",
                                   "negative_prompt": "blurry, low quality, distorted, flickering, static, worst quality, watermark, text",
                                   "width": w, "height": h, "frames": frames, "steps": steps, "seed": seed, "guidance": 5.0,
                                   "flow_shift": 3.0, "out": work.appendingPathComponent("frames").path]
        if let image {
            let cg = VideoIO.loadCGImage(image)
            guard let cg else { throw Failure(description: "cannot read \(image.path)") }
            let fitted = VideoIO.fill(CIImage(cgImage: cg), to: CGSize(width: w, height: h))
            let p = work.appendingPathComponent("src.png")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try VideoIO.writePNG(CIContext().createCGImage(fitted, from: CGRect(x: 0, y: 0, width: w, height: h))!, to: p)
            args["image"] = p.path
            if prompt == nil { args["prompt"] = VideoAIModel.describe(cg) + ", natural subtle motion, the camera slowly pushes in" }
        }
        if let video {
            let dir = work.appendingPathComponent("src", isDirectory: true)
            let info = try await VideoIO.info(video)
            let n = min(frames, max(5, Int(info.duration * Double(model.videoFPS)) / 4 * 4 + 1))
            try await VideoIO.extractFrames(from: video, fps: Double(model.videoFPS), count: n, size: CGSize(width: w, height: h), to: dir)
            args["video_frames"] = dir.path
            args["strength"] = strength
            args["frames"] = n
            if prompt == nil { args["prompt"] = "The same scene in winter, snow covered landscape, overcast light" }
        }
        let t0 = Date()
        var lastStep = 0
        var lastElapsed = 0.0
        let ev = try await engine.request(cmd, args) { e in
            if e.kind == "progress" {
                lastStep = e.int("step") ?? 0
                lastElapsed = e.double("elapsed") ?? 0
                print(String(format: "   step %d/%d  %.0fs", lastStep, e.int("total") ?? 0, lastElapsed))
                if let c = cancelAfter, lastStep == c { engine.cancelCurrent() }
            }
        }
        let secs = Date().timeIntervalSince(t0)
        if ev.kind == "result" {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await VideoIO.writeMovie(frames: work.appendingPathComponent("frames"), fps: model.videoFPS, to: out,
                                         metadata: VideoIO.AIMetadata(generated: cmd != "v2v", model: model.name, prompt: args["prompt"] as? String ?? "", operation: cmd, seed: UInt32(seed)),
                                         audioFrom: video)
        }
        return GenResult(event: ev, out: out, seconds: secs, secondsPerStep: lastStep > 0 ? lastElapsed / Double(lastStep) : nil, model: model)
    }

    static func check(_ r: GenResult) throws {
        let e = r.event
        let valid = (e["valid"] as? Bool) ?? false
        print("video \(r.model.id): valid=\(valid) frames=\(e.int("frames") ?? 0) \(e.int("width") ?? 0)x\(e.int("height") ?? 0) time=\(String(format: "%.1f", r.seconds))s s/step=\(r.secondsPerStep.map { String(format: "%.2f", $0) } ?? "-") peak=\(e.double("peak_rss_gb") ?? 0) GB reasons=\((e["reasons"] as? [String]) ?? [])")
        if let m = e["metrics"] as? [String: Any] { print("  metrics: motion=\(m["mean_frame_diff"] ?? "-") flicker=\(m["brightness_flicker"] ?? "-") worst_std=\(m["worst_std"] ?? "-") worst_noise=\(m["worst_noise"] ?? "-")") }
        guard valid else { throw Failure(description: "invalid video: \((e["reasons"] as? [String]) ?? [])") }
        print("  wrote \(r.out.path)")
    }

    // MARK: Non-generative tools

    /// A real test clip: slow pan and zoom over a photo (for background replacement / optimisation tests).
    static func makeClip(image: URL, out: URL, seconds: Double) async throws {
        guard let cg = VideoIO.loadCGImage(image) else { throw Failure(description: "cannot read \(image.path)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = Int(seconds * 25)
        let size = CGSize(width: 960, height: 540)
        let ctx = CIContext()
        let src = CIImage(cgImage: cg)
        for i in 0..<n {
            let f = Double(i) / Double(max(1, n - 1))
            let zoom = 1.0 + 0.12 * f
            let shake = CGPoint(x: sin(Double(i) * 1.7) * 6, y: cos(Double(i) * 2.3) * 5)   // hand-held shake
            var img = src.transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.width * 0.04 * f + shake.x, y: shake.y))
            img = VideoIO.fill(img, to: size)
            try VideoIO.writePNG(ctx.createCGImage(img, from: CGRect(origin: .zero, size: size))!, to: dir.appendingPathComponent(String(format: "f_%05d.png", i)))
        }
        try await VideoIO.writeMovie(frames: dir, fps: 25, to: out, metadata: nil)
        print("clip: \(out.path) \(n) frames")
    }

    static func background(_ input: URL, _ out: URL, bg: String) async throws {
        let background: VideoBackgroundReplacer.Background
        if bg == "blur" { background = .blur(24) }
        else if let cg = VideoIO.loadCGImage(URL(fileURLWithPath: (bg as NSString).expandingTildeInPath)) { background = .image(CIImage(cgImage: cg)) }
        else { background = .color(CIColor(red: 0.1, green: 0.5, blue: 0.9)) }
        let t = Date()
        try await VideoBackgroundReplacer.run(input, background: background, subject: .people, to: out, isCancelled: { false }) { _ in }
        let info = try await VideoIO.info(out)
        print(String(format: "background: %@ %.1f s video in %.1f s, %d×%d", out.lastPathComponent, info.duration, Date().timeIntervalSince(t), Int(info.size.width), Int(info.size.height)))
        try await compare(input, out, expectChange: true)
    }

    static func optimize(_ input: URL, _ out: URL, stabilize: Bool) async throws {
        let t = Date()
        let plan = try await VideoOptimizer.analyze(input, options: .init(color: true, stabilize: stabilize, strength: .balanced), isCancelled: { false }) { _ in }
        print("optimize plan: cuts=\(plan.cuts.count) keyframes=\(plan.recipes.count) zoom=\(String(format: "%.3f", plan.zoom)) notes=\(plan.notes.prefix(3))")
        try await VideoOptimizer.run(input, plan: plan, to: out, isCancelled: { false }) { _ in }
        print(String(format: "optimize: done in %.1f s", Date().timeIntervalSince(t)))
        try await compare(input, out, expectChange: true)
        if stabilize { try await shakeCompare(input, out) }
    }

    /// Reads both videos back: same length, real content, temporal stability (no flicker introduced).
    static func compare(_ a: URL, _ b: URL, expectChange: Bool) async throws {
        let ia = try await VideoIO.info(a), ib = try await VideoIO.info(b)
        guard abs(ia.duration - ib.duration) < 0.25 else { throw Failure(description: "duration changed \(ia.duration) → \(ib.duration)") }
        let src = try await VideoFrameProcessor.open(b)
        var lumas: [Double] = []
        let ctx = CIContext()
        var verdicts: [AIImageValidator.Verdict] = []
        try VideoFrameProcessor.forEachFrame(src, maxSize: 256) { img, i, _ in
            if let cg = ctx.createCGImage(img, from: img.extent) {
                let m = AIImageValidator.metrics(cg)
                lumas.append(m.mean)
                if i % 10 == 0 { verdicts.append(AIImageValidator.check(cg)) }
            }
            return true
        }
        let d = zip(lumas.dropFirst(), lumas).map { $0 - $1 }
        let flicker = zip(d.dropFirst(), d).map { max(0, -($0 * $1)).squareRoot() }.reduce(0, +) / Double(max(1, d.count - 1))
        let bad = verdicts.filter { !$0.valid }.count
        print(String(format: "  read back: %d frames, %.1f s, brightness flicker %.4f, invalid sampled frames %d/%d, audio %@",
                     lumas.count, ib.duration, flicker, bad, verdicts.count, ib.hasAudio ? "yes" : "no"))
        guard bad == 0 else { throw Failure(description: "invalid frames in output") }
        guard flicker < 0.02 else { throw Failure(description: "output flickers (\(flicker))") }
        guard ia.hasAudio == ib.hasAudio else { throw Failure(description: "audio track lost") }
    }

    /// Frame-to-frame translation before vs after stabilisation (Vision registration on both).
    static func shakeCompare(_ a: URL, _ b: URL) async throws {
        func jitter(_ u: URL) async throws -> Double {
            let src = try await VideoFrameProcessor.open(u)
            var prev: CGImage?
            var moves: [CGPoint] = []
            let ctx = CIContext()
            try VideoFrameProcessor.forEachFrame(src, maxSize: 384) { img, _, _ in
                guard let cg = ctx.createCGImage(img, from: img.extent) else { return true }
                if let p = prev {
                    let r = VNTranslationalImageRegistrationRequest(targetedCGImage: cg)
                    try? VNImageRequestHandler(cgImage: p).perform([r])
                    let t = r.results?.first?.alignmentTransform ?? .identity
                    moves.append(CGPoint(x: t.tx, y: t.ty))
                }
                prev = cg
                return true
            }
            // jitter = deviation of each move from the local average motion (shake, not the intended pan)
            guard moves.count > 4 else { return 0 }
            var s = 0.0
            for i in 2..<(moves.count - 2) {
                let ax = (moves[i - 2].x + moves[i - 1].x + moves[i + 1].x + moves[i + 2].x) / 4
                let ay = (moves[i - 2].y + moves[i - 1].y + moves[i + 1].y + moves[i + 2].y) / 4
                s += hypot(moves[i].x - ax, moves[i].y - ay)
            }
            return s / Double(moves.count - 4)
        }
        let before = try await jitter(a), after = try await jitter(b)
        print(String(format: "  shake: before %.2f px/frame, after %.2f px/frame", before, after))
        guard after < before * 0.7 else { throw Failure(description: "stabilisation did not reduce the shake") }
    }

    /// Contact sheet: 4 frames side by side (for visual review of results).
    static func sheet(_ input: URL, _ out: URL) async throws {
        let info = try await VideoIO.info(input)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: input))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        var frames: [CGImage] = []
        for i in 0..<4 {
            let t = CMTime(seconds: info.duration * (Double(i) + 0.5) / 4, preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { frames.append(cg) }
        }
        guard let f0 = frames.first else { throw Failure(description: "no frames") }
        let w = f0.width, h = f0.height
        guard let ctx = CGContext(data: nil, width: w * frames.count, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for (i, f) in frames.enumerated() { ctx.draw(f, in: CGRect(x: i * w, y: 0, width: w, height: h)) }
        if let img = ctx.makeImage() { try VideoIO.writePNG(img, to: out) }
    }

    // MARK: Acceptance (hardware test)

    static func acceptance(_ a: [String]) async throws {
        var outDir = AIAcceptanceTest.defaultOutputDir().deletingLastPathComponent()
            .appendingPathComponent(AIAcceptanceTest.defaultOutputDir().lastPathComponent + " Video")
        var runs = 5
        var i = 0
        while i < a.count {
            switch a[i] {
            case "--out" where i + 1 < a.count: outDir = URL(fileURLWithPath: (a[i + 1] as NSString).expandingTildeInPath); i += 1
            case "--runs" where i + 1 < a.count: runs = Int(a[i + 1]) ?? runs; i += 1
            case "--model" where i + 1 < a.count: setenv("PHOTOFLOW_VIDEO_MODEL", a[i + 1], 1); i += 1
            default: break
            }
            i += 1
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var lines: [String] = ["# PhotoFlow Video-KI – Hardwaretest", "", "Mac: \(AIHardware.current.summary)", "", "| Test | Ergebnis | Details |", "|---|---|---|"]
        var passed = 0, total = 0
        func record(_ name: String, _ ok: Bool, _ detail: String) {
            total += 1; if ok { passed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name) – \(detail)")
            lines.append("| \(name) | \(ok ? "✓" : "✗") | \(detail.replacingOccurrences(of: "|", with: "/")) |")
        }
        do { try await engineCheck(); record("Engine start", true, "") } catch { record("Engine start", false, "\(error)") }
        let model = try? videoModel(.textToVideo)
        let fps = model?.videoFPS ?? 16
        let (w, h) = model?.videoKind == "wan-ti2v" ? (832, 480) : (832, 480)
        let prompts = ["A red vintage car driving along a coastal road at sunset, the camera follows from the side, realistic lighting",
                       "Waves rolling onto a sandy beach at golden hour, gentle camera dolly forward",
                       "A woman with a red coat walking through a park in autumn, leaves falling, tracking shot"]
        var times: [Double] = []
        var peaks: [Double] = []
        for r in 0..<runs {
            let p = prompts[r % prompts.count]
            let out = outDir.appendingPathComponent(String(format: "t2v_%02d.mp4", r + 1))
            do {
                let g = try await generate("t2v", out: out, image: nil, video: nil, w: w, h: h, frames: 2 * fps + 1, steps: 30, seed: 100 + r, prompt: p)
                let valid = (g.event["valid"] as? Bool) ?? false
                times.append(g.seconds)
                if let pk = g.event.double("peak_rss_gb") { peaks.append(pk) }
                record("Text→Video \(r + 1)/\(runs)", valid, String(format: "%.0f s, %.2f s/Schritt, Spitze %.1f GB, %@", g.seconds, g.secondsPerStep ?? 0, g.event.double("peak_rss_gb") ?? 0, ((g.event["reasons"] as? [String]) ?? []).joined(separator: ", ")))
            } catch { record("Text→Video \(r + 1)/\(runs)", false, "\(error)") }
        }
        if peaks.count >= 3 { record("Speicher stabil", (peaks.last ?? 0) - (peaks[1]) < 1.0, "Spitzen: " + peaks.map { String(format: "%.1f", $0) }.joined(separator: " → ") + " GB") }
        do {
            let g = try await generate("t2v", out: outDir.appendingPathComponent("cancel.mp4"), image: nil, video: nil, w: w, h: h, frames: 2 * fps + 1, steps: 30, cancelAfter: 3)
            record("Abbrechen", g.event.kind == "cancelled", g.event.kind)
        } catch VideoEngineClient.EngineError.cancelled { record("Abbrechen", true, "nach Schritt 3") } catch { record("Abbrechen", false, "\(error)") }
        let first = outDir.appendingPathComponent("t2v_01.mp4")
        if FileManager.default.fileExists(atPath: first.path) {
            do {
                let g = try await generate("v2v", out: outDir.appendingPathComponent("v2v.mp4"), image: nil, video: first, w: w, h: h, frames: 2 * fps + 1, steps: 30)
                record("Video→Video", (g.event["valid"] as? Bool) ?? false, String(format: "%.0f s", g.seconds))
            } catch { record("Video→Video", false, "\(error)") }
        }
        if (try? videoModel(.imageToVideo)) != nil, FileManager.default.fileExists(atPath: first.path), let poster = await VideoIO.poster(first, maxSize: 1280) {
            let photo = outDir.appendingPathComponent("i2v_source.png")
            try? VideoIO.writePNG(poster, to: photo)
            do {
                let g = try await generate("i2v", out: outDir.appendingPathComponent("i2v.mp4"), image: photo, video: nil, w: 832, h: 480, frames: 49, steps: 30)
                record("Bild→Video", (g.event["valid"] as? Bool) ?? false, String(format: "%.0f s", g.seconds))
            } catch { record("Bild→Video", false, "\(error)") }
        }
        VideoEngineClient.shared.stop()
        if FileManager.default.fileExists(atPath: first.path) {
            do { try await background(first, outDir.appendingPathComponent("background.mp4"), bg: "blur"); record("Hintergrund ersetzen", true, "") }
            catch { record("Hintergrund ersetzen", false, "\(error)") }
            do { try await optimize(first, outDir.appendingPathComponent("optimized.mp4"), stabilize: false); record("Video optimieren", true, "") }
            catch { record("Video optimieren", false, "\(error)") }
        }
        lines.insert("**Ergebnis: \(passed) von \(total) Tests bestanden.**", at: 4)
        if !times.isEmpty { lines.append(""); lines.append(String(format: "Text→Video: Ø %.0f s pro Clip (%d Bilder, %d×%d).", times.reduce(0, +) / Double(times.count), 2 * fps + 1, w, h)) }
        try lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print("report: \(outDir.appendingPathComponent("report.md").path)")
        guard passed == total else { throw Failure(description: "\(total - passed) video tests failed") }
    }
}
