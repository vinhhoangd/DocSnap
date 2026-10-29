import AVFoundation
import SwiftUI

/// Full-screen document camera. A blue outline follows the page; holding it steady fills a
/// ring and then captures automatically (or tap the shutter). Multi-page: keep scanning, then Save.
struct ScannerView: View {
    @AppStorage(Settings.autoCaptureDelayKey) private var delay: AutoCaptureDelay = .oneAndHalf
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinish: ([DocumentStore.NewPage]) -> Void
    let onCancel: () -> Void

    struct CapturedPage: Identifiable {
        let id = UUID()
        let url: URL
        let quad: Quad?
    }

    @State private var camera = CameraController.shared
    @State private var pages: [CapturedPage] = []
    @State private var lastThumbnail: UIImage?
    @State private var flashOpacity = 0.0
    @State private var confirmDiscard = false
    @State private var captureError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                preview
                Spacer(minLength: 0)
                bottomBar
            }
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            camera.holdDuration = delay.seconds
            camera.onPhoto = { url, quad in didCapture(url: url, quad: quad) }
            camera.onCaptureFailed = { captureError = $0 }
            await camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: delay) { _, newValue in camera.holdDuration = newValue.seconds }
        .onChange(of: flashMode) { _, newValue in camera.flashMode = newValue }
        .confirmationDialog("Discard \(pages.count == 1 ? "1 scan" : "\(pages.count) scans")?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discardAndClose() }
            Button("Keep Scanning", role: .cancel) {}
        }
        .alert("Couldn't Capture", isPresented: Binding(get: { captureError != nil }, set: { if !$0 { captureError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(captureError ?? "")
        }
    }

    // MARK: - Preview + outline

    private var preview: some View {
        CameraPreview(session: camera.session)
            .aspectRatio(camera.frameAspect, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    outline(in: proxy.size)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) { hint.padding(.top, Theme.Space.sm) }
            .overlay { statusOverlay }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.horizontal, Theme.Space.xs)
    }

    @ViewBuilder
    private func outline(in size: CGSize) -> some View {
        // The border appears only once the phone is held still (never while it is moving).
        if let quad = camera.quad, camera.status == .running, showsOutline {
            let points = quad.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let color = outlineColor
            ZStack {
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .fill(color.opacity(camera.phase == .captured ? 0.08 : 0.18))
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                if case .holding(let progress) = camera.phase, camera.holdDuration > 0 {
                    HoldRing(progress: progress, color: color)
                        .position(centroid(points))
                }
            }
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: quad.points.map(\.x))
        }
    }

    private var showsOutline: Bool {
        switch camera.phase {
        case .holding, .ready: true
        // The saved page keeps a faint border only while the phone is still, never while moving on.
        case .captured: camera.isDeviceStill
        case .searching, .aligning: false
        }
    }

    private var outlineColor: Color {
        switch camera.phase {
        case .ready, .captured: .green
        default: .accentColor
        }
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
    }

    private var hint: some View {
        Text(hintText)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs - 2)
            .background(.black.opacity(0.55), in: Capsule())
            .accessibilityIdentifier("scannerHint")
            .animation(reduceMotion ? nil : Theme.Motion.quick, value: hintText)
    }

    private var hintText: String {
        guard camera.status == .running else { return "Starting camera…" }
        switch camera.phase {
        case .searching:
            return "Point the camera at a document"
        case .aligning:
            return "Hold your phone still"
        case .holding:
            return camera.holdDuration > 0 ? "Hold steady…" : "Tap the shutter to capture"
        case .ready:
            return "Capturing…"
        case .captured:
            return pages.isEmpty ? "Capturing…" : "Page \(pages.count) saved · point at the next page"
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .unauthorized:
            CameraMessage(icon: "camera.fill", title: "Camera Access Needed",
                          message: "Allow DocSnap to use the camera in Settings to scan documents.",
                          action: ("Open Settings", {
                              if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                          }))
        case .unavailable:
            CameraMessage(icon: "video.slash", title: "No Camera", message: "This device has no camera DocSnap can use.", action: nil)
        case .failed(let message):
            CameraMessage(icon: "exclamationmark.triangle", title: "Camera Problem", message: message,
                          action: ("Try Again", { Task { await camera.start() } }))
        case .interrupted:
            CameraMessage(icon: "pause.circle", title: "Camera Paused",
                          message: "Another app is using the camera. It resumes automatically.", action: nil)
        case .idle, .starting, .running:
            EmptyView()
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button {
                pages.isEmpty ? close() : (confirmDiscard = true)
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: Theme.minTarget, height: Theme.minTarget)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("scannerClose")
            .disabled(camera.isCapturing)

            Spacer()

            Menu {
                Picker("Auto-Capture", selection: $delay) {
                    ForEach(AutoCaptureDelay.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(delay == .manual ? "Manual" : "Auto \(delay.seconds.formatted())s",
                      systemImage: delay == .manual ? "hand.tap" : "timer")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Theme.Space.sm)
                    .frame(height: 32)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            .accessibilityIdentifier("autoCaptureMenu")

            Spacer()

            Button {
                flashMode = nextFlashMode
            } label: {
                Image(systemName: flashIcon)
                    .font(.body.weight(.semibold))
                    .frame(width: Theme.minTarget, height: Theme.minTarget)
            }
            .accessibilityLabel("Flash \(flashLabel)")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.top, Theme.Space.xs)
    }

    /// Last captured page with the page count badge.
    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let lastThumbnail {
                    Image(uiImage: lastThumbnail).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 52, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 1))
            if !pages.isEmpty {
                Text("\(pages.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 8, y: -8)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            // Tap the thumbnail to take back the last page (e.g. captured too early).
            Menu {
                Button("Remove Page \(pages.count)", systemImage: "trash", role: .destructive) { removeLastPage() }
            } label: {
                thumbnail
            }
            .disabled(pages.isEmpty || camera.isCapturing)
            .frame(width: 80, alignment: .leading)
            .accessibilityLabel(pages.isEmpty ? "No pages yet" : "\(pages.count) pages scanned")
            .accessibilityHint(pages.isEmpty ? "" : "Opens an option to remove the last page")
            .accessibilityIdentifier("scannerThumbnail")

            Spacer()

            Button {
                camera.capture()
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 62, height: 62)
                        .scaleEffect(camera.isCapturing ? 0.85 : 1)
                }
            }
            .buttonStyle(.pressable)
            .disabled(camera.status != .running || camera.isCapturing)
            .accessibilityLabel("Take Photo")
            .accessibilityIdentifier("shutterButton")

            Spacer()

            Button {
                save()
            } label: {
                Text("Save")
                    .font(.headline)
                    .padding(.horizontal, Theme.Space.md)
                    .frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            // Wait for an in-flight photo, or it would be lost (and its file left behind).
            .disabled(pages.isEmpty || camera.isCapturing)
            .frame(width: 80, alignment: .trailing)
            .accessibilityIdentifier("scannerSave")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    // MARK: - Flash

    @State private var flashMode: AVCaptureDevice.FlashMode = .off

    private var nextFlashMode: AVCaptureDevice.FlashMode {
        switch flashMode {
        case .off: .auto
        case .auto: .on
        default: .off
        }
    }

    private var flashIcon: String {
        switch flashMode {
        case .on: "bolt.fill"
        case .auto: "bolt.badge.automatic"
        default: "bolt.slash"
        }
    }

    private var flashLabel: String {
        switch flashMode {
        case .on: "On"
        case .auto: "Auto"
        default: "Off"
        }
    }

    // MARK: - Actions

    private func didCapture(url: URL, quad: Quad?) {
        pages.append(CapturedPage(url: url, quad: quad))
        Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: "Page \(pages.count) captured")
        if !reduceMotion {
            flashOpacity = 0.7
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
        Task {
            let thumbnail = await Task.detached(priority: .utility) {
                DocumentStore.loadImage(at: url, maxPixelSize: 200)
            }.value
            // A slower load must not overwrite a newer (or removed) page's thumbnail.
            if pages.last?.url == url { lastThumbnail = thumbnail }
        }
    }

    private func removeLastPage() {
        guard let last = pages.popLast() else { return }
        try? FileManager.default.removeItem(at: last.url)
        camera.rearm()
        Haptics.impact(.medium)
        UIAccessibility.post(notification: .announcement, argument: "Page removed")
        lastThumbnail = nil
        guard let previous = pages.last?.url else { return }
        Task {
            let thumbnail = await Task.detached(priority: .utility) {
                DocumentStore.loadImage(at: previous, maxPixelSize: 200)
            }.value
            if pages.last?.url == previous { lastThumbnail = thumbnail }
        }
    }

    private func save() {
        camera.stop()
        let newPages = pages.map { DocumentStore.NewPage(fileURL: $0.url, quad: nil, quadHint: $0.quad) }
        pages = []
        onFinish(newPages)
    }

    private func discardAndClose() {
        for page in pages { try? FileManager.default.removeItem(at: page.url) }
        pages = []
        close()
    }

    private func close() {
        camera.stop()
        onCancel()
    }
}

/// The ring that fills while the page is held steady.
private struct HoldRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 54, height: 54)
        .background(.black.opacity(0.25), in: Circle())
        .accessibilityHidden(true)
    }
}

private struct CameraMessage: View {
    let icon: String
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
    }
}

/// Hosts the AVFoundation preview layer (aspect-fit, so overlay coordinates match the frame).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } // swiftlint:disable:this force_cast

        /// The layer's connection only exists once the session has an input, so keep it upright on every layout.
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90),
               connection.videoRotationAngle != 90 {
                connection.videoRotationAngle = 90
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}
