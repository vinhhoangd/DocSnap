import SwiftUI

/// Navigation targets inside the main stack.
enum Route: Hashable {
    case document(UUID)
    case page(documentID: UUID, pageID: UUID)
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
    var title: String { self == .grid ? "Icons" : "List" }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case modified
    case created
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .name: "Name"
        }
    }
}

struct LibraryView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(Settings.defaultFilterKey) private var defaultFilter: ScanFilter = .magicColor
    @AppStorage(Settings.pdfPageSizeKey) private var pageSize: PDFPageSize = .auto
    @AppStorage(Settings.searchablePDFKey) private var searchablePDF = true
    @AppStorage(Settings.libraryLayoutKey) private var layout: LibraryLayout = .grid
    @AppStorage(Settings.librarySortKey) private var sort: LibrarySort = .modified

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
                .navigationTitle("Documents")
                .searchable(text: $query, prompt: "Search documents and text")
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) {
                    if !store.documents.isEmpty { actionBar }
                }
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
        .alert("Rename Document", isPresented: $showRename, presenting: renaming) { doc in
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
            Button("Delete Document", role: .destructive) {
                Haptics.impact(.medium)
                withAnimation(reduceMotion ? nil : Theme.Motion.standard) { store.deleteDocument(doc.id) }
            }
        } message: { doc in
            Text("All \(doc.pageCountText) will be removed. This can't be undone.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Data

    private var visibleDocuments: [ScanDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matches = q.isEmpty ? store.documents : store.documents.filter {
            $0.title.range(of: q, options: options) != nil || $0.allText.range(of: q, options: options) != nil
        }
        switch sort {
        case .modified: return matches.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return matches.sorted { $0.createdAt > $1.createdAt }
        case .name: return matches.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// Date-based sections ("Today", "Yesterday", …) when sorted by date; one section by name.
    private var sections: [DocumentSection] {
        let docs = visibleDocuments
        guard sort != .name else { return [DocumentSection(title: nil, documents: docs)] }
        var result: [DocumentSection] = []
        for doc in docs {
            let title = DocumentSection.title(for: sort == .created ? doc.createdAt : doc.updatedAt)
            if result.last?.title == title {
                result[result.count - 1].documents.append(doc)
            } else {
                result.append(DocumentSection(title: title, documents: [doc]))
            }
        }
        return result
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.documents.isEmpty {
            emptyState
        } else if visibleDocuments.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if layout == .grid {
            grid
        } else {
            list
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("Scan Your First Document")
            } icon: {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
            }
        } description: {
            Text("DocSnap finds the edges, flattens the page and cleans it up. Everything stays on your iPhone.")
        } actions: {
            Button {
                captureSource = .camera
            } label: {
                Label("Scan Document", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.vertical, Theme.Space.xxs)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("emptyScanButton")
            Button("Import from Photos", systemImage: "photo.on.rectangle.angled") { captureSource = .photos }
                .accessibilityIdentifier("emptyImportButton")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                // Accessibility text sizes get one wide column so titles have room.
                columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 150, maximum: typeSize.isAccessibilitySize ? 600 : 220),
                                   spacing: Theme.Space.md, alignment: .top)],
                alignment: .leading,
                spacing: Theme.Space.lg
            ) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.documents) { doc in
                            NavigationLink(value: Route.document(doc.id)) {
                                DocumentCard(document: doc)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("documentRow")
                            .contextMenu { documentActions(doc) }
                        }
                    } header: {
                        if let title = section.title { SectionHeader(title: title) }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.xl)
            .motion(Theme.Motion.standard, value: visibleDocuments.map(\.id), reduceMotion: reduceMotion)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var list: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.documents) { doc in
                        NavigationLink(value: Route.document(doc.id)) {
                            DocumentRow(document: doc)
                        }
                        .accessibilityIdentifier("documentRow")
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { startDelete(doc) }
                            Button("Rename", systemImage: "pencil") { startRename(doc) }
                                .tint(.indigo)
                        }
                        .contextMenu { documentActions(doc) }
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func documentActions(_ doc: ScanDocument) -> some View {
        Button("Share PDF", systemImage: "square.and.arrow.up") { sharePDF(doc) }
        Button("Rename", systemImage: "pencil") { startRename(doc) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { startDelete(doc) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("View As", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("View Options", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("viewOptionsMenu")
            .disabled(store.documents.isEmpty)
        }
    }

    /// Floating primary actions in the thumb zone: Import (secondary) and Scan (primary).
    private var actionBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                captureSource = .photos
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3.weight(.medium))
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("Import from Photos")
            .accessibilityIdentifier("importPhotosButton")
            .floatingSecondaryStyle()

            Button {
                captureSource = .camera
            } label: {
                Label("Scan", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, Theme.Space.lg)
                    .frame(height: 52)
            }
            .accessibilityIdentifier("scanButton")
            .floatingPrimaryStyle()
        }
        .padding(.bottom, Theme.Space.xs)
        // Like system bars, the floating controls stop growing at the largest standard sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - Actions

    private func createDocument(_ pages: [DocumentStore.NewPage]) {
        busyMessage = pages.count == 1 ? "Saving page…" : "Saving \(pages.count) pages…"
        Task {
            defer { busyMessage = nil }
            do {
                let doc = try await store.createDocument(pages: pages, filter: defaultFilter)
                Haptics.success()
                path = [.document(doc.id)]
            } catch {
                Haptics.error()
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
                Haptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Sections

private struct DocumentSection: Identifiable {
    var title: String?
    var documents: [ScanDocument]
    var id: String { title ?? "all" }

    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return "Previous 7 Days"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Cells

/// Grid cell: the first page as a sheet of paper, page count badge, title and date.
private struct DocumentCard: View {
    let document: ScanDocument

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Color(.secondarySystemGroupedBackground)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let first = document.pages.first {
                        PageImageView(documentID: document.id, page: first, maxPixelSize: 480, contentMode: .fill)
                    } else {
                        Image(systemName: "doc")
                            .font(.largeTitle.weight(.light))
                            .foregroundStyle(.tertiary)
                    }
                }
                .paperStyle(radius: Theme.Radius.control)
                .overlay(alignment: .bottomTrailing) {
                    PageCountBadge(count: document.pages.count)
                        .padding(Theme.Space.xs)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.title), \(document.pageCountText), \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct PageCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.on.doc")
            Text(count == 1 ? "1 page" : "\(count) pages")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        // Solid scrim: white text stays ≥ 4.5:1 over a white page in both appearances.
        .background(Color.black.opacity(0.62), in: Capsule())
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        // An overlay on the thumbnail: keep it a badge, not a block (the card's label carries the info).
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityHidden(true)
    }
}

/// List row: small paper thumbnail, title, date and page count.
private struct DocumentRow: View {
    let document: ScanDocument

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Color(.secondarySystemGroupedBackground)
                .frame(width: 46, height: 60)
                .overlay {
                    if let first = document.pages.first {
                        PageImageView(documentID: document.id, page: first, maxPixelSize: 200, contentMode: .fill)
                    } else {
                        Image(systemName: "doc").foregroundStyle(.tertiary)
                    }
                }
                .paperStyle()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text("\(document.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(document.pageCountText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, Theme.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Floating button styles

private extension View {
    /// Liquid Glass on iOS 26; a tinted capsule with a soft shadow on earlier versions.
    @ViewBuilder
    func floatingPrimaryStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    func floatingSecondaryStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            buttonStyle(.plain)
                .foregroundStyle(.tint)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}
