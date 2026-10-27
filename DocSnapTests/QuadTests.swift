import XCTest
@testable import DocSnap

final class QuadTests: XCTestCase {
    func testOrderedSortsShuffledAxisAlignedCorners() {
        let shuffled = [CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.1)]
        let quad = Quad.ordered(shuffled)
        XCTAssertEqual(quad.topLeft, CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(quad.topRight, CGPoint(x: 0.9, y: 0.1))
        XCTAssertEqual(quad.bottomRight, CGPoint(x: 0.9, y: 0.9))
        XCTAssertEqual(quad.bottomLeft, CGPoint(x: 0.1, y: 0.9))
    }

    func testOrderedHandlesTiltedPage() {
        let pts = [CGPoint(x: 0.82, y: 0.88), CGPoint(x: 0.16, y: 0.12), CGPoint(x: 0.12, y: 0.85), CGPoint(x: 0.86, y: 0.15)]
        let quad = Quad.ordered(pts)
        XCTAssertEqual(quad.topLeft, CGPoint(x: 0.16, y: 0.12))
        XCTAssertEqual(quad.topRight, CGPoint(x: 0.86, y: 0.15))
        XCTAssertEqual(quad.bottomRight, CGPoint(x: 0.82, y: 0.88))
        XCTAssertEqual(quad.bottomLeft, CGPoint(x: 0.12, y: 0.85))
        XCTAssertTrue(quad.isValid)
    }

    func testValidity() {
        XCTAssertTrue(Quad.full.isValid)
        XCTAssertTrue(Quad.full.isFull)
        // Bow-tie (crossed) quad is invalid.
        let crossed = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 1),
                           bottomRight: CGPoint(x: 1, y: 0), bottomLeft: CGPoint(x: 0, y: 1))
        XCTAssertFalse(crossed.isValid)
        // Collapsed to a line.
        let line = Quad(topLeft: .zero, topRight: CGPoint(x: 1, y: 0), bottomRight: CGPoint(x: 1, y: 0), bottomLeft: .zero)
        XCTAssertFalse(line.isValid)
    }

    func testAreaAndFlip() {
        XCTAssertEqual(Quad.full.area, 1, accuracy: 1e-9)
        let q = Quad(topLeft: CGPoint(x: 0.2, y: 0.1), topRight: CGPoint(x: 0.8, y: 0.1),
                     bottomRight: CGPoint(x: 0.8, y: 0.6), bottomLeft: CGPoint(x: 0.2, y: 0.6))
        XCTAssertEqual(q.area, 0.3, accuracy: 1e-9)
        for (a, b) in zip(q.flippedVertically().flippedVertically().points, q.points) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
        XCTAssertEqual(q.flippedVertically().topLeft.y, 0.9, accuracy: 1e-9)
    }

    func testInsetAndFullFrame() {
        XCTAssertTrue(Quad.full.isNearlyFullFrame)
        let inset = Quad.full.inset(by: 0.01)
        XCTAssertFalse(inset.isFull)
        XCTAssertEqual(inset.topLeft.x, 0.01 / 2.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(inset.bottomRight.y, 1 - 0.01 / 2.squareRoot(), accuracy: 1e-6)
        XCTAssertTrue(inset.isNearlyFullFrame)
        XCTAssertFalse(Quad.full.inset(by: 0.1).isNearlyFullFrame)
    }

    func testRotatedNormalizedMatchesImageRotation() {
        let tl = CGPoint(x: 0.1, y: 0.2)
        XCTAssertEqual(tl.rotatedNormalized(quarterTurns: 0), tl)
        // One clockwise turn moves the top-left area to the top-right.
        let once = tl.rotatedNormalized(quarterTurns: 1)
        XCTAssertEqual(once.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(once.y, 0.1, accuracy: 1e-9)
        let twice = tl.rotatedNormalized(quarterTurns: 2)
        XCTAssertEqual(twice.x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(twice.y, 0.8, accuracy: 1e-9)
        for turns in 0..<4 {
            let back = tl.rotatedNormalized(quarterTurns: turns).rotatedNormalized(quarterTurns: 4 - turns)
            XCTAssertEqual(back.x, tl.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, tl.y, accuracy: 1e-9)
        }
        XCTAssertEqual(tl.rotatedNormalized(quarterTurns: -1).x, tl.rotatedNormalized(quarterTurns: 3).x, accuracy: 1e-9)
    }

    func testCodableRoundTrip() throws {
        let page = ScanPage(quad: Quad.ordered([CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.95, y: 0.9), CGPoint(x: 0.05, y: 0.8)]),
                            filter: .blackWhite, rotation: 3, textLines: [TextLine(text: "Xin chào", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05))])
        let doc = ScanDocument(title: "Test", pages: [page])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ScanDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
    }

    func testDecodingToleratesMissingAndUnknownFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","filter":"futureFilter","rotation":-1}"#
        let page = try JSONDecoder().decode(ScanPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.filter, .magicColor)
        XCTAssertEqual(page.rotation, 3)
        XCTAssertEqual(page.quad, .full)
        XCTAssertNil(page.textLines)
    }
}
