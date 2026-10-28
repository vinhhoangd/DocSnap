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
    /// Tail of the edit queue for each page, so edits to one page apply strictly in order.
    @ObservationIgnored private var editQueues: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?

    nonisolated static var defaultRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DocSnap", isDirectory: true)
    }

    init(rootURL: URL = DocumentStore.defaultRootURL) {
        self.rootURL = rootURL
        imageCache.countLimit = 200
        imageCache.totalCostLimit = 120 * 1024 * 1024
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.imageCache.removeAllObjects() }
        }
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
        enum Source {
            case image(UIImage)
            /// An encoded image file. Preferred for camera/photo batches: pages are decoded one at a
            /// time, so a 50-page scan never holds 50 decoded 12 MP bitmaps in memory.
            /// The file is deleted after it has been saved.
            case file(URL)
        }

        var source: Source
        var quad: Quad?
        /// Used when `quad` is nil and auto-detection on the full photo finds nothing
        /// (e.g. the corners the live camera saw when it captured).
        var quadHint: Quad?

        init(image: UIImage, quad: Quad?) {
            source = .image(image)
            self.quad = quad
        }

        init(fileURL: URL, quad: Quad?, quadHint: Quad? = nil) {
            source = .file(fileURL)
            self.quad = quad
            self.quadHint = quadHint
        }
    }

    /// Scratch folder for captured pages waiting to be saved.
    nonisolated static var captureDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Capture", isDirectory: true)
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
        defer {
            for newPage in newPages {
                if case .file(let url) = newPage.source { try? fileManager.removeItem(at: url) }
            }
        }
        do {
            for newPage in newPages {
                let pageID = UUID()
                let originalURL = originalURL(documentID, pageID)
                let processedURL = processedURL(documentID, pageID)
                let source = newPage.source
                let requestedQuad = newPage.quad
                let quadHint = newPage.quadHint.flatMap { $0.isValid ? $0 : nil }
                let page = try await Task.detached(priority: .userInitiated) { () throws -> ScanPage in
                    try autoreleasepool {
                        let decoded: CGImage?
                        switch source {
                        case .image(let image):
                            decoded = ImageProcessor.normalizedCGImage(image)
                        case .file(let url):
                            // Applies EXIF orientation and caps the size while decoding.
                            decoded = ImageProcessor.loadCGImage(at: url, maxPixelSize: ImageProcessor.maxStoredDimension)
                        }
                        guard let cg = decoded, let originalData = ImageProcessor.jpegData(cg, quality: 0.9) else {
                            throw StoreError.imageProcessingFailed
                        }
                        let quad = requestedQuad ?? DocumentDetector.detectSync(in: cg) ?? quadHint ?? .full
                        let page = ScanPage(id: pageID, quad: quad, filter: filter)
                        try originalData.write(to: originalURL, options: .atomic)
                        try Self.renderProcessed(original: cg, page: page, to: processedURL)
                        return page
                    }
                }.value
                result.append(page)
            }
        } catch {
            // Don't leave unreferenced page files behind.
            for page in result { removeFiles(documentID, page.id) }
            throw error
        }
        return result
    }

    // MARK: - Editing

    /// Saves an edited page's crop, rotation and filter and re-renders its image.
    func updatePage(_ page: ScanPage, in documentID: UUID) async throws {
        try await editPage(page.id, in: documentID) {
            $0.quad = page.quad
            $0.rotation = page.rotation
            $0.filter = page.filter
        }
    }

    /// Applies `change` to the page as it is *when the edit runs*. Edits to the same page are
    /// queued, so tapping Rotate twice rotates twice and a quick filter change can't undo a rotation.
    func editPage(_ pageID: UUID, in documentID: UUID, _ change: @escaping (inout ScanPage) -> Void) async throws {
        let previous = editQueues[pageID]
        let edit = Task { @MainActor () throws in
            _ = await previous?.value
            try await self.applyEdit(pageID, in: documentID, change)
        }
        let tail = Task { @MainActor in _ = try? await edit.value }
        editQueues[pageID] = tail
        defer {
            if editQueues[pageID] == tail { editQueues[pageID] = nil }
        }
        try await edit.value
    }

    private func applyEdit(_ pageID: UUID, in documentID: UUID, _ change: (inout ScanPage) -> Void) async throws {
        guard let current = document(documentID)?.pages.first(where: { $0.id == pageID }) else { return }
        var updated = current
        change(&updated)
        updated.id = current.id
        updated.rotation = ((updated.rotation % 4) + 4) % 4
        guard updated.quad != current.quad || updated.rotation != current.rotation || updated.filter != current.filter else { return }
        updated.version = current.version + 1
        updated.textLines = nil
        updated.answer = nil
        let originalURL = originalURL(documentID, pageID)
        let processedURL = processedURL(documentID, pageID)
        let snapshot = updated
        do {
            try await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    guard let original = ImageProcessor.loadCGImage(at: originalURL) else { throw StoreError.missingFile }
                    try Self.renderProcessed(original: original, page: snapshot, to: processedURL)
                }
            }.value
        } catch {
            // The page was deleted while rendering: that's not an error worth showing.
            if document(documentID)?.pages.contains(where: { $0.id == pageID }) != true {
                removeFiles(documentID, pageID)
                return
            }
            throw error
        }
        // Re-read after the await: other pages may have changed, or this page may be gone —
        // in which case the render may have re-created a file that deletePage already removed.
        guard var doc = document(documentID), let index = doc.pages.firstIndex(where: { $0.id == pageID }) else {
            removeFiles(documentID, pageID)
            return
        }
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

    /// Stores Claude's answer, unless the page changed since the answer was requested.
    func setAnswer(_ answer: PageAnswer, pageID: UUID, in documentID: UUID) {
        guard var doc = document(documentID), let index = doc.pages.firstIndex(where: { $0.id == pageID }),
              doc.pages[index].version == answer.pageVersion else { return }
        doc.pages[index].answer = answer
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
        if let image, let cg = image.cgImage {
            imageCache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        }
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

    /// Clears old exports (only needed while the share sheet is open) and captured photos
    /// left behind by an interrupted scan. Call at launch, when nothing is in progress.
    func cleanExports() {
        try? fileManager.removeItem(at: fileManager.temporaryDirectory.appendingPathComponent("Exports"))
        try? fileManager.removeItem(at: Self.captureDirectory)
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
