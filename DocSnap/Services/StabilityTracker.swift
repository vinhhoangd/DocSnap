import CoreGraphics
import Foundation

/// Decides when the live camera should auto-capture.
///
/// A page is captured only when **the phone is held still** (gyroscope/accelerometer, see
/// `StillnessDetector`) **and** the detected page stays in place (every corner within
/// `moveTolerance`) for `holdDuration` seconds. While the phone moves, the phase is `.aligning`
/// and no border is shown.
///
/// After a capture, auto-capture re-arms only after a physical "next page" action, and never
/// within `minCaptureInterval`:
/// - the page left the frame for `capturedAbsence` seconds (paper swapped, hand over it), or
/// - the phone was really moved (`rearmMotion` seconds of movement in total) **and** the old page
///   either dropped out of view at some point or the outline now sits fully elsewhere
///   (every corner ≥ `newPlacementDistance` from the captured one). Re-aiming over the same
///   sheet does neither, so it is not captured twice.
/// Then a full still hold is needed again — and if that hold ends on the captured page's spot
/// while the page never left the view (e.g. one stray outline re-armed it), the tracker goes back
/// to `.captured` instead of capturing a duplicate.
struct StabilityTracker {
    enum Phase: Equatable {
        /// No page in view.
        case searching
        /// A page is in view but the phone is moving: no border, no countdown.
        case aligning
        /// Phone still and page in view; `progress` (0...1) fills while both stay that way.
        case holding(progress: Double)
        /// Steady long enough: capture now.
        case ready
        /// Just captured; waiting for the user to move on to the next page.
        case captured
    }

    /// Seconds the page must stay steady. 0 disables auto-capture (manual shutter only).
    var holdDuration: TimeInterval
    /// Largest corner movement (normalized) still counted as "steady".
    var moveTolerance: CGFloat = 0.03
    /// Vision misses the page on single frames; gaps shorter than this don't reset the hold.
    var dropoutTolerance: TimeInterval = 0.35
    /// No new auto-capture can start until this long after the previous capture.
    var minCaptureInterval: TimeInterval = 1.5
    /// After a capture, the page must be out of view this long to re-arm (paper swapped, hand over it).
    var capturedAbsence: TimeInterval = 0.8
    /// After a capture, the phone must have moved this long in total to re-arm.
    var rearmMotion: TimeInterval = 0.6
    /// With movement only: every corner must be at least this far (normalized) from where the
    /// captured page was, unless the page dropped out of view meanwhile.
    var newPlacementDistance: CGFloat = 0.15

    private(set) var phase: Phase = .searching
    private var anchor: Quad?
    private var anchorTime: TimeInterval = 0
    private var lastSeen: TimeInterval?
    private var lastUpdate: TimeInterval?
    private var captureTime: TimeInterval = -.infinity
    private var movedSinceCapture: TimeInterval = 0
    private var pageLeftSinceCapture = false
    private var pageLostSinceCapture = false
    private var capturedQuad: Quad?

    init(holdDuration: TimeInterval) {
        self.holdDuration = holdDuration
    }

    var isAutoCaptureEnabled: Bool { holdDuration > 0 }

    /// True once, after a capture, the user has taken the page away, or moved the phone and the
    /// old page dropped out of view. (Movement plus a fully new outline position is checked per frame.)
    var isRearmed: Bool { pageLeftSinceCapture || (movedSinceCapture >= rearmMotion && pageLostSinceCapture) }

    private func isRearmed(with quad: Quad?) -> Bool {
        if isRearmed { return true }
        guard movedSinceCapture >= rearmMotion, let quad, let capturedQuad else { return false }
        return Self.minCornerDistance(quad, capturedQuad) >= newPlacementDistance
    }

    /// Feeds one analysed frame at `time` (seconds, monotonic): the detected page (nil = none)
    /// and whether the phone is being held still.
    @discardableResult
    mutating func update(quad: Quad?, deviceStill: Bool, at time: TimeInterval) -> Phase {
        let dt = lastUpdate.map { min(max(time - $0, 0), 0.25) } ?? 0
        lastUpdate = time

        if phase == .captured, !leaveCapturedIfRearmed(quad: quad, deviceStill: deviceStill, dt: dt, at: time) {
            return phase
        }

        guard let quad else {
            let gap = lastSeen.map { time - $0 } ?? .infinity
            if gap > dropoutTolerance { pageLostSinceCapture = true }
            if gap <= dropoutTolerance { return phase }
            anchor = nil
            phase = .searching
            return phase
        }
        lastSeen = time

        guard deviceStill else {
            // The hold only counts while the phone itself is still.
            anchor = nil
            phase = .aligning
            return phase
        }

        if let anchor, Self.maxCornerDistance(quad, anchor) <= moveTolerance {
            guard isAutoCaptureEnabled else {
                phase = .holding(progress: 0)
                return phase
            }
            let progress = min(1, (time - anchorTime) / holdDuration)
            if progress >= 1, isSamePlacementAsCapture(anchor) {
                // Re-armed by a stray frame but held on the page just captured: don't duplicate it.
                self.anchor = nil
                phase = .captured
                return phase
            }
            phase = progress >= 1 ? .ready : .holding(progress: progress)
        } else {
            anchor = quad
            anchorTime = time
            phase = .holding(progress: 0)
        }
        return phase
    }

