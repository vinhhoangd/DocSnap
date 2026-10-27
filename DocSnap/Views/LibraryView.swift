import SwiftUI

/// Navigation targets inside the main stack.
enum Route: Hashable {
    case document(UUID)
    case page(documentID: UUID, pageID: UUID)
}

struct LibraryView: View {
    @Environment(DocumentStore.self) private var store
    @AppStorage(Settings.defaultFilterKey) private var defaultFilter: ScanFilter = .magicColor
    @AppStorage(Settings.pdfPageSizeKey) private var pageSize: PDFPageSize = .auto
    @AppStorage(Settings.searchablePDFKey) private var searchablePDF = true

    @State private var path: [Route] = []
    @State private var query = ""
    @State private var captureSource: CaptureSource?
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var renaming: ScanDocument?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var deleting: ScanDocument?
    @State private var showDelete = false
    @State private var shareItem: ShareItem?
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("DocSnap")
                .searchable(text: $query, prompt: "Search titles and text")
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { scanButton }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .document(let id):
                        DocumentDetailView(documentID: id)
                    case .page(let documentID, let pageID):
                        PageViewer(documentID: documentID, initialPageID: pageID)
                    }
                }
        }
        .capture(source: $captureSource) { pages in
            createDocument(pages)
        }
        .overlay {
            if let busyMessage { BusyOverlay(message: busyMessage) }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls) { shareItem = nil }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Rename", isPresented: $showRename, presenting: renaming) { doc in
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { try? store.rename(doc.id, to: renameText) }
        }
        .confirmationDialog(
            "Delete \"\(deleting?.title ?? "")\"?",
            isPresented: $showDelete,
            titleVisibility: .visible,
            presenting: deleting
        ) { doc in
            Button("Delete", role: .destructive) { store.deleteDocument(doc.id) }
        } message: { _ in
            Text("This can't be undone.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Content

    private var filtered: [ScanDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.documents }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return store.documents.filter {
            $0.title.range(of: q, options: options) != nil || $0.allText.range(of: q, options: options) != nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.documents.isEmpty {
            ContentUnavailableView {
                Label("No Documents Yet", systemImage: "doc.viewfinder")
            } description: {
                Text("Tap Scan to capture a document with the camera, or import a photo.")
            }
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(filtered) { doc in
                    NavigationLink(value: Route.document(doc.id)) {
                        DocumentRow(document: doc)
                    }
                    .accessibilityIdentifier("documentRow")
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { startDelete(doc) }
                        Button("Rename", systemImage: "pencil") { startRename(doc) }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button("Share PDF", systemImage: "square.and.arrow.up") { sharePDF(doc) }
                        Button("Rename", systemImage: "pencil") { startRename(doc) }
                        Button("Delete", systemImage: "trash", role: .destructive) { startDelete(doc) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Import from Photos", systemImage: "photo.on.rectangle") { captureSource = .photos }
                .accessibilityIdentifier("importPhotosButton")
        }
    }

    private var scanButton: some View {
        Button {
            captureSource = .camera
        } label: {
            Label("Scan", systemImage: "camera.viewfinder")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .shadow(radius: 6, y: 3)
        .padding(.bottom, 8)
        .accessibilityIdentifier("scanButton")
    }

    // MARK: - Actions

    private func createDocument(_ pages: [DocumentStore.NewPage]) {
        busyMessage = "Saving…"
        Task {
            defer { busyMessage = nil }
            do {
                let doc = try await store.createDocument(pages: pages, filter: defaultFilter)
                path = [.document(doc.id)]
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startRename(_ doc: ScanDocument) {
        renameText = doc.title
        renaming = doc
        showRename = true
    }

    private func startDelete(_ doc: ScanDocument) {
        deleting = doc
        showDelete = true
    }

    private func sharePDF(_ doc: ScanDocument) {
        busyMessage = "Preparing PDF…"
        Task {
            defer { busyMessage = nil }
            do {
                let url = try await store.exportPDF(doc.id, pageSize: pageSize, searchable: searchablePDF)
                shareItem = ShareItem(urls: [url])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DocumentRow: View {
    let document: ScanDocument

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let first = document.pages.first {
                    PageImageView(documentID: document.id, page: first, maxPixelSize: 200, contentMode: .fill)
                } else {
                    Image(systemName: "doc").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(document.pages.count == 1 ? "1 page" : "\(document.pages.count) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
