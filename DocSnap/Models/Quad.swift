import CoreGraphics
import Foundation

/// The four corners of a document inside an image.
///
/// Points are normalized to 0...1 with the origin at the **top-left** of the
/// orientation-corrected image (UIKit convention). Vision and Core Image use a
/// bottom-left origin, so convert with `flippedVertically()` at those boundaries.
struct Quad: Codable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let full = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// Corners in clockwise order starting at the top-left.
    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Builds a quad from four points given clockwise from the top-left.
    init(points: [CGPoint]) {
        precondition(points.count == 4, "A quad needs exactly four points")
        self.init(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
    }

    subscript(index: Int) -> CGPoint {
        get { points[index] }
        set {
            switch index {
            case 0: topLeft = newValue
            case 1: topRight = newValue
            case 2: bottomRight = newValue
            default: bottomLeft = newValue
            }
        }
    }

    /// Re-orders four arbitrary points into top-left, top-right, bottom-right, bottom-left
    /// (top-left origin). Works for rotated documents as well as axis-aligned ones.
    static func ordered(_ points: [CGPoint]) -> Quad {
        precondition(points.count == 4, "A quad needs exactly four points")
        let cx = points.map(\.x).reduce(0, +) / 4
        let cy = points.map(\.y).reduce(0, +) / 4
        // With y pointing down, ascending atan2 walks clockwise on screen.
        var sorted = points.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        let start = sorted.indices.min { sorted[$0].x + sorted[$0].y < sorted[$1].x + sorted[$1].y } ?? 0
        sorted = Array(sorted[start...] + sorted[..<start])
        return Quad(points: sorted)
    }

    /// The same quad with a bottom-left origin (or back again).
    func flippedVertically() -> Quad {
        Quad(
            topLeft: CGPoint(x: topLeft.x, y: 1 - topLeft.y),
            topRight: CGPoint(x: topRight.x, y: 1 - topRight.y),
            bottomRight: CGPoint(x: bottomRight.x, y: 1 - bottomRight.y),
            bottomLeft: CGPoint(x: bottomLeft.x, y: 1 - bottomLeft.y)
        )
    }

    func clamped() -> Quad {
        Quad(points: points.map { CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) })
    }

    /// Corner positions in a space of the given size (e.g. pixels or view points).
    func scaled(to size: CGSize) -> [CGPoint] {
        points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }

    /// True when the quad covers (practically) the whole image, so no crop is needed.
    var isFull: Bool {
        zip(points, Quad.full.points).allSatisfy { abs($0.x - $1.x) < 0.001 && abs($0.y - $1.y) < 0.001 }
    }

    /// A usable crop: convex, wound consistently, and not collapsed to a sliver.
    var isValid: Bool {
        let pts = points
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-6 { return false }
            if sign == 0 {
                sign = cross > 0 ? 1 : -1
            } else if (cross > 0 ? 1 : -1) != sign {
                return false
            }
        }
        return area > 0.01
    }

    /// Area as a fraction of the image (shoelace formula).
    var area: CGFloat {
        let pts = points
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}
