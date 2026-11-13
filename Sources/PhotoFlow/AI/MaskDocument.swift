import Foundation
import CoreGraphics

/// Editable selection mask. Operations are stored in normalised image coordinates (0…1, top-left
/// origin), so the mask can be rendered at preview size for display and at full size for processing.
struct MaskDocument: Equatable {
    enum Tool: String, CaseIterable, Identifiable {
        case brush, eraser, rectangle, ellipse
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brush: return String(localized: "Brush")
            case .eraser: return String(localized: "Eraser")
            case .rectangle: return String(localized: "Rectangle")
            case .ellipse: return String(localized: "Ellipse")
            }
        }
        var symbol: String {
            switch self {
            case .brush: return "paintbrush.pointed"
            case .eraser: return "eraser"
            case .rectangle: return "rectangle.dashed"
            case .ellipse: return "circle.dashed"
            }
        }
    }

    struct Operation: Equatable {
        var tool: Tool
        var points: [CGPoint]      // brush/eraser path, or [start, end] for shapes
        var size: CGFloat          // brush diameter relative to the image's long side
    }

    /// Optional starting mask (e.g. the subject found by Vision), same aspect as the image.
    var base: CGImage?
    var operations: [Operation] = []
    var inverted = false
    /// Grow (+) or shrink (−) the selection, in percent of the long side ×10 (−20…20 → ±2 %).
    var refine: Double = 0
    /// Edge softness in pixels at full resolution.
    var feather: Double = 8

    static func == (a: MaskDocument, b: MaskDocument) -> Bool {
        a.base === b.base && a.operations == b.operations && a.inverted == b.inverted && a.refine == b.refine && a.feather == b.feather
    }

    var isEmpty: Bool { base == nil && operations.allSatisfy { $0.tool == .eraser } && !inverted }

    mutating func clear() { base = nil; operations = []; inverted = false; refine = 0 }
    mutating func undo() { if !operations.isEmpty { operations.removeLast() } else if base != nil { base = nil } }

    /// Renders the mask (grey, 255 = selected) at the given size.
    func render(width: Int, height: Int) -> CGImage? {
        let long = CGFloat(max(width, height))
        let raw = AIImage.grayMask(width: width, height: height) { ctx in
            if let base { ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height)) }
            // flip to top-left coordinates
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for op in operations {
                let value: CGFloat = op.tool == .eraser ? 0 : 1
                ctx.setFillColor(gray: value, alpha: 1)
                ctx.setStrokeColor(gray: value, alpha: 1)
                let pts = op.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
                switch op.tool {
                case .brush, .eraser:
                    let d = max(1, op.size * long)
                    ctx.setLineWidth(d)
                    if pts.count == 1 {
                        ctx.fillEllipse(in: CGRect(x: pts[0].x - d / 2, y: pts[0].y - d / 2, width: d, height: d))
                    } else if let first = pts.first {
                        ctx.beginPath()
                        ctx.move(to: first)
                        for p in pts.dropFirst() { ctx.addLine(to: p) }
                        ctx.strokePath()
                    }
                case .rectangle, .ellipse:
                    guard pts.count >= 2 else { continue }
                    let r = CGRect(x: min(pts[0].x, pts[1].x), y: min(pts[0].y, pts[1].y),
                                   width: abs(pts[1].x - pts[0].x), height: abs(pts[1].y - pts[0].y))
                    if op.tool == .rectangle { ctx.fill(r) } else { ctx.fillEllipse(in: r) }
                }
            }
        }
        guard var mask = raw else { return nil }
        if inverted, let inv = AIImage.invert(mask) { mask = inv }
        if abs(refine) >= 1 {
            let px = abs(refine) / 1000 * Double(long)
            if refine > 0 {
                mask = AIImage.dilate(mask, pixels: px) ?? mask
            } else if let inv = AIImage.invert(mask), let grown = AIImage.dilate(inv, pixels: px), let back = AIImage.invert(grown) {
                mask = back
            }
        }
        return mask
    }
}
