import AVFoundation
import PhotosUI
import SwiftUI
import VisionKit

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
    @AppStorage(Settings.scannerKey) private var scanner: ScannerKind = .docsnap

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCameraUnavailable = false
    @State private var cameraError: String?
    @State private var showCameraDenied = false
    @State private var importMessage: String?
    @State private var loading = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: cameraPresented) { cameraCover }
            .photosPicker(
                isPresented: photosPresented,
                selection: $photoItems,
                maxSelectionCount: 50,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .compatible
            )
            .onChange(of: source) { _, newValue in
                guard newValue == .camera else { return }
                if !cameraSupported {
                    source = nil
                    showCameraUnavailable = true
                } else if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video)) {
                    source = nil
                    showCameraDenied = true
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                loadPhotos(items)
            }
            .overlay {
                if loading { BusyOverlay(message: "Importing…") }
            }
            .alert("Camera Access Needed", isPresented: $showCameraDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow DocSnap to use the camera in Settings to scan documents.")
            }
            .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
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

    @ViewBuilder
    private var cameraCover: some View {
        switch scanner {
        case .docsnap:
            ScannerView(
                onFinish: { pages in
                    source = nil
                    if !pages.isEmpty { onCapture(pages) }
                },
                onCancel: { source = nil }
            )
        case .apple:
            DocumentCameraView(
                onFinish: { scan in
                    source = nil
                    savePages(of: scan)
                },
                onCancel: { source = nil },
                onError: { _ in
                    source = nil
                    cameraError = "The camera couldn't start. Close other apps that use the camera and try again."
                }
            )
            .ignoresSafeArea()
        }
    }

    private var cameraPresented: Binding<Bool> {
        Binding(
            get: {
                source == .camera && cameraSupported
                    && ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
            },
            set: { if !$0, source == .camera { source = nil } }
        )
    }

    private var cameraSupported: Bool {
        switch scanner {
        case .docsnap: CameraController.isCameraAvailable
        case .apple: DocumentCameraView.isSupported
        }
    }

    private var photosPresented: Binding<Bool> {
        Binding(
            get: { source == .photos },
            set: { if !$0, source == .photos { source = nil } }
        )
    }

    /// Writes each VisionKit page to a temp JPEG off the main thread, one page in memory at a time.
    private func savePages(of scan: VNDocumentCameraScan) {
        loading = true
        Task {
            let urls = await Task.detached(priority: .userInitiated) { () -> [URL] in
                let folder = DocumentStore.captureDirectory
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls: [URL] = []
                for index in 0..<scan.pageCount {
                    autoreleasepool {
                        let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
                        if let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.92),
                           (try? data.write(to: url)) != nil {
                            urls.append(url)
                        }
                    }
                }
                return urls
            }.value
            loading = false
            // VisionKit already found the borders and flattened each page.
            let pages = urls.map { DocumentStore.NewPage(fileURL: $0, quad: .full) }
            if pages.count < scan.pageCount {
                importMessage = "\(scan.pageCount - pages.count) page(s) couldn't be saved."
            }
            if !pages.isEmpty { onCapture(pages) }
        }
    }

    /// Copies the picked photos' encoded data to temp files without decoding them.
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        loading = true
        Task {
            let folder = DocumentStore.captureDirectory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var pages: [DocumentStore.NewPage] = []
            var failed = 0
            for item in items {
                let url = folder.appendingPathComponent(UUID().uuidString)
                if let data = try? await item.loadTransferable(type: Data.self), UIImage(data: data) != nil,
                   (try? data.write(to: url)) != nil {
                    pages.append(DocumentStore.NewPage(fileURL: url, quad: nil))
                } else {
                    failed += 1
                }
            }
            loading = false
            if failed > 0 {
                importMessage = failed == items.count
                    ? "The selected photos couldn't be imported. If they're stored in iCloud, check your connection and try again."
                    : "\(failed) of \(items.count) photos couldn't be imported."
            }
            if !pages.isEmpty { onCapture(pages) }
        }
    }
}

extension View {
    func capture(source: Binding<CaptureSource?>, onCapture: @escaping ([DocumentStore.NewPage]) -> Void) -> some View {
        modifier(CaptureModifier(source: source, onCapture: onCapture))
    }
}
