import CoreGraphics
import Foundation

/// One line of OCR output. `box` is normalized (0...1, top-left origin) within the processed page image.
struct TextLine: Codable, Equatable {
    var text: String
    var box: CGRect
}

/// Claude's answer to the questions on a page, kept until the page image changes.
struct PageAnswer: Codable, Equatable {
    var text: String
    var model: String
    var createdAt: Date
    /// The page version the answer was made from.
    var pageVersion: Int
}

struct ScanPage: Codable, Identifiable, Equatable {
    var id: UUID
    /// Crop corners within the stored original image.
    var quad: Quad
    var filter: ScanFilter
    /// Clockwise quarter turns, 0...3.
    var rotation: Int
    /// OCR result for the processed image; `nil` until recognized, cleared whenever the image changes.
    var textLines: [TextLine]?
    /// Bumped on every edit so cached images are invalidated.
    var version: Int
    /// Claude's answer for the current image; cleared whenever the image changes.
    var answer: PageAnswer?

    init(id: UUID = UUID(), quad: Quad = .full, filter: ScanFilter = .magicColor, rotation: Int = 0,
         textLines: [TextLine]? = nil, version: Int = 0, answer: PageAnswer? = nil) {
        self.id = id
        self.quad = quad
        self.filter = filter
        self.rotation = rotation
        self.textLines = textLines
        self.version = version
        self.answer = answer
    }

    var recognizedText: String? {
        textLines.map { $0.map(\.text).joined(separator: "\n") }
    }

    // Tolerant decoding so documents saved by older/newer builds still open.
    private enum CodingKeys: String, CodingKey { case id, quad, filter, rotation, textLines, version, answer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        quad = try c.decodeIfPresent(Quad.self, forKey: .quad) ?? .full
        filter = try c.decodeIfPresent(ScanFilter.self, forKey: .filter) ?? .magicColor
        rotation = ((try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0) % 4 + 4) % 4
        textLines = try c.decodeIfPresent([TextLine].self, forKey: .textLines)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        answer = try? c.decodeIfPresent(PageAnswer.self, forKey: .answer)
    }
}

struct ScanDocument: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var pages: [ScanPage]

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), updatedAt: Date? = nil, pages: [ScanPage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.pages = pages
    }

    /// All OCR text in page order, for search and "copy all text".
    var allText: String {
        pages.compactMap(\.recognizedText).joined(separator: "\n\n")
    }

    /// Default name in the style "Scan 2026-10-27 14.30".
    static func defaultTitle(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "Scan \(f.string(from: date))"
    }
}
