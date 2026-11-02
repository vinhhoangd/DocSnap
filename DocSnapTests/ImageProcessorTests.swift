import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import DocSnap

final class ImageProcessorTests: XCTestCase {
    /// 200×100 image: red left half, blue right half.
    private func twoColorImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        return ctx.makeImage()!
    }

    /// RGBA of the pixel at (x, y) with a top-left origin.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    func testOriginalIsUnchangedInSize() throws {
        let out = try XCTUnwrap(ImageProcessor.process(twoColorImage(), quad: .full, rotation: 0, filter: .original))
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 100)
    }

    func testRotationClockwise() throws {
        let out = try XCTUnwrap(ImageProcessor.process(twoColorImage(), quad: .full, rotation: 1, filter: .original))
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 200)
        // Rotating clockwise moves the left (red) half to the top.
        XCTAssertGreaterThan(pixel(out, 50, 20).r, 200)
        XCTAssertGreaterThan(pixel(out, 50, 180).b, 200)
    }

    func testRotationCounterClockwise() throws {
        let out = try XCTUnwrap(ImageProcessor.process(twoColorImage(), quad: .full, rotation: 3, filter: .original))
        XCTAssertGreaterThan(pixel(out, 50, 20).b, 200)
        XCTAssertGreaterThan(pixel(out, 50, 180).r, 200)
    }

    func testPerspectiveCropKeepsOnlyQuad() throws {
        // Crop the right (blue) half only.
        let quad = Quad(topLeft: CGPoint(x: 0.55, y: 0.05), topRight: CGPoint(x: 0.95, y: 0.05),
                        bottomRight: CGPoint(x: 0.95, y: 0.95), bottomLeft: CGPoint(x: 0.55, y: 0.95))
        let out = try XCTUnwrap(ImageProcessor.process(twoColorImage(), quad: quad, rotation: 0, filter: .original))
        XCTAssertEqual(Double(out.width), 80, accuracy: 2)
        XCTAssertEqual(Double(out.height), 90, accuracy: 2)
        let center = pixel(out, out.width / 2, out.height / 2)
        XCTAssertGreaterThan(center.b, 200)
        XCTAssertLessThan(center.r, 50)
    }

    func testCropUsesTopLeftOrigin() throws {
        // Image with a black top half and white bottom half; crop the top band.
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 50, width: 100, height: 50)) // CG origin is bottom-left → this is the visual top
        let image = ctx.makeImage()!
        let topBand = Quad(topLeft: CGPoint(x: 0.1, y: 0.05), topRight: CGPoint(x: 0.9, y: 0.05),
                           bottomRight: CGPoint(x: 0.9, y: 0.4), bottomLeft: CGPoint(x: 0.1, y: 0.4))
        let out = try XCTUnwrap(ImageProcessor.process(image, quad: topBand, rotation: 0, filter: .original))
        XCTAssertLessThan(pixel(out, out.width / 2, out.height / 2).r, 30)
    }

    func testEveryFilterRendersSameSize() throws {
        let photo = try XCTUnwrap(SampleData.photoOfPaper(lines: ["Hello"], size: CGSize(width: 600, height: 800)).cgImage)
        for filter in ScanFilter.allCases {
            let out = try XCTUnwrap(ImageProcessor.process(photo, quad: .full, rotation: 0, filter: filter), "\(filter)")
            XCTAssertEqual(out.width, 600, "\(filter)")
            XCTAssertEqual(out.height, 800, "\(filter)")
        }
    }

    func testBlackWhiteWhitensShadowedPaper() throws {
        let photo = try XCTUnwrap(SampleData.photoOfPaper(lines: ["Shadow test"], size: CGSize(width: 600, height: 800)).cgImage)
        let quad = Quad(topLeft: CGPoint(x: 0.16, y: 0.12), topRight: CGPoint(x: 0.86, y: 0.15),
                        bottomRight: CGPoint(x: 0.82, y: 0.88), bottomLeft: CGPoint(x: 0.12, y: 0.85))
        let out = try XCTUnwrap(ImageProcessor.process(photo, quad: quad, rotation: 0, filter: .blackWhite))
        // The bottom-right of the page is darkened by the synthetic shadow; B&W should flatten it to white.
        let p = pixel(out, out.width - 20, out.height - 20)
        XCTAssertGreaterThan(p.r, 230)
    }

    func testNormalizedRespectsOrientationAndCap() throws {
        let base = UIImage(cgImage: twoColorImage(), scale: 1, orientation: .right)
        let cg = try XCTUnwrap(ImageProcessor.normalizedCGImage(base))
        XCTAssertEqual(cg.width, 100)
        XCTAssertEqual(cg.height, 200)
        let capped = try XCTUnwrap(ImageProcessor.normalizedCGImage(UIImage(cgImage: twoColorImage()), maxDimension: 50))
        XCTAssertEqual(capped.width, 50)
        XCTAssertEqual(capped.height, 25)
    }

    // MARK: - Scan quality

    private let pageQuad = Quad(topLeft: CGPoint(x: 0.16, y: 0.12), topRight: CGPoint(x: 0.86, y: 0.15),
                                bottomRight: CGPoint(x: 0.82, y: 0.88), bottomLeft: CGPoint(x: 0.12, y: 0.85))

    /// The synthetic page photo, slightly out of focus like a hand-held shot.
    private func blurredPagePhoto() throws -> CGImage {
        let sharp = CIImage(cgImage: try XCTUnwrap(SampleData.photoOfPaper(lines: ["INVOICE 2026", "DocSnap sample page", "Total: 120.00"]).cgImage))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = sharp.clampedToExtent()
        blur.radius = 1.5
        return try XCTUnwrap(ImageProcessor.render(try XCTUnwrap(blur.outputImage).cropped(to: sharp.extent)))
    }

    /// 8-bit luminance, row-major with a top-left origin.
    private func grayPixels(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height)
        let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }

    /// Mean gradient magnitude over pixels that are neither paper nor ink core in `mask`.
    private func edgeGradient(_ px: [UInt8], mask: [UInt8], width: Int, height: Int) -> Double {
        var total = 0.0, count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                guard mask[i] > 60, mask[i] < 200 else { continue }
                let gx = Double(px[i + 1]) - Double(px[i - 1]), gy = Double(px[i + width]) - Double(px[i - width])
                total += (gx * gx + gy * gy).squareRoot()
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 1000, "the page should have text edges")
        return total / Double(max(count, 1))
    }

    func testGrayscaleSharpensTextWithoutBrightRims() throws {
        let photo = try blurredPagePhoto()
        let out = try XCTUnwrap(ImageProcessor.process(photo, quad: pageQuad, rotation: 0, filter: .grayscale))
        // The same filter without sharpening.
        let plain = CIFilter.colorControls()
        plain.inputImage = ImageProcessor.perspectiveCorrected(CIImage(cgImage: photo), quad: pageQuad)
        plain.saturation = 0
        plain.contrast = 1.1
        plain.brightness = 0.02
        let reference = try XCTUnwrap(ImageProcessor.render(try XCTUnwrap(plain.outputImage)))
        XCTAssertEqual(out.width, reference.width)
        let a = grayPixels(out), b = grayPixels(reference)
        // Skip a 2 px border: the unclamped reference has partly transparent edge pixels.
        var brighter = 0
        for y in 2..<(out.height - 2) {
            for x in 2..<(out.width - 2) where Int(a[y * out.width + x]) > Int(b[y * out.width + x]) + 2 { brighter += 1 }
        }
        XCTAssertLessThan(Double(brighter) / Double(a.count), 0.001, "sharpening must not lighten the paper around strokes")
        let sharp = edgeGradient(a, mask: b, width: out.width, height: out.height)
        let soft = edgeGradient(b, mask: b, width: out.width, height: out.height)
        XCTAssertGreaterThan(sharp, soft * 1.15, "text edges should be noticeably crisper")
    }

    func testMagicColorWhitensPaperAndKeepsInkDark() throws {
        let out = try XCTUnwrap(ImageProcessor.process(try blurredPagePhoto(), quad: pageQuad, rotation: 0, filter: .magicColor))
        let px = grayPixels(out)
        // Paper samples away from the text, including the shadowed bottom-right.
        for (fx, fy) in [(0.1, 0.6), (0.5, 0.7), (0.9, 0.9), (0.9, 0.5)] {
            let i = Int(fy * Double(out.height - 1)) * out.width + Int(fx * Double(out.width - 1))
            XCTAssertGreaterThanOrEqual(px[i], 245, "paper at \(fx),\(fy)")
        }
        XCTAssertGreaterThan(px.filter { $0 < 50 }.count, 2000, "the text should stay dark")
    }

    func testStoredImagesKeepHighJPEGQuality() {
        XCTAssertGreaterThanOrEqual(ImageProcessor.originalJPEGQuality, 0.95)
        XCTAssertGreaterThanOrEqual(ImageProcessor.processedJPEGQuality, 0.9)
        XCTAssertGreaterThanOrEqual(ImageProcessor.maxStoredDimension, 4032, "a 12 MP photo must keep full resolution")
    }
}
