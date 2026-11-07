import Foundation
import CoreImage

/// Which parts of the automatic correction to run.
struct AutoEnhanceOptions: Codable, Hashable, Sendable {
    var tone = true          // exposure, highlights, shadows, whites, blacks, contrast
    var color = true         // vibrance / saturation
    var whiteBalance = true
    var straighten = false
    var perspective = false
    var detail = true        // sharpening, noise reduction, clarity

    static let everything = AutoEnhanceOptions(tone: true, color: true, whiteBalance: true, straighten: true, perspective: true, detail: true)
    static let enhanceOnly = AutoEnhanceOptions()
}

/// The one-click enhancement engine. It analyses every photo individually (tonal statistics, colour cast,
/// noise, scene type via Apple's on-device classifier, faces) and derives *individual* correction values.
/// After computing a recipe it renders a small preview and re-measures it (self-check) to prevent clipped
/// highlights or over-saturation. Every decision is recorded as a human-readable note.
enum AutoEnhanceEngine {
    struct Outcome: Sendable {
        var recipe: EditRecipe
        var notes: [String]
    }

    static func enhance(_ a: PhotoAnalysis, base: EditRecipe = .identity, strength: EnhanceStrength,
                        options: AutoEnhanceOptions) -> Outcome {
        let f = strength.factor
        var r = base
        var notes: [String] = []
        let s = a.stats

        // ---------- Scene description (for the user) ----------
        var sceneWords: [String] = []
        if a.isPortrait { sceneWords.append(String(localized: "portrait")) }
        if a.isLandscape { sceneWords.append(String(localized: "landscape")) }
        if a.isArchitecture { sceneWords.append(String(localized: "architecture")) }
        if a.isNight { sceneWords.append(String(localized: "night / low light")) }
        if a.isSunset { sceneWords.append(String(localized: "warm light / sunset")) }
        if a.isDocument { sceneWords.append(String(localized: "document")) }
        if a.isFood { sceneWords.append(String(localized: "food")) }
        if a.isHighKey { sceneWords.append(String(localized: "bright scene")) }
        if !sceneWords.isEmpty {
            notes.append(String(localized: "Recognized: \(sceneWords.joined(separator: ", "))"))
        }

        // ---------- Tone ----------
        var ev = 0.0
        if options.tone {
            var target = 0.46
            if a.isNight { target = 0.30 } else if a.isHighKey { target = 0.62 } else if a.isDocument { target = 0.62 }
            var current = s.p50
            if let fl = a.faceLuma, a.hasFaces {
                current = 0.6 * fl + 0.4 * s.p50
                target = max(target, 0.50)
            }
            ev = log2(max(ColorMath.toLinear(target), 1e-4) / max(ColorMath.toLinear(max(current, 0.01)), 1e-4)) * 0.7
            ev = min(1.8, max(-1.5, ev))
            if ev > 0 {
                // Keep headroom: don't push the brightest 0.5 % far beyond white (highlight recovery helps a bit).
                let headroom = log2(1.0 / max(ColorMath.toLinear(s.p995), 1e-3)) + 0.35
                ev = min(ev, max(0, headroom))
            }
            if abs(ev) < 0.08 { ev = 0 }
            ev *= f
            ev = (ev * 100).rounded() / 100
            r.exposure = ev
            if ev >= 0.1 { notes.append(String(localized: "Brightened by \(fmt(ev)) EV")) }
            if ev <= -0.1 { notes.append(String(localized: "Darkened by \(fmt(-ev)) EV")) }

            // Projected tonal values after exposure
            func project(_ v: Double) -> Double { ColorMath.toGamma(min(1, ColorMath.toLinear(v) * pow(2, ev))) }
            let pHi = project(s.p995), pLo = project(s.p005)
            let bright = s.brightFraction + (ev > 0 ? ev * 0.04 : 0)

            var hl = 0.0
            if s.clippedHighlights > 0.004 || bright > 0.08 || pHi >= 0.99 {
                hl = -min(70, bright * 250 + s.clippedHighlights * 1500 + max(0, ev) * 20)
            }
            var sh = 0.0
            if !a.isNight && s.darkFraction > 0.12 {
                sh = min(60, s.darkFraction * 140)
                if a.hasFaces, let fl = a.faceLuma, fl < 0.35 { sh = min(70, sh + 15) }
            }
            r.highlights = round(hl * f)
            r.shadows = round(sh * f)
            if r.highlights <= -10 { notes.append(String(localized: "Recovered bright highlights")) }
            if r.shadows >= 10 { notes.append(String(localized: "Opened up dark shadows")) }

            var whites = 0.0, blacks = 0.0
            if !a.isNight && pHi < 0.90 && s.clippedHighlights < 0.001 { whites = min(40, (0.96 - pHi) * 130) }
            if pLo > 0.05 { blacks = -min(40, (pLo - 0.02) * 260) }          // hazy / washed-out blacks
            else if s.clippedShadows > 0.03 && !a.isNight { blacks = min(20, s.clippedShadows * 250) } // crushed
            r.whites = round(whites * f)
            r.blacks = round(blacks * f)
            if r.blacks <= -8 || r.whites >= 8 { notes.append(String(localized: "Extended the tonal range")) }

            var con = 0.0
            if s.stdLuma < 0.17 && s.dynamicRange < 0.85 { con = min(30, (0.22 - s.stdLuma) * 260) }
            else if s.stdLuma > 0.30 { con = -min(20, (s.stdLuma - 0.28) * 160) }
            if a.isPortrait { con = min(con, 12) }
            if a.isDocument { con = max(con, 18) }
            r.contrast = round(con * f)
            if r.contrast >= 8 { notes.append(String(localized: "Added contrast to a flat image")) }
            if r.contrast <= -8 { notes.append(String(localized: "Softened harsh contrast")) }
        }

        // ---------- White balance ----------
        if options.whiteBalance {
            let wb = a.whiteBalance
            if wb.castDegrees >= 1.5 && wb.confidence > 0.05 {
                var fWarm: Double, fGreen: Double
                if wb.warmth > 0 {
                    // Warm cast: often intentional (sunset, candle light, golden hour) – preserve atmosphere.
                    fWarm = (a.isSunset || a.isNight) ? 0.25 : 0.6
                } else {
                    fWarm = a.isUnderwater ? 0.9 : 0.8
                }
                fGreen = wb.greenness > 0 ? 0.85 : 0.7       // green/magenta casts are rarely wanted
                // Foliage and other strongly coloured scenes look like a "green cast" to colour-constancy
                // estimators (measured on real landscapes: tint over-corrected toward magenta). Be careful there.
                if wb.greenness > 0 && (a.isLandscape || s.colorfulness > 0.45 || s.meanSaturation > 0.35) { fGreen *= 0.3 }
                let trust = min(1, wb.confidence / 0.35)
                fWarm = min(1, fWarm * trust * f)
                fGreen = min(1, fGreen * trust * f)

                var warm2 = wb.warmth * (1 - fWarm), green2 = wb.greenness * (1 - fGreen)
                var gains = gainsFor(wb, warm2, green2)
                // Skin-tone guard: corrected faces must stay plausible (R > G > B).
                if let fc = a.faceColorLinear {
                    for _ in 0 ..< 3 {
                        let cr = fc.r * gains.r, cg = fc.g * gains.g, cb = fc.b * gains.b
                        if cr > cg && cg > cb * 0.98 { break }
                        warm2 = (warm2 + wb.warmth) / 2; green2 = (green2 + wb.greenness) / 2
                        gains = gainsFor(wb, warm2, green2)
                    }
                }
                let sliders = WhiteBalanceModel.sliders(forGains: gains.r, gains.g, gains.b)
                r.temperature = round(sliders.temperature)
                // Without clearly neutral surfaces, large tint shifts are more often wrong than right.
                let tintLimit = (wb.neutralFraction >= 0.08 && wb.confidence >= 0.6) ? 25.0 : 12.0
                r.tint = round(max(-tintLimit, min(tintLimit, sliders.tint)))
                if abs(r.temperature) >= 3 || abs(r.tint) >= 3 {
                    if wb.warmth > 0.02 {
                        notes.append(a.isSunset || a.isNight
                                     ? String(localized: "Reduced a warm color cast (kept the mood)")
                                     : String(localized: "Removed a warm/yellow color cast"))
                    } else if wb.warmth < -0.02 {
                        notes.append(String(localized: "Removed a cool/blue color cast"))
                    }
                    if wb.greenness > 0.03 { notes.append(String(localized: "Removed a green tint")) }
                    if wb.greenness < -0.03 { notes.append(String(localized: "Removed a magenta tint")) }
                }
            }
        }

        // ---------- Colour ----------
        if options.color {
            var vib = 0.0
            if s.meanSaturation < 0.22 && s.colorfulness < 0.4 { vib = min(35, (0.27 - s.meanSaturation) * 190) }
            if a.isLandscape { vib += 8 }
            if a.isFood { vib += 6 }
            if a.hasFaces { vib = min(vib, 18) }
            if s.p95Saturation > 0.92 { vib = min(vib, -8) } else if s.p95Saturation > 0.85 { vib = min(vib, 0) }
            if a.isDocument { vib = 0 }
            r.vibrance = round(vib * f)
            r.saturation = 0
            if r.vibrance >= 8 { notes.append(String(localized: "Gave dull colors more life")) }
            if r.vibrance <= -5 { notes.append(String(localized: "Toned down oversaturated colors")) }
        }

        // ---------- Detail ----------
        if options.detail {
            let noisy = s.noiseSigma > 0.012 || (a.iso ?? 0) >= 3200
            if noisy {
                r.noiseReduction = round(min(60, max(15, s.noiseSigma * 1800)) * min(1, f))
                notes.append(String(localized: "Reduced image noise"))
            }
            r.sharpness = round((noisy ? 8 : 22) * f)
            var clarity = 6.0
            if a.isLandscape || a.isArchitecture { clarity = 16 }
            if a.isPortrait { clarity = 0 }
            if a.isDocument { clarity = 12 }
            if noisy { clarity = min(clarity, 5) }
            r.clarity = round(clarity * f)
        }

        // ---------- Geometry ----------
        if options.straighten {
            let st = a.straighten
            if st.shouldApply {
                r.rotation = (st.correction * 100).rounded() / 100
                notes.append(String(localized: "Straightened by \(fmt(abs(st.correction)))°"))
            }
        }
        if options.perspective {
            let p = a.perspective
            if a.isDocument, let corners = PerspectiveEngine.documentCorners(in: a.analysisImage) {
                r.documentCorners = corners
                notes.append(String(localized: "Rectified the document"))
            } else {
                if p.applyVertical { r.perspectiveVertical = p.verticalSlider.rounded() }
                if p.applyHorizontal { r.perspectiveHorizontal = p.horizontalSlider.rounded() }
                if p.applyVertical || p.applyHorizontal { notes.append(String(localized: "Corrected converging lines")) }
            }
        }

        // ---------- Self-check on a rendered preview ----------
        r = selfCheck(r, analysis: a, notes: &notes)

        r.auto = AutoEnhanceInfo(strength: strength, analyzedAt: Date(), sceneLabels: a.scene.topLabels,
                                 faceCount: a.scene.faces.count, notes: notes)
        return Outcome(recipe: r, notes: notes)
    }

