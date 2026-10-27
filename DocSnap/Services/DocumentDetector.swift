import CoreGraphics
import Vision

/// Finds the paper's corners in a still photo (used for imports and the "Auto" crop button).
/// The live camera uses VisionKit, which does its own detection.
enum DocumentDetector {
    /// Returns the document's corners (top-left origin), or `nil` if nothing convincing was found.
    static func detect(in image: CGImage) async -> Quad? {
        await Task.detached(priority: .userInitiated) {
            detectSync(in: image)
        }.value
    }

    /// Runs both detectors and keeps the largest plausible page. The ML segmenter can return
    /// the whole frame or a partial strip, while the edge-based finder can lock onto a box
    /// printed *inside* the page, so neither result is trusted on its own.
    static func detectSync(in image: CGImage) -> Quad? {
        let candidates = ([segmentDocument(in: image)] + detectRectangles(in: image)).compactMap { $0 }
        guard let best = candidates.filter({ !$0.isNearlyFullFrame }).max(by: { $0.area < $1.area }) else { return nil }
        return best.inset(by: 0.004)
    }

    /// Apple's document segmentation model (iOS 15+): best at real paper on a desk.
    private static func segmentDocument(in image: CGImage) -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first, obs.confidence >= 0.5 else { return nil }
        return quad(from: obs)
    }

    /// Classic edge-based rectangle finder: precise on high-contrast page edges.
    private static func detectRectangles(in image: CGImage) -> [Quad] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.2
        request.quadratureTolerance = 30
        request.minimumConfidence = 0.5
        request.maximumObservations = 3
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap(quad(from:))
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
