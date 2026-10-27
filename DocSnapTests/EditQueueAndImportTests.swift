import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import DocSnap

/// Regression tests for the builder's fixes: queued page edits, clockwise-only quads,
/// file-based imports with EXIF orientation, and PDF size.
@MainActor
final class EditQueueAndImportTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EditQueueTests-\(UUID().uuidString)")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("EditQueueScratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Helpers

    /// `width`×`height` image: `first` color on the top half, `second` on the bottom half (as displayed).
    private func twoBandImage(width: Int, height: Int, top: CGColor, bottom: CGColor) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // CG origin is bottom-left: the upper rect is the visual top.
        ctx.setFillColor(bottom)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(top)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return try XCTUnwrap(ctx.makeImage())
    }

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    /// RGB of the pixel at (x, y) with a top-left origin.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func props(at url: URL) throws -> (width: Int, height: Int, orientation: Int?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try XCTUnwrap(p[kCGImagePropertyPixelWidth] as? Int), try XCTUnwrap(p[kCGImagePropertyPixelHeight] as? Int),
                p[kCGImagePropertyOrientation] as? Int)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    /// Writes `image` as a JPEG file, optionally tagged with an EXIF orientation.
    private func writeJPEG(_ image: CGImage, orientation: Int?, name: String = UUID().uuidString) throws -> URL {
        let url = scratch.appendingPathComponent("\(name).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { options[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Photo-like noise so JPEG vs. raw-pixel embedding makes a real size difference.
    private func noisyImage(width: Int, height: Int, seed: UInt32) throws -> UIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var s = seed
        for i in stride(from: 0, to: bytes.count, by: 4) {
            s = s &* 1_664_525 &+ 1_013_904_223
            let n = UInt8(truncatingIfNeeded: s >> 24) / 4
            bytes[i] = 190 &+ n
            bytes[i + 1] = 180 &+ n
            bytes[i + 2] = 160 &+ n
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return UIImage(cgImage: cg)
    }

    /// One 600×800 page: red top half, blue bottom half, Original filter (colors stay checkable).
    private func makeBandDocument(_ store: DocumentStore) async throws -> (doc: ScanDocument, pageID: UUID) {
        let image = UIImage(cgImage: try twoBandImage(width: 600, height: 800, top: red, bottom: blue))
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(image: image, quad: .full)], filter: .original)
        return (doc, try XCTUnwrap(doc.pages.first?.id))
    }

    // MARK: - (1) Concurrent edits on one page

    func testTwoConcurrentRotationsBothApply() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, pageID) = try await makeBandDocument(store)

        async let first: Void = store.editPage(pageID, in: doc.id) { $0.rotation += 1 }
        async let second: Void = store.editPage(pageID, in: doc.id) { $0.rotation += 1 }
        _ = try await (first, second)

        let page = try XCTUnwrap(store.document(doc.id)?.pages.first)
        XCTAssertEqual(page.rotation, 2, "A second Rotate tap must not be lost or overwrite the first")
        XCTAssertEqual(page.version, 2)
        let processed = try XCTUnwrap(ImageProcessor.loadCGImage(at: store.processedURL(doc.id, pageID)))
        XCTAssertEqual(processed.width, 600)
        XCTAssertEqual(processed.height, 800)
        // 180°: the blue bottom half is now on top. Proves the file on disk matches rotation 2, not 0.
        XCTAssertGreaterThan(pixel(processed, 300, 100).b, 200)
        XCTAssertGreaterThan(pixel(processed, 300, 700).r, 200)
        // Reloading from disk gives the same state.
        XCTAssertEqual(DocumentStore(rootURL: root).document(doc.id)?.pages.first?.rotation, 2)
    }

    func testThreeConcurrentRotationsGiveLandscapeFile() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, pageID) = try await makeBandDocument(store)
        async let a: Void = store.editPage(pageID, in: doc.id) { $0.rotation += 1 }
        async let b: Void = store.editPage(pageID, in: doc.id) { $0.rotation += 1 }
        async let c: Void = store.editPage(pageID, in: doc.id) { $0.rotation += 1 }
        _ = try await (a, b, c)
        let page = try XCTUnwrap(store.document(doc.id)?.pages.first)
        XCTAssertEqual(page.rotation, 3)
        XCTAssertEqual(page.version, 3)
        let processed = try props(at: store.processedURL(doc.id, pageID))
        XCTAssertEqual(processed.width, 800)
        XCTAssertEqual(processed.height, 600)
    }

    // MARK: - (2) Filter right after rotate

    func testFilterEditRightAfterRotateKeepsBoth() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, pageID) = try await makeBandDocument(store)

        async let rotate: Void = store.editPage(pageID, in: doc.id) { $0.rotation += 1 }
        async let filter: Void = store.editPage(pageID, in: doc.id) { $0.filter = .grayscale }
        _ = try await (rotate, filter)

        let page = try XCTUnwrap(store.document(doc.id)?.pages.first)
        XCTAssertEqual(page.rotation, 1, "Filter change must not undo the rotation")
        XCTAssertEqual(page.filter, .grayscale, "Rotation must not undo the filter change")
        XCTAssertEqual(page.version, 2)
        let processed = try XCTUnwrap(ImageProcessor.loadCGImage(at: store.processedURL(doc.id, pageID)))
        XCTAssertEqual(processed.width, 800)
        XCTAssertEqual(processed.height, 600)
        let p = pixel(processed, 50, 300)
        XCTAssertLessThan(abs(p.r - p.b), 20, "Processed file should be grayscale, got \(p)")
    }

    func testIdenticalEditDoesNotBumpVersion() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, pageID) = try await makeBandDocument(store)
        try await store.editPage(pageID, in: doc.id) { $0.filter = .original } // already Original
        XCTAssertEqual(store.document(doc.id)?.pages.first?.version, 0)
    }

    // MARK: - (3) Quad winding

    func testMirroredQuadIsInvalid() {
        let good = Quad(topLeft: CGPoint(x: 0.1, y: 0.1), topRight: CGPoint(x: 0.9, y: 0.1),
                        bottomRight: CGPoint(x: 0.9, y: 0.9), bottomLeft: CGPoint(x: 0.1, y: 0.9))
        XCTAssertTrue(good.isValid)
        var mirrored = good
        mirrored.topLeft = good.topRight
        mirrored.topRight = good.topLeft
        mirrored.bottomRight = good.bottomLeft
        mirrored.bottomLeft = good.bottomRight
        XCTAssertFalse(mirrored.isValid, "Left/right mirrored quad (counter-clockwise) must be invalid")
        // Only TL and TR swapped: a bow-tie.
        var swappedTop = good
        swappedTop.topLeft = good.topRight
        swappedTop.topRight = good.topLeft
        XCTAssertFalse(swappedTop.isValid)
        // Same corners listed counter-clockwise.
        XCTAssertFalse(Quad(points: good.points.reversed()).isValid)
        // ordered() always produces a usable clockwise quad from shuffled corners.
        XCTAssertTrue(Quad.ordered(mirrored.points).isValid)
    }

    // MARK: - (4) File-based import with EXIF orientation

    func testFileImportWithExifOrientation6IsStoredUprightAndTempFileDeleted() async throws {
        // Sensor-order pixels 800×600: red left half, blue right half. EXIF 6 = rotate 90° CW to display,
        // so the user sees a 600×800 portrait with red on top.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        ctx.setFillColor(blue)
        ctx.fill(CGRect(x: 400, y: 0, width: 400, height: 600))
        let fileURL = try writeJPEG(try XCTUnwrap(ctx.makeImage()), orientation: 6)
        XCTAssertEqual(try props(at: fileURL).orientation, 6)

        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(fileURL: fileURL, quad: .full)], filter: .original)
        let page = try XCTUnwrap(doc.pages.first)

        let original = try props(at: store.originalURL(doc.id, page.id))
        XCTAssertEqual(original.width, 600, "Stored original must be upright (portrait)")
        XCTAssertEqual(original.height, 800)
        XCTAssertTrue(original.orientation == nil || original.orientation == 1, "Stored file must not rely on EXIF")
        let image = try XCTUnwrap(ImageProcessor.loadCGImage(at: store.originalURL(doc.id, page.id)))
        XCTAssertGreaterThan(pixel(image, 300, 100).r, 200, "Top should be red after applying EXIF 6")
        XCTAssertGreaterThan(pixel(image, 300, 700).b, 200, "Bottom should be blue after applying EXIF 6")

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Capture temp file must be deleted after saving")
    }

    func testFileImportCapsLargeFileAt4096() async throws {
        let big = try XCTUnwrap(SampleData.photoOfPaper(lines: ["Big"], size: CGSize(width: 6000, height: 4500)).cgImage)
        let fileURL = try writeJPEG(big, orientation: nil)
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(fileURL: fileURL, quad: .full)], filter: .original)
        let original = try props(at: store.originalURL(doc.id, doc.pages[0].id))
        XCTAssertEqual(original.width, 4096)
        XCTAssertEqual(original.height, 3072)
    }

    func testFailedPageInBatchCleansUpEarlierPagesAndTempFiles() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(
            image: SampleData.photoOfPaper(lines: ["Keep"], size: CGSize(width: 600, height: 800)), quad: .full)], filter: .original)
        let filesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: store.folderURL(doc.id).path))

        let good = try writeJPEG(try twoBandImage(width: 600, height: 800, top: red, bottom: blue), orientation: nil, name: "good")
        let broken = scratch.appendingPathComponent("broken.jpg")
        try Data("not a jpeg".utf8).write(to: broken)

        do {
            try await store.addPages([DocumentStore.NewPage(fileURL: good, quad: .full),
                                      DocumentStore.NewPage(fileURL: broken, quad: .full)], to: doc.id, filter: .original)
            XCTFail("A corrupt image must make addPages throw")
        } catch {
            // expected
        }
        XCTAssertEqual(store.document(doc.id)?.pages.count, 1)
        let filesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: store.folderURL(doc.id).path))
        XCTAssertEqual(filesAfter, filesBefore, "Page files from the failed batch were left behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
    }

    // MARK: - (5) PDF size

    func testThreePagePDFEmbedsJPEGData() async throws {
        let store = DocumentStore(rootURL: root)
        let pages = try (0..<3).map {
            DocumentStore.NewPage(image: try noisyImage(width: 1500, height: 2000, seed: UInt32(7 + $0)), quad: .full)
        }
        let doc = try await store.createDocument(title: "Three pages", pages: pages, filter: .original)
        let jpegSum = try doc.pages.map { try fileSize(store.processedURL(doc.id, $0.id)) }.reduce(0, +)
        let url = try await store.exportPDF(doc.id, pageSize: .a4, searchable: false)
        let pdfSize = try fileSize(url)
        let rawPixels = 3 * 1500 * 2000 * 3
        let ratio = String(format: "%.3f", Double(pdfSize) / Double(jpegSum))
        print("PDF_SIZE_REPORT pages=3 pdf=\(pdfSize) jpegSum=\(jpegSum) ratio=\(ratio) rawRGB=\(rawPixels)")
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
        XCTAssertLessThan(pdfSize, 2 * jpegSum, "PDF \(pdfSize) B vs JPEG sum \(jpegSum) B: images are being re-encoded")
    }
}
