import Foundation
import ImageIO
import UIKit

/// Claude models the Answer feature can use (the server only accepts these).
enum AnswerModel: String, CaseIterable, Identifiable, Codable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    var detail: String {
        switch self {
        case .opus: "Most accurate"
        case .sonnet: "Faster, cheaper"
        case .haiku: "Fastest, cheapest"
        }
    }
}

/// Where the DocSnap server is and the shared secret that proves this is the DocSnap app.
/// Both come from `Config/Local.xcconfig` (git-ignored) through Info.plist — never from source code.
struct AnswerConfig: Equatable {
    var baseURL: URL
    var token: String

    static func fromBundle(_ bundle: Bundle = .main) -> AnswerConfig? {
        #if DEBUG
        // UI tests run with sample data and must never call the real (paid) server.
        if ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument) { return nil }
        #endif
        guard let urlString = bundle.object(forInfoDictionaryKey: "DocSnapAPIURL") as? String,
              let token = bundle.object(forInfoDictionaryKey: "DocSnapAppToken") as? String,
              !token.isEmpty, !token.hasPrefix("$("),
              let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1"
        else { return nil }
        return AnswerConfig(baseURL: url, token: token)
    }

    var answerURL: URL { baseURL.appendingPathComponent("api/answer") }
}

/// One line of the server's NDJSON stream.
enum AnswerEvent: Equatable {
    case start(model: String)
    case text(String)
    case done(stopReason: String?, model: String, inputTokens: Int, outputTokens: Int)
    case failure(code: String, message: String)
}

enum AnswerError: LocalizedError, Equatable {
    case notConfigured
    case imageUnavailable
    case http(status: Int, message: String)
    case server(code: String, message: String)
    case emptyAnswer
    case incomplete

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Answers aren't set up yet: the app doesn't know the DocSnap server address."
        case .imageUnavailable:
            "This page's image couldn't be read."
        case .http(let status, let message):
            status == 401 ? "The DocSnap server didn't accept this app. Reinstall the latest build." : message
        case .server(_, let message):
            message
        case .emptyAnswer:
            "Claude didn't return an answer. Try again."
        case .incomplete:
            "The answer was interrupted before it finished. Try again."
        }
    }
}

/// Talks to the DocSnap server, which forwards the page to Claude and streams the answer back.
struct AnswerService {
    var config: AnswerConfig
    var session: URLSession = .shared

    /// Long-edge size sent to Claude; larger images are downscaled by the API anyway.
    static let maxImageDimension: CGFloat = 1568

    // MARK: - Pure helpers (unit-tested)

    static func makeRequest(config: AnswerConfig, imageJPEG: Data, ocrText: String?, model: AnswerModel) throws -> URLRequest {
        var request = URLRequest(url: config.answerURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.setValue(config.token, forHTTPHeaderField: "x-docsnap-token")
        var body: [String: Any] = ["image": imageJPEG.base64EncodedString(), "model": model.rawValue]
        if let ocrText, !ocrText.isEmpty { body["text"] = ocrText }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Decodes one NDJSON line; unknown or malformed lines return nil and are skipped.
    static func decodeEvent(line: String) -> AnswerEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "start":
            return .start(model: object["model"] as? String ?? "")
        case "text":
            guard let text = object["text"] as? String else { return nil }
            return .text(text)
        case "done":
            return .done(
                stopReason: object["stopReason"] as? String,
                model: object["model"] as? String ?? "",
                inputTokens: object["inputTokens"] as? Int ?? 0,
                outputTokens: object["outputTokens"] as? Int ?? 0
            )
        case "error":
            return .failure(code: object["code"] as? String ?? "error",
                            message: object["message"] as? String ?? "Something went wrong.")
        default:
            return nil
        }
    }

    /// Message from a non-200 JSON error body like {"error":"…","message":"…"}.
    static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return "The DocSnap server returned an error (\(status))."
    }

    /// Downscaled JPEG of a page for upload.
    static func uploadJPEG(fromImageAt url: URL) -> Data? {
        guard let cg = ImageProcessor.loadCGImage(at: url, maxPixelSize: maxImageDimension) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    // MARK: - Network

    /// Streams the answer. Cancelling the consuming task cancels the request.
    func stream(imageJPEG: Data, ocrText: String?, model: AnswerModel) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.makeRequest(config: config, imageJPEG: imageJPEG, ocrText: ocrText, model: model)
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 16_384 { break }
                        }
                        throw AnswerError.http(status: status, message: Self.errorMessage(from: data, status: status))
                    }
                    var sawDone = false
                    for try await line in bytes.lines {
                        guard let event = Self.decodeEvent(line: line) else { continue }
                        continuation.yield(event)
                        switch event {
                        case .failure(let code, let message):
                            throw AnswerError.server(code: code, message: message)
                        case .done:
                            sawDone = true
                        default:
                            break
                        }
                    }
                    try Task.checkCancellation()
                    // A clean end of stream without "done" means the server was cut off (e.g. time limit).
                    guard sawDone else { throw AnswerError.incomplete }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// GET /api/answer — true when the server is reachable and has its keys configured.
    func checkHealth() async -> Bool {
        var request = URLRequest(url: config.answerURL)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["configured"] as? Bool == true
    }
}
