import CoreGraphics
import Vision

/// On-device OCR with Vision. No network, no API key.
enum TextRecognizer {
    /// Recognition languages in priority order; filtered to what this iOS version supports.
    static let preferredLanguages = ["vi-VT", "en-US", "fr-FR", "de-DE", "es-ES", "pt-BR", "it-IT",
                                     "zh-Hans", "zh-Hant", "ja-JP", "ko-KR"]

    static func recognize(in image: CGImage) async throws -> [TextLine] {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSync(in: image)
        }.value
    }

    static func recognizeSync(in image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let languages = preferredLanguages.filter(supported.contains)
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        let lines = observations.compactMap { obs -> TextLine? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let b = obs.boundingBox
            // Vision: bottom-left origin → top-left origin.
            return TextLine(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        return readingOrder(lines)
    }

    /// Sorts lines top-to-bottom, then left-to-right for lines on the same row.
    static func readingOrder(_ lines: [TextLine]) -> [TextLine] {
        lines.sorted { a, b in
            let rowTolerance = min(a.box.height, b.box.height) * 0.5
            if abs(a.box.midY - b.box.midY) > rowTolerance { return a.box.midY < b.box.midY }
            return a.box.minX < b.box.minX
        }
    }
}
