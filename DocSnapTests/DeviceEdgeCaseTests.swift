import Darwin
import ImageIO
import PDFKit
import Vision
import XCTest
@testable import DocSnap

/// Edge cases that matter on a real iPhone 13 Pro: 12 MP camera photos with EXIF orientation,
/// documents/pages deleted while work is in flight, empty exports, Vietnamese file names, OCR.
@MainActor
final class DeviceEdgeCaseTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EdgeTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func samplePage(_ text: String = "Hello", size: CGSize = CGSize(width: 600, height: 800)) -> DocumentStore.NewPage {
        DocumentStore.NewPage(image: SampleData.photoOfPaper(lines: [text], size: size), quad: .full)
    }

    /// Pixel size of an image file, read from its header without decoding.
    private func pixelSize(at url: URL) throws -> (width: Int, height: Int, orientation: Int?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let h = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        return (w, h, props[kCGImagePropertyOrientation] as? Int)
    }

    private func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Same picture the way an iPhone camera stores it: pixels in landscape sensor order,
    /// with orientation `.right` telling viewers to rotate 90° clockwise for display.
    private func cameraStyle(_ upright: UIImage) throws -> UIImage {
        let cg = try XCTUnwrap(upright.cgImage)
        let w = cg.width, h = cg.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Store the upright picture rotated 90° counter-clockwise; `.right` undoes that on display.
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stored = try XCTUnwrap(ctx.makeImage())
        XCTAssertEqual(stored.width, h)
        XCTAssertEqual(stored.height, w)
        return UIImage(cgImage: stored, scale: 1, orientation: .right)
    }

    /// Solid image with mild per-pixel noise, so it compresses like a real photo rather than a flat drawing.
    private func noisyImage(width: Int, height: Int) throws -> UIImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = UInt8(truncatingIfNeeded: seed >> 24) / 4
            bytes[i] = 180 &+ n
            bytes[i + 1] = 170 &+ n
            bytes[i + 2] = 150 &+ n
            bytes[i + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return UIImage(cgImage: cg)
    }

    private func textImage(_ text: String, size: CGSize = CGSize(width: 1800, height: 600), fontSize: CGFloat = 130) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            (text as NSString).draw(at: CGPoint(x: 60, y: (size.height - fontSize * 1.2) / 2), withAttributes: attributes)
        }
    }

    private func normalized(_ s: String) -> String {
        s.uppercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - 12 MP camera photos

    func testTwelveMegapixelPhotoIsStoredFullSizeQuicklyAndWithinMemory() async throws {
        let store = DocumentStore(rootURL: root)
        let photo = SampleData.photoOfPaper(lines: ["INVOICE 2026", "Twelve megapixels"], size: CGSize(width: 4032, height: 3024))
        let before = physFootprintMB()
        let start = Date()
        let doc = try await store.createDocument(title: "Big", pages: [DocumentStore.NewPage(image: photo, quad: nil)], filter: .magicColor)
        let elapsed = Date().timeIntervalSince(start)
        let after = physFootprintMB()

        let page = try XCTUnwrap(doc.pages.first)
        let original = try pixelSize(at: store.originalURL(doc.id, page.id))
        XCTAssertEqual(original.width, 4032, "A 13 Pro photo (4032 px) is under the 4096 cap and must keep full detail")
        XCTAssertEqual(original.height, 3024)
        let processed = try pixelSize(at: store.processedURL(doc.id, page.id))
        XCTAssertLessThanOrEqual(max(processed.width, processed.height), 4096)
        XCTAssertFalse(page.quad.isFull, "Border should be auto-detected on a 12 MP photo too")
        // Generous bounds: they catch an accidental extra full-size decode/copy being kept alive,
        // or a pathological slowdown, without being flaky on a busy simulator.
        XCTAssertLessThan(elapsed, 15, "Saving one 12 MP page took \(elapsed) s")
        XCTAssertLessThan(after - before, 250, "Footprint grew \(after - before) MB after saving one 12 MP page")
    }

    func testOversizedPhotoIsCappedAt4096() async throws {
        let store = DocumentStore(rootURL: root)
        let photo = SampleData.photoOfPaper(lines: ["Huge"], size: CGSize(width: 6000, height: 4000))
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(image: photo, quad: .full)], filter: .original)
        let page = try XCTUnwrap(doc.pages.first)
        let original = try pixelSize(at: store.originalURL(doc.id, page.id))
        XCTAssertEqual(original.width, 4096)
        XCTAssertEqual(original.height, 2731) // 4000 × 4096 / 6000 = 2730.67, rounded
        let processed = try pixelSize(at: store.processedURL(doc.id, page.id))
        XCTAssertEqual(processed.width, 4096)
        XCTAssertEqual(processed.height, 2731)
    }

    func testCameraOrientationRightIsStoredUprightAndBorderDetected() async throws {
        let store = DocumentStore(rootURL: root)
        // Portrait sheet of paper as the user sees it; the camera stores it as 4032×3024 + orientation .right.
        let upright = SampleData.photoOfPaper(lines: ["INVOICE 2026", "DocSnap sample page one", "Total: 120.00"],
                                              size: CGSize(width: 3024, height: 4032))
        let camera = try cameraStyle(upright)
        XCTAssertEqual(camera.size, CGSize(width: 3024, height: 4032), "UIImage reports the display size")

        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(image: camera, quad: nil)], filter: .original)
        let page = try XCTUnwrap(doc.pages.first)
        let original = try pixelSize(at: store.originalURL(doc.id, page.id))
        XCTAssertEqual(original.width, 3024, "Stored original must be upright (portrait)")
        XCTAssertEqual(original.height, 4032)
        XCTAssertTrue(original.orientation == nil || original.orientation == 1, "Stored file must not rely on EXIF orientation")

        // Corners of the synthetic paper in upright coordinates: (0.16,0.12) (0.86,0.15) (0.82,0.88) (0.12,0.85).
        let quad = page.quad
        XCTAssertFalse(quad.isFull, "Expected a detected border on a rotated camera photo")
        XCTAssertEqual(quad.topLeft.x, 0.16, accuracy: 0.02)
        XCTAssertEqual(quad.topLeft.y, 0.12, accuracy: 0.02)
        XCTAssertEqual(quad.topRight.x, 0.86, accuracy: 0.02)
        XCTAssertEqual(quad.topRight.y, 0.15, accuracy: 0.02)
        XCTAssertEqual(quad.bottomRight.x, 0.82, accuracy: 0.02)
        XCTAssertEqual(quad.bottomRight.y, 0.88, accuracy: 0.02)
        XCTAssertEqual(quad.bottomLeft.x, 0.12, accuracy: 0.02)
        XCTAssertEqual(quad.bottomLeft.y, 0.85, accuracy: 0.02)

        // The flattened page is portrait as well.
        let processed = try pixelSize(at: store.processedURL(doc.id, page.id))
        XCTAssertGreaterThan(processed.height, processed.width)
    }

    // MARK: - Deleted while in flight

    func testAddPagesToDeletedDocumentIsANoOp() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [samplePage()], filter: .original)
        store.deleteDocument(doc.id)
        try await store.addPages([samplePage("late")], to: doc.id, filter: .original)
        XCTAssertNil(store.document(doc.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL(doc.id).path),
                       "Adding pages to a deleted document must not resurrect its folder")
        XCTAssertTrue(DocumentStore(rootURL: root).documents.isEmpty)
    }

    func testUpdatePageAfterPageWasDeletedIsANoOp() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [samplePage("A"), samplePage("B")], filter: .original)
        var gone = doc.pages[0]
        try store.deletePage(gone.id, from: doc.id)
        gone.rotation = 1
        try await store.updatePage(gone, in: doc.id)
        XCTAssertEqual(store.document(doc.id)?.pages.map(\.id), [doc.pages[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.processedURL(doc.id, gone.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.originalURL(doc.id, gone.id).path))
    }

    /// The page viewer's edit bar stays enabled while an edit renders, so a user can tap Rotate and then
    /// Delete → Delete Page on a big 12 MP page before the rotation has finished (the reorder sheet too).
    func testPageDeletedWhileEditIsRenderingLeavesNoFilesBehind() async throws {
        let store = DocumentStore(rootURL: root)
        let pages = (0..<6).map { samplePage("Page \($0)", size: CGSize(width: 2400, height: 3200)) }
        let doc = try await store.createDocument(pages: pages, filter: .original)
        var errors: [String] = []
        for var page in doc.pages {
            page.rotation = 1
            let edit = Task { try await store.updatePage(page, in: doc.id) }
            // Let the queued edit reach its background render before deleting (a few hops: queue task → applyEdit → detached).
            for _ in 0..<5 { await Task.yield() }
            try store.deletePage(page.id, from: doc.id)
            do { try await edit.value } catch { errors.append("\(error)") }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.folderURL(doc.id).path)
            .filter { $0.hasSuffix(".jpg") }
        // Regression: the background render used to re-create "<page>-processed.jpg" after deletePage
        // removed it, orphaning the file.
        XCTAssertEqual(leftovers, [], "Orphaned page files left on disk after delete-during-edit")
        // Regression: a delete that landed before the render loaded the original surfaced
        // "A page file is missing." for a page the user had just deleted.
        XCTAssertEqual(errors, [], "updatePage threw for a page deleted mid-edit")
    }

    // MARK: - Export

    func testEmptyDocumentExportThrowsNoPages() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(title: "Empty", pages: [samplePage()], filter: .original)
        try store.deletePage(doc.pages[0].id, from: doc.id)
        XCTAssertEqual(store.document(doc.id)?.pages.count, 0)

        do {
            _ = try await store.exportPDF(doc.id, pageSize: .auto, searchable: true)
            XCTFail("Exporting an empty document must throw")
        } catch PDFExporter.ExportError.noPages {
            // expected
        } catch {
            XCTFail("Expected noPages, got \(error)")
        }
        XCTAssertEqual(try store.exportImages(doc.id), [])
    }

    func testExportImagesSinglePageUsesPlainTitle() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(title: "Receipt: Oct", pages: [samplePage()], filter: .original)
        let urls = try store.exportImages(doc.id)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Receipt- Oct.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    }

    func testVietnameseTitleInPDFFileNameAndMetadata() async throws {
        let store = DocumentStore(rootURL: root)
        let title = "Hóa đơn tiền điện tháng 10/2026"
        let doc = try await store.createDocument(title: title, pages: [samplePage()], filter: .original)
        let url = try await store.exportPDF(doc.id, pageSize: .a4, searchable: false)
        XCTAssertEqual(url.lastPathComponent.precomposedStringWithCanonicalMapping,
                       "Hóa đơn tiền điện tháng 10-2026.pdf".precomposedStringWithCanonicalMapping)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title)

        let images = try store.exportImages(doc.id)
        XCTAssertEqual(images.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping },
                       ["Hóa đơn tiền điện tháng 10-2026.jpg".precomposedStringWithCanonicalMapping])
    }

    func testLongVietnameseTitleStillExports() async throws {
        let store = DocumentStore(rootURL: root)
        let title = String(repeating: "Biên bản nghiệm thu dự án ", count: 6) // 156 characters
        let doc = try await store.createDocument(title: title, pages: [samplePage(), samplePage()], filter: .original)
        let url = try await store.exportPDF(doc.id, pageSize: .auto, searchable: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.exportImages(doc.id).count, 2)
    }

    func testLongCJKTitleStillExports() async throws {
        // CJK characters take 3 bytes each in UTF-8, so the 100-character name is ~300 bytes.
        // APFS limits names to 255 *characters*, so this must still export.
        let store = DocumentStore(rootURL: root)
        let title = String(repeating: "季度财务报告", count: 20) // 120 characters
        let doc = try await store.createDocument(title: title, pages: [samplePage(), samplePage()], filter: .original)
        XCTAssertEqual(DocumentStore.safeFileName(title).count, 100)
        do {
            let url = try await store.exportPDF(doc.id, pageSize: .auto, searchable: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        } catch {
            XCTFail("PDF export failed: \(error)")
        }
        do {
            XCTAssertEqual(try store.exportImages(doc.id).count, 2)
        } catch {
            XCTFail("Image export failed: \(error)")
        }
    }

    func testAutoPageSizeForLandscapeImage() async throws {
        let bounds = PDFExporter.pageBounds(for: CGSize(width: 4032, height: 3024), pageSize: .auto)
        XCTAssertEqual(bounds.height, 595, accuracy: 1, "Short side matches A4's short side")
        XCTAssertEqual(bounds.width, 794, accuracy: 1) // 595.28 × 4032 / 3024
        let a4 = PDFExporter.pageBounds(for: CGSize(width: 4032, height: 3024), pageSize: .a4)
        XCTAssertEqual(a4.width, 841.89, accuracy: 0.5)
        XCTAssertEqual(a4.height, 595.28, accuracy: 0.5)

        // End to end: a landscape page exported with Auto gets a landscape PDF page.
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [samplePage("Wide", size: CGSize(width: 1600, height: 1200))], filter: .original)
        let url = try await store.exportPDF(doc.id, pageSize: .auto, searchable: false)
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 794, accuracy: 1)
        XCTAssertEqual(box.height, 595, accuracy: 1)
    }

    func testPDFEmbedsJPEGInsteadOfRawPixels() async throws {
        // Big PDFs are slow to AirDrop and bounce off mail size limits.
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(image: try noisyImage(width: 2000, height: 1500), quad: .full)],
                                                 filter: .original)
        let jpegBytes = try XCTUnwrap(try FileManager.default.attributesOfItem(
            atPath: store.processedURL(doc.id, doc.pages[0].id).path)[.size] as? Int)
        let url = try await store.exportPDF(doc.id, pageSize: .auto, searchable: false)
        let pdfBytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(pdfBytes, jpegBytes * 2 + 100_000, "PDF \(pdfBytes) B vs page JPEG \(jpegBytes) B")
    }

    // MARK: - OCR

    func testTextRecognizerReadsClearText() throws {
        let cg = try XCTUnwrap(textImage("HELLO DOCSNAP 2026").cgImage)
        let lines = try TextRecognizer.recognizeSync(in: cg)
        let text = normalized(lines.map(\.text).joined(separator: " "))
        XCTAssertTrue(text.contains("HELLO DOCSNAP 2026"), "Recognized: \(text)")
        for line in lines {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.01, dy: -0.01).contains(line.box),
                          "Box not normalized: \(line.box)")
        }
        // Text sits in the vertical middle of the image; the top-left-origin box must agree.
        let box = try XCTUnwrap(lines.first?.box)
        XCTAssertEqual(box.midY, 0.5, accuracy: 0.15)
        XCTAssertLessThan(box.minX, 0.2)
    }

    func testRecognizedTextFlowsIntoSearchablePDF() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [DocumentStore.NewPage(image: textImage("HELLO DOCSNAP 2026"), quad: .full)],
                                                 filter: .blackWhite)
        let url = try await store.exportPDF(doc.id, pageSize: .auto, searchable: true)
        let stored = normalized(store.document(doc.id)?.allText ?? "")
        XCTAssertTrue(stored.contains("HELLO DOCSNAP 2026"), "Stored OCR: \(stored)")
        let pdfText = normalized(PDFDocument(url: url)?.string ?? "")
        XCTAssertTrue(pdfText.contains("HELLO DOCSNAP 2026"), "PDF text: \(pdfText)")
    }

    func testVietnameseIsAmongTheRecognitionLanguagesActuallyUsed() throws {
        let supported = try VNRecognizeTextRequest().supportedRecognitionLanguages()
        let used = TextRecognizer.preferredLanguages.filter(supported.contains)
        XCTAssertTrue(used.contains { $0.hasPrefix("vi") },
                      "No Vietnamese code from \(TextRecognizer.preferredLanguages) is supported; Vision offers \(supported)")
    }

    // MARK: - Decoding

    func testScanFilterDecodingOfUnknownValues() throws {
        let json = #"["original","sepia","blackWhite","","MAGICCOLOR","lighten"]"#
        let filters = try JSONDecoder().decode([ScanFilter].self, from: Data(json.utf8))
        XCTAssertEqual(filters, [.original, .magicColor, .blackWhite, .magicColor, .magicColor, .lighten])
        // Encoding stays the raw value so older builds can read it.
        XCTAssertEqual(String(data: try JSONEncoder().encode(ScanFilter.blackWhite), encoding: .utf8), #""blackWhite""#)
    }

    func testDocumentWithUnknownFilterStillLoadsFromDisk() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(title: "Future", pages: [samplePage()], filter: .grayscale)
        let jsonURL = store.folderURL(doc.id).appendingPathComponent("document.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8).replacingOccurrences(of: "\"grayscale\"", with: "\"sepiaFromV2\"")
        try json.write(to: jsonURL, atomically: true, encoding: .utf8)
        let reloaded = DocumentStore(rootURL: root)
        XCTAssertEqual(reloaded.documents.count, 1)
        XCTAssertEqual(reloaded.documents.first?.pages.first?.filter, .magicColor)
    }
}