    /// While `.captured`: records movement and absence, and leaves `.captured` (returns true)
    /// once re-armed and past the cooldown.
    private mutating func leaveCapturedIfRearmed(quad: Quad?, deviceStill: Bool, dt: TimeInterval, at time: TimeInterval) -> Bool {
        if !deviceStill { movedSinceCapture += dt }
        if quad == nil {
            let gap = lastSeen.map { time - $0 } ?? .infinity
            if gap > dropoutTolerance { pageLostSinceCapture = true }
            if gap >= capturedAbsence { pageLeftSinceCapture = true }
        } else {
            lastSeen = time
        }
        guard isRearmed(with: quad), time - captureTime >= minCaptureInterval else { return false }
        phase = .searching
        anchor = nil
        return true
    }

    /// Image-only update (phone assumed still). Used by tests and as a fallback.
    @discardableResult
    mutating func update(quad: Quad?, at time: TimeInterval) -> Phase {
        update(quad: quad, deviceStill: true, at: time)
    }

    /// The captured page is (still) in the same spot and never left or dropped out of view.
    private func isSamePlacementAsCapture(_ quad: Quad) -> Bool {
        guard let capturedQuad, !pageLeftSinceCapture, !pageLostSinceCapture else { return false }
        return Self.minCornerDistance(quad, capturedQuad) < newPlacementDistance
    }

    /// Call after a photo is taken (auto or manual) with the outline seen at that moment.
    mutating func didCapture(quad: Quad?, at time: TimeInterval) {
        captureTime = time
        capturedQuad = quad
        movedSinceCapture = 0
        pageLeftSinceCapture = false
        pageLostSinceCapture = false
        lastUpdate = time // movement before the capture doesn't count
        anchor = nil
        phase = .captured
    }

    /// The user removed the last page (e.g. blurry): allow scanning the same sheet again
    /// without moving, still respecting the cooldown.
    mutating func rearm() {
        guard phase == .captured else { return }
        pageLeftSinceCapture = true
    }

    /// Restarts the hold without forgetting a recent capture (used after interruptions and
    /// when the delay changes, so the page still in view isn't captured again).
    mutating func restartHold() {
        anchor = nil
        if phase != .captured { phase = .searching }
    }

    mutating func reset() {
        anchor = nil
        lastSeen = nil
        lastUpdate = nil
        captureTime = -.infinity
        movedSinceCapture = 0
        pageLeftSinceCapture = false
        pageLostSinceCapture = false
        capturedQuad = nil
        phase = .searching
    }

    static func minCornerDistance(_ a: Quad, _ b: Quad) -> CGFloat {
        zip(a.points, b.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.min() ?? 0
    }

    static func maxCornerDistance(_ a: Quad, _ b: Quad) -> CGFloat {
        zip(a.points, b.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? .infinity
    }
}

/// Decides from gyroscope + accelerometer samples whether the phone is being held still.
struct StillnessDetector {
    /// The phone must have been still for at least this long.
    var window: TimeInterval = 0.35
    /// Rotation rate (rad/s) above which the phone is moving; hand tremor is about 0.02–0.1.
    var maxRotationRate: Double = 0.22
    /// User acceleration (g, gravity removed) above which the phone is moving.
    var maxAcceleration: Double = 0.05

    private var samples: [(time: TimeInterval, rotation: Double, acceleration: Double)] = []

    mutating func add(rotationRate: Double, acceleration: Double, at time: TimeInterval) {
        samples.append((time, rotationRate, acceleration))
        samples.removeAll { $0.time < time - window - 1 }
    }

    /// True when samples cover the whole `window` before `time` and every one is below the limits.
    func isStill(at time: TimeInterval) -> Bool {
        let recent = samples.filter { $0.time >= time - window && $0.time <= time }
        guard let first = recent.first, first.time <= time - window * 0.75,
              let last = recent.last, time - last.time < 0.2 else { return false }
        return recent.allSatisfy { $0.rotation <= maxRotationRate && $0.acceleration <= maxAcceleration }
    }

    mutating func reset() { samples.removeAll() }
}

/// Exponential smoothing of the live outline so it glides instead of jittering frame to frame.
struct QuadSmoother {
    /// 0...1; higher follows the newest detection more closely.
    var responsiveness: CGFloat = 0.45
    /// Jumps larger than this snap immediately (a different page, not jitter).
    var snapDistance: CGFloat = 0.2
    private(set) var current: Quad?

    init(responsiveness: CGFloat = 0.45) {
        self.responsiveness = responsiveness
    }

    mutating func add(_ quad: Quad?) -> Quad? {
        guard let quad else {
            current = nil
            return nil
        }
        guard let previous = current, StabilityTracker.maxCornerDistance(previous, quad) < snapDistance else {
            current = quad
            return quad
        }
        let a = responsiveness
        current = Quad(points: zip(previous.points, quad.points).map { old, new in
            CGPoint(x: old.x + (new.x - old.x) * a, y: old.y + (new.y - old.y) * a)
        })
        return current
    }

    mutating func reset() { current = nil }
}
