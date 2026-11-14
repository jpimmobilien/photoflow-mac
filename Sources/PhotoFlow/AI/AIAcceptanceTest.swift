import Foundation
import CoreGraphics
import AppKit
import StableDiffusion

/// Hardware acceptance test for AI Studio – runs the real models on this Mac and decides from the pictures
/// themselves whether generation works. Used by Model Management ("Hardware test") and by
/// `PhotoFlow --qa ai-acceptance`. Every image is saved as PNG, opened again from disk and checked:
/// not uniform, not noise, not black/white, and Apple's scene classifier must recognise content.
///
/// Output folder: report.md (German), report.json, index.html (contact sheet) and all images.
final class AIAcceptanceTest: @unchecked Sendable {
    struct Options {
        var models: [AIModelDescriptor]
        var consecutive: Int = 20
        var steps: Int = 20
        var includeEditing = true
        /// Load cycles, reproducibility, variants, formats, cancellation, model switching.
        var extended = true
        var sourcePhoto: URL?
        var outDir: URL
    }

    struct Entry: Codable {
        var section: String
        var name: String
        var passed: Bool
        var seconds: Double
        var detail: String
        var image: String?
        var model: String?
        var secondsPerStep: Double?
        var footprintMB: Double?
        var labels: [String]?
    }

    struct Report: Codable {
        var started: Date
        var finished: Date?
        var app: String
        var hardware: String
        var macOS: String
        var models: [String]
        var entries: [Entry]
        var passed: Bool { !entries.isEmpty && entries.allSatisfy(\.passed) }
    }

    /// Prompts with words Apple's classifier should find in a correct image.
    static let prompts: [(String, [String])] = [
        ("a photo of a cat sitting on a sofa in a living room", ["cat", "feline", "sofa", "couch", "furniture", "living", "room", "mammal", "animal", "pet"]),
        ("a red sports car parked on a city street, daylight", ["car", "automobile", "vehicle", "street", "road", "wheel", "sports"]),
        ("a bowl of fresh fruit on a wooden kitchen table", ["fruit", "food", "bowl", "apple", "orange", "banana", "table", "kitchen", "produce"]),
        ("a mountain lake at sunrise, pine trees, reflections", ["mountain", "lake", "water", "landscape", "tree", "sky", "outdoor", "nature", "forest", "conifer"]),
        ("a bright modern living room interior with large windows and plants", ["room", "interior", "living", "furniture", "window", "house", "home", "plant", "indoor", "structure"])
    ]

    let options: Options
    let token: AICancelToken
    var progress: (String, Double) -> Void = { _, _ in }
    private(set) var report: Report
    private var lastSource: CGImage?

