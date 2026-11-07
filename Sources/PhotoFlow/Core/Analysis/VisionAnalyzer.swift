import Foundation
import Vision
import CoreGraphics

/// Wraps Apple's on-device Vision models. These models ship with macOS itself – nothing is bundled,
/// downloaded or uploaded – and run on the Neural Engine, GPU or CPU depending on the Mac (Intel included).
enum VisionAnalyzer {
    struct SceneResult: Sendable {
        var labels: [(identifier: String, confidence: Float)]
        var faces: [CGRect]          // normalized, origin top-left
        var horizonAngle: Double?    // degrees, visual CCW tilt of the detected horizon
        var horizonConfidence: Float
        var salientRect: CGRect?     // normalized, origin top-left

        func has(_ ids: [String], minConfidence: Float = 0.3) -> Bool {
            labels.contains { l in l.confidence >= minConfidence && ids.contains { l.identifier.hasPrefix($0) } }
        }

        var topLabels: [String] { labels.prefix(5).map { $0.identifier } }
    }

    /// Runs classification, face detection, horizon detection and saliency in a single Vision pass.
    static func analyzeScene(_ image: CGImage) -> SceneResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let horizon = VNDetectHorizonRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([classify, faces, horizon, saliency])

        let labels = (classify.results ?? [])
            .filter { $0.confidence > 0.05 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(20)
            .map { (identifier: $0.identifier, confidence: $0.confidence) }
        let faceRects = (faces.results ?? []).map { flip($0.boundingBox) }
        var hAngle: Double?
        var hConf: Float = 0
        if let h = horizon.results?.first {
            // Vision reports the angle of the horizon; positive values are counter-clockwise.
            hAngle = Double(h.angle) * 180 / .pi
            hConf = h.confidence
        }
        let salient = (saliency.results?.first?.salientObjects ?? [])
            .map { flip($0.boundingBox) }
            .reduce(nil as CGRect?) { acc, r in acc.map { $0.union(r) } ?? r }
        return SceneResult(labels: Array(labels), faces: faceRects, horizonAngle: hAngle,
                           horizonConfidence: hConf, salientRect: salient)
    }

    /// Vision feature print (an embedding produced by Apple's on-device image model).
    /// Returned as an L2-normalized float vector together with the model revision.
    static func featurePrint(_ image: CGImage) -> (vector: [Float], revision: Int)? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
        var v: [Float]
        switch obs.elementType {
        case .float:
            v = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            v = obs.data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
        default:
            return nil
        }
        guard !v.isEmpty else { return nil }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrt(norm)
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return (v, request.revision)
    }

    /// Apple's on-device aesthetics model (macOS 15+). Returns (overall score −1…1, isUtility) or nil.
    static func aesthetics(_ image: CGImage) -> (score: Double, isUtility: Bool)? {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
            return (Double(obs.overallScore), obs.isUtility)
        }
        #endif
        return nil
    }

    /// Detects a dominant document-like rectangle (for document perspective rectification).
    static func documentQuad(_ image: CGImage) -> [CGPoint]? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.8
        request.minimumAspectRatio = 0.3
        request.minimumSize = 0.35
        request.maximumObservations = 1
        request.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let r = request.results?.first else { return nil }
        // Normalized, origin bottom-left (Core Image convention): TL, TR, BR, BL
        return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]
    }

    /// Vision uses a bottom-left origin; the rest of PhotoFlow uses top-left for normalized rects.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    // Scene vocabularies (identifiers from VNClassifyImageRequest's taxonomy).
    static let landscapeLabels = ["landscape", "mountain", "outdoor", "sky", "beach", "lake", "ocean", "forest", "field", "hill", "desert", "waterfall", "river", "shore", "valley", "cliff", "canyon"]
    static let sunsetLabels = ["sunset_sunrise", "sunset", "sunrise", "dusk", "twilight", "candle", "fire", "bonfire", "fireworks", "concert", "stage", "light_show"]
    static let nightLabels = ["night_sky", "night", "fireworks", "concert", "aurora", "moon", "star"]
    static let snowLabels = ["snow", "ski", "glacier", "ice", "winter"]
    static let architectureLabels = ["building", "structure", "architecture", "skyscraper", "house", "church", "tower", "cathedral", "bridge", "interior_room", "room", "kitchen", "office", "facade", "temple", "museum", "monument", "castle", "city", "street"]
    static let documentLabels = ["document", "text", "receipt", "paper", "screenshot", "printed_page", "whiteboard", "blackboard", "sign"]
    static let foodLabels = ["food", "dessert", "fruit", "drink", "meal", "baked_goods"]
    static let underwaterLabels = ["underwater", "aquarium", "coral_reef", "scuba"]
}
