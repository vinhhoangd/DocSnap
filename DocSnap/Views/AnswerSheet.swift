import SwiftUI

/// Sends the page to Claude (through the DocSnap server) and shows the answer as it streams in.
struct AnswerSheet: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.answerModelKey) private var model: AnswerModel = .opus

    let documentID: UUID
    let pageID: UUID
    let pageTitle: String

    enum Phase: Equatable {
        case idle
        case waiting
        case streaming
        case finished
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var text = ""
    @State private var answeredBy: String?
    @State private var truncated = false
    @State private var task: Task<Void, Never>?
    @State private var copied = false

    private var page: ScanPage? {
        store.document(documentID)?.pages.first { $0.id == pageID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    header
                    content
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Answer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .onAppear(perform: loadOrStart)
        .onDisappear { task?.cancel() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            if let page {
                PageImageView(documentID: documentID, page: page, maxPixelSize: 200)
                    .paperStyle(radius: 4)
                    .frame(width: 38, height: 50)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle).font(.subheadline.weight(.semibold))
                Text(answeredBy.map { "Answered by \($0)" } ?? model.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.sm)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .waiting:
            HStack(spacing: Theme.Space.sm) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading the page…").font(.subheadline.weight(.semibold))
                    Text("Claude is working through the questions. This can take up to a minute.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Theme.Space.lg)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("answerLoading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Get an Answer", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise") { start() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
            .accessibilityIdentifier("answerError")
        case .streaming, .finished:
            MarkdownText(text)
                .textSelection(.enabled)
                .accessibilityIdentifier("answerText")
            if phase == .streaming {
                ProgressView().padding(.top, Theme.Space.xs)
            } else {
                if truncated {
                    Label("The answer was cut off because it was very long.", systemImage: "scissors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Label("AI answers can be wrong. Check important steps yourself.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, Theme.Space.xs)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if phase == .finished {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = text
                    copied = true
                    Haptics.success()
                }
                ShareLink(item: text)
                Menu {
                    ForEach(AnswerModel.allCases) { option in
                        Button {
                            model = option
                            start()
                        } label: {
                            Label("\(option.displayName) – \(option.detail)",
                                  systemImage: option == model ? "checkmark" : "sparkles")
                        }
                    }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("regenerateMenu")
            }
        }
    }

    // MARK: - Flow

    private func loadOrStart() {
        guard phase == .idle else { return }
        if let cached = page?.answer, cached.pageVersion == page?.version {
            text = cached.text
            answeredBy = AnswerModel(rawValue: cached.model)?.displayName ?? cached.model
            phase = .finished
        } else {
            start()
        }
    }

    private func start() {
        task?.cancel()
        text = ""
        truncated = false
        copied = false
        answeredBy = nil
        phase = .waiting
        let chosenModel = model
        task = Task {
            do {
                try await run(model: chosenModel)
            } catch is CancellationError {
                // Sheet closed or regenerated.
            } catch let error as URLError where error.code == .cancelled {
                // Sheet closed.
            } catch {
                Haptics.error()
                phase = .failed(Self.message(for: error))
            }
        }
    }

    private func run(model: AnswerModel) async throws {
        guard let config = AnswerConfig.fromBundle() else { throw AnswerError.notConfigured }
        guard let page else { throw AnswerError.imageUnavailable }
        let version = page.version
        let imageURL = store.processedURL(documentID, page.id)
        let ocr = page.recognizedText
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
            AnswerService.uploadJPEG(fromImageAt: imageURL)
        }).value else { throw AnswerError.imageUnavailable }

        let service = AnswerService(config: config)
        var servedBy = model.rawValue
        for try await event in service.stream(imageJPEG: jpeg, ocrText: ocr, model: model) {
            try Task.checkCancellation()
            switch event {
            case .start:
                break
            case .text(let chunk):
                if phase != .streaming { phase = .streaming }
                text += chunk
            case .done(let stopReason, let served, _, _):
                servedBy = served.isEmpty ? servedBy : served
                truncated = stopReason == "max_tokens"
            case .failure:
                break // the stream throws right after yielding a failure
            }
        }
        // Closing the sheet ends the stream without an error; never save a partial answer.
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnswerError.emptyAnswer }
        answeredBy = AnswerModel(rawValue: servedBy)?.displayName ?? servedBy
        phase = .finished
        Haptics.success()
        store.setAnswer(PageAnswer(text: text, model: servedBy, createdAt: Date(), pageVersion: version),
                        pageID: pageID, in: documentID)
    }

    static func message(for error: Error) -> String {
        if let error = error as? AnswerError { return error.errorDescription ?? "Something went wrong." }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Connect to the internet and try again."
            case .timedOut:
                return "Claude took too long to answer. Try again."
            default:
                return "Couldn't reach the DocSnap server (\(error.code.rawValue))."
            }
        }
        return error.localizedDescription
    }
}

/// Minimal Markdown for answers: ### headings, paragraphs, "-"/"1." lists, inline **bold**/*italic*.
struct MarkdownText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case numbered(String, String)
        case paragraph(String)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let match = line.firstMatch(of: /^(\d{1,3})[.)]\s+(.*)$/) {
                flush()
                blocks.append(.numbered(String(match.1), String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(Array(Self.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(.headline)
                        .padding(.top, Theme.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
