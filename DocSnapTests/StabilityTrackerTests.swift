import CoreGraphics
import XCTest
@testable import DocSnap

/// Hold-steady auto-capture. Every test passes explicit timestamps, so nothing depends on the clock.
final class StabilityTrackerTests: XCTestCase {
    /// The live camera analyses at most this many frames per second.
    private let fps = 15.0

    /// A page rectangle, optionally shifted by (dx, dy).
    private func page(dx: CGFloat = 0, dy: CGFloat = 0) -> Quad {
        Quad(
            topLeft: CGPoint(x: 0.25 + dx, y: 0.25 + dy),
            topRight: CGPoint(x: 0.75 + dx, y: 0.25 + dy),
            bottomRight: CGPoint(x: 0.75 + dx, y: 0.75 + dy),
            bottomLeft: CGPoint(x: 0.25 + dx, y: 0.75 + dy)
        )
    }

    private func isHolding(_ phase: StabilityTracker.Phase) -> Bool {
        if case .holding = phase { return true }
        return false
    }

    private func progress(_ phase: StabilityTracker.Phase) -> Double? {
        if case .holding(let progress) = phase { return progress }
        return nil
    }

    /// Feeds `quad` at 15 fps from `start` (inclusive) to `end` (exclusive); returns every phase.
    @discardableResult
    private func feed(_ tracker: inout StabilityTracker, _ quad: Quad?, from start: Double, to end: Double) -> [StabilityTracker.Phase] {
        var phases: [StabilityTracker.Phase] = []
        var frame = 0
        while true {
            let time = start + Double(frame) / fps
            if time >= end - 1e-9 { break }
            phases.append(tracker.update(quad: quad, at: time))
            frame += 1
        }
        return phases
    }

    /// First time (at 15 fps from `start`) the phase becomes `.ready`, or nil within `limit` seconds.
    private func timeUntilReady(_ tracker: inout StabilityTracker, _ quad: (Double) -> Quad?,
                                from start: Double = 0, limit: Double = 10) -> Double? {
        var frame = 0
        while true {
            let time = start + Double(frame) / fps
            if time > start + limit { return nil }
            if tracker.update(quad: quad(time), at: time) == .ready { return time - start }
            frame += 1
        }
    }

    // MARK: - Holding steady

    func testStartsSearchingWithAutoCaptureEnabled() {
        let tracker = StabilityTracker(holdDuration: 1.5)
        XCTAssertEqual(tracker.phase, .searching)
        XCTAssertTrue(tracker.isAutoCaptureEnabled)
    }

