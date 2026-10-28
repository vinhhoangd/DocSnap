import CoreGraphics
import Foundation

/// Decides when the live camera should auto-capture: the detected page must stay in place
/// (every corner within `moveTolerance`) for `holdDuration` seconds. That gives the user
/// time to line the camera up instead of capturing the first moment a border appears.
///
/// After a capture it waits for a *different* page (or for the page to leave the frame)
/// so the same sheet isn't captured twice.
struct StabilityTracker {
    enum Phase: Equatable {
        /// No page in view.
        case searching
        /// A page is in view; `progress` (0...1) fills while it is held steady.
        case holding(progress: Double)
        /// Steady long enough: capture now.
        case ready
        /// Just captured; waiting for the next page.
        case captured
    }

    /// Seconds the page must stay steady. 0 disables auto-capture (manual shutter only).
    var holdDuration: TimeInterval
    /// Largest corner movement (normalized) still counted as "steady".
    var moveTolerance: CGFloat = 0.03
    /// After a capture, a corner must move this far (normalized) to count as a new page.
    var newPageDistance: CGFloat = 0.15
    /// Vision misses the page on single frames; gaps shorter than this don't reset the hold.
    var dropoutTolerance: TimeInterval = 0.35
    /// After a capture, the page must be gone this long before the same spot counts as a new page.
    var capturedAbsence: TimeInterval = 1.0

    private(set) var phase: Phase = .searching
    private var anchor: Quad?
    private var anchorTime: TimeInterval = 0
    private var lastSeen: TimeInterval?
    private var capturedQuad: Quad?

    init(holdDuration: TimeInterval) {
        self.holdDuration = holdDuration
    }

    var isAutoCaptureEnabled: Bool { holdDuration > 0 }

    /// Feeds one detection result (nil = no page found) at `time` (seconds, monotonic).
    @discardableResult
    mutating func update(quad: Quad?, at time: TimeInterval) -> Phase {
        guard let quad else {
            let gap = lastSeen.map { time - $0 } ?? .infinity
            if phase == .captured {
                // Keep remembering the captured page through flicker, flash, or a hand passing over it.
                if gap < capturedAbsence { return phase }
                capturedQuad = nil
            } else if gap <= dropoutTolerance {
                return phase
            }
            anchor = nil
            phase = .searching
            return phase
        }
        lastSeen = time

        if phase == .captured {
            if let capturedQuad, Self.maxCornerDistance(quad, capturedQuad) < newPageDistance {
                return phase
            }
            // A new page (or the old one moved a lot): start over.
            capturedQuad = nil
            anchor = nil
        }

        if let anchor, Self.maxCornerDistance(quad, anchor) <= moveTolerance {
            guard isAutoCaptureEnabled else {
                phase = .holding(progress: 0)
                return phase
            }
            let progress = min(1, (time - anchorTime) / holdDuration)
            phase = progress >= 1 ? .ready : .holding(progress: progress)
        } else {
            anchor = quad
            anchorTime = time
            phase = .holding(progress: 0)
        }
        return phase
    }

    /// Call after a photo is taken (auto or manual).
    mutating func didCapture(quad: Quad?) {
        capturedQuad = quad ?? anchor
        anchor = nil
        phase = .captured
    }

    mutating func reset() {
        anchor = nil
        lastSeen = nil
        capturedQuad = nil
        phase = .searching
    }

    static func maxCornerDistance(_ a: Quad, _ b: Quad) -> CGFloat {
        zip(a.points, b.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? .infinity
    }
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
