import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import XCTest
@testable import DocSnap

final class EdgeRefinerTests: XCTestCase {
    /// A tilted page (normalized, top-left origin), like a phone held a little off-axis.
    private let truth = Quad(topLeft: CGPoint(x: 0.14, y: 0.10), topRight: CGPoint(x: 0.87, y: 0.13),
                             bottomRight: CGPoint(x: 0.84, y: 0.90), bottomLeft: CGPoint(x: 0.11, y: 0.86))

    /// A white page on a darker desk, slightly out of focus. Optional text right inside the edges
    /// and a printed frame inside the page test that the outline stays on the paper's own edge.
    private func photo(page: Quad, size: CGSize = CGSize(width: 1200, height: 1600), desk: CGFloat = 0.38,
                       paper: CGFloat = 0.93, textNearEdges: Bool = false, printedFrame: Bool = false,
                       sheetBelow: Quad? = nil, blur: Double = 1.5) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor(white: desk, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            if let sheetBelow {
                let below = sheetBelow.scaled(to: size)
                let under = UIBezierPath()
                under.move(to: below[0])
                below.dropFirst().forEach { under.addLine(to: $0) }
                under.close()
                UIColor(white: paper - 0.12, alpha: 1).setFill()
                under.fill()
            }
            let corners = page.scaled(to: size)
            let path = UIBezierPath()
            path.move(to: corners[0])
            corners.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            UIColor(white: paper, alpha: 1).setFill()
            path.fill()
            if printedFrame {
                let frame = UIBezierPath()
                let inner = page.inset(by: 0.03).scaled(to: size)
                frame.move(to: inner[0])
                inner.dropFirst().forEach { frame.addLine(to: $0) }
                frame.close()
                frame.lineWidth = 4
                UIColor(white: 0.1, alpha: 1).setStroke()
                frame.stroke()
            }
            if textNearEdges {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor(white: 0.05, alpha: 1),
                ]
                let tl = corners[0]
                ("Header text close to the top edge" as NSString).draw(at: CGPoint(x: tl.x + 60, y: tl.y + 30), withAttributes: attributes)
                for i in 0..<12 {
                    ("Line" as NSString).draw(at: CGPoint(x: corners[3].x + 20 + CGFloat(i) * 2, y: tl.y + 150 + CGFloat(i) * 90),
                                              withAttributes: attributes)
                }
            }
        }
        let ci = CIImage(cgImage: try XCTUnwrap(image.cgImage))
        guard blur > 0 else { return try XCTUnwrap(image.cgImage) }
        let f = CIFilter.gaussianBlur()
        f.inputImage = ci.clampedToExtent()
        f.radius = Float(blur)
        return try XCTUnwrap(ImageProcessor.render(try XCTUnwrap(f.outputImage).cropped(to: ci.extent)))
    }

    private func assertClose(_ a: Quad, _ b: Quad, within tolerance: CGFloat, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        for (p, q) in zip(a.points, b.points) {
            XCTAssertLessThanOrEqual(hypot(p.x - q.x, p.y - q.y), tolerance, "\(message) corner \(p) vs \(q)", file: file, line: line)
        }
    }

    func testSnapsAnOutlineThatSitsInsideThePaper() throws {
        let gray = try XCTUnwrap(GrayImage(try photo(page: truth), maxSide: 1600))
        let rough = truth.inset(by: 0.02) // ≈ 30 px inside on every corner
        assertClose(EdgeRefiner.refine(rough, in: gray).quad, truth, within: 0.003)
    }

    func testSnapsAnOutlineThatSitsOutsideThePaper() throws {
        let gray = try XCTUnwrap(GrayImage(try photo(page: truth), maxSide: 1600))
        let rough = truth.inset(by: -0.015)
        assertClose(EdgeRefiner.refine(rough, in: gray).quad, truth, within: 0.003)
    }

    func testIgnoresTextAndPrintedFramesInsideThePage() throws {
        let image = try photo(page: truth, textNearEdges: true, printedFrame: true)
        let gray = try XCTUnwrap(GrayImage(image, maxSide: 1600))
        assertClose(EdgeRefiner.refine(truth.inset(by: 0.012), in: gray).quad, truth, within: 0.003)
    }

    func testLowContrastDeskStillSnaps() throws {
        // Off-white paper on a light gray desk.
        let gray = try XCTUnwrap(GrayImage(try photo(page: truth, desk: 0.72, paper: 0.9), maxSide: 1600))
        assertClose(EdgeRefiner.refine(truth.inset(by: 0.015), in: gray).quad, truth, within: 0.004)
    }

    func testDarkPaperOnLightDesk() throws {
        let gray = try XCTUnwrap(GrayImage(try photo(page: truth, desk: 0.9, paper: 0.35), maxSide: 1600))
        assertClose(EdgeRefiner.refine(truth.inset(by: 0.015), in: gray).quad, truth, within: 0.004)
    }

    func testStaysOnTheTopSheetOfAStack() throws {
        // Another sheet peeks out 1.5% below and to the right of the page being scanned.
        let below = Quad(points: truth.points.map { CGPoint(x: $0.x + 0.015, y: $0.y + 0.015) })
        let gray = try XCTUnwrap(GrayImage(try photo(page: truth, sheetBelow: below), maxSide: 1600))
        assertClose(EdgeRefiner.refine(truth.inset(by: 0.006), in: gray).quad, truth, within: 0.003)
    }

    func testReportsHowManySidesWereRefined() throws {
        let gray = try XCTUnwrap(GrayImage(try photo(page: truth), maxSide: 1600))
        XCTAssertEqual(EdgeRefiner.refine(truth.inset(by: 0.01), in: gray).refinedSides, 4)
        let blank = try XCTUnwrap(GrayImage(try photo(page: truth, desk: 0.6, paper: 0.6), maxSide: 1600))
        XCTAssertEqual(EdgeRefiner.refine(truth.inset(by: 0.01), in: blank).refinedSides, 0)
    }

    func testKeepsTheOutlineWhenThereIsNoEdge() throws {
        let blank = try photo(page: truth, desk: 0.6, paper: 0.6)
        let gray = try XCTUnwrap(GrayImage(blank, maxSide: 1600))
        let rough = truth.inset(by: 0.01)
        assertClose(EdgeRefiner.refine(rough, in: gray).quad, rough, within: 1e-9)
    }

    func testDetectorPutsTheBorderOnThePaperEdge() throws {
        // End to end through Vision: the outline must land on the paper, not millimetres inside it.
        let image = try photo(page: truth, textNearEdges: true)
        let found = try XCTUnwrap(DocumentDetector.detectSync(in: image))
        assertClose(found, truth, within: 0.004, "detected")
    }

    func testGrayImageFromCGImageIsTopDown() throws {
        // Top half black, bottom half white.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20)) // CG origin is bottom-left: this is the bottom half
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        let gray = try XCTUnwrap(GrayImage(try XCTUnwrap(ctx.makeImage()), maxSide: 40))
        XCTAssertLessThan(gray.pixels[5 * 40 + 5], 20)
        XCTAssertGreaterThan(gray.pixels[35 * 40 + 5], 235)
    }

    func testGrayImageFromBGRAPixelBuffer() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<48 {
            for x in 0..<64 {
                let p = base + y * rowBytes + x * 4
                let v: UInt8 = x < 32 ? 0 : 255
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let gray = try XCTUnwrap(GrayImage(pb, maxSide: 32))
        XCTAssertEqual(gray.width, 32)
        XCTAssertEqual(gray.height, 24)
        XCTAssertLessThan(gray.pixels[10], 5)
        XCTAssertGreaterThan(gray.pixels[30], 250)
    }
}