    func testNoPageStaysSearching() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        let phases = feed(&tracker, nil, from: 0, to: 3)
        XCTAssertTrue(phases.allSatisfy { $0 == .searching })
    }

    func testSteadyPageBecomesReadyExactlyAfterHoldDuration() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        XCTAssertEqual(tracker.update(quad: page(), at: 10), .holding(progress: 0))
        XCTAssertEqual(progress(tracker.update(quad: page(), at: 10.75)) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertTrue(isHolding(tracker.update(quad: page(), at: 11.49)), "Must not capture before holdDuration")
        XCTAssertEqual(tracker.update(quad: page(), at: 11.5), .ready)
        XCTAssertEqual(tracker.phase, .ready)
    }

    func testProgressRisesMonotonicallyWithinZeroToOne() {
        var tracker = StabilityTracker(holdDuration: 2)
        let progresses = feed(&tracker, page(), from: 0, to: 2).compactMap(progress)
        XCTAssertEqual(progresses.count, 30)
        XCTAssertEqual(progresses.first, 0)
        XCTAssertEqual(progresses, progresses.sorted(), "Progress must never go backwards while steady")
        XCTAssertTrue(progresses.allSatisfy { (0...1).contains($0) })
    }

    func testEveryAutoCaptureDelayWaitsItsSecondsAt15fps() throws {
        for delay in AutoCaptureDelay.allCases where delay.seconds > 0 {
            var tracker = StabilityTracker(holdDuration: delay.seconds)
            let ready = try XCTUnwrap(timeUntilReady(&tracker, { _ in self.page() }), "\(delay) never became ready")
            XCTAssertGreaterThanOrEqual(ready, delay.seconds - 1e-9, "\(delay) captured too early")
            XCTAssertLessThan(ready, delay.seconds + 1 / fps + 1e-9, "\(delay) captured too late")
        }
    }

    func testHandJitterWithinToleranceStillCaptures() throws {
        var tracker = StabilityTracker(holdDuration: 1.5)
        // 0 / 0.025 alternating each frame: always within the 0.03 tolerance of the first position.
        var frame = 0
        let ready = timeUntilReady(&tracker, { _ in
            frame += 1
            return self.page(dx: frame.isMultiple(of: 2) ? 0.025 : 0)
        })
        let readyTime = try XCTUnwrap(ready)
        XCTAssertEqual(readyTime, 1.5, accuracy: 1 / fps + 1e-9)
    }

    func testMovingBeyondToleranceRestartsTheHold() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 1.2)
        XCTAssertEqual(tracker.update(quad: page(dx: 0.05), at: 1.2), .holding(progress: 0), "A 0.05 move restarts the timer")
        XCTAssertTrue(isHolding(tracker.update(quad: page(dx: 0.05), at: 2.0)), "1.5 s from the first position must not count")
        XCTAssertTrue(isHolding(tracker.update(quad: page(dx: 0.05), at: 2.69)))
        XCTAssertEqual(tracker.update(quad: page(dx: 0.05), at: 2.7), .ready)
    }

    func testToleranceIsMeasuredFromWhereTheHoldStarted() {
        // A slow drift (0.005 per frame) is never "steady" even though each frame barely moves.
        var drift = StabilityTracker(holdDuration: 1.5)
        var frame = 0
        let phases = (0..<90).map { _ -> StabilityTracker.Phase in
            frame += 1
            return drift.update(quad: page(dx: CGFloat(frame) * 0.005 - 0.2), at: Double(frame) / fps)
        }
        XCTAssertFalse(phases.contains(.ready), "A page drifting 0.075/s across the frame must not be captured")
    }

    func testManualModeNeverAutoCaptures() {
        var tracker = StabilityTracker(holdDuration: 0)
        XCTAssertFalse(tracker.isAutoCaptureEnabled)
        let phases = feed(&tracker, page(), from: 0, to: 10)
        XCTAssertFalse(phases.contains(.ready))
        XCTAssertTrue(phases.allSatisfy { $0 == .holding(progress: 0) }, "Manual mode shows the page without a timer")
        XCTAssertFalse(StabilityTracker(holdDuration: AutoCaptureDelay.manual.seconds).isAutoCaptureEnabled)
    }

    func testManualShutterInManualModeWaitsForNextPage() {
        var tracker = StabilityTracker(holdDuration: 0)
        feed(&tracker, page(), from: 0, to: 1)
        tracker.didCapture(quad: page())
        XCTAssertEqual(tracker.update(quad: page(), at: 1.1), .captured)
        XCTAssertEqual(tracker.update(quad: page(dx: 0.2), at: 1.2), .holding(progress: 0))
    }

    // MARK: - Dropouts (Vision misses single frames)

    func testShortDropoutKeepsTheHoldGoing() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 1.0) // last seen at 14/15 s
        let lastSeen = 14 / fps
        let during = tracker.update(quad: nil, at: lastSeen + 0.2)
        XCTAssertTrue(isHolding(during), "A 0.2 s miss must not reset, got \(during)")
        XCTAssertTrue(isHolding(tracker.update(quad: nil, at: lastSeen + 0.34)), "Just under dropoutTolerance is still a short miss")
        XCTAssertEqual(tracker.update(quad: page(), at: 1.5), .ready, "The hold still counts from t = 0")
    }

    func testLongDropoutResetsToSearching() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 1.0)
        let lastSeen = 14 / fps
        XCTAssertEqual(tracker.update(quad: nil, at: lastSeen + 0.4), .searching)
        XCTAssertEqual(tracker.update(quad: page(), at: 1.5), .holding(progress: 0), "The hold starts over")
        XCTAssertTrue(isHolding(tracker.update(quad: page(), at: 2.9)))
        XCTAssertEqual(tracker.update(quad: page(), at: 3.0), .ready)
    }

    func testFirstFrameWithoutPageIsSearching() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        XCTAssertEqual(tracker.update(quad: nil, at: 0), .searching)
    }

    // MARK: - After a capture

    private func capturedTracker(holdDuration: Double = 1.5) -> StabilityTracker {
        var tracker = StabilityTracker(holdDuration: holdDuration)
        XCTAssertNotNil(timeUntilReady(&tracker, { _ in self.page() }))
        tracker.didCapture(quad: page())
        XCTAssertEqual(tracker.phase, .captured)
        return tracker
    }

    func testSamePageIsNotCapturedTwice() {
        var tracker = capturedTracker()
        let phases = feed(&tracker, page(), from: 2, to: 8)
        XCTAssertTrue(phases.allSatisfy { $0 == .captured }, "Holding the captured page must not trigger another capture")
    }

    func testSmallMoveAfterCaptureIsStillTheSamePage() {
        var tracker = capturedTracker()
        let phases = feed(&tracker, page(dx: 0.1), from: 2, to: 6)
        XCTAssertTrue(phases.allSatisfy { $0 == .captured }, "A 0.1 move is the same sheet (newPageDistance 0.15)")
    }

    func testNewPageStartsANewHold() {
        var tracker = capturedTracker()
        XCTAssertEqual(tracker.update(quad: page(dx: 0.2), at: 2), .holding(progress: 0))
        XCTAssertNotNil(timeUntilReady(&tracker, { _ in self.page(dx: 0.2) }, from: 2 + 1 / fps))
    }

    func testMovingExactlyNewPageDistanceCountsAsANewPage() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        tracker.newPageDistance = 0.25 // 0.25 and 0.5 are exact in binary, so the boundary is exact.
        tracker.update(quad: page(), at: 0)
        tracker.didCapture(quad: page())
        XCTAssertEqual(tracker.update(quad: page(dx: 0.2499), at: 0.1), .captured)
        XCTAssertEqual(tracker.update(quad: page(dx: 0.25), at: 0.2), .holding(progress: 0))
    }

    func testBriefDropoutAfterCaptureKeepsCaptured() {
        var tracker = capturedTracker()
        let lastSeen = tracker.update(quad: page(), at: 5) // lastSeen = 5
        XCTAssertEqual(lastSeen, .captured)
        XCTAssertEqual(tracker.update(quad: nil, at: 5.3), .captured)
        XCTAssertEqual(tracker.update(quad: page(), at: 5.4), .captured, "The same page coming back is not new")
    }

    func testHandPassingOverTheCapturedPageKeepsCaptured() {
        // Longer than a detection dropout, shorter than `capturedAbsence`: still the same sheet.
        var tracker = capturedTracker()
        XCTAssertGreaterThan(tracker.capturedAbsence, tracker.dropoutTolerance)
        tracker.update(quad: page(), at: 5)
        let gap = (tracker.dropoutTolerance + tracker.capturedAbsence) / 2
        XCTAssertEqual(tracker.update(quad: nil, at: 5 + gap), .captured)
        XCTAssertEqual(tracker.update(quad: page(), at: 5 + gap + 0.05), .captured)
    }

    func testPageLeavingTheFrameAllowsCapturingItAgain() {
        var tracker = capturedTracker()
        tracker.update(quad: page(), at: 5)
        let away = 5 + tracker.capturedAbsence
        XCTAssertEqual(tracker.update(quad: nil, at: away), .searching, "Gone for capturedAbsence: the page left")
        XCTAssertEqual(tracker.update(quad: page(), at: away + 0.5), .holding(progress: 0))
        XCTAssertEqual(tracker.update(quad: page(), at: away + 2.0), .ready, "The same sheet put back can be scanned again")
    }

    func testCaptureWithoutQuadUsesTheHeldPage() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 0.5)
        tracker.didCapture(quad: nil) // manual shutter: the controller may not pass the corners
        XCTAssertEqual(tracker.update(quad: page(), at: 0.6), .captured)
        XCTAssertEqual(tracker.update(quad: page(), at: 3), .captured)
    }

    func testResetForgetsEverything() {
        var tracker = capturedTracker()
        tracker.update(quad: page(), at: 5)
        tracker.reset()
        XCTAssertEqual(tracker.phase, .searching)
        XCTAssertEqual(tracker.update(quad: nil, at: 5.01), .searching, "No last-seen time survives a reset")
        XCTAssertEqual(tracker.update(quad: page(), at: 5.1), .holding(progress: 0), "The captured page is forgotten")
    }

    func testMaxCornerDistance() {
        XCTAssertEqual(StabilityTracker.maxCornerDistance(page(), page()), 0)
        var moved = page()
        moved.bottomLeft.x += 0.3
        moved.bottomLeft.y += 0.4
        XCTAssertEqual(StabilityTracker.maxCornerDistance(page(), moved), 0.5, accuracy: 1e-9)
    }

    // MARK: - Smoother + tracker together (as CameraController uses them)

    func testJitteryDetectionThroughSmootherStillAutoCaptures() throws {
        var tracker = StabilityTracker(holdDuration: 1.5)
        var smoother = QuadSmoother()
        var frame = 0
        // Raw detection jumps ±0.04 each frame, beyond moveTolerance; smoothing must calm it down.
        let ready = timeUntilReady(&tracker, { _ in
            frame += 1
            return smoother.add(self.page(dx: frame.isMultiple(of: 2) ? 0.04 : -0.04))
        })
        let readyTime = try XCTUnwrap(ready, "Hand shake should not prevent auto-capture")
        XCTAssertLessThan(readyTime, 2.0)
    }

    func testSingleMissedFrameThroughSmootherDoesNotRestart() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        var smoother = QuadSmoother()
        for frame in 0..<20 {
            let detected: Quad? = frame == 10 ? nil : page()
            let phase = tracker.update(quad: smoother.add(detected), at: Double(frame) / fps)
            if frame == 10 { XCTAssertTrue(isHolding(phase)) }
        }
        XCTAssertEqual(tracker.update(quad: smoother.add(page()), at: 1.5), .ready)
    }
}

