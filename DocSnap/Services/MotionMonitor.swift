import CoreMotion
import QuartzCore

/// Tells the camera whether the phone is being held still (gyroscope + accelerometer).
/// Device motion needs no permission prompt. Without motion hardware (the simulator),
/// the phone always counts as still so the image-based checks still work.
@MainActor
final class MotionMonitor {
    private let manager = CMMotionManager()
    private var detector = StillnessDetector()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        detector.reset()
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let r = motion.rotationRate
            let a = motion.userAcceleration
            let rotation = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            let acceleration = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            // Same clock as the camera frames (CACurrentMediaTime).
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                self?.detector.add(rotationRate: rotation, acceleration: acceleration, at: now)
            }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        detector.reset()
    }

    func isStill(at time: TimeInterval) -> Bool {
        isAvailable ? detector.isStill(at: time) : true
    }
}
