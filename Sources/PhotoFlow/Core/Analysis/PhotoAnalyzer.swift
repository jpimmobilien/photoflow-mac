import Foundation
import CoreGraphics

/// Everything PhotoFlow measures about one photo before deciding how to improve it.
struct PhotoAnalysis: Sendable {
    var stats: ImageStatistics
    var whiteBalance: WhiteBalanceEstimator.Estimate
    var scene: VisionAnalyzer.SceneResult
    var straighten: StraightenEngine.Result
    var perspective: PerspectiveEngine.Result
    var faceLuma: Double?           // mean gamma luma inside detected faces
    var faceColorLinear: (r: Double, g: Double, b: Double)?
    var iso: Int?
    var analysisImage: CGImage      // ~768 px oriented copy used for the analysis and the self-check

    var isNight: Bool {
        scene.has(VisionAnalyzer.nightLabels, minConfidence: 0.3) || (stats.meanLuma < 0.16 && stats.p99 > 0.6)
    }
    var isHighKey: Bool { scene.has(VisionAnalyzer.snowLabels, minConfidence: 0.3) || (stats.p50 > 0.62 && stats.clippedHighlights < 0.03) }
    var isSunset: Bool { scene.has(VisionAnalyzer.sunsetLabels, minConfidence: 0.25) }
    var isLandscape: Bool { scene.has(VisionAnalyzer.landscapeLabels, minConfidence: 0.35) }
    var isArchitecture: Bool { scene.has(VisionAnalyzer.architectureLabels, minConfidence: 0.3) }
    var isDocument: Bool { scene.has(VisionAnalyzer.documentLabels, minConfidence: 0.35) }
    var isFood: Bool { scene.has(VisionAnalyzer.foodLabels, minConfidence: 0.35) }
    var isUnderwater: Bool { scene.has(VisionAnalyzer.underwaterLabels, minConfidence: 0.3) }
    var hasFaces: Bool { !scene.faces.isEmpty }
    /// Portrait = faces covering a meaningful part of the frame.
    var isPortrait: Bool { scene.faces.reduce(0) { $0 + $1.width * $1.height } > 0.03 }
}

enum PhotoAnalyzer {
    static let analysisSize = 768

    static func analyze(url: URL, iso: Int? = nil) -> PhotoAnalysis? {
        guard let cg = ImageLoader.thumbnail(url: url, maxPixel: analysisSize) else { return nil }
        return analyze(image: cg, iso: iso)
    }

    static func analyze(image cg: CGImage, iso: Int? = nil) -> PhotoAnalysis? {
        guard let px = PixelBuffer(cgImage: cg, maxSide: analysisSize) else { return nil }
        let stats = ImageStatistics.compute(px)
        let wb = WhiteBalanceEstimator.estimate(px)
        let scene = VisionAnalyzer.analyzeScene(cg)
        let edges = EdgeField(luma: px.luma(), width: px.width, height: px.height)
        let straight = StraightenEngine.detect(edges: edges, vision: scene)
        let persp = PerspectiveEngine.detect(edges: edges, rotationCorrection: straight.shouldApply ? straight.correction : 0, scene: scene)

        var faceLuma: Double?
        var faceColor: (r: Double, g: Double, b: Double)?
        if !scene.faces.isEmpty {
            var sum = 0.0, n = 0.0, cr = 0.0, cg2 = 0.0, cb = 0.0
            let lut = ColorMath.toLinearLUT
            for f in scene.faces {
                // Use the central part of the face box (skin, not hair/background)
                let inner = f.insetBy(dx: f.width * 0.2, dy: f.height * 0.2)
                let x0 = max(0, Int(inner.minX * Double(px.width))), x1 = min(px.width, Int(inner.maxX * Double(px.width)))
                let y0 = max(0, Int(inner.minY * Double(px.height))), y1 = min(px.height, Int(inner.maxY * Double(px.height)))
                guard x1 > x0, y1 > y0 else { continue }
                for y in y0 ..< y1 {
                    for x in x0 ..< x1 {
                        let i = (y * px.width + x) * 4
                        let r = px.data[i], g = px.data[i + 1], b = px.data[i + 2]
                        sum += (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
                        cr += Double(lut[Int(r)]); cg2 += Double(lut[Int(g)]); cb += Double(lut[Int(b)])
                        n += 1
                    }
                }
            }
            if n > 0 { faceLuma = sum / n; faceColor = (r: cr / n, g: cg2 / n, b: cb / n) }
        }
        return PhotoAnalysis(stats: stats, whiteBalance: wb, scene: scene, straighten: straight, perspective: persp,
                             faceLuma: faceLuma, faceColorLinear: faceColor, iso: iso, analysisImage: cg)
    }
}
