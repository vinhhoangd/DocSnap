import SwiftUI

struct DocumentDetailView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.defaultFilterKey) private var defaultFilter: ScanFilter = .magicColor
    @AppStorage(Settings.pdfPageSizeKey) private var pageSize: PDFPageSize = .auto
    @AppStorage(Settings.searchablePDFKey) private var searchablePDF = true

    let documentID: UUID

    @State private var captureSource: CaptureSource?
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showReorder = false
    @State private var showDeleteDocument = false
    @State private var allText: TextSheetContent?

    private var document: ScanDocument? { store.document(documentID) }

    var body: some View {
        Group {
            if let document {
                pageGrid(document)
                    .navigationTitle(document.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbar(document) }
            } else {
                ContentUnavailableView("Document Deleted", systemImage: "trash")
            }
        }
        .capture(source: $captureSource) { pages in
            addPages(pages)
        }
        .overlay {
            if let busyMessage { BusyOverlay(message: busyMessage) }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
        }
        .sheet(isPresented: $showReorder) {
            ReorderPagesView(documentID: documentID)
        }
        .sheet(item: $allText) { content in
            TextSheet(content: content)
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { try? store.rename(documentID, to: renameText) }
        }
        .confirmationDialog("Delete this document?", isPresented: $showDeleteDocument, titleVisibility: .visible) {
            Button("Delete Document", role: .destructive) {
                store.deleteDocument(documentID)
                dismiss()
            }
        } message: {
            Text("All pages will be removed. This can't be undone.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Grid

    private func pageGrid(_ document: ScanDocument) -> some View {
        ScrollView {
            if document.pages.isEmpty {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc")
                } description: {
                    Text("Add pages with the camera or from Photos.")
                }
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        NavigationLink(value: Route.page(documentID: documentID, pageID: page.id)) {
                            VStack(spacing: 6) {
                                PageImageView(documentID: documentID, page: page, maxPixelSize: 500)
                                    .frame(height: 200)
                                    .frame(maxWidth: .infinity)
                                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                                Text("\(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pageCell")
                    }
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { bottomBar(document) }
    }

    private func bottomBar(_ document: ScanDocument) -> some View {
        HStack(spacing: 12) {
            Menu {
                Button("Scan Pages", systemImage: "camera.viewfinder") { captureSource = .camera }
                Button("Import from Photos", systemImage: "photo.on.rectangle") { captureSource = .photos }
            } label: {
                Label("Add", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("addPagesMenu")

            Menu {
                Button("Share PDF", systemImage: "doc.richtext") { sharePDF() }
                Button("Share Images (JPEG)", systemImage: "photo.stack") { shareImages() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } primaryAction: {
                sharePDF()
            }
            .buttonStyle(.borderedProminent)
            .disabled(document.pages.isEmpty)
            .accessibilityIdentifier("shareButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private func toolbar(_ document: ScanDocument) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    renameText = document.title
                    showRename = true
                }
                Button("Reorder Pages", systemImage: "arrow.up.arrow.down") { showReorder = true }
                    .disabled(document.pages.count < 2)
                Button("Extract All Text", systemImage: "text.viewfinder") { extractAllText() }
                    .disabled(document.pages.isEmpty)
                Divider()
                Button("Delete Document", systemImage: "trash", role: .destructive) { showDeleteDocument = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("documentMenu")
        }
    }

    // MARK: - Actions

    private func addPages(_ pages: [DocumentStore.NewPage]) {
        busyMessage = "Saving…"
        Task {
            defer { busyMessage = nil }
            do {
                try await store.addPages(pages, to: documentID, filter: defaultFilter)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sharePDF() {
        busyMessage = searchablePDF ? "Reading text & building PDF…" : "Building PDF…"
        Task {
            defer { busyMessage = nil }
            do {
                let url = try await store.exportPDF(documentID, pageSize: pageSize, searchable: searchablePDF)
                shareItem = ShareItem(urls: [url])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func shareImages() {
        do {
            shareItem = ShareItem(urls: try store.exportImages(documentID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extractAllText() {
        busyMessage = "Reading text…"
        Task {
            await store.recognizeMissingText(in: documentID)
            busyMessage = nil
            let text = store.document(documentID)?.allText ?? ""
            allText = TextSheetContent(title: document?.title ?? "Text", text: text)
        }
    }
}

/// Drag to reorder, swipe to delete.
struct ReorderPagesView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID

    var body: some View {
        NavigationStack {
            List {
                if let doc = store.document(documentID) {
                    ForEach(Array(doc.pages.enumerated()), id: \.element.id) { index, page in
                        HStack(spacing: 14) {
                            PageImageView(documentID: documentID, page: page, maxPixelSize: 160)
                                .frame(width: 44, height: 58)
                            Text("Page \(index + 1)")
                        }
                    }
                    .onMove { source, destination in
                        try? store.movePages(in: documentID, fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { doc.pages[$0].id }
                        for id in ids { try? store.deletePage(id, from: documentID) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
