import CoreImage
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
}
