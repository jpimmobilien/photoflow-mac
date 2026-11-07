import Foundation
import CoreGraphics
import CoreImage

/// Geometric correction model shared by straightening, perspective correction, rendering and the UI.
///
/// Coordinates are centred on the image and y points **up** (Core Image convention).
/// The full transform is  `P ∘ R`: first a rotation by `rotation` (CCW positive), then a projective
/// keystone correction `P` defined in homogeneous coordinates as
///
///     [x, y, 1]  →  [x, y, 1 − cv·y/H + ch·x/W]
///
/// `cv` > 0 widens the top of the image (corrects verticals that converge upwards, e.g. buildings
/// photographed from below). `ch` corrects converging horizontals. Because the model is a true homography,
/// straight lines stay straight, and the same parameters work at any resolution.
struct GeometryModel: Sendable, Equatable {
    var rotationDegrees: Double
    var cv: Double
    var ch: Double

    /// Slider value (−100…100) ↔ projective coefficient.
    static let perspectiveRange: Double = 0.8

    init(rotationDegrees: Double = 0, cv: Double = 0, ch: Double = 0) {
        self.rotationDegrees = rotationDegrees; self.cv = cv; self.ch = ch
    }

    init(recipe: EditRecipe) {
        rotationDegrees = recipe.rotation
        cv = recipe.perspectiveVertical / 100 * GeometryModel.perspectiveRange
        ch = recipe.perspectiveHorizontal / 100 * GeometryModel.perspectiveRange
    }

    var isIdentity: Bool { abs(rotationDegrees) < 1e-6 && abs(cv) < 1e-6 && abs(ch) < 1e-6 }

    /// Maps a centred point (y up) of an image of size W×H.
    func map(_ p: CGPoint, size: CGSize) -> CGPoint {
        let t = rotationDegrees * .pi / 180
        let c = cos(t), s = sin(t)
        let x = Double(p.x) * c - Double(p.y) * s
        let y = Double(p.x) * s + Double(p.y) * c
        let w = 1 - cv * y / Double(size.height) + ch * x / Double(size.width)
        return CGPoint(x: x / w, y: y / w)
    }

    /// Destination quadrilateral of the source image corners (centred coordinates): TL, TR, BR, BL.
    func quad(size: CGSize) -> [CGPoint] {
        let hw = size.width / 2, hh = size.height / 2
        return [CGPoint(x: -hw, y: hh), CGPoint(x: hw, y: hh), CGPoint(x: hw, y: -hh), CGPoint(x: -hw, y: -hh)]
            .map { map($0, size: size) }
    }

    /// Largest axis-aligned rectangle with the original aspect ratio that lies completely inside the
    /// transformed image (so no empty corners are ever visible). Returned in centred coordinates.
    func inscribedRect(size: CGSize) -> CGRect {
        let q = quad(size: size)
        guard !isIdentity else { return CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height) }
        guard GeometryModel.isConvex(q) else { return .zero }
        let aspect = size.width / size.height
        var best = CGRect.zero
        // Search a small grid of centre offsets – keystone corrections are not symmetric vertically.
        let steps = [-0.15, -0.1, -0.05, 0, 0.05, 0.1, 0.15]
        for dyf in steps {
            for dxf in steps where abs(dxf) <= 0.1 || abs(ch) > 1e-6 {
                let cx = dxf * size.width, cy = dyf * size.height
                var lo = 0.0, hi = 2.0
                for _ in 0 ..< 32 {
                    let mid = (lo + hi) / 2
                    let w = size.width * mid, h = w / aspect
                    let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                    if GeometryModel.rect(r, inside: q) { lo = mid } else { hi = mid }
                }
                let w = size.width * lo, h = w / aspect
                if w * h > best.width * best.height {
                    best = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                }
            }
        }
        return best
    }

    /// Fraction of the original area that survives the inscribed crop (shown in the UI, used for safety limits).
    func retainedArea(size: CGSize) -> Double {
        let r = inscribedRect(size: size)
        return Double(r.width * r.height / (size.width * size.height))
    }

    static func rect(_ r: CGRect, inside q: [CGPoint]) -> Bool {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        return pts.allSatisfy { point($0, inside: q) }
    }

    /// Point-in-convex-polygon (either winding).
    static func point(_ p: CGPoint, inside q: [CGPoint]) -> Bool {
        var sign = 0.0
        for i in 0 ..< q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            let cross = Double((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x))
            if abs(cross) < 1e-9 { continue }
            if sign == 0 { sign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sign { return false }
        }
        return true
    }

    static func isConvex(_ q: [CGPoint]) -> Bool {
        var sign = 0.0
        for i in 0 ..< q.count {
            let a = q[i], b = q[(i + 1) % q.count], c = q[(i + 2) % q.count]
            let cross = Double((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
            if sign == 0 { sign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sign { return false }
        }
        return true
    }
}

extension CIImage {
    /// Moves the image so its extent starts at the origin.
    func normalizedToOrigin() -> CIImage {
        let e = extent
        guard e.origin != .zero, e.origin.x.isFinite else { return self }
        return transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    /// Rotates by multiples of 90° counter-clockwise and re-anchors at the origin.
    func rotatedQuarterTurns(_ turns: Int) -> CIImage {
        let k = ((turns % 4) + 4) % 4
        guard k != 0 else { return self }
        let t = CGAffineTransform(rotationAngle: CGFloat(k) * .pi / 2)
        return transformed(by: t).normalizedToOrigin()
    }

    /// Applies the geometry model plus inscribed crop (and optional user crop in normalized coordinates).
    func applyingGeometry(_ model: GeometryModel, crop: NormalizedRect?) -> CIImage {
        var img = normalizedToOrigin()
        let size = img.extent.size
        var rect: CGRect
        if model.isIdentity {
            rect = CGRect(origin: .zero, size: size)
        } else {
            let q = model.quad(size: size)
            let off = CGPoint(x: size.width / 2, y: size.height / 2)
            func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x + off.x, y: p.y + off.y) }
            img = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": v(q[0]), "inputTopRight": v(q[1]),
                "inputBottomRight": v(q[2]), "inputBottomLeft": v(q[3])
            ])
            let r = model.inscribedRect(size: size)
            rect = r.offsetBy(dx: off.x, dy: off.y)
        }
        if let crop, !crop.isFull {
            // Normalized crop has its origin at the top-left; Core Image's y axis points up.
            let x = rect.minX + CGFloat(crop.x) * rect.width
            let w = CGFloat(crop.width) * rect.width
            let h = CGFloat(crop.height) * rect.height
            let y = rect.maxY - CGFloat(crop.y) * rect.height - h
            rect = CGRect(x: x, y: y, width: w, height: h)
        }
        rect = rect.integral.intersection(img.extent.integral)
        guard rect.width >= 1, rect.height >= 1 else { return self }
        return img.cropped(to: rect).normalizedToOrigin()
    }
}
