import SwiftUI

/// Swipe through pages and edit the current one: crop, rotate, filter, text, delete.
struct PageViewer: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let documentID: UUID
    let initialPageID: UUID

    @State private var currentPageID: UUID?
    @State private var showFilters = false
    @State private var cropping: ScanPage?
    @State private var textContent: TextSheetContent?
    @State private var answering: AnswerTarget?
    @State private var showDeletePage = false
    @State private var pendingEdits = 0
    @State private var recognizing = false
    /// While a page is zoomed in, horizontal drags pan the page instead of switching pages.
    @State private var isZoomed = false
    @State private var errorMessage: String?

    private var working: Bool { pendingEdits > 0 || recognizing }

    private var pages: [ScanPage] { store.document(documentID)?.pages ?? [] }

    private var currentPage: ScanPage? {
        pages.first { $0.id == currentPageID } ?? pages.first
    }

    private var currentIndex: Int {
        pages.firstIndex { $0.id == currentPage?.id } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPageID) {
                ForEach(pages) { page in
                    ZoomableView(isZoomed: $isZoomed) {
                        // A fixed, full-size frame: when a rotation turns the page from portrait to
                        // landscape in place, the paging view doesn't re-measure its content, so a
                        // size that depends on the image's aspect ratio would be drawn stale and overflow.
                        PageImageView(documentID: documentID, page: page, maxPixelSize: 2400)
                            .paperStyle(radius: 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .tag(Optional(page.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(isZoomed)
            .overlay(alignment: .top) {
                if working {
                    // Non-blocking status pill: the page stays visible while an edit renders.
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text(recognizing ? "Reading text…" : "Applying…")
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, Theme.Space.xs)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    .padding(.top, Theme.Space.xs)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                }
            }
            .motion(Theme.Motion.quick, value: working, reduceMotion: reduceMotion)

            if showFilters, let page = currentPage {
                FilterStrip(documentID: documentID, page: page) { filter in
                    Haptics.selection()
                    apply(to: page.id) { $0.filter = filter }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            editBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(pages.isEmpty ? "" : "\(currentIndex + 1) / \(pages.count)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if currentPageID == nil { currentPageID = initialPageID }
        }
        .onChange(of: pages.map(\.id)) { _, ids in
            if ids.isEmpty { dismiss() }
        }
        .fullScreenCover(item: $cropping) { page in
            CropView(documentID: documentID, page: page) { quad in
                Haptics.impact()
                apply(to: page.id) { $0.quad = quad }
            }
        }
        .sheet(item: $textContent) { content in
            TextSheet(content: content)
        }
        .sheet(item: $answering) { target in
            AnswerSheet(documentID: documentID, pageID: target.pageID, pageTitle: target.title)
                .presentationDetents([.large])
        }
        .confirmationDialog("Delete this page?", isPresented: $showDeletePage, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) {
                Haptics.impact(.medium)
                deleteCurrentPage()
            }
                .accessibilityIdentifier("confirmDeletePageButton")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var editBar: some View {
        HStack {
            barButton("Crop", "crop", id: "cropButton") {
                cropping = currentPage
            }
            // The crop screen shows the page as rotated, so wait for queued edits to land first.
            .disabled(pendingEdits > 0)
            barButton("Rotate", "rotate.right", id: "rotateButton") {
                guard let page = currentPage else { return }
                // Relative to the page's state when the edit runs, so quick double taps rotate twice.
                Haptics.impact()
                apply(to: page.id) { $0.rotation += 1 }
            }
            barButton("Filters", "camera.filters", id: "filtersButton", selected: showFilters) {
                withAnimation(reduceMotion ? nil : Theme.Motion.quick) { showFilters.toggle() }
            }
            barButton("Text", "text.viewfinder", id: "textButton") {
                recognizeText()
            }
            barButton("Answer", "sparkles", id: "answerButton") {
                guard let page = currentPage else { return }
                Haptics.impact()
                answering = AnswerTarget(pageID: page.id, title: "Page \(currentIndex + 1)")
            }
            // The answer should describe the final image, so wait for queued edits.
            .disabled(pendingEdits > 0)
            barButton("Delete", "trash", id: "deletePageButton") {
                showDeletePage = true
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.xxs)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .disabled(currentPage == nil)
    }

    private func barButton(_ title: String, _ icon: String, id: String, selected: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                    .frame(height: 26)
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Actions

    /// Queues an edit in the store; edits to one page apply in order, each on the latest state.
    private func apply(to pageID: UUID, _ change: @escaping (inout ScanPage) -> Void) {
        pendingEdits += 1
        Task {
            defer { pendingEdits -= 1 }
            do {
                try await store.editPage(pageID, in: documentID, change)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recognizeText() {
        guard let page = currentPage, !recognizing else { return }
        // Capture now: the user may swipe to another page while OCR runs.
        let title = "Page \(currentIndex + 1)"
        if let text = page.recognizedText {
            textContent = TextSheetContent(title: title, text: text)
            return
        }
        recognizing = true
        Task {
            // Let queued edits to this page finish first, so the text matches the final image.
            while pendingEdits > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            let fresh = store.document(documentID)?.pages.first { $0.id == page.id } ?? page
            let lines = await store.recognizeText(for: fresh, in: documentID)
            recognizing = false
            let text = lines.map { $0.map(\.text).joined(separator: "\n") } ?? ""
            textContent = TextSheetContent(title: title, text: text)
        }
    }

    private func deleteCurrentPage() {
        guard let page = currentPage else { return }
        let index = currentIndex
        do {
            try store.deletePage(page.id, from: documentID)
            // Stay at the same position (the next page), not jump back to page 1.
            let remaining = pages
            if !remaining.isEmpty { currentPageID = remaining[min(index, remaining.count - 1)].id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Horizontal strip of filter previews rendered from the page's own image.
private struct FilterStrip: View {
    @Environment(DocumentStore.self) private var store
    let documentID: UUID
    let page: ScanPage
    let onSelect: (ScanFilter) -> Void

    @State private var previews: [ScanFilter: UIImage] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(ScanFilter.allCases) { filter in
                    let selected = filter == page.filter
                    Button {
                        if !selected { onSelect(filter) }
                    } label: {
                        VStack(spacing: Theme.Space.xxs + 2) {
                            Group {
                                if let image = previews[filter] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Color(.tertiarySystemFill)
                                }
                            }
                            .frame(width: 62, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor : Color(.separator), lineWidth: selected ? 2.5 : 0.5)
                            }
                            .overlay(alignment: .topTrailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .padding(3)
                                }
                            }
                            Text(filter.displayName)
                                .font(.caption2.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("filter-\(filter.rawValue)")
                    .accessibilityLabel(filter.displayName)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: "\(page.id)-\(page.quad.points)-\(page.rotation)") {
            let url = store.originalURL(documentID, page.id)
            let quad = page.quad
            let rotation = page.rotation
            previews = await Task.detached(priority: .userInitiated) {
                guard let small = ImageProcessor.loadCGImage(at: url, maxPixelSize: 320) else { return [:] }
                var result: [ScanFilter: UIImage] = [:]
                for filter in ScanFilter.allCases {
                    if let cg = ImageProcessor.process(small, quad: quad, rotation: rotation, filter: filter) {
                        result[filter] = UIImage(cgImage: cg)
                    }
                }
                return result
            }.value
        }
    }
}

/// Pinch to zoom, drag to pan while zoomed, double-tap to toggle 2×.
struct ZoomableView<Content: View>: View {
    @Binding var isZoomed: Bool
    @ViewBuilder let content: Content

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value.magnification, 1), 5)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 { reset() }
                    }
            )
            .simultaneousGesture(
                scale > 1
                    ? DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                    : nil
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2
                        lastScale = 2
                    }
                }
            }
            .onChange(of: scale > 1) { _, zoomed in isZoomed = zoomed }
            .onDisappear {
                reset()
                isZoomed = false
            }
            .accessibilityIdentifier("zoomablePage")
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

struct AnswerTarget: Identifiable {
    let pageID: UUID
    let title: String
    var id: UUID { pageID }
}

struct TextSheetContent: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// Shows recognized text with copy and share.
struct TextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let content: TextSheetContent

    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if content.text.isEmpty {
                    ContentUnavailableView("No Text Found", systemImage: "text.magnifyingglass",
                                           description: Text("DocSnap couldn't read any text on this page."))
                } else {
                    ScrollView {
                        Text(content.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .accessibilityIdentifier("recognizedText")
                }
            }
            .navigationTitle(content.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = content.text
                        copied = true
                    }
                    .disabled(content.text.isEmpty)
                    ShareLink(item: content.text)
                        .disabled(content.text.isEmpty)
                }
            }
        }
    }
}
