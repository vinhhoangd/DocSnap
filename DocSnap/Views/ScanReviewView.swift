import SwiftUI

/// "Adjust Borders": after scanning or importing, shows each page with its detected border so the
/// user can drag the corners (or edges) onto the paper before anything is saved.
///
/// Corners are detected up front for every page (on a 2048 px copy, the same orientation the store
/// saves), so the page strip and Save are ready quickly; only the page on screen keeps a full image
/// in memory.
struct ScanReviewView: View {
    struct Page: Identifiable {
        let id = UUID()
        let url: URL
        /// The corners already chosen (e.g. adjusted before going back to the camera).
        var quad: Quad?
        /// The live camera's outline, used when detection on the photo finds nothing.
        var hint: Quad?
    }

    enum LeadingAction {
        /// Back to the camera, keeping the pages and adjustments.
        case back
        /// Drop the batch (photo imports: the photos stay in the library).
        case cancel
    }

    let leadingAction: LeadingAction
    /// Called with one quad per page, in order.
    let onSave: ([Quad]) -> Void
    /// Called with the quads so far (`nil` = not reviewed yet) when the user leaves without saving.
    let onLeave: ([Quad?]) -> Void

    @State private var pages: [Page]
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var index = 0
    @State private var image: UIImage?
    @State private var imageID: UUID?
    @State private var detecting = false
    @State private var notFound = false
    @State private var prepared = false
    /// Set on the first Save/Back tap: the screen is closing, so a second tap must not act again.
    @State private var finished = false

    init(pages: [Page], leadingAction: LeadingAction, onSave: @escaping ([Quad]) -> Void, onLeave: @escaping ([Quad?]) -> Void) {
        _pages = State(initialValue: pages)
        self.leadingAction = leadingAction
        self.onSave = onSave
        self.onLeave = onLeave
    }

    /// Longest side of the image shown and detected on.
    static let workingSize: CGFloat = 2048

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editor
                if pages.count > 1 { strip }
                CropActionsBar(detecting: detecting, canDetect: image != nil,
                               onAutoDetect: autoDetect, onFullPage: { setQuad(.full, animated: true) })
            }
            .background(Color.black)
            .navigationTitle(pages.count > 1 ? "Page \(index + 1) of \(pages.count)" : "Adjust Borders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(leadingAction == .back ? "Back" : "Cancel") {
                        guard !finished else { return }
                        finished = true
                        onLeave(pages.map(\.quad))
                    }
                    .disabled(finished)
                    .accessibilityIdentifier("reviewBackButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !finished else { return }
                        finished = true
                        onSave(pages.map { $0.quad ?? $0.hint ?? .full })
                    }
                    .fontWeight(.semibold)
                    .disabled(finished || !prepared || pages.contains { !($0.quad ?? .full).isValid })
                    .accessibilityIdentifier("reviewSaveButton")
                }
            }
            .alert("No Document Found", isPresented: $notFound) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Drag the corners to the edges of the paper.")
            }
        }
        .preferredColorScheme(.dark)
        .task { await prepare() }
        .task(id: index) { await loadImage() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var editor: some View {
        if let image, imageID == pages[index].id, let quad = pages[index].quad {
            CropEditor(image: image, quad: Binding(get: { quad }, set: { setQuad($0, animated: false) }))
                .id(pages[index].id)
                .overlay(alignment: .top) {
                    if !quad.isValid {
                        Text("Corners crossed — drag them back around the page")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Space.sm)
                            .padding(.vertical, Theme.Space.xs - 2)
                            .background(.red.opacity(0.8), in: Capsule())
                            .padding(.top, Theme.Space.xs)
                    }
                }
        } else {
            ProgressView().tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Finding the page border")
        }
    }

    private var strip: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                        Button {
                            index = i
                            Haptics.selection()
                        } label: {
                            thumbnail(for: page, selected: i == index, number: i + 1)
                        }
                        .buttonStyle(.plain)
                        .id(page.id)
                        .accessibilityLabel("Page \(i + 1)")
                        .accessibilityAddTraits(i == index ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.xs)
            }
            .onChange(of: index) { _, newValue in
                withAnimation(Theme.Motion.quick) { scroller.scrollTo(pages[newValue].id, anchor: .center) }
            }
        }
        .background(Color.black)
        .accessibilityIdentifier("reviewStrip")
    }

    private func thumbnail(for page: Page, selected: Bool, number: Int) -> some View {
        Group {
            if let thumb = thumbnails[page.id] {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 44, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.3), lineWidth: selected ? 2.5 : 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(2)
        }
        .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
    }

    // MARK: - Actions

    private func setQuad(_ quad: Quad, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        if animated {
            withAnimation(.snappy) { pages[index].quad = quad }
        } else {
            pages[index].quad = quad
        }
    }

    /// Detects every page that has no corners yet and makes the strip's thumbnails.
    private func prepare() async {
        let size = Self.workingSize
        for i in pages.indices {
            // Leaving the screen cancels this task: don't keep running Vision next to the live camera.
            if Task.isCancelled { return }
            let page = pages[i]
            let result = await Task.detached(priority: .userInitiated) { () -> (Quad?, UIImage?) in
                autoreleasepool {
                    let thumb = ImageProcessor.loadCGImage(at: page.url, maxPixelSize: 160).map { UIImage(cgImage: $0) }
                    // Pages adjusted earlier keep their corners; only new ones need the 2048 px decode.
                    if let quad = page.quad { return (quad, thumb) }
                    let quad = ImageProcessor.loadCGImage(at: page.url, maxPixelSize: size).flatMap(DocumentDetector.detectSync(in:))
                    return (quad, thumb)
                }
            }.value
            guard !Task.isCancelled, pages.indices.contains(i), pages[i].id == page.id else { return }
            if pages[i].quad == nil { pages[i].quad = result.0 ?? page.hint.flatMap { $0.isValid ? $0 : nil } ?? .full }
            if let thumb = result.1 { thumbnails[page.id] = thumb }
        }
        prepared = true
    }

    /// Loads the page on screen (and drops the previous one, so memory stays at one full image).
    private func loadImage() async {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        if imageID == page.id { return }
        image = nil
        let size = Self.workingSize
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageProcessor.loadCGImage(at: page.url, maxPixelSize: size).map { UIImage(cgImage: $0) }
        }.value
        guard !Task.isCancelled, pages.indices.contains(index), pages[index].id == page.id else { return }
        image = loaded
        imageID = page.id
    }

    private func autoDetect() {
        guard let cg = image?.cgImage else { return }
        let pageID = pages[index].id
        detecting = true
        Task {
            let found = await DocumentDetector.detect(in: cg)
            detecting = false
            guard pages.indices.contains(index), pages[index].id == pageID else { return }
            if let found {
                Haptics.success()
                setQuad(found, animated: true)
            } else {
                Haptics.warning()
                notFound = true
            }
        }
    }
}
