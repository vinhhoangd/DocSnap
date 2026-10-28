import SwiftUI

struct DocumentDetailView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.defaultFilterKey) private var defaultFilter: ScanFilter = .magicColor
    @AppStorage(Settings.pdfPageSizeKey) private var pageSize: PDFPageSize = .auto
    @AppStorage(Settings.searchablePDFKey) private var searchablePDF = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            ShareSheet(items: item.urls) { shareItem = nil }
        }
        .sheet(isPresented: $showReorder) {
            ReorderPagesView(documentID: documentID)
        }
        .sheet(item: $allText) { content in
            TextSheet(content: content)
        }
        .alert("Rename Document", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { try? store.rename(documentID, to: renameText) }
        }
        .confirmationDialog("Delete this document?", isPresented: $showDeleteDocument, titleVisibility: .visible) {
            Button("Delete Document", role: .destructive) {
                Haptics.impact(.medium)
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
                } actions: {
                    Button("Scan Pages", systemImage: "camera.viewfinder") { captureSource = .camera }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
                .accessibilityIdentifier("noPagesView")
                .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("\(document.pageCountText) · Edited \(document.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Space.xxs)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.md)], spacing: Theme.Space.lg) {
                        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                            NavigationLink(value: Route.page(documentID: documentID, pageID: page.id)) {
                                PageCell(documentID: documentID, page: page, number: index + 1)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("pageCell")
                            .contextMenu { pageActions(page) }
                        }
                    }
                }
                .padding(Theme.Space.md)
                .motion(Theme.Motion.standard, value: document.pages.map(\.id), reduceMotion: reduceMotion)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func pageActions(_ page: ScanPage) -> some View {
        Button("Rotate", systemImage: "rotate.right") {
            Haptics.impact()
            Task { try? await store.editPage(page.id, in: documentID) { $0.rotation += 1 } }
        }
        Divider()
        Button("Delete Page", systemImage: "trash", role: .destructive) {
            Haptics.impact(.medium)
            try? store.deletePage(page.id, from: documentID)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ document: ScanDocument) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    renameText = document.title
                    showRename = true
                }
                .accessibilityIdentifier("renameMenuItem")
                Button("Reorder Pages", systemImage: "arrow.up.arrow.down") { showReorder = true }
                    .accessibilityIdentifier("reorderMenuItem")
                    .disabled(document.pages.count < 2)
                Button("Share Images (JPEG)", systemImage: "photo.stack") { shareImages() }
                    .disabled(document.pages.isEmpty)
                Button("Extract All Text", systemImage: "text.viewfinder") { extractAllText() }
                    .accessibilityIdentifier("extractTextMenuItem")
                    .disabled(document.pages.isEmpty)
                Divider()
                Button("Delete Document", systemImage: "trash", role: .destructive) { showDeleteDocument = true }
                    .accessibilityIdentifier("deleteDocumentMenuItem")
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("documentMenu")
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                Button("Scan Pages", systemImage: "camera.viewfinder") { captureSource = .camera }
                Button("Import from Photos", systemImage: "photo.on.rectangle.angled") { captureSource = .photos }
            } label: {
                Label("Add Pages", systemImage: "plus")
            }
            .accessibilityIdentifier("addPagesMenu")
        }
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        } else {
            ToolbarItem(placement: .bottomBar) { Spacer() }
        }
        ToolbarItem(placement: .bottomBar) {
            // The main task gets the one prominent control (HIG: prominent style for the key action).
            Button {
                sharePDF()
            } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.semibold)
                    .padding(.horizontal, Theme.Space.xs)
            }
            .disabled(document.pages.isEmpty)
            .accessibilityIdentifier("shareButton")
            .prominentToolbarButton()
        }
    }

    // MARK: - Actions

    private func addPages(_ pages: [DocumentStore.NewPage]) {
        busyMessage = "Saving…"
        Task {
            defer { busyMessage = nil }
            do {
                try await store.addPages(pages, to: documentID, filter: defaultFilter)
                Haptics.success()
            } catch {
                Haptics.error()
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
                Haptics.error()
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
                        HStack(spacing: Theme.Space.sm) {
                            PageImageView(documentID: documentID, page: page, maxPixelSize: 160)
                                .paperStyle()
                                .frame(width: 44, height: 58)
                                .accessibilityHidden(true)
                            Text("Page \(index + 1)")
                        }
                        .accessibilityIdentifier("reorderRow")
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

/// A page thumbnail drawn as a sheet of paper with its number below.
private struct PageCell: View {
    let documentID: UUID
    let page: ScanPage
    let number: Int

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            PageImageView(documentID: documentID, page: page, maxPixelSize: 500)
                .paperStyle()
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.xs)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// The key action in a toolbar: `.prominent` glass on iOS 26, bordered-prominent before.
    @ViewBuilder
    func prominentToolbarButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}
