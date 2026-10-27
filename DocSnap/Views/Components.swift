import SwiftUI
import UIKit
import VisionKit

/// Loads a page's finished image asynchronously (downsampled + cached).
struct PageImageView: View {
    @Environment(DocumentStore.self) private var store
    let documentID: UUID
    let page: ScanPage
    var maxPixelSize: CGFloat? = 400
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(ProgressView())
            }
        }
        .task(id: "\(page.id)-\(page.version)-\(Int(maxPixelSize ?? 0))") {
            image = await store.image(for: page, in: documentID, maxPixelSize: maxPixelSize)
        }
    }
}

/// UIKit share sheet: AirDrop, Files, Mail, Messages, Print, Save Image…
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so a list of files can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Apple's document camera: live edge detection, auto-capture, perspective correction, multi-page.
struct DocumentCameraView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView

        init(_ parent: DocumentCameraView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
        }
    }
}

/// Full-screen "working…" overlay.
struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(message).font(.headline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityIdentifier("busyOverlay")
    }
}

/// User preferences shared across screens.
enum Settings {
    static let defaultFilterKey = "defaultFilter"
    static let pdfPageSizeKey = "pdfPageSize"
    static let searchablePDFKey = "searchablePDF"
}
