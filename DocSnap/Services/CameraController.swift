import AVFoundation
import Observation
import UIKit

/// DocSnap's document camera: live page detection on video frames, a hold-steady timer
/// before auto-capture, and full-resolution photos for the saved page.
@MainActor
@Observable
final class CameraController: NSObject {
    enum Status: Equatable {
        case idle
        case starting
        case running
        /// Another app, a call, or multitasking took the camera; resumes automatically.
        case interrupted
        case unauthorized
        case unavailable
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Smoothed page corners, normalized with a top-left origin in the upright camera frame.
    private(set) var quad: Quad?
    private(set) var phase: StabilityTracker.Phase = .searching
    /// Width / height of the upright camera frame (the preview uses the same aspect).
    private(set) var frameAspect: CGFloat = 3.0 / 4.0
    private(set) var isCapturing = false
    /// Whether the phone is currently held still (the border is only drawn then).
    private(set) var isDeviceStill = false
    var flashMode: AVCaptureDevice.FlashMode = .off

    /// Called on the main actor with the saved photo file and the corners seen when it was taken.
    @ObservationIgnored var onPhoto: ((URL, Quad?) -> Void)?
    @ObservationIgnored var onCaptureFailed: ((String) -> Void)?

    @ObservationIgnored nonisolated let session = AVCaptureSession()
    @ObservationIgnored nonisolated private let sessionQueue = DispatchQueue(label: "docsnap.camera.session")
    @ObservationIgnored nonisolated private let videoQueue = DispatchQueue(label: "docsnap.camera.video", qos: .userInitiated)
    // AVFoundation objects are configured on `sessionQueue` only.
    @ObservationIgnored nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private var tracker: StabilityTracker
    @ObservationIgnored private var smoother = QuadSmoother()
    /// Touched only on `sessionQueue`.
    @ObservationIgnored nonisolated(unsafe) private var configured = false
    @ObservationIgnored private var captureQuad: Quad?
    @ObservationIgnored private let motion = MotionMonitor()
    /// Touched only on `videoQueue`.
    @ObservationIgnored nonisolated(unsafe) private var lastAnalysis: CFTimeInterval = 0
    @ObservationIgnored nonisolated(unsafe) private var lastAspect: CGFloat = 0

    /// Analyse at most this many frames per second (detection is the expensive part).
    nonisolated static let analysisInterval: CFTimeInterval = 1.0 / 12.0

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastDetection: CFTimeInterval = 0

    /// One camera for the app: the scanner sheet reuses it, so the capture session is
    /// configured once instead of on every visit.
    static let shared = CameraController(holdDuration: AutoCaptureDelay.oneAndHalf.seconds)

