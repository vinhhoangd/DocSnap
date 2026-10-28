import ImageIO
import UIKit
import XCTest
@testable import DocSnap

/// The app side of the Answer feature: request building, NDJSON decoding, error text, upload images,
/// and reading the server address/token from Info.plist. No network access.
final class AnswerServiceTests: XCTestCase {
    private let config = AnswerConfig(baseURL: URL(string: "https://docsnap-test.example.com")!, token: "test-token-123")

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - makeRequest

    func testMakeRequestTargetsAnswerEndpointWithHeaders() throws {
        let request = try AnswerService.makeRequest(config: config, imageJPEG: Data([1, 2, 3]), ocrText: nil, model: .opus)
        XCTAssertEqual(request.url?.absoluteString, "https://docsnap-test.example.com/api/answer")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-docsnap-token"), "test-token-123")
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 120, "Claude can think for a while; the default 60 s is too short")
    }

    func testBaseURLWithTrailingSlashOrPath() {
        let slash = AnswerConfig(baseURL: URL(string: "https://x.example.com/")!, token: "t")
        XCTAssertEqual(slash.answerURL.absoluteString, "https://x.example.com/api/answer")
        let local = AnswerConfig(baseURL: URL(string: "http://localhost:3000")!, token: "t")
        XCTAssertEqual(local.answerURL.absoluteString, "http://localhost:3000/api/answer")
    }

    func testMakeRequestBodyMatchesServerContract() throws {
        let jpeg = Data((0..<3000).map { UInt8($0 % 256) })
        let request = try AnswerService.makeRequest(config: config, imageJPEG: jpeg, ocrText: "1. Solve x² = 4", model: .sonnet)
        let body = try jsonBody(request)
        let image = try XCTUnwrap(body["image"] as? String)
        XCTAssertEqual(Data(base64Encoded: image), jpeg)
        // The server only accepts plain base64 (no data: prefix, no line breaks).
        XCTAssertNotNil(image.wholeMatch(of: /[A-Za-z0-9+\/]+={0,2}/), "Image must be plain base64")
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["text"] as? String, "1. Solve x² = 4")
        XCTAssertEqual(Set(body.keys), ["image", "model", "text"])
    }

    func testMakeRequestOmitsMissingOrEmptyOCRText() throws {
        for ocr in [nil, ""] as [String?] {
            let body = try jsonBody(AnswerService.makeRequest(config: config, imageJPEG: Data([9]), ocrText: ocr, model: .haiku))
            XCTAssertNil(body["text"], "Empty OCR text should not be sent")
            XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        }
    }

    // MARK: - decodeEvent (server NDJSON lines)

    func testDecodesEveryServerEventType() {
        XCTAssertEqual(AnswerService.decodeEvent(line: #"{"type":"start","model":"claude-opus-5-5"}"#),
                       .start(model: "claude-opus-5-5"))
        XCTAssertEqual(AnswerService.decodeEvent(line: "{\"type\":\"text\",\"text\":\"### 1. Câu hỏi\\n**x = 2**\"}"),
                       .text("### 1. Câu hỏi\n**x = 2**"))
        XCTAssertEqual(
            AnswerService.decodeEvent(line: #"{"type":"done","stopReason":"end_turn","model":"claude-opus-5-5","inputTokens":1834,"outputTokens":912}"#),
            .done(stopReason: "end_turn", model: "claude-opus-5-5", inputTokens: 1834, outputTokens: 912))
        XCTAssertEqual(
            AnswerService.decodeEvent(line: #"{"type":"error","code":"refusal","message":"Claude declined to answer this page."}"#),
            .failure(code: "refusal", message: "Claude declined to answer this page."))
    }

    func testDoneWithNullStopReason() {
        XCTAssertEqual(
            AnswerService.decodeEvent(line: #"{"type":"done","stopReason":null,"model":"m","inputTokens":1,"outputTokens":2}"#),
            .done(stopReason: nil, model: "m", inputTokens: 1, outputTokens: 2))
    }

    func testErrorEventWithMissingFieldsGetsDefaults() {
        XCTAssertEqual(AnswerService.decodeEvent(line: #"{"type":"error"}"#),
                       .failure(code: "error", message: "Something went wrong."))
    }

    func testUnknownOrMalformedLinesAreSkipped() {
        for line in ["", "   ", "not json", "{", "[1,2]", #"{"type":"ping"}"#, #"{"text":"no type"}"#,
                     #"{"type":"text"}"#, #"{"type":"text","text":42}"#, #"{"type":7}"#] {
            XCTAssertNil(AnswerService.decodeEvent(line: line), "Expected nil for \(line)")
        }
    }

    // MARK: - Errors

    func testErrorMessageFromServerJSON() {
        let data = Data(#"{"error":"bad_request","message":"Page image is too large."}"#.utf8)
        XCTAssertEqual(AnswerService.errorMessage(from: data, status: 400), "Page image is too large.")
    }

    func testErrorMessageFallsBackForNonJSONBodies() {
        for data in [Data(), Data("<html>502 Bad Gateway</html>".utf8), Data(#"{"error":"x"}"#.utf8)] {
            XCTAssertEqual(AnswerService.errorMessage(from: data, status: 502), "The DocSnap server returned an error (502).")
        }
    }

    func testAnswerErrorDescriptions() {
        XCTAssertTrue(AnswerError.notConfigured.errorDescription?.contains("aren't set up") == true)
        XCTAssertTrue(AnswerError.http(status: 401, message: "Unknown app token.").errorDescription?.contains("didn't accept") == true,
                      "401 should tell the user to reinstall, not show the raw server text")
        XCTAssertEqual(AnswerError.http(status: 503, message: "Server is missing keys.").errorDescription, "Server is missing keys.")
        XCTAssertEqual(AnswerError.server(code: "rate_limited", message: "Busy").errorDescription, "Busy")
        XCTAssertNotNil(AnswerError.emptyAnswer.errorDescription)
        XCTAssertNotNil(AnswerError.imageUnavailable.errorDescription)
    }

    @MainActor
    func testSheetMessagesForNetworkErrors() {
        XCTAssertTrue(AnswerSheet.message(for: URLError(.notConnectedToInternet)).contains("offline"))
        XCTAssertTrue(AnswerSheet.message(for: URLError(.networkConnectionLost)).contains("offline"))
        XCTAssertTrue(AnswerSheet.message(for: URLError(.timedOut)).contains("too long"))
        XCTAssertTrue(AnswerSheet.message(for: URLError(.cannotFindHost)).contains("\(URLError.Code.cannotFindHost.rawValue)"))
        XCTAssertEqual(AnswerSheet.message(for: AnswerError.notConfigured), AnswerError.notConfigured.errorDescription)
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Custom failure"])
        XCTAssertEqual(AnswerSheet.message(for: other), "Custom failure")
    }

    // MARK: - uploadJPEG

    private func writeJPEG(size: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("answer-\(UUID().uuidString).jpg")
        let image = SampleData.photoOfPaper(lines: ["1. What is 2 + 2?"], size: size)
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pixelSize(of data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    func testUploadJPEGDownscalesALargePage() throws {
        let url = try writeJPEG(size: CGSize(width: 3024, height: 4032)) // 12 MP, the iPhone 13 Pro camera
        let data = try XCTUnwrap(AnswerService.uploadJPEG(fromImageAt: url))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "Must be a JPEG")
        let size = try pixelSize(of: data)
        XCTAssertEqual(max(size.width, size.height), AnswerService.maxImageDimension, accuracy: 1)
        XCTAssertEqual(size.width / size.height, 3024.0 / 4032.0, accuracy: 0.01, "Aspect ratio must be kept")
        // The server rejects base64 images over 3,400,000 characters.
        XCTAssertLessThan(data.base64EncodedString().count, 3_400_000)
    }

    func testUploadJPEGDoesNotUpscaleASmallPage() throws {
        let url = try writeJPEG(size: CGSize(width: 600, height: 800))
        let size = try pixelSize(of: try XCTUnwrap(AnswerService.uploadJPEG(fromImageAt: url)))
        XCTAssertEqual(size, CGSize(width: 600, height: 800))
    }

    func testUploadJPEGOfMissingFileIsNil() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).jpg")
        XCTAssertNil(AnswerService.uploadJPEG(fromImageAt: missing))
    }

    // MARK: - AnswerConfig.fromBundle

    /// A throwaway bundle whose Info.plist holds the given values (nil = key absent).
    private func bundle(url: String?, token: String?) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigBundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var info: [String: Any] = ["CFBundleIdentifier": "com.example.\(UUID().uuidString)"]
        info["DocSnapAPIURL"] = url
        info["DocSnapAppToken"] = token
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    func testConfigFromBundleWithHTTPSURLAndToken() throws {
        let config = try XCTUnwrap(AnswerConfig.fromBundle(bundle(url: "https://docsnap.example.com", token: "abc")))
        XCTAssertEqual(config.token, "abc")
        XCTAssertEqual(config.answerURL.absoluteString, "https://docsnap.example.com/api/answer")
    }

    func testConfigTrimsSpacesAroundURL() throws {
        let config = try XCTUnwrap(AnswerConfig.fromBundle(bundle(url: "  https://docsnap.example.com ", token: "abc")))
        XCTAssertEqual(config.baseURL.host, "docsnap.example.com")
    }

    func testConfigAllowsLocalhostOverHTTP() throws {
        XCTAssertNotNil(AnswerConfig.fromBundle(try bundle(url: "http://localhost:3000", token: "abc")))
        XCTAssertNotNil(AnswerConfig.fromBundle(try bundle(url: "http://127.0.0.1:3000", token: "abc")))
    }

    func testConfigRejectsMissingOrPlaceholderValues() throws {
        let cases: [(String?, String?, String)] = [
            ("", "abc", "empty URL (Local.xcconfig sets a token but no server)"),
            (nil, "abc", "missing URL key"),
            ("https://docsnap.example.com", "", "empty token"),
            ("https://docsnap.example.com", nil, "missing token key"),
            ("https://docsnap.example.com", "$(DOCSNAP_APP_TOKEN)", "unexpanded build setting"),
            ("http://docsnap.example.com", "abc", "plain http to a real host"),
            ("docsnap.example.com", "abc", "no scheme"),
        ]
        for (url, token, label) in cases {
            XCTAssertNil(AnswerConfig.fromBundle(try bundle(url: url, token: token)), "Should be nil for \(label)")
        }
    }
}

/// The small Markdown subset Claude is asked to use.
@MainActor
final class MarkdownParseTests: XCTestCase {
    typealias Block = MarkdownText.Block

    func testEmptyInput() {
        XCTAssertEqual(MarkdownText.parse(""), [])
        XCTAssertEqual(MarkdownText.parse("\n\n  \n"), [])
    }

    func testHeadingsAnyLevel() {
        XCTAssertEqual(MarkdownText.parse("### 1. Are v₁, v₂, v₃ linearly independent?\n# Title\n##No space"),
                       [.heading("1. Are v₁, v₂, v₃ linearly independent?"), .heading("Title"), .heading("No space")])
    }

    func testBulletsWithEachMarker() {
        XCTAssertEqual(MarkdownText.parse("- one\n* two\n• three\n   - indented"),
                       [.bullet("one"), .bullet("two"), .bullet("three"), .bullet("indented")])
    }

    func testNumberedItems() {
        XCTAssertEqual(MarkdownText.parse("1. First\n2) Second\n10.   Tenth"),
                       [.numbered("1", "First"), .numbered("2", "Second"), .numbered("10", "Tenth")])
    }

    func testParagraphLinesJoinUntilBlankLine() {
        XCTAssertEqual(MarkdownText.parse("**Answer: x = 2**\nx² = 4\n\nSecond paragraph"),
                       [.paragraph("**Answer: x = 2**\nx² = 4"), .paragraph("Second paragraph")])
    }

    func testThingsThatLookLikeListsButAreNot() {
        XCTAssertEqual(MarkdownText.parse("**Bold** start"), [.paragraph("**Bold** start")], "** is bold, not a bullet")
        XCTAssertEqual(MarkdownText.parse("-5 degrees"), [.paragraph("-5 degrees")])
        XCTAssertEqual(MarkdownText.parse("1.5 is the answer"), [.paragraph("1.5 is the answer")])
        XCTAssertEqual(MarkdownText.parse("*italic* note"), [.paragraph("*italic* note")])
    }

    func testBlocksEndTheParagraphBeforeThem() {
        XCTAssertEqual(MarkdownText.parse("Intro line\n### Q1\nWork\n- step"),
                       [.paragraph("Intro line"), .heading("Q1"), .paragraph("Work"), .bullet("step")])
    }

    func testPartialStreamedTextParses() {
        // The sheet re-parses on every streamed chunk; half a heading must not break anything.
        XCTAssertEqual(MarkdownText.parse("### 1. Câu"), [.heading("1. Câu")])
        XCTAssertEqual(MarkdownText.parse("### 1. Câu hỏi\n**Đáp"), [.heading("1. Câu hỏi"), .paragraph("**Đáp")])
    }

    func testWindowsLineEndings() {
        // Regression: "\r\n" line endings used to leave "\r" in headings and merge paragraphs.
        XCTAssertEqual(MarkdownText.parse("### Q1\r\nFirst\r\n\r\nSecond"),
                       [.heading("Q1"), .paragraph("First"), .paragraph("Second")])
    }
}
