import PDFKit
import XCTest
@testable import DocSnap

@MainActor
final class StoreAndExportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func samplePage(_ text: String = "Hello") -> DocumentStore.NewPage {
        DocumentStore.NewPage(image: SampleData.photoOfPaper(lines: [text], size: CGSize(width: 600, height: 800)), quad: .full)
    }

    func testCreatePersistAndReload() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(title: "Receipt", pages: [samplePage(), samplePage()], filter: .grayscale)
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(doc.pages.count, 2)
        for page in doc.pages {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.originalURL(doc.id, page.id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.processedURL(doc.id, page.id).path))
        }
        let reloaded = DocumentStore(rootURL: root)
        XCTAssertEqual(reloaded.documents.first?.title, "Receipt")
        XCTAssertEqual(reloaded.documents.first?.pages.map(\.filter), [.grayscale, .grayscale])
    }

    func testAutoDetectsBorderOnImport() async throws {
        let store = DocumentStore(rootURL: root)
        // Different text changes what the ML segmenter sees; every sample must still find the page.
        let samples = [["Detect me"], ["INVOICE 2026", "DocSnap sample page one", "Total: 120.00"],
                       ["MEETING NOTES", "Second sample page", "Scan, crop, share"]]
        let pages = samples.map { DocumentStore.NewPage(image: SampleData.photoOfPaper(lines: $0), quad: nil) }
        let doc = try await store.createDocument(pages: pages, filter: .original)
        for page in doc.pages {
            let quad = page.quad
            // The synthetic paper's corners: (0.16,0.12) (0.86,0.15) (0.82,0.88) (0.12,0.85).
            XCTAssertFalse(quad.isFull, "Expected a detected border, got the full image")
            XCTAssertEqual(quad.topLeft.x, 0.16, accuracy: 0.02)
            XCTAssertEqual(quad.topLeft.y, 0.12, accuracy: 0.02)
            XCTAssertEqual(quad.topRight.x, 0.86, accuracy: 0.02)
            XCTAssertEqual(quad.bottomRight.x, 0.82, accuracy: 0.02)
            XCTAssertEqual(quad.bottomRight.y, 0.88, accuracy: 0.02)
            XCTAssertEqual(quad.bottomLeft.y, 0.85, accuracy: 0.02)
        }
    }

    func testEditsBumpVersionAndClearText() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [samplePage()], filter: .original)
        var page = try XCTUnwrap(doc.pages.first)
        store.setTextLines([TextLine(text: "x", box: .zero)], pageID: page.id, version: page.version, in: doc.id)
        XCTAssertNotNil(store.document(doc.id)?.pages.first?.textLines)

        page.rotation = 1
        try await store.updatePage(page, in: doc.id)
        let updated = try XCTUnwrap(store.document(doc.id)?.pages.first)
        XCTAssertEqual(updated.version, 1)
        XCTAssertNil(updated.textLines)
        let image = try XCTUnwrap(ImageProcessor.loadCGImage(at: store.processedURL(doc.id, page.id)))
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 600)
    }

    func testStaleOCRResultIsIgnored() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [samplePage()], filter: .original)
        var page = try XCTUnwrap(doc.pages.first)
        page.filter = .grayscale
        try await store.updatePage(page, in: doc.id)
        // OCR that started on version 0 finishes after the edit: must be dropped.
        store.setTextLines([TextLine(text: "stale", box: .zero)], pageID: page.id, version: 0, in: doc.id)
        XCTAssertNil(store.document(doc.id)?.pages.first?.textLines)
    }

    func testDeleteMoveRename() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(pages: [samplePage("A"), samplePage("B"), samplePage("C")], filter: .original)
        let ids = doc.pages.map(\.id)
        try store.movePages(in: doc.id, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.document(doc.id)?.pages.map(\.id), [ids[2], ids[0], ids[1]])

        try store.deletePage(ids[0], from: doc.id)
        XCTAssertEqual(store.document(doc.id)?.pages.map(\.id), [ids[2], ids[1]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.originalURL(doc.id, ids[0]).path))

        try store.rename(doc.id, to: "  New name  ")
        XCTAssertEqual(store.document(doc.id)?.title, "New name")
        try store.rename(doc.id, to: "   ")
        XCTAssertEqual(store.document(doc.id)?.title, "New name")

        store.deleteDocument(doc.id)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL(doc.id).path))
    }

    func testPDFExportPageCountAndSearchableText() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(title: "Invoice/2026", pages: [samplePage(), samplePage()], filter: .original)
        for page in doc.pages {
            store.setTextLines([TextLine(text: "DOCSNAP SEARCHABLE", box: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.05))],
                               pageID: page.id, version: page.version, in: doc.id)
        }
        let url = try await store.exportPDF(doc.id, pageSize: .a4, searchable: true)
        XCTAssertEqual(url.lastPathComponent, "Invoice-2026.pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.string?.contains("DOCSNAP SEARCHABLE") ?? false, "PDF text: \(pdf.string ?? "nil")")
        let bounds = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(bounds.width, 595.28, accuracy: 1)
        XCTAssertEqual(bounds.height, 841.89, accuracy: 1)
    }

    func testImageExport() async throws {
        let store = DocumentStore(rootURL: root)
        let doc = try await store.createDocument(title: "Pics", pages: [samplePage(), samplePage()], filter: .original)
        let urls = try store.exportImages(doc.id)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Pics 1.jpg", "Pics 2.jpg"])
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testPageBoundsAuto() {
        let portrait = PDFExporter.pageBounds(for: CGSize(width: 1000, height: 2000), pageSize: .auto)
        XCTAssertEqual(portrait.width, 595, accuracy: 1)
        XCTAssertEqual(portrait.height, 1191, accuracy: 1)
        let landscapeA4 = PDFExporter.pageBounds(for: CGSize(width: 2000, height: 1000), pageSize: .a4)
        XCTAssertGreaterThan(landscapeA4.width, landscapeA4.height)
    }

    func testSafeFileName() {
        XCTAssertEqual(DocumentStore.safeFileName("a/b:c"), "a-b-c")
        XCTAssertEqual(DocumentStore.safeFileName("   "), "DocSnap")
        XCTAssertEqual(DocumentStore.safeFileName("Hóa đơn"), "Hóa đơn")
    }
}