    init(holdDuration: TimeInterval) {
        tracker = StabilityTracker(holdDuration: holdDuration)
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionInterrupted() }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionResumed() }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionFailed() }
            },
        ]
    }

    static var isCameraAvailable: Bool { bestCamera() != nil }

    var holdDuration: TimeInterval {
        get { tracker.holdDuration }
        set {
            tracker.holdDuration = newValue
            // Keep a recent capture in mind: changing the delay mustn't re-capture the page in view.
            tracker.restartHold()
            phase = tracker.phase
        }
    }

    /// Prefer the multi-camera virtual devices: on iPhone 13 Pro they switch to the
    /// ultra-wide (macro) lens automatically when the page is very close.
    nonisolated static func bestCamera() -> AVCaptureDevice? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return session.devices.first
    }

    // MARK: - Lifecycle

    func start() async {
        guard status != .running, status != .starting else { return }
        status = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .unauthorized
                return
            }
        default:
            status = .unauthorized
            return
        }
        guard Self.isCameraAvailable else {
            status = .unavailable
            return
        }
        let error: String? = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                continuation.resume(returning: configureAndRun())
            }
        }
        // stop() may have run while the session was starting.
        guard status == .starting else {
            sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
            return
        }
        if let error {
            status = .failed(error)
        } else {
            tracker.reset()
            smoother.reset()
            motion.start()
            status = .running
        }
    }

    private func sessionInterrupted() {
        guard status == .running else { return }
        status = .interrupted
        quad = nil
        // Don't forget a recent capture: after the interruption the same page may still be in view.
        tracker.restartHold()
        phase = tracker.phase
        smoother.reset()
    }

    private func sessionResumed() {
        if status == .interrupted { status = .running }
    }

    private func sessionFailed() {
        guard status == .running || status == .interrupted else { return }
        status = .starting
        sessionQueue.async { [weak self, session] in
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.status == .starting else { return }
                    self.status = running ? .running : .failed("The camera stopped unexpectedly. Close the scanner and try again.")
                }
            }
        }
    }

    func stop() {
        status = .idle
        quad = nil
        phase = .searching
        motion.stop()
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Runs on `sessionQueue`. Returns an error message, or nil on success.
    nonisolated private func configureAndRun() -> String? {
        if !configured {
            guard let device = Self.bestCamera() else { return "No camera is available." }
            session.beginConfiguration()
            session.sessionPreset = .photo
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                return "The camera couldn't be opened."
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .balanced
                // Full sensor resolution (12 MP on iPhone 13 Pro) for sharp text.
                if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    photoOutput.maxPhotoDimensions = largest
                }
            }
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            // The app is portrait-only: deliver upright frames and photos.
            for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
                if let connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            }
            session.commitConfiguration()
            configureFocus(device)
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? nil : "The camera didn't start. Close other camera apps and try again."
    }

    nonisolated private func configureFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        device.isSubjectAreaChangeMonitoringEnabled = true
        device.unlockForConfiguration()
    }

    private enum CameraError: Error { case cannotAddInput }

    // MARK: - Detection results (main actor)

    private func handle(detected: Quad?, aspect: CGFloat?, at time: CFTimeInterval) {
        if let aspect { frameAspect = aspect }
        guard status == .running else { return }
        // Keep drawing the last outline through single missed frames instead of flickering.
        if detected != nil { lastDetection = time }
        let smoothed: Quad?
        if detected == nil, time - lastDetection <= 0.35, let current = smoother.current {
            smoothed = current
        } else {
            smoothed = smoother.add(detected)
        }
        quad = smoothed
        let still = motion.isStill(at: time)
        if still != isDeviceStill { isDeviceStill = still }
        // The tracker sees real detection gaps right away (it has its own dropout tolerance);
        // only the on-screen outline is held through brief misses.
        let newPhase = tracker.update(quad: detected == nil ? nil : smoothed, deviceStill: still, at: time)
        phase = newPhase
        if newPhase == .ready { capture() }
    }

    // MARK: - Capture

    /// Takes a full-resolution photo now (shutter button or auto-capture).
    func capture() {
        guard status == .running, !isCapturing else { return }
        isCapturing = true
        captureQuad = quad
        tracker.didCapture(quad: quad, at: CACurrentMediaTime())
        phase = .captured
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .balanced
        let flashMode = flashMode
        sessionQueue.async { [self] in
            // capturePhoto raises an Objective-C exception without an active connection (e.g. interrupted).
            guard session.isRunning, photoOutput.connection(with: .video)?.isActive == true else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finishCapture(url: nil, error: "The camera isn't ready yet. Try again.") }
                }
                return
            }
            if photoOutput.supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
            if photoOutput.maxPhotoDimensions.width > 0 { settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// After the user removes the last page, let the same sheet be scanned again without moving.
    func rearm() {
        tracker.rearm()
    }

    private func finishCapture(url: URL?, error: String?) {
        isCapturing = false
        if let url {
            onPhoto?(url, captureQuad)
        } else {
            tracker.reset()
            phase = .searching
            onCaptureFailed?(error ?? "The photo couldn't be saved.")
        }
        captureQuad = nil
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysis >= Self.analysisInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        var aspect: CGFloat?
        if height > 0, abs(width / height - lastAspect) > 0.001 {
            lastAspect = width / height
            aspect = lastAspect
        }
        let detected = DocumentDetector.detectSync(in: pixelBuffer, orientation: .up)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.handle(detected: detected, aspect: aspect, at: now)
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        var savedURL: URL?
        var message: String?
        if error != nil {
            message = "The photo couldn't be taken."
        } else if let data = photo.fileDataRepresentation() {
            let folder = DocumentStore.captureDirectory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
            if (try? data.write(to: url, options: .atomic)) != nil { savedURL = url }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.finishCapture(url: savedURL, error: message)
            }
        }
    }
}
