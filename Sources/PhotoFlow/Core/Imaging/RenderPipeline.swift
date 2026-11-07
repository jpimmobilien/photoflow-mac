import Foundation
import CoreImage

/// Applies an `EditRecipe` to an image using only built-in Core Image filters (GPU via Metal when available,
/// CPU otherwise). All spatial parameters are relative to the image size, so a 1,000-pixel preview and a
/// 50-megapixel export look the same.
enum RenderPipeline {
    /// Processing order: tone & colour in linear light on the source → geometry → detail.
    static func apply(_ r: EditRecipe, to source: CIImage) -> CIImage {
        var img = source.normalizedToOrigin()
        let extent = img.extent
        let longSide = Double(max(extent.width, extent.height))
        img = img.clampedToExtent()

        // 1. Exposure (linear EV)
        if r.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure])
        }

        // 2. White balance as per-channel gains in linear light (temperature = blue↔amber, tint = green↔magenta)
        if r.temperature != 0 || r.tint != 0 {
            let g = WhiteBalanceModel.gains(temperature: r.temperature, tint: r.tint)
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g.r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g.g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g.b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }

        // 3. Highlight recovery / shadow lift (local, edge-aware filter)
        let recover = r.highlights < 0 ? -r.highlights / 100 : 0
        let lift = r.shadows > 0 ? r.shadows / 100 : 0
        if recover > 0 || lift > 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - 0.75 * recover,
                "inputShadowAmount": 0.85 * lift,
                "inputRadius": max(1.0, longSide * 0.004)
            ])
        }

        // 4. Global tone curve in gamma-encoded space (blacks, whites, brightness, contrast,
        //    positive highlights, negative shadows)
        let curve = ToneCurve(recipe: r)
        if !curve.isIdentity {
            img = img.applyingFilter("CILinearToSRGBToneCurve")
            let p = curve.points
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: p[0].x, y: p[0].y), "inputPoint1": CIVector(x: p[1].x, y: p[1].y),
                "inputPoint2": CIVector(x: p[2].x, y: p[2].y), "inputPoint3": CIVector(x: p[3].x, y: p[3].y),
                "inputPoint4": CIVector(x: p[4].x, y: p[4].y)
            ])
            img = img.applyingFilter("CISRGBToneCurveToLinear")
        }

        // 5. Colour intensity
        if r.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": r.vibrance / 100])
        }
        if r.saturation != 0 || r.monochrome {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: r.monochrome ? 0 : max(0, 1 + r.saturation / 100),
                kCIInputBrightnessKey: 0, kCIInputContrastKey: 1
            ])
        }

        // 6. Local contrast ("clarity"): large-radius unsharp mask
        if r.clarity != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(2.0, longSide * 0.012),
                kCIInputIntensityKey: r.clarity / 100 * 0.55
            ])
        }

        img = img.cropped(to: extent)

        // 7. Geometry (document rectification, quarter turns, straighten, perspective, crop)
        if let c = r.documentCorners, c.count == 8 {
            let w = extent.width, h = extent.height
            func v(_ i: Int) -> CIVector { CIVector(x: CGFloat(c[i * 2]) * w, y: CGFloat(c[i * 2 + 1]) * h) }
            img = img.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": v(0), "inputTopRight": v(1), "inputBottomRight": v(2), "inputBottomLeft": v(3)
            ]).normalizedToOrigin()
        }
        if r.quarterTurns % 4 != 0 { img = img.rotatedQuarterTurns(r.quarterTurns) }
        let model = GeometryModel(recipe: r)
        if !model.isIdentity || r.crop != nil {
            img = img.applyingGeometry(model, crop: r.crop)
        }

        // 8. Detail: noise reduction then sharpening (after resampling, so sharpening isn't blurred again)
        let outExtent = img.extent
        let outLong = Double(max(outExtent.width, outExtent.height))
        if r.noiseReduction > 0 || r.sharpness > 0 {
            img = img.clampedToExtent()
            if r.noiseReduction > 0 {
                img = img.applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": 0.005 + r.noiseReduction / 100 * 0.05,
                    "inputSharpness": 0.35
                ])
            }
            if r.sharpness > 0 {
                img = img.applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: r.sharpness / 100 * 0.9,
                    kCIInputRadiusKey: max(0.6, min(2.5, outLong / 2400))
                ])
            }
            img = img.cropped(to: outExtent)
        }
        return img
    }
}

/// Five-point tone curve evaluated from the slider values (input/output in gamma-encoded 0…1).
struct ToneCurve {
    let points: [CGPoint]
    let isIdentity: Bool

    init(recipe r: EditRecipe) {
        let b = r.blacks / 100, w = r.whites / 100
        let bright = r.brightness / 100, con = r.contrast / 100
        let hiBoost = max(0, r.highlights) / 100, shDeepen = max(0, -r.shadows) / 100
        isIdentity = b == 0 && w == 0 && bright == 0 && con == 0 && hiBoost == 0 && shDeepen == 0
        func f(_ x0: Double) -> Double {
            // Input levels (negative blacks clip deeper, positive whites clip brighter)
            let inLo = b < 0 ? -0.06 * b : 0
            let inHi = w > 0 ? 1 - 0.07 * w : 1
            var x = min(1, max(0, (x0 - inLo) / (inHi - inLo)))
            // Brightness: mid-tone gamma
            x = pow(x, pow(2, -bright * 0.65))
            // Contrast: monotonic cubic S-curve around 0.5
            let s = con * 0.5
            x = x + 2 * s * (2 * x - 1) * x * (1 - x)
            // Positive highlights brighten upper tones; negative shadows deepen lower tones
            x += hiBoost * 0.12 * pow(x, 2) * (1 - x) * 4
            x -= shDeepen * 0.12 * x * pow(1 - x, 2) * 4
            // Output levels (positive blacks lift, negative whites dim)
            let outLo = b > 0 ? 0.06 * b : 0
            let outHi = w < 0 ? 1 + 0.07 * w : 1
            return min(1, max(0, outLo + x * (outHi - outLo)))
        }
        points = [0, 0.25, 0.5, 0.75, 1].map { CGPoint(x: $0, y: f($0)) }
    }
}

/// Mapping between the temperature/tint sliders and per-channel linear gains.
enum WhiteBalanceModel {
    /// Gain exponent per slider unit (temperature 100 ⇒ red ×1.87, blue ×0.54 before luminance normalisation).
    static let k = 0.9

    static func gains(temperature: Double, tint: Double) -> (r: Double, g: Double, b: Double) {
        let t = temperature / 100, m = tint / 100
        var r = pow(2, k * t), b = pow(2, -k * t), g = pow(2, -k * m)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r /= lum; g /= lum; b /= lum
        return (r, g, b)
    }

    /// Inverse mapping: desired linear gains → slider values (clamped to the slider range).
    static func sliders(forGains gR: Double, _ gG: Double, _ gB: Double) -> (temperature: Double, tint: Double) {
        let t = log2(gR / gB) / (2 * k)
        let m = -log2(gG / sqrt(gR * gB)) / k
        return (max(-100, min(100, t * 100)), max(-100, min(100, m * 100)))
    }
}
