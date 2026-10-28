import SwiftUI
import UIKit
import XCTest
@testable import DocSnap

/// Saved answers (`PageAnswer` + `DocumentStore.setAnswer`), the live camera's corner hint, and the new settings enums.
@MainActor
final class AnswerStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AnswerStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Whole seconds: documents are saved with ISO-8601 dates, which drop fractions.
    private let answerDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func answer(_ text: String = "### 1.\n**x = 2**", version: Int = 0) -> PageAnswer {
        PageAnswer(text: text, model: AnswerModel.opus.rawValue, createdAt: answerDate, pageVersion: version)
    }

    private func makeDocument(_ store: DocumentStore) async throws -> (ScanDocument, ScanPage) {
        let image = SampleData.photoOfPaper(lines: ["1. Solve x² = 4"], size: CGSize(width: 600, height: 800))
        let doc = try await store.createDocument(title: "Homework", pages: [DocumentStore.NewPage(image: image, quad: .full)],
                                                 filter: .original)
        return (doc, try XCTUnwrap(doc.pages.first))
    }

    private func storedPage(_ store: DocumentStore, _ doc: ScanDocument) -> ScanPage? {
        store.document(doc.id)?.pages.first
    }

    // MARK: - setAnswer

    func testSetAnswerStoresAndPersists() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        let before = try XCTUnwrap(store.document(doc.id)?.updatedAt)
        store.setAnswer(answer(), pageID: page.id, in: doc.id)
        XCTAssertEqual(storedPage(store, doc)?.answer, answer())
        XCTAssertEqual(store.document(doc.id)?.updatedAt, before, "Saving an answer is not an edit of the document")

        let reloaded = DocumentStore(rootURL: root)
        XCTAssertEqual(reloaded.document(doc.id)?.pages.first?.answer, answer(), "Answer must survive a relaunch")
    }

    func testSetAnswerReplacesAnEarlierAnswer() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        store.setAnswer(answer("old"), pageID: page.id, in: doc.id)
        store.setAnswer(answer("new"), pageID: page.id, in: doc.id)
        XCTAssertEqual(storedPage(store, doc)?.answer?.text, "new")
    }

    func testStaleAnswerIsIgnored() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        var edited = page
        edited.filter = .grayscale
        try await store.updatePage(edited, in: doc.id)
        XCTAssertEqual(storedPage(store, doc)?.version, 1)
        // The answer was requested for version 0 and arrives after the edit: must be dropped.
        store.setAnswer(answer(version: 0), pageID: page.id, in: doc.id)
        XCTAssertNil(storedPage(store, doc)?.answer)
        store.setAnswer(answer(version: 1), pageID: page.id, in: doc.id)
        XCTAssertNotNil(storedPage(store, doc)?.answer)
    }

    func testSetAnswerForMissingPageOrDocumentDoesNothing() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, _) = try await makeDocument(store)
        store.setAnswer(answer(), pageID: UUID(), in: doc.id)
        store.setAnswer(answer(), pageID: UUID(), in: UUID())
        XCTAssertNil(storedPage(store, doc)?.answer)
        XCTAssertEqual(store.documents.count, 1)
    }

    func testAnswerDoesNotLeakToOtherPages() async throws {
        let store = DocumentStore(rootURL: root)
        let image = SampleData.photoOfPaper(lines: ["p"], size: CGSize(width: 300, height: 400))
        let doc = try await store.createDocument(pages: [.init(image: image, quad: .full), .init(image: image, quad: .full)],
                                                 filter: .original)
        store.setAnswer(answer(), pageID: doc.pages[1].id, in: doc.id)
        let pages = try XCTUnwrap(store.document(doc.id)?.pages)
        XCTAssertNil(pages[0].answer)
        XCTAssertNotNil(pages[1].answer)
    }

    // MARK: - Edits clear the answer

    func testEveryImageChangeClearsTheAnswer() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        let changes: [(String, (inout ScanPage) -> Void)] = [
            ("rotate", { $0.rotation += 1 }),
            ("filter", { $0.filter = .blackWhite }),
            ("crop", { $0.quad.topLeft = CGPoint(x: 0.1, y: 0.1) }),
        ]
        for (name, change) in changes {
            let version = try XCTUnwrap(storedPage(store, doc)?.version)
            store.setAnswer(answer(version: version), pageID: page.id, in: doc.id)
            XCTAssertNotNil(storedPage(store, doc)?.answer)
            try await store.editPage(page.id, in: doc.id, change)
            XCTAssertNil(storedPage(store, doc)?.answer, "\(name) changes the image, so the answer must go")
            XCTAssertEqual(storedPage(store, doc)?.version, version + 1)
        }
        let reloaded = DocumentStore(rootURL: root)
        XCTAssertNil(reloaded.document(doc.id)?.pages.first?.answer)
    }

    func testNoOpEditKeepsTheAnswer() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        store.setAnswer(answer(), pageID: page.id, in: doc.id)
        try await store.editPage(page.id, in: doc.id) { $0.rotation += 4 } // a full turn is no change
        XCTAssertEqual(storedPage(store, doc)?.answer, answer())
        XCTAssertEqual(storedPage(store, doc)?.version, 0)
    }

    func testOCRResultKeepsTheAnswer() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        store.setAnswer(answer(), pageID: page.id, in: doc.id)
        store.setTextLines([TextLine(text: "1. Solve", box: .zero)], pageID: page.id, version: 0, in: doc.id)
        XCTAssertEqual(storedPage(store, doc)?.answer, answer())
        XCTAssertNotNil(storedPage(store, doc)?.textLines)
    }

    func testAnswerArrivingWhileAnEditRendersIsClearedByTheEdit() async throws {
        let store = DocumentStore(rootURL: root)
        let (doc, page) = try await makeDocument(store)
        let edit = Task { try await store.editPage(page.id, in: doc.id) { $0.filter = .grayscale } }
        for _ in 0..<5 { await Task.yield() } // let the edit start rendering off the main actor
        // The edit is still rendering, so the store is at version 0 and accepts the answer...
        store.setAnswer(answer(version: 0), pageID: page.id, in: doc.id)
        try await edit.value
        // ...but the finished edit must not keep an answer that describes the old image.
        let final = try XCTUnwrap(storedPage(store, doc))
        XCTAssertEqual(final.version, 1)
        XCTAssertNil(final.answer)
    }

    // MARK: - PageAnswer coding

    func testPageAnswerRoundTripsInsideAPage() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let page = ScanPage(version: 3, answer: answer(version: 3))
        let decoded = try decoder.decode(ScanPage.self, from: encoder.encode(page))
        XCTAssertEqual(decoded, page)
    }

    func testPagesSavedBeforeAnswersStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","filter":"grayscale","rotation":1,"version":2}"#
        let page = try JSONDecoder().decode(ScanPage.self, from: Data(json.utf8))
        XCTAssertNil(page.answer)
        XCTAssertEqual(page.version, 2)
    }

    func testCorruptAnswerIsDroppedButThePageOpens() throws {
        for answerJSON in [#""oops""#, #"{"text":"no model"}"#, "42", "null"] {
            let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","version":1,"answer":"# + answerJSON + "}"
            let page = try JSONDecoder().decode(ScanPage.self, from: Data(json.utf8))
            XCTAssertNil(page.answer, "Bad answer \(answerJSON) should decode as nil")
            XCTAssertEqual(page.version, 1)
        }
    }

    // MARK: - NewPage.quadHint (corners the live camera saw)

    private let hint = Quad(
        topLeft: CGPoint(x: 0.3, y: 0.2), topRight: CGPoint(x: 0.7, y: 0.22),
        bottomRight: CGPoint(x: 0.72, y: 0.8), bottomLeft: CGPoint(x: 0.28, y: 0.78)
    )

    /// A JPEG file the way the camera leaves one in the capture folder.
    private func captureFile(_ image: UIImage) throws -> URL {
        let folder = DocumentStore.captureDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    private func solidPhoto(_ color: UIColor, size: CGSize = CGSize(width: 600, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Seeded speckle noise: no edges or page-like region.
    private func noisePhoto(size: CGSize = CGSize(width: 600, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var seed: UInt64 = 42
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            for y in stride(from: 0, to: Int(size.height), by: 4) {
                for x in stride(from: 0, to: Int(size.width), by: 4) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    UIColor(white: CGFloat(seed >> 56) / 255, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }

    /// A page photographed so close that it fills the frame (the detector drops full-frame results).
    private func fullFramePaper(size: CGSize = CGSize(width: 600, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black]
            for (i, line) in ["1. Solve x² = 4", "2. Simplify (a + b)²", "3. Define a vector space"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 60 + CGFloat(i) * 60), withAttributes: attributes)
            }
        }
    }

    /// Dark frame with a light rectangle 1% in from every edge: only a nearly-full-frame quad to find.
    private func edgeToEdgeFrame(size: CGSize = CGSize(width: 600, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.01, dy: size.height * 0.01))
        }
    }

    /// A frame the detector finds no page in (needed to reach the hint), or skips if Vision finds one in all of them.
    private func blankPhoto() throws -> UIImage {
        let candidates = [fullFramePaper(), edgeToEdgeFrame(), solidPhoto(UIColor(white: 0.5, alpha: 1)), solidPhoto(.black),
                          solidPhoto(.white), solidPhoto(UIColor(red: 0.36, green: 0.25, blue: 0.17, alpha: 1)), noisePhoto()]
        for image in candidates {
            // Check what the store will see: the image after a JPEG round trip.
            let decoded = try XCTUnwrap(image.jpegData(compressionQuality: 0.9).flatMap(UIImage.init(data:))?.cgImage)
            if DocumentDetector.detectSync(in: decoded) == nil { return image }
        }
        throw XCTSkip("Vision found a page in every featureless frame, so the hint path can't be reached")
    }

    private func assertQuad(_ quad: Quad, equals expected: Quad, accuracy: CGFloat = 1e-6,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(StabilityTracker.maxCornerDistance(quad, expected), accuracy,
                          "Got \(quad), expected \(expected)", file: file, line: line)
    }

    func testPlainGrayFrameHasNoPage() throws {
        // Regression: the segmentation model reported a steady strip across the bottom ~25% of a blank
        // frame, which the DocSnap camera would auto-capture.
        let gray = try XCTUnwrap(solidPhoto(UIColor(white: 0.5, alpha: 1)).cgImage)
        XCTAssertNil(DocumentDetector.detectSync(in: gray))
    }

    func testHintIsUsedWhenDetectionFindsNothing() async throws {
        let store = DocumentStore(rootURL: root)
        let file = try captureFile(blankPhoto())
        let doc = try await store.createDocument(pages: [.init(fileURL: file, quad: nil, quadHint: hint)], filter: .original)
        assertQuad(try XCTUnwrap(doc.pages.first).quad, equals: hint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "The capture file is removed after saving")
    }

    func testInvalidHintFallsBackToFullPage() async throws {
        let mirrored = Quad(topLeft: hint.topRight, topRight: hint.topLeft, bottomRight: hint.bottomLeft, bottomLeft: hint.bottomRight)
        let sliver = Quad(topLeft: CGPoint(x: 0.5, y: 0.1), topRight: CGPoint(x: 0.52, y: 0.1),
                          bottomRight: CGPoint(x: 0.52, y: 0.2), bottomLeft: CGPoint(x: 0.5, y: 0.2))
        XCTAssertFalse(mirrored.isValid)
        XCTAssertFalse(sliver.isValid)
        let store = DocumentStore(rootURL: root)
        let pages = try [mirrored, sliver].map { DocumentStore.NewPage(fileURL: try captureFile(try blankPhoto()), quad: nil, quadHint: $0) }
        let doc = try await store.createDocument(pages: pages, filter: .original)
        for page in doc.pages { XCTAssertTrue(page.quad.isFull, "An unusable hint must not be used as the crop") }
    }

    func testDetectionWinsOverTheHint() async throws {
        let store = DocumentStore(rootURL: root)
        let file = try captureFile(SampleData.photoOfPaper(lines: ["INVOICE 2026", "Total: 120.00"]))
        let doc = try await store.createDocument(pages: [.init(fileURL: file, quad: nil, quadHint: hint)], filter: .original)
        let quad = try XCTUnwrap(doc.pages.first).quad
        // The synthetic paper's top-left corner is at (0.16, 0.12); the hint's is at (0.3, 0.2).
        XCTAssertEqual(quad.topLeft.x, 0.16, accuracy: 0.02)
        XCTAssertEqual(quad.topLeft.y, 0.12, accuracy: 0.02)
    }

    func testExplicitQuadWinsOverTheHint() async throws {
        let store = DocumentStore(rootURL: root)
        let file = try captureFile(solidPhoto(.gray))
        let doc = try await store.createDocument(pages: [.init(fileURL: file, quad: .full, quadHint: hint)], filter: .original)
        XCTAssertTrue(try XCTUnwrap(doc.pages.first).quad.isFull)
    }

    func testNoHintAndNoDetectionKeepsTheFullPhoto() async throws {
        let store = DocumentStore(rootURL: root)
        let file = try captureFile(blankPhoto())
        let doc = try await store.createDocument(pages: [.init(fileURL: file, quad: nil)], filter: .original)
        XCTAssertTrue(try XCTUnwrap(doc.pages.first).quad.isFull)
    }
}

