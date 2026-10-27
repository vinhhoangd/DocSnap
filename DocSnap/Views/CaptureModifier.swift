import PhotosUI
import SwiftUI

enum CaptureSource: Identifiable {
    case camera
    case photos

    var id: Self { self }
}

/// Presents the document camera or the photo picker and hands back the captured pages.
/// Camera pages arrive already cropped by VisionKit; photo imports get automatic border detection.
struct CaptureModifier: ViewModifier {
    @Binding var source: CaptureSource?
    let onCapture: ([DocumentStore.NewPage]) -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCameraUnavailable = false
    @State private var cameraError: String?
    @State private var loadingPhotos = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: cameraPresented) {
                DocumentCameraView(
                    onFinish: { images in
                        source = nil
                        // VisionKit already found the borders and flattened the page.
                        let pages = images.map { DocumentStore.NewPage(image: $0, quad: .full) }
                        if !pages.isEmpty { onCapture(pages) }
                    },
                    onCancel: { source = nil },
                    onError: { error in
                        source = nil
                        cameraError = error.localizedDescription
                    }
                )
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: photosPresented,
                selection: $photoItems,
                maxSelectionCount: 50,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .compatible
            )
            .onChange(of: source) { _, newValue in
                if newValue == .camera, !DocumentCameraView.isSupported {
                    source = nil
                    showCameraUnavailable = true
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                loadPhotos(items)
            }
            .overlay {
                if loadingPhotos { BusyOverlay(message: "Importing…") }
            }
            .alert("Camera Unavailable", isPresented: $showCameraUnavailable) {
                Button("Import from Photos") { source = .photos }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Document scanning needs an iPhone camera. You can import photos of documents instead.")
            }
            .alert("Scan Failed", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cameraError ?? "")
            }
    }

    private var cameraPresented: Binding<Bool> {
        Binding(
            get: { source == .camera && DocumentCameraView.isSupported },
            set: { if !$0, source == .camera { source = nil } }
        )
    }

    private var photosPresented: Binding<Bool> {
        Binding(
            get: { source == .photos },
            set: { if !$0, source == .photos { source = nil } }
        )
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        loadingPhotos = true
        Task {
            var pages: [DocumentStore.NewPage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    pages.append(DocumentStore.NewPage(image: image, quad: nil))
                }
            }
            loadingPhotos = false
            if !pages.isEmpty { onCapture(pages) }
        }
    }
}

extension View {
    func capture(source: Binding<CaptureSource?>, onCapture: @escaping ([DocumentStore.NewPage]) -> Void) -> some View {
        modifier(CaptureModifier(source: source, onCapture: onCapture))
    }
}