    private static func gainsFor(_ wb: WhiteBalanceEstimator.Estimate, _ warm2: Double, _ green2: Double) -> (r: Double, g: Double, b: Double) {
        let lRG2 = warm2 - green2, lBG2 = -warm2 - green2
        return (exp(lRG2 - wb.logRG), 1, exp(lBG2 - wb.logBG))
    }

    /// Renders the recipe on the analysis image and verifies it did not introduce clipping or
    /// garish colours. Up to two corrective iterations.
    private static func selfCheck(_ recipe: EditRecipe, analysis a: PhotoAnalysis, notes: inout [String]) -> EditRecipe {
        var r = recipe
        let source = CIImage(cgImage: a.analysisImage)
        for _ in 0 ..< 2 {
            var check = r
            check.rotation = 0; check.perspectiveVertical = 0; check.perspectiveHorizontal = 0; check.documentCorners = nil
            guard let px = PixelBuffer(ciImage: RenderPipeline.apply(check, to: source), maxSide: 512) else { break }
            let after = ImageStatistics.compute(px)
            var changed = false
            let clipIncrease = after.clippedHighlights - a.stats.clippedHighlights
            if clipIncrease > 0.01 && after.clippedHighlights > a.stats.clippedHighlights * 1.5 {
                r.exposure = max(-1.5, r.exposure - 0.2)
                r.highlights = max(-90, r.highlights - 15)
                r.whites = min(r.whites, 0)
                changed = true
            }
            if after.clippedShadows - a.stats.clippedShadows > 0.02 {
                r.blacks = min(25, r.blacks + 10)
                r.contrast = max(-20, r.contrast - 8)
                changed = true
            }
            if after.meanSaturation > 0.55 && after.meanSaturation - a.stats.meanSaturation > 0.1 {
                r.vibrance = max(-20, r.vibrance - 12)
                changed = true
            }
            if !changed { break }
        }
        return r
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