final class SettingsEnumTests: XCTestCase {
    func testAppearanceModes() {
        XCTAssertEqual(AppearanceMode.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppearanceMode.allCases.map(\.title), ["System", "Light", "Dark"])
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.system.interfaceStyle, .unspecified)
        XCTAssertEqual(AppearanceMode.light.interfaceStyle, .light)
        XCTAssertEqual(AppearanceMode.dark.interfaceStyle, .dark)
    }

    func testStoredRawValuesAreStable() {
        // @AppStorage saves the raw value; renaming a case would silently reset the user's choice.
        XCTAssertEqual(AppearanceMode.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(ScannerKind.allCases.map(\.rawValue), ["docsnap", "apple"])
        XCTAssertEqual(AutoCaptureDelay.allCases.map(\.rawValue), ["manual", "one", "oneAndHalf", "two"])
        XCTAssertEqual(AnswerModel.allCases.map(\.rawValue), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertNil(AppearanceMode(rawValue: "Dark"))
        XCTAssertNil(AnswerModel(rawValue: "claude-unknown"))
    }

    func testScannerKinds() {
        XCTAssertEqual(ScannerKind.allCases.map(\.title), ["DocSnap Camera", "Apple Scanner"])
        XCTAssertEqual(ScannerKind.docsnap.id, "docsnap")
    }

    func testAutoCaptureDelays() {
        XCTAssertEqual(AutoCaptureDelay.allCases.map(\.seconds), [0, 1, 1.5, 2])
        XCTAssertEqual(Set(AutoCaptureDelay.allCases.map(\.title)).count, AutoCaptureDelay.allCases.count)
        for delay in AutoCaptureDelay.allCases {
            XCTAssertEqual(StabilityTracker(holdDuration: delay.seconds).isAutoCaptureEnabled, delay != .manual, "\(delay)")
        }
    }

    func testAnswerModelLabels() {
        XCTAssertEqual(AnswerModel.allCases.map(\.displayName), ["Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5"])
        XCTAssertEqual(Set(AnswerModel.allCases.map(\.detail)).count, 3)
    }

    func testSettingsKeysAreUnique() {
        let keys = [Settings.defaultFilterKey, Settings.pdfPageSizeKey, Settings.searchablePDFKey, Settings.libraryLayoutKey,
                    Settings.appearanceKey, Settings.answerModelKey, Settings.scannerKey, Settings.autoCaptureDelayKey,
                    Settings.librarySortKey]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    #if targetEnvironment(simulator)
    @MainActor
    func testSimulatorHasNoCameraSoScanShowsUnavailable() {
        XCTAssertFalse(CameraController.isCameraAvailable)
    }
    #endif
}
