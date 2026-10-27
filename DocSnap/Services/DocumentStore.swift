import Foundation
import Observation
import UIKit

/// Owns every scanned document and its files on disk.
///
/// Layout under `rootURL`:
/// ```
/// <document id>/document.json
/// <document id>/<page id>-original.jpg    upright photo as captured/imported
/// <document id>/<page id>-processed.jpg   cropped + rotated + filtered result
/// ```
@MainActor
@Observable
final class DocumentStore {
    private(set) var documents: [ScanDocument] = []
    private(set) var lastError: String?

    let rootURL: URL
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored let imageCache = NSCache<NSString, UIImage>()

    nonisolated static var defaultRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DocSnap", isDirectory: true)
    }

    init(rootURL: URL = DocumentStore.defaultRootURL) {
        self.rootURL = rootURL
        imageCache.countLimit = 200
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Paths

    func folderURL(_ documentID: UUID) -> URL {
        rootURL.appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    func originalURL(_ documentID: UUID, _ pageID: UUID) -> URL {
        folderURL(documentID).appendingPathComponent("\(pageID.uuidString)-original.jpg")
    }

    func processedURL(_ documentID: UUID, _ pageID: UUID) -> URL {
        folderURL(documentID).appendingPathComponent("\(pageID.uuidString)-processed.jpg")
    }

    private func metadataURL(_ documentID: UUID) -> URL {
        folderURL(documentID).appendingPathComponent("document.json")
    }

    // MARK: - Loading

    func load() {
        let folders = (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        documents = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("document.json")) else { return nil }
            return try? decoder.decode(ScanDocument.self, from: data)
        }
        sortDocuments()
    }

    func document(_ id: UUID) -> ScanDocument? {
        documents.first { $0.id == id }
    }

    // MARK: - Creating

    /// A captured or imported image plus the crop to apply (`nil` = auto-detect, `.full` = keep everything).
    struct NewPage {
        var image: UIImage
        var quad: Quad?
    }

    /// Creates a document from scanned images. Heavy work happens off the main thread.
    @discardableResult
    func createDocument(title: String? = nil, pages newPages: [NewPage], filter: ScanFilter) async throws -> ScanDocument {
        var doc = ScanDocument(title: title ?? ScanDocument.defaultTitle())
        try fileManager.createDirectory(at: folderURL(doc.id), withIntermediateDirectories: true)
        do {
            doc.pages = try await savePages(newPages, documentID: doc.id, filter: filter)
            try save(doc)
        } catch {
            try? fileManager.removeItem(at: folderURL(doc.id))
            throw error
        }
        documents.append(doc)
        sortDocuments()
        return doc
    }

    func addPages(_ newPages: [NewPage], to documentID: UUID, filter: ScanFilter) async throws {
        guard document(documentID) != nil else { return }
        let pages = try await savePages(newPages, documentID: documentID, filter: filter)
        // Re-read after the await: the document may have changed (or been deleted) meanwhile.
        guard var doc = document(documentID) else {
            for page in pages { removeFiles(documentID, page.id) }
            return
        }
        doc.pages.append(contentsOf: pages)
        try commit(doc)
    }

    private func savePages(_ newPages: [NewPage], documentID: UUID, filter: ScanFilter) async throws -> [ScanPage] {
        var result: [ScanPage] = []
        for newPage in newPages {
            let pageID = UUID()
            let originalURL = originalURL(documentID, pageID)
            let processedURL = processedURL(documentID, pageID)
            let image = newPage.image
            let requestedQuad = newPage.quad
            let page = try await Task.detached(priority: .userInitiated) { () throws -> ScanPage in
                try autoreleasepool {
                    guard let cg = ImageProcessor.normalizedCGImage(image),
                          let originalData = ImageProcessor.jpegData(cg, quality: 0.9) else {
                        throw StoreError.imageProcessingFailed
                    }
                    let quad = requestedQuad ?? DocumentDetector.detectSync(in: cg) ?? .full
                    let page = ScanPage(id: pageID, quad: quad, filter: filter)
                    try originalData.write(to: originalURL, options: .atomic)
                    try Self.renderProcessed(original: cg, page: page, to: processedURL)
                    return page
                }
            }.value
            result.append(page)
        }
        return result
    }

    // MARK: - Editing

    /// Saves an edited page (crop, rotation or filter) and re-renders its image.
    func updatePage(_ page: ScanPage, in documentID: UUID) async throws {
        guard let current = document(documentID)?.pages.first(where: { $0.id == page.id }) else { return }
        var updated = page
        updated.rotation = ((page.rotation % 4) + 4) % 4
        let imageChanged = updated.quad != current.quad || updated.rotation != current.rotation || updated.filter != current.filter
        if imageChanged {
            updated.version = max(current.version, page.version) + 1
            updated.textLines = nil
            let originalURL = originalURL(documentID, page.id)
            let processedURL = processedURL(documentID, page.id)
            let snapshot = updated
            try await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    guard let original = ImageProcessor.loadCGImage(at: originalURL) else { throw StoreError.missingFile }
                    try Self.renderProcessed(original: original, page: snapshot, to: processedURL)
                }
            }.value
        }
        // Re-read after the await so concurrent edits to other pages aren't lost.
        guard var doc = document(documentID), let index = doc.pages.firstIndex(where: { $0.id == page.id }) else { return }
        doc.pages[index] = updated
        try commit(doc)
    }

    /// Stores OCR results without touching the image.
    func setTextLines(_ lines: [TextLine], pageID: UUID, version: Int, in documentID: UUID) {
        guard var doc = document(documentID), let index = doc.pages.firstIndex(where: { $0.id == pageID }),
              doc.pages[index].version == version else { return }
        doc.pages[index].textLines = lines
        try? commit(doc, touch: false)
    }

    func deletePage(_ pageID: UUID, from documentID: UUID) throws {
        guard var doc = document(documentID) else { return }
        doc.pages.removeAll { $0.id == pageID }
        try commit(doc)
        removeFiles(documentID, pageID)
    }

    func movePages(in documentID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) throws {
        guard var doc = document(documentID) else { return }
        doc.pages.move(fromOffsets: source, toOffset: destination)
        try commit(doc)
    }

    func rename(_ documentID: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var doc = document(documentID) else { return }
        doc.title = trimmed
        try commit(doc)
    }

    func deleteDocument(_ documentID: UUID) {
        documents.removeAll { $0.id == documentID }
        try? fileManager.removeItem(at: folderURL(documentID))
    }

    // MARK: - Images

    /// The finished page image, downsampled to `maxPixelSize` if given. Cached per page version.
    nonisolated static func loadImage(at url: URL, maxPixelSize: CGFloat?) -> UIImage? {
        ImageProcessor.loadCGImage(at: url, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
    }

    func cacheKey(_ documentID: UUID, _ page: ScanPage, maxPixelSize: CGFloat?) -> NSString {
        "\(documentID.uuidString)/\(page.id.uuidString)/\(page.version)/\(Int(maxPixelSize ?? 0))" as NSString
    }

    func image(for page: ScanPage, in documentID: UUID, maxPixelSize: CGFloat?) async -> UIImage? {
        let key = cacheKey(documentID, page, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) { return cached }
        let url = processedURL(documentID, page.id)
        let image = await Task.detached(priority: .userInitiated) {
            Self.loadImage(at: url, maxPixelSize: maxPixelSize)
        }.value
        if let image { imageCache.setObject(image, forKey: key) }
        return image
    }

    // MARK: - Export

    func exportPDF(_ documentID: UUID, pageSize: PDFPageSize, searchable: Bool) async throws -> URL {
        guard let doc = document(documentID) else { throw StoreError.missingFile }
        if searchable { await recognizeMissingText(in: documentID) }
        guard let fresh = document(documentID) else { throw StoreError.missingFile }
        let pages = fresh.pages.map {
            ExportPage(imageURL: processedURL(documentID, $0.id), textLines: searchable ? $0.textLines : nil)
        }
        let url = try exportDirectory().appendingPathComponent("\(Self.safeFileName(doc.title)).pdf")
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: url)
            try PDFExporter.write(pages: pages, pageSize: pageSize, title: doc.title, to: url)
        }.value
        return url
    }

    func exportImages(_ documentID: UUID) throws -> [URL] {
        guard let doc = document(documentID) else { throw StoreError.missingFile }
        let folder = try exportDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Self.safeFileName(doc.title)
        return try doc.pages.enumerated().map { index, page in
            let name = doc.pages.count == 1 ? "\(base).jpg" : "\(base) \(index + 1).jpg"
            let url = folder.appendingPathComponent(name)
            try fileManager.copyItem(at: processedURL(documentID, page.id), to: url)
            return url
        }
    }

    /// Runs OCR on every page that doesn't have text yet.
    func recognizeMissingText(in documentID: UUID) async {
        guard let doc = document(documentID) else { return }
        for page in doc.pages where page.textLines == nil {
            _ = await recognizeText(for: page, in: documentID)
        }
    }

    func recognizeText(for page: ScanPage, in documentID: UUID) async -> [TextLine]? {
        let url = processedURL(documentID, page.id)
        let lines = try? await Task.detached(priority: .userInitiated) { () throws -> [TextLine] in
            guard let image = ImageProcessor.loadCGImage(at: url) else { throw StoreError.missingFile }
            return try TextRecognizer.recognizeSync(in: image)
        }.value
        if let lines { setTextLines(lines, pageID: page.id, version: page.version, in: documentID) }
        return lines
    }

    /// Clears old exports; they're only needed while the share sheet is open.
    func cleanExports() {
        try? fileManager.removeItem(at: fileManager.temporaryDirectory.appendingPathComponent("Exports"))
    }

    // MARK: - Internals

    enum StoreError: LocalizedError {
        case imageProcessingFailed
        case missingFile

        var errorDescription: String? {
            switch self {
            case .imageProcessingFailed: "The image couldn't be processed."
            case .missingFile: "A page file is missing."
            }
        }
    }

    nonisolated private static func renderProcessed(original: CGImage, page: ScanPage, to url: URL) throws {
        guard let processed = ImageProcessor.process(original, page: page),
              let data = ImageProcessor.jpegData(processed, quality: 0.85) else {
            throw StoreError.imageProcessingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private func commit(_ doc: ScanDocument, touch: Bool = true) throws {
        var doc = doc
        if touch { doc.updatedAt = Date() }
        try save(doc)
        if let index = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[index] = doc
        }
        if touch { sortDocuments() }
    }

    private func save(_ doc: ScanDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(doc).write(to: metadataURL(doc.id), options: .atomic)
    }

    private func removeFiles(_ documentID: UUID, _ pageID: UUID) {
        try? fileManager.removeItem(at: originalURL(documentID, pageID))
        try? fileManager.removeItem(at: processedURL(documentID, pageID))
    }

    private func sortDocuments() {
        documents.sort { $0.updatedAt > $1.updatedAt }
    }

    private func exportDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func safeFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "DocSnap" : String(cleaned.prefix(100))
    }
}
