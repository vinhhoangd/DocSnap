#if DEBUG
import UIKit

/// Synthetic documents for the simulator (which has no camera) and for UI tests.
/// Launch with `-uiTestingSampleData` to start from a fresh store containing one sample document.
@MainActor
enum SampleData {
    static let launchArgument = "-uiTestingSampleData"
    /// Starts from an empty temporary store and imports two synthetic photos at launch, as if they
    /// were picked in Photos (UI tests can't drive the system picker), so the Adjust Borders flow runs.
    static let reviewImportArgument = "-uiTestingReviewImport"

    /// Either UI-test mode: keep the real library untouched.
    static var usesTemporaryStore: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(launchArgument) || arguments.contains(reviewImportArgument)
    }

    /// Several views attach the capture modifier; only the first one to ask runs the import.
    private static var reviewImportPending = ProcessInfo.processInfo.arguments.contains(reviewImportArgument)

    /// `true` once, if the app was launched with `reviewImportArgument`.
    static func takeReviewImport() -> Bool {
        defer { reviewImportPending = false }
        return reviewImportPending
    }

    /// Writes the photos of a review import as encoded files in the capture folder, like a Photos import.
    nonisolated static func writeReviewImportPhotos() -> [URL] {
        let folder = DocumentStore.captureDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pages = [["IMPORTED PAGE ONE", "Adjust Borders test"], ["IMPORTED PAGE TWO", "Second photo"]]
        return pages.compactMap { lines in
            let url = folder.appendingPathComponent(UUID().uuidString)
            guard let data = photoOfPaper(lines: lines).jpegData(compressionQuality: 0.9),
                  (try? data.write(to: url)) != nil else { return nil }
            return url
        }
    }

    static func makeStore() -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITestStore-\(UUID().uuidString)")
        return DocumentStore(rootURL: root)
    }

    static func seed(_ store: DocumentStore) async {
        guard store.documents.isEmpty else { return }
        let pages = [
            DocumentStore.NewPage(image: photoOfPaper(lines: ["INVOICE 2026", "DocSnap sample page one", "Total: 120.00"]), quad: nil),
            DocumentStore.NewPage(image: photoOfPaper(lines: ["MEETING NOTES", "Second sample page", "Scan, crop, share"]), quad: nil),
        ]
        _ = try? await store.createDocument(title: "Sample Invoice", pages: pages, filter: .magicColor)
    }

    /// A tilted white page with dark text on a wooden-brown "desk", with a lighting gradient.
    nonisolated static func photoOfPaper(lines: [String], size: CGSize = CGSize(width: 1200, height: 1600)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.36, green: 0.25, blue: 0.17, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let corners = [
                CGPoint(x: size.width * 0.16, y: size.height * 0.12),
                CGPoint(x: size.width * 0.86, y: size.height * 0.15),
                CGPoint(x: size.width * 0.82, y: size.height * 0.88),
                CGPoint(x: size.width * 0.12, y: size.height * 0.85),
            ]
            let paper = UIBezierPath()
            paper.move(to: corners[0])
            corners.dropFirst().forEach { paper.addLine(to: $0) }
            paper.close()
            UIColor(white: 0.96, alpha: 1).setFill()
            paper.fill()

            // Shadow-like gradient across the page.
            cg.saveGState()
            paper.addClip()
            let colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.25).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: size.width * 0.2, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])
            }
            cg.restoreGState()

            cg.saveGState()
            cg.translateBy(x: corners[0].x, y: corners[0].y)
            cg.rotate(by: atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 52, weight: .semibold),
                .foregroundColor: UIColor(white: 0.1, alpha: 1),
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 90 + CGFloat(i) * 110), withAttributes: attributes)
            }
            cg.restoreGState()
        }
    }
}
#endif
