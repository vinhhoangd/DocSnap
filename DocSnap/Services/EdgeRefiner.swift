import CoreGraphics
import CoreVideo
import simd

/// 8-bit luminance pixels, row-major with a top-left origin. Used to measure paper edges.
struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must match the size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// `image` scaled down so its longest side is at most `maxSide`.
    init?(_ image: CGImage, maxSide: Int) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height, 1)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var px = [UInt8](repeating: 0, count: w * h)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: px)
    }

    /// A BGRA camera frame, subsampled so its longest side is at most about `maxSide`.
    init?(_ buffer: CVPixelBuffer, maxSide: Int) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, Int((Double(max(bw, bh)) / Double(maxSide)).rounded(.up)))
        let w = bw / step, h = bh / step
        guard w > 0, h > 0 else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var px = [UInt8](repeating: 0, count: w * h)
        // Sample at each output pixel's center, so normalized positions match the full frame exactly.
        let sx = Double(bw) / Double(w), sy = Double(bh) / Double(h)
        for y in 0..<h {
            let row = src + min(Int((Double(y) + 0.5) * sy), bh - 1) * rowBytes
            for x in 0..<w {
                let p = row + min(Int((Double(x) + 0.5) * sx), bw - 1) * 4 // B, G, R, A
                px[y * w + x] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
            }
        }
        self.init(width: w, height: h, pixels: px)
    }

    /// Bilinear sample at a pixel-space point (pixel centers at +0.5), clamped to the image.
    func sample(_ p: SIMD2<Double>) -> Double {
        let x = min(max(p.x - 0.5, 0), Double(width - 1))
        let y = min(max(p.y - 0.5, 0), Double(height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let top = Double(pixels[y0 * width + x0]) * (1 - fx) + Double(pixels[y0 * width + x1]) * fx
        let bottom = Double(pixels[y1 * width + x0]) * (1 - fx) + Double(pixels[y1 * width + x1]) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// Snaps a roughly detected page outline onto the paper's real edges.
///
/// Vision's outline is coarse (the segmentation mask is low resolution), so it often sits a few
/// millimetres inside the paper. For each side, the refiner looks along the side's normal for the
/// strongest brightness step between paper and background, fits a straight line through those
/// points (dropping outliers such as text or a finger), and intersects neighbouring lines to get
/// the corners. A side with no clear edge keeps its original position.
enum EdgeRefiner {
    /// Search distance each way, as a fraction of the image's longest side.
    static let searchFraction = 0.03
    /// Smallest brightness step (0–255) that counts as a paper edge.
    static let minimumContrast = 14.0

    struct Result {
        var quad: Quad
        /// How many of the four sides were moved onto a measured edge (the rest kept Vision's line).
        var refinedSides: Int
    }

    static func refine(_ quad: Quad, in image: GrayImage) -> Result {
        let unchanged = Result(quad: quad, refinedSides: 0)
        guard image.width >= 32, image.height >= 32, quad.isValid else { return unchanged }
        let w = Double(image.width), h = Double(image.height)
        let search = searchDistance(in: image)
        let pts = quad.points.map { SIMD2<Double>(Double($0.x) * w, Double($0.y) * h) }
        let center = pts.reduce(SIMD2<Double>(0, 0), +) / 4

        let fitted = (0..<4).map { i -> Line? in
            fitSide(from: pts[i], to: pts[(i + 1) % 4], center: center, image: image)
        }
        let lines = (0..<4).map { i in fitted[i] ?? Line(point: pts[i], direction: simd_normalize(pts[(i + 1) % 4] - pts[i])) }
        var corners: [SIMD2<Double>] = []
        for i in 0..<4 {
            // Corner i joins side i-1 (ending at it) and side i (starting at it).
            guard let p = lines[(i + 3) % 4].intersection(with: lines[i]),
                  simd_distance(p, pts[i]) <= search * 2 else { return unchanged }
            corners.append(p)
        }
        let refined = Quad(points: corners.map { CGPoint(x: $0.x / w, y: $0.y / h) }).clamped()
        guard refined.isValid, refined.area > quad.area * 0.85, refined.area < quad.area * 1.3 else { return unchanged }
        return Result(quad: refined, refinedSides: fitted.compactMap { $0 }.count)
    }

    struct Line {
        var point: SIMD2<Double>
        var direction: SIMD2<Double> // unit length

        func intersection(with other: Line) -> SIMD2<Double>? {
            let d1 = direction, d2 = other.direction
            let denominator = d1.x * d2.y - d1.y * d2.x
            // Nearly parallel neighbours (under ~3°) can't define a corner.
            guard abs(denominator) > 0.05 else { return nil }
            let diff = other.point - point
            let t = (diff.x * d2.y - diff.y * d2.x) / denominator
            return point + d1 * t
        }
    }

    /// Edge points along one side, fitted to a line; nil when the edge isn't clear enough.
    /// Pixels searched each way from Vision's line.
    private static func searchDistance(in image: GrayImage) -> Double {
        max(6, Double(max(image.width, image.height)) * searchFraction)
    }

    private static func fitSide(from a: SIMD2<Double>, to b: SIMD2<Double>, center: SIMD2<Double>, image: GrayImage) -> Line? {
        let search = searchDistance(in: image)
        // Brightness is averaged over this many pixels on each side of a candidate edge.
        let window = max(3, Double(max(image.width, image.height)) * 0.006)
        let side = b - a
        let length = simd_length(side)
        guard length > 20 else { return nil }
        let tangent = side / length
        var normal = SIMD2<Double>(-tangent.y, tangent.x)
        if simd_dot(normal, (a + b) / 2 - center) < 0 { normal = -normal } // point outward

        let step = 0.5
        let reach = Int((search / step).rounded())
        let span = max(2, Int((window / step).rounded()))
        let half = reach + span + 1
        let samples = 40
        var brighterInside: [SIMD2<Double>] = []
        var darkerInside: [SIMD2<Double>] = []
        var profile = [Double](repeating: 0, count: 2 * half + 1)
        var prefix = [Double](repeating: 0, count: profile.count + 1)
        var scores = [Double](repeating: 0, count: profile.count)

        for k in 0..<samples {
            // Stay clear of the corners, where the neighbouring side's edge interferes.
            let p = a + side * (0.1 + 0.8 * Double(k) / Double(samples - 1))
            for j in profile.indices {
                let q = p + normal * (Double(j - half) * step)
                // Average across the tangent too, so paper texture and thin strokes count less.
                profile[j] = (image.sample(q - tangent * 1.5) + image.sample(q) + image.sample(q + tangent * 1.5)) / 3
                prefix[j + 1] = prefix[j] + profile[j]
            }
            // score > 0: brighter on the inside (toward the page center) than outside.
            let range = (half - reach)...(half + reach)
            for j in range {
                let inside = (prefix[j] - prefix[j - span]) / Double(span)
                let outside = (prefix[j + 1 + span] - prefix[j + 1]) / Double(span)
                scores[j] = inside - outside
            }
            if let j = nearestPeak(scores, in: range, origin: half, sign: 1) {
                brighterInside.append(p + normal * (Double(j - half) * step))
            }
            if let j = nearestPeak(scores, in: range, origin: half, sign: -1) {
                darkerInside.append(p + normal * (Double(j - half) * step))
            }
        }
        // Usually the paper is brighter than the desk; a dark page on a light desk flips it.
        let points = brighterInside.count >= darkerInside.count ? brighterInside : darkerInside
        let needed = Int(Double(samples) * 0.35)
        guard points.count >= needed, let line = robustLine(points, minimumCount: needed) else { return nil }
        // The refined side must run roughly the same way as the detected one (within 10°).
        guard abs(line.direction.x * tangent.y - line.direction.y * tangent.x) < 0.17 else { return nil }
        return line
    }

    /// Among the local maxima of `sign * score` that are clear steps (at least 1.5× the minimum
    /// contrast and 20% of the strongest), the one nearest Vision's line (`origin`). Vision is only a
    /// few millimetres off, so the nearest clear step is the paper's edge — not a printed frame or
    /// text just inside it, nor another sheet or the table just outside it (a white page on a
    /// slightly darker sheet is a much weaker step than that sheet against the desk).
    private static func nearestPeak(_ scores: [Double], in range: ClosedRange<Int>, origin: Int, sign: Double) -> Int? {
        var best = 0.0
        for j in range { best = max(best, sign * scores[j]) }
        guard best >= minimumContrast else { return nil }
        var chosen: Int?
        for j in range {
            let s = sign * scores[j]
            guard s >= max(best * 0.2, minimumContrast * 1.5) else { continue }
            let left = j > range.lowerBound ? sign * scores[j - 1] : -.infinity
            let right = j < range.upperBound ? sign * scores[j + 1] : -.infinity
            guard s >= left, s >= right else { continue }
            if chosen.map({ abs(j - origin) < abs($0 - origin) }) ?? true { chosen = j }
        }
        return chosen
    }

    /// Total-least-squares line, refitted after dropping points far from it.
    private static func robustLine(_ points: [SIMD2<Double>], minimumCount: Int) -> Line? {
        var kept = points
        var line: Line?
        for _ in 0..<3 {
            guard kept.count >= max(minimumCount, 2) else { return nil }
            let mean = kept.reduce(SIMD2<Double>(0, 0), +) / Double(kept.count)
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for p in kept {
                let d = p - mean
                sxx += d.x * d.x
                sxy += d.x * d.y
                syy += d.y * d.y
            }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let fitted = Line(point: mean, direction: SIMD2(cos(angle), sin(angle)))
            line = fitted
            let normal = SIMD2(-fitted.direction.y, fitted.direction.x)
            let residuals = kept.map { abs(simd_dot($0 - mean, normal)) }
            let median = residuals.sorted()[residuals.count / 2]
            let limit = max(1.0, median * 3)
            let next = zip(kept, residuals).filter { $0.1 <= limit }.map(\.0)
            if next.count == kept.count { break }
            kept = next
        }
        guard kept.count >= minimumCount else { return nil }
        return line
    }
}
