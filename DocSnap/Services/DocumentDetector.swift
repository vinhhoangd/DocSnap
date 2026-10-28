import CoreGraphics
import Vision

/// Finds the paper's corners in a photo or a live camera frame
/// (used for imports, the "Auto Detect" crop button and DocSnap's camera).
enum DocumentDetector {
    /// Returns the document's corners (top-left origin), or `nil` if nothing convincing was found.
    static func detect(in image: CGImage) async -> Quad? {
        await Task.detached(priority: .userInitiated) {
            detectSync(in: image)
        }.value
    }

    static func detectSync(in image: CGImage) -> Quad? {
        detect(using: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    /// For live camera frames. `orientation` describes how the buffer is rotated relative to upright.
    static func detectSync(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> Quad? {
        detect(using: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]))
    }

    /// Runs both detectors and keeps the largest plausible page. The ML segmenter can return
    /// the whole frame or a partial strip, while the edge-based finder can lock onto a box
    /// printed *inside* the page, so neither result is trusted on its own.
    private static func detect(using handler: VNImageRequestHandler) -> Quad? {
        let segmentation = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.25
        rectangles.maximumAspectRatio = 1.0
        rectangles.minimumSize = 0.2
        rectangles.quadratureTolerance = 30
        rectangles.minimumConfidence = 0.5
        rectangles.maximumObservations = 3

        // Perform separately: if one request fails (e.g. no Neural Engine), the other still runs.
        var candidates: [Quad] = []
        if (try? handler.perform([segmentation])) != nil,
           let obs = segmentation.results?.first, obs.confidence >= 0.5, let quad = quad(from: obs) {
            candidates.append(quad)
        }
        if (try? handler.perform([rectangles])) != nil {
            candidates += (rectangles.results ?? []).compactMap(quad(from:))
        }
        guard let best = candidates.filter({ !$0.isNearlyFullFrame && !$0.isMostlyOnFrameEdge })
            .max(by: { $0.area < $1.area }) else { return nil }
        return best.inset(by: 0.004)
    }

    private static func quad(from obs: VNRectangleObservation) -> Quad? {
        // Vision uses a bottom-left origin; flip to top-left and normalize the corner order.
        let points = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
        let quad = Quad.ordered(points).clamped()
        guard quad.isValid, quad.area > 0.05 else { return nil }
        return quad
    }
}

extension Quad {
    /// Three or more corners on the image border. The segmentation model reports such strips
    /// (e.g. the bottom quarter of a blank wall) with high confidence; a real page in view has
    /// corners inside the frame, and one cut off by the frame can't be cropped correctly anyway.
    var isMostlyOnFrameEdge: Bool {
        let margin: CGFloat = 0.02
        let onEdge = points.filter { $0.x < margin || $0.x > 1 - margin || $0.y < margin || $0.y > 1 - margin }
        return onEdge.count >= 3
    }

    /// Every corner within 2% of the image corner: the detector saw no real page edge.
    var isNearlyFullFrame: Bool {
        zip(points, Quad.full.points).allSatisfy { abs($0.x - $1.x) < 0.02 && abs($0.y - $1.y) < 0.02 }
    }

    /// Pulls each corner toward the center by `fraction` of the image, so a detected edge that
    /// sits a pixel or two outside the paper doesn't leave a sliver of desk in the scan.
    func inset(by fraction: CGFloat) -> Quad {
        let cx = points.map(\.x).reduce(0, +) / 4
        let cy = points.map(\.y).reduce(0, +) / 4
        return Quad(points: points.map { p in
            let dx = cx - p.x, dy = cy - p.y
            let length = max(hypot(dx, dy), 1e-9)
            let step = min(fraction, length / 2)
            return CGPoint(x: p.x + dx / length * step, y: p.y + dy / length * step)
        })
    }
}
