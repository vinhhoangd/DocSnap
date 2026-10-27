import CoreText
import UIKit

enum PDFPageSize: String, CaseIterable, Identifiable {
    case auto
    case a4
    case letter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto (fit image)"
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }

    /// Portrait size in PDF points (1/72 inch).
    var portraitSize: CGSize? {
        switch self {
        case .auto: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}

/// A page ready for export: the finished image file plus optional OCR text.
struct ExportPage {
    var imageURL: URL
    var textLines: [TextLine]?
}

enum PDFExporter {
    enum ExportError: LocalizedError {
        case noPages
        case unreadableImage(URL)

        var errorDescription: String? {
            switch self {
            case .noPages: "This document has no pages to export."
            case .unreadableImage: "A page image couldn't be read."
            }
        }
    }

    /// Writes a PDF. Images are drawn from their JPEG files so the PDF embeds the JPEG data
    /// instead of raw pixels. OCR text is drawn invisibly on top, making the PDF searchable.
    static func write(pages: [ExportPage], pageSize: PDFPageSize, title: String, to url: URL) throws {
        guard !pages.isEmpty else { throw ExportError.noPages }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "DocSnap",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89), format: format)

        var failure: Error?
        try renderer.writePDF(to: url) { ctx in
            for page in pages {
                let drawn: Bool = autoreleasepool {
                    guard let image = UIImage(contentsOfFile: page.imageURL.path), image.size.width > 0, image.size.height > 0 else {
                        failure = ExportError.unreadableImage(page.imageURL)
                        return false
                    }
                    let bounds = pageBounds(for: image.size, pageSize: pageSize)
                    ctx.beginPage(withBounds: bounds, pageInfo: [:])
                    let imageRect = fittedRect(for: image.size, in: bounds)
                    image.draw(in: imageRect)
                    if let lines = page.textLines, !lines.isEmpty {
                        drawInvisibleText(lines, in: imageRect, context: ctx.cgContext)
                    }
                    return true
                }
                if !drawn { break }
            }
        }
        if let failure {
            try? FileManager.default.removeItem(at: url)
            throw failure
        }
    }

    static func pageBounds(for imageSize: CGSize, pageSize: PDFPageSize) -> CGRect {
        let landscape = imageSize.width > imageSize.height
        if let portrait = pageSize.portraitSize {
            let size = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
            return CGRect(origin: .zero, size: size)
        }
        // Auto: page takes the image's aspect ratio; the short side matches A4's short side.
        let shortSide: CGFloat = 595.28
        let scale = shortSide / max(1, min(imageSize.width, imageSize.height))
        return CGRect(x: 0, y: 0, width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }

    /// Aspect-fit, centered.
    static func fittedRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func drawInvisibleText(_ lines: [TextLine], in imageRect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setTextDrawingMode(.invisible)
        // The UIKit PDF context is flipped (y down); flip glyphs back upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for line in lines {
            let rect = CGRect(
                x: imageRect.minX + line.box.minX * imageRect.width,
                y: imageRect.minY + line.box.minY * imageRect.height,
                width: line.box.width * imageRect.width,
                height: line.box.height * imageRect.height
            )
            guard rect.width > 1, rect.height > 1 else { continue }

            // Size the font so the invisible text spans the same box as the printed text,
            // which keeps search highlights and text selection aligned with the image.
            var fontSize = rect.height * 0.85
            var ctLine = makeLine(line.text, fontSize: fontSize)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            if width > 0 {
                fontSize *= rect.width / CGFloat(width)
                fontSize = min(max(fontSize, 1), rect.height * 1.5)
                ctLine = makeLine(line.text, fontSize: fontSize)
            }
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, nil, &descent, nil)
            context.textPosition = CGPoint(x: rect.minX, y: rect.maxY - descent)
            CTLineDraw(ctLine, context)
        }
    }

    private static func makeLine(_ text: String, fontSize: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineCreateWithAttributedString(attributed)
    }
}