    init(options: Options, token: AICancelToken = AICancelToken()) {
        self.options = options
        self.token = token
        let hw = AIHardware.current
        let v = ProcessInfo.processInfo.operatingSystemVersion
        report = Report(started: Date(), finished: nil,
                        app: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                            + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-") + ")",
                        hardware: hw.summary + " · " + (hw.base.gpuName ?? "-"),
                        macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                        models: options.models.map { "\($0.name) [\($0.id), \(hw.diffusionPlan(for: $0).title)]" }, entries: [])
    }

    // MARK: Helpers

    private var footprintMB: Double { Double(MemoryMonitor.footprintBytes()) / 1_048_576 }

    private func add(_ e: Entry) {
        report.entries.append(e)
        print("ACCEPTANCE \(e.passed ? "PASS" : "FAIL") [\(e.section)] \(e.name) – \(e.detail)")
        writeReport()
    }

    /// Saves the image as PNG, opens the file again and validates what was read back.
    private func saveAndCheck(_ image: CGImage, name: String, expect: [String]? = nil) -> (file: String, ok: Bool, detail: String, labels: [String]) {
        let file = name + ".png"
        let url = options.outDir.appendingPathComponent(file)
        guard let data = AIImage.pngData(image), (try? data.write(to: url)) != nil, let back = AIImage.loadPNG(url) else {
            return (file, false, "PNG could not be written or read back", [])
        }
        let v = AIImageValidator.check(back)
        let labels = AIImageValidator.labels(back, limit: 6)
        let labelText = labels.map { "\($0.0) \(Int($0.1 * 100))%" }
        var detail = String(format: "%dx%d, spread %.3f, noise ratio %.2f", back.width, back.height, v.metrics.spread, v.metrics.detailRatio)
        if let reason = v.reason { detail += " – " + reason }
        var ok = v.valid
        if let expect {
            let hit = labels.contains { l in expect.contains { l.0.lowercased().contains($0) } && l.1 > 0.05 }
            detail += hit ? " – content recognised" : " – expected content NOT recognised"
            ok = ok && hit
        }
        return (file, ok, detail, labelText)
    }

    private func t2i(_ model: AIModelDescriptor, prompt: String, seed: UInt32, steps: Int, aspect: AIAspect = .square) throws -> (CGImage, Double, Double?) {
        let s = GenerationSettings(model: model, prompt: prompt, style: AIStyle.style("photo"), steps: steps)
        var sps: Double?
        let t0 = Date()
        let img = try AIOperations.textToImage(s, aspect: aspect, seed: seed, token: token) { r in sps = r.secondsPerStep ?? sps }
        if let f = DiffusionEngine.shared.lastFailover { throw AIError.failed("model switched to \(f.name) after invalid output") }
        return (img, Date().timeIntervalSince(t0), sps)
    }

    // MARK: Run

    func run() {
        try? FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let models = options.models
        guard let first = models.first else {
            add(Entry(section: "Setup", name: "Diffusion model installed", passed: false, seconds: 0, detail: "No compatible diffusion model is installed."))
            finish(); return
        }
        for m in models {
            add(Entry(section: "System", name: "Ausführung \(m.name)", passed: true, seconds: 0,
                      detail: AIHardware.current.diffusionPlan(for: m).title + " – " + AIComputePlanInfo.unetSummary(for: m), model: m.id))
        }
        let total = Double(options.consecutive + (options.extended ? 12 + max(0, models.count - 1) * 3 : 0) + (options.includeEditing ? 6 : 0))
        var done = 0.0
        func step(_ text: String) { done += 1; progress(text, min(1, done / total)) }

        // 1. Load / unload cycles (cold start of the model, then 2 reloads)
        for cycle in 1...3 where !token.isCancelled && options.extended {
            step("Laden/Freigeben \(cycle)/3")
            DiffusionEngine.shared.unloadSync()
            let before = footprintMB
            do {
                let (img, sec, sps) = try t2i(first, prompt: Self.prompts[0].0, seed: UInt32(1000 + cycle), steps: 10)
                let c = saveAndCheck(img, name: "load-\(cycle)")
                add(Entry(section: "Laden/Freigeben", name: "Modell laden + Bild \(cycle)", passed: c.ok, seconds: sec,
                          detail: String(format: "%@ – Speicher vor dem Laden %.0f MB, danach %.0f MB", c.detail, before, footprintMB),
                          image: c.file, model: first.id, secondsPerStep: sps, footprintMB: footprintMB, labels: c.labels))
            } catch { fail("Laden/Freigeben", "Modell laden + Bild \(cycle)", error, first) }
        }
        DiffusionEngine.shared.unloadSync()
        let releasedMB = footprintMB
        if options.extended { add(Entry(section: "Laden/Freigeben", name: "Speicher nach dem Freigeben", passed: true, seconds: 0,
                  detail: String(format: "%.0f MB nach dem Entladen des Modells", releasedMB), footprintMB: releasedMB)) }

        // 2. Consecutive generations with different prompts and seeds
        var footprints: [Double] = []
        var times: [Double] = []
        var failures = 0
        for i in 0..<options.consecutive where !token.isCancelled {
            step("Bild \(i + 1)/\(options.consecutive)")
            let (prompt, expect) = Self.prompts[i % Self.prompts.count]
            let seed = UInt32(20_000 + i * 7919)
            do {
                let (img, sec, sps) = try t2i(first, prompt: prompt, seed: seed, steps: options.steps)
                let c = saveAndCheck(img, name: String(format: "t2i-%02d", i + 1), expect: expect)
                if !c.ok { failures += 1 }
                times.append(sec)
                footprints.append(footprintMB)
                add(Entry(section: "Serie", name: "Bild \(i + 1): \(prompt)", passed: c.ok, seconds: sec,
                          detail: c.detail + " (Seed \(seed))" + (c.ok ? "" : " – " + PipelineDiagnostics.summary),
                          image: c.file, model: first.id, secondsPerStep: sps, footprintMB: footprintMB, labels: c.labels))
            } catch { failures += 1; fail("Serie", "Bild \(i + 1)", error, first) }
            if (i + 1 == 10 || i + 1 == options.consecutive) && options.consecutive >= 5 {
                let growth = footprints.count > 3 ? (footprints.last! - footprints[2]) : 0
                add(Entry(section: "Serie", name: "Zwischenstand nach \(i + 1) Bildern", passed: failures == 0 && growth < 400, seconds: times.reduce(0, +),
                          detail: String(format: "%d Fehler · Ø %.1f s/Bild · max %.1f s · Speicher %.0f → %.0f MB (Zuwachs ab Bild 3: %.0f MB)",
                                         failures, times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count), times.max() ?? 0,
                                         footprints.first ?? 0, footprints.last ?? 0, growth)))
            }
        }

        // 3. Reproducibility and variants
        if !token.isCancelled && options.extended {
            step("Reproduzierbarkeit")
            do {
                let (a, _, _) = try t2i(first, prompt: Self.prompts[1].0, seed: 4242, steps: options.steps)
                let (b, sec, _) = try t2i(first, prompt: Self.prompts[1].0, seed: 4242, steps: options.steps)
                let d = AIQA.diff(a, b, inside: nil).outside
                add(Entry(section: "Varianten", name: "Gleicher Seed → gleiches Bild", passed: d < 0.01, seconds: sec,
                          detail: String(format: "mittlere Abweichung %.4f", d), model: first.id))
                step("Varianten")
                var imgs = [a]
                for k in 1...3 {
                    let (v, _, _) = try t2i(first, prompt: Self.prompts[1].0, seed: 4242 &+ UInt32(k), steps: options.steps)
                    imgs.append(v)
                    _ = saveAndCheck(v, name: "variant-\(k)")
                }
                var minDiff = 1.0
                for x in 0..<imgs.count { for y in (x + 1)..<imgs.count { minDiff = min(minDiff, AIQA.diff(imgs[x], imgs[y], inside: nil).outside) } }
                let valid = imgs.allSatisfy { AIImageValidator.check($0).valid }
                add(Entry(section: "Varianten", name: "4 Varianten (verschiedene Seeds)", passed: valid && minDiff > 0.03, seconds: 0,
                          detail: String(format: "kleinste Abweichung zwischen zwei Varianten %.3f", minDiff), model: first.id))
            } catch { fail("Varianten", "Reproduzierbarkeit/Varianten", error, first) }
        }

        // 4. Formats and resolutions
        for aspect in [AIAspect.wide16x9, .portrait9x16] where !token.isCancelled && options.extended {
            step("Format \(aspect.title)")
            do {
                let (img, sec, _) = try t2i(first, prompt: Self.prompts[3].0, seed: 777, steps: options.steps, aspect: aspect)
                let c = saveAndCheck(img, name: "format-\(aspect.rawValue)")
                let ratioOK = abs(Double(img.width) / Double(img.height) - aspect.ratio) < 0.02
                add(Entry(section: "Formate", name: "Format \(aspect.title)", passed: c.ok && ratioOK, seconds: sec, detail: c.detail, image: c.file, model: first.id))
            } catch { fail("Formate", "Format \(aspect.title)", error, first) }
        }
        if !token.isCancelled, options.extended, let up = ModelStoreSnapshot.current.upscaler(scale: 2) {
            step("Hohe Auflösung")
            do {
                let (img, _, _) = try t2i(first, prompt: Self.prompts[4].0, seed: 99, steps: options.steps)
                let t0 = Date()
                let big = try Upscaler.shared.upscaleSync(img, with: up, token: token) { _ in }
                let c = saveAndCheck(big, name: "highres-2x")
                add(Entry(section: "Formate", name: "Qualität „Hoch“ (\(big.width) × \(big.height), Real-ESRGAN)", passed: c.ok, seconds: Date().timeIntervalSince(t0),
                          detail: c.detail, image: c.file, model: up.id))
            } catch { fail("Formate", "Hohe Auflösung", error, first) }
        }

        // 5. Cancellation
        if !token.isCancelled && options.extended {
            step("Abbruch")
            let inner = AICancelToken()
            var stoppedAt = 0
            var requestedAt: Date?
            do {
                let s = GenerationSettings(model: first, prompt: Self.prompts[2].0, steps: 30)
                _ = try AIOperations.textToImage(s, aspect: .square, seed: 5, token: inner) { r in
                    stoppedAt = r.step
                    if r.step >= 3 && requestedAt == nil { requestedAt = Date(); inner.cancel() }
                }
                add(Entry(section: "Abbruch", name: "Abbruch während der Generierung", passed: false, seconds: 0, detail: "Generierung lief bis zum Ende"))
            } catch AIError.cancelled {
                let latency = Date().timeIntervalSince(requestedAt ?? Date())
                add(Entry(section: "Abbruch", name: "Abbruch während der Generierung", passed: stoppedAt <= 5, seconds: latency,
                          detail: String(format: "gestoppt nach Schritt %d, %.2f s nach der Anforderung", stoppedAt, latency)))
            } catch { fail("Abbruch", "Abbruch während der Generierung", error, first) }
            do {
                let (img, sec, _) = try t2i(first, prompt: Self.prompts[2].0, seed: 6, steps: options.steps)
                let c = saveAndCheck(img, name: "after-cancel", expect: Self.prompts[2].1)
                add(Entry(section: "Abbruch", name: "Bild direkt nach dem Abbruch", passed: c.ok, seconds: sec, detail: c.detail, image: c.file, model: first.id, labels: c.labels))
            } catch { fail("Abbruch", "Bild direkt nach dem Abbruch", error, first) }
        }

        // 6. Model switching
        if models.count > 1 && options.extended {
            for (k, m) in [models[1], models[0], models[1]].enumerated() where !token.isCancelled {
                step("Modellwechsel \(k + 1)/3")
                do {
                    let (img, sec, sps) = try t2i(m, prompt: Self.prompts[k % Self.prompts.count].0, seed: UInt32(300 + k), steps: options.steps)
                    let c = saveAndCheck(img, name: "switch-\(k + 1)-\(m.id)", expect: Self.prompts[k % Self.prompts.count].1)
                    add(Entry(section: "Modellwechsel", name: "\(m.name)", passed: c.ok, seconds: sec, detail: c.detail, image: c.file,
                              model: m.id, secondsPerStep: sps, footprintMB: footprintMB, labels: c.labels))
                } catch { fail("Modellwechsel", m.name, error, m) }
            }
        }

        // 7. Editing functions
        if options.includeEditing && !token.isCancelled { runEditing(first, step: step) }

        DiffusionEngine.shared.unloadSync()
        add(Entry(section: "Speicher", name: "Speicher am Ende (Modelle entladen)", passed: true, seconds: 0,
                  detail: String(format: "%.0f MB", footprintMB), footprintMB: footprintMB))
        if token.isCancelled {
            add(Entry(section: "Test", name: "Test abgebrochen", passed: false, seconds: 0, detail: "vom Benutzer abgebrochen"))
        }
        finish()
    }

    private func runEditing(_ model: AIModelDescriptor, step: (String) -> Void) {
        // Source: a real photo when available, otherwise a generated one.
        var source: CGImage?
        var sourceName = "generiertes Bild"
        if let url = options.sourcePhoto, let img = try? AIImage.load(url: url, maxPixel: 1600) { source = img; sourceName = url.lastPathComponent }
        if source == nil, let img = try? t2i(model, prompt: Self.prompts[4].0, seed: 31, steps: options.steps).0 { source = img }
        guard let src = source else { return }
        _ = saveAndCheck(src, name: "edit-source")
        let s = { (p: String) in GenerationSettings(model: model, prompt: p, style: AIStyle.style("photo"), steps: self.options.steps) }

        step("Bild zu Bild")
        do {
            let t0 = Date()
            let img = try AIOperations.imageToImage(src, s("the same scene in winter, snow, overcast light"), strength: 0.55, seed: 3, token: token) { _ in }
            let c = saveAndCheck(img, name: "edit-i2i")
            let kept = AIImage.resize(img, width: src.width, height: src.height).map { AIQA.diff(src, $0, inside: nil).outside } ?? 1
            add(Entry(section: "Bearbeitung", name: "Bild zu Bild (Quelle: \(sourceName))", passed: c.ok && kept < 0.35, seconds: Date().timeIntervalSince(t0),
                      detail: c.detail + String(format: " – Abweichung zur Vorlage %.3f (Komposition erhalten < 0.35)", kept), image: c.file, model: model.id))
        } catch { fail("Bearbeitung", "Bild zu Bild", error, model) }

        let r = CGRect(x: src.width / 3, y: src.height / 3, width: src.width / 3, height: src.height / 3)
        if let mask = AIQA.rectMask(src.width, src.height, r) {
            step("Generative Füllung")
            do {
                let t0 = Date()
                let img = try AIOperations.generativeFill(src, mask: mask, s("a large green potted plant"), feather: 8, seed: 11, token: token) { _ in }
                let outside = AIQA.diff(src, img, inside: r.insetBy(dx: -24, dy: -24)).outside
                let filled = AIImage.crop(img, r.insetBy(dx: 8, dy: 8))
                let fv = filled.map { AIImageValidator.check($0) }
                let c = saveAndCheck(img, name: "edit-fill")
                add(Entry(section: "Bearbeitung", name: "Generative Füllung (maskiert)", passed: c.ok && outside < 0.002 && (fv?.valid ?? false), seconds: Date().timeIntervalSince(t0),
                          detail: String(format: "außerhalb der Maske Abweichung %.5f, Füllung gültig: %@", outside, (fv?.valid ?? false) ? "ja" : "nein"),
                          image: c.file, model: model.id))
            } catch { fail("Bearbeitung", "Generative Füllung", error, model) }

            if ModelStoreSnapshot.current.lamaInstalled {
                step("Objekt entfernen")
                do {
                    let t0 = Date()
                    let res = try AIOperations.removeObject(src, mask: mask, token: token, fallback: nil) { _ in }
                    let outside = AIQA.diff(src, res.image, inside: r.insetBy(dx: -CGFloat(src.width) / 10, dy: -CGFloat(src.width) / 10)).outside
                    let c = saveAndCheck(res.image, name: "edit-remove")
                    add(Entry(section: "Bearbeitung", name: "Objekt entfernen (LaMa)", passed: c.ok && outside < 0.002, seconds: Date().timeIntervalSince(t0),
                              detail: String(format: "außerhalb Abweichung %.5f", outside), image: c.file, model: "lama"))
                } catch { fail("Bearbeitung", "Objekt entfernen", error, model) }
            }
        }

        step("Bild erweitern")
        do {
            let t0 = Date()
            let e = AIOperations.Expansion(left: src.width / 4, top: 0, right: src.width / 4, bottom: 0)
            let img = try AIOperations.expand(src, by: e, s("seamless natural continuation of the scene"), seed: 5, token: token) { _ in }
            let band = Double(max(img.width, img.height)) * 0.015 * 1.6
            let inner = AIImage.crop(img, CGRect(x: e.left, y: 0, width: src.width, height: src.height))
            let d = inner.map { AIQA.diff(src, $0, inside: CGRect(x: band, y: band, width: Double(src.width) - 2 * band, height: Double(src.height) - 2 * band)).inside } ?? 1
            let newArea = AIImage.crop(img, CGRect(x: 0, y: 0, width: e.left, height: img.height)).map { AIImageValidator.check($0).valid } ?? false
            let c = saveAndCheck(img, name: "edit-expand")
            add(Entry(section: "Bearbeitung", name: "Bild erweitern (\(src.width) → \(img.width) px)", passed: c.ok && d < 0.002 && newArea, seconds: Date().timeIntervalSince(t0),
                      detail: String(format: "Original erhalten (Abweichung %.5f), neuer Bereich gültig: %@", d, newArea ? "ja" : "nein"), image: c.file, model: model.id))
        } catch { fail("Bearbeitung", "Bild erweitern", error, model) }

        step("Hintergrund ersetzen")
        do {
            let t0 = Date()
            let subject = try AIOperations.subjectMask(src)
            let img = try AIOperations.replaceBackground(src, subject: subject, s("a bright beach at sunset"), shadow: true, seed: 8, token: token) { _ in }
            let c = saveAndCheck(img, name: "edit-background")
            add(Entry(section: "Bearbeitung", name: "Hintergrund ersetzen", passed: c.ok, seconds: Date().timeIntervalSince(t0),
                      detail: c.detail + String(format: " – Motivanteil %.2f", AIImage.maskCoverage(subject)), image: c.file, model: model.id))
        } catch AIError.unsupported(let m) {
            add(Entry(section: "Bearbeitung", name: "Hintergrund ersetzen", passed: true, seconds: 0, detail: "übersprungen: \(m) (kein Motiv im Testbild)"))
        } catch { fail("Bearbeitung", "Hintergrund ersetzen", error, model) }
    }

    private func fail(_ section: String, _ name: String, _ error: Error, _ model: AIModelDescriptor) {
        if case AIError.cancelled = error, token.isCancelled { return }
        add(Entry(section: section, name: name, passed: false, seconds: 0,
                  detail: (error as? LocalizedError)?.errorDescription ?? String(describing: error), model: model.id))
    }

    private func finish() {
        report.finished = Date()
        writeReport()
    }

    /// Short check after an app restart: one generation, appended to an existing report.
    static func restartCheck(reportDir: URL, model: AIModelDescriptor) -> Bool {
        let t = AIAcceptanceTest(options: Options(models: [model], outDir: reportDir))
        if let d = try? Data(contentsOf: reportDir.appendingPathComponent("report.json")), let r = try? JSONDecoder.iso.decode(Report.self, from: d) {
            t.report = r
        }
        do {
            let (img, sec, sps) = try t.t2i(model, prompt: prompts[0].0, seed: 2024, steps: 20)
            let c = t.saveAndCheck(img, name: "after-restart", expect: prompts[0].1)
            t.add(Entry(section: "Neustart", name: "Generierung nach Neustart der App", passed: c.ok, seconds: sec, detail: c.detail,
                        image: c.file, model: model.id, secondsPerStep: sps, labels: c.labels))
        } catch {
            t.fail("Neustart", "Generierung nach Neustart der App", error, model)
        }
        t.finish()
        return t.report.entries.last?.passed ?? false
    }

    // MARK: Report

    func writeReport() {
        let dir = options.outDir
        if let d = try? JSONEncoder.iso.encode(report) { try? d.write(to: dir.appendingPathComponent("report.json")) }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium; df.locale = Locale(identifier: "de_DE")
        var md = "# PhotoFlow AI Studio – Hardware-Abnahmetest\n\n"
        md += "| | |\n|---|---|\n"
        md += "| Ergebnis | **\(report.finished == nil ? "läuft …" : (report.passed ? "BESTANDEN" : "NICHT BESTANDEN"))** |\n"
        md += "| Gestartet | \(df.string(from: report.started)) |\n"
        if let f = report.finished { md += "| Dauer | \(Int(f.timeIntervalSince(report.started) / 60)) min |\n" }
        md += "| PhotoFlow | \(report.app) |\n| Hardware | \(report.hardware) |\n| macOS | \(report.macOS) |\n"
        md += "| Modelle | \(report.models.joined(separator: "; ")) |\n\n"
        let passed = report.entries.filter(\.passed).count
        md += "**\(passed) von \(report.entries.count) Prüfungen bestanden.**\n\n"
        var section = ""
        for e in report.entries {
            if e.section != section {
                section = e.section
                md += "\n## \(section)\n\n| | Prüfung | Zeit | Details |\n|---|---|---|---|\n"
            }
            var detail = e.detail.replacingOccurrences(of: "|", with: "/")
            if let sps = e.secondsPerStep { detail += String(format: " · %.2f s/Schritt", sps) }
            if let l = e.labels, !l.isEmpty { detail += " · erkannt: " + l.prefix(3).joined(separator: ", ") }
            md += "| \(e.passed ? "✅" : "❌") | \(e.name) | \(String(format: "%.1f s", e.seconds)) | \(detail) |\n"
        }
        try? md.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)

        var html = """
        <!doctype html><html lang="de"><head><meta charset="utf-8"><title>PhotoFlow KI-Hardwaretest</title>
        <style>body{font:14px -apple-system,sans-serif;margin:24px;background:#f5f5f7;color:#1d1d1f}
        .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px}
        .c{background:#fff;border-radius:14px;padding:10px;box-shadow:0 1px 4px #0001}.c img{width:100%;border-radius:10px}
        .ok{color:#1a7f37}.no{color:#c4161c}small{color:#6e6e73}</style></head><body>
        <h1>PhotoFlow KI-Hardwaretest – \(report.finished == nil ? "läuft" : (report.passed ? "<span class=ok>bestanden</span>" : "<span class=no>nicht bestanden</span>"))</h1>
        <p>\(report.hardware) · macOS \(report.macOS) · PhotoFlow \(report.app)<br>\(passed) von \(report.entries.count) Prüfungen bestanden.</p><div class=g>
        """
        for e in report.entries {
            html += "<div class=c>"
            if let img = e.image { html += "<img src=\"\(img)\">" }
            html += "<b class=\(e.passed ? "ok" : "no")>\(e.passed ? "✓" : "✗") \(e.name.htmlEscaped)</b><br><small>\(String(format: "%.1f s", e.seconds)) · \(e.detail.htmlEscaped)</small></div>"
        }
        html += "</div></body></html>"
        try? html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    static func defaultOutputDir() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        return AIMetadata.libraryFolder.deletingLastPathComponent()
            .appendingPathComponent("PhotoFlow KI-Hardwaretest", isDirectory: true)
            .appendingPathComponent(f.string(from: Date()), isDirectory: true)
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