final class QuadSmootherTests: XCTestCase {
    private func page(_ offset: CGFloat) -> Quad {
        Quad(
            topLeft: CGPoint(x: 0.2 + offset, y: 0.2),
            topRight: CGPoint(x: 0.8 + offset, y: 0.2),
            bottomRight: CGPoint(x: 0.8 + offset, y: 0.8),
            bottomLeft: CGPoint(x: 0.2 + offset, y: 0.8)
        )
    }

    func testFirstDetectionIsReturnedAsIs() {
        var smoother = QuadSmoother()
        XCTAssertEqual(smoother.add(page(0)), page(0))
        XCTAssertEqual(smoother.current, page(0))
    }

    func testSmallMovesAreBlended() throws {
        var smoother = QuadSmoother(responsiveness: 0.45)
        _ = smoother.add(page(0))
        let blended = try XCTUnwrap(smoother.add(page(0.1)))
        XCTAssertEqual(blended.topLeft.x, 0.2 + 0.1 * 0.45, accuracy: 1e-9)
        XCTAssertEqual(blended.topLeft.y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(blended.bottomRight.x, 0.8 + 0.1 * 0.45, accuracy: 1e-9)
    }

    func testConvergesOnASteadyTarget() throws {
        var smoother = QuadSmoother()
        _ = smoother.add(page(0))
        var latest: Quad?
        for _ in 0..<30 { latest = smoother.add(page(0.1)) }
        let result = try XCTUnwrap(latest)
        XCTAssertLessThan(StabilityTracker.maxCornerDistance(result, page(0.1)), 1e-4)
    }

    func testLargeJumpSnaps() {
        var smoother = QuadSmoother()
        _ = smoother.add(page(0))
        XCTAssertEqual(smoother.add(page(0.2)), page(0.2), "A jump of snapDistance or more is a new page, not jitter")
    }

    func testNilClearsTheOutline() {
        var smoother = QuadSmoother()
        _ = smoother.add(page(0))
        XCTAssertNil(smoother.add(nil))
        XCTAssertNil(smoother.current)
        XCTAssertEqual(smoother.add(page(0.05)), page(0.05), "After a miss the next detection is used directly")
    }

    func testFullResponsivenessFollowsExactly() {
        var smoother = QuadSmoother(responsiveness: 1)
        _ = smoother.add(page(0))
        XCTAssertEqual(smoother.add(page(0.1)), page(0.1))
    }

    func testReset() {
        var smoother = QuadSmoother()
        _ = smoother.add(page(0))
        smoother.reset()
        XCTAssertNil(smoother.current)
    }
}
