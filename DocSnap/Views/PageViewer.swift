import SwiftUI

/// Swipe through pages and edit the current one: crop, rotate, filter, text, delete.
struct PageViewer: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let documentID: UUID
    let initialPageID: UUID

    @State private var currentPageID: UUID?
    @State private var showFilters = false
    @State private var cropping: ScanPage?
    @State private var textContent: TextSheetContent?
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 12)
                    .tag(Optional(page.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(isZoomed)
            .overlay {
                if working {
                    ProgressView().controlSize(.large)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            if showFilters, let page = currentPage {
                FilterStrip(documentID: documentID, page: page) { filter in
                    apply(to: page.id) { $0.filter = filter }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            editBar
        }
        .background(Color(.secondarySystemBackground))
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
                apply(to: page.id) { $0.quad = quad }
            }
        }
        .sheet(item: $textContent) { content in
            TextSheet(content: content)
        }
        .confirmationDialog("Delete this page?", isPresented: $showDeletePage, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) { deleteCurrentPage() }
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
                apply(to: page.id) { $0.rotation += 1 }
            }
            barButton("Filters", "camera.filters", id: "filtersButton", selected: showFilters) {
                withAnimation(.snappy) { showFilters.toggle() }
            }
            barButton("Text", "text.viewfinder", id: "textButton") {
                recognizeText()
            }
            barButton("Delete", "trash", id: "deletePageButton") {
                showDeletePage = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .background(.bar)
        .disabled(currentPage == nil)
    }

    private func barButton(_ title: String, _ icon: String, id: String, selected: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .accessibilityIdentifier(id)
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
            HStack(spacing: 12) {
                ForEach(ScanFilter.allCases) { filter in
                    Button {
                        if filter != page.filter { onSelect(filter) }
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let image = previews[filter] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.15)
                                }
                            }
                            .frame(width: 64, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(filter == page.filter ? Color.accentColor : .clear, lineWidth: 3)
                            )
                            Text(filter.displayName)
                                .font(.caption2.weight(filter == page.filter ? .bold : .regular))
                                .foregroundStyle(filter == page.filter ? Color.accentColor : Color.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filter-\(filter.rawValue)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
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
