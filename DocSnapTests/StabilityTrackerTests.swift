// swiftlint:disable file_length type_body_length
import CoreGraphics
import XCTest
@testable import DocSnap

/// Hold-steady auto-capture. Every test passes explicit timestamps, so nothing depends on the clock.
/// Times are chosen so that the boundaries checked are exact in binary floating point.
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

    /// Feeds frames at 15 fps from `start` (inclusive) to `end` (exclusive); returns every phase.
    @discardableResult
    private func feed(_ tracker: inout StabilityTracker, _ quad: Quad?, still: Bool = true,
                      from start: Double, to end: Double) -> [StabilityTracker.Phase] {
        var phases: [StabilityTracker.Phase] = []
        var frame = 0
        while true {
            let time = start + Double(frame) / fps
            if time >= end - 1e-9 { break }
            phases.append(tracker.update(quad: quad, deviceStill: still, at: time))
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
            if tracker.update(quad: quad(time), deviceStill: true, at: time) == .ready { return time - start }
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
        XCTAssertTrue(feed(&tracker, nil, from: 0, to: 3).allSatisfy { $0 == .searching })
        XCTAssertTrue(feed(&tracker, nil, still: false, from: 3, to: 5).allSatisfy { $0 == .searching },
                      "Moving with nothing in view is still searching, not aligning")
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
        XCTAssertEqual(try XCTUnwrap(ready), 1.5, accuracy: 1 / fps + 1e-9)
    }

    func testMovingBeyondToleranceRestartsTheHold() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 1.2)
        XCTAssertEqual(tracker.update(quad: page(dx: 0.05), at: 1.25), .holding(progress: 0), "A 0.05 move restarts the timer")
        XCTAssertTrue(isHolding(tracker.update(quad: page(dx: 0.05), at: 2.0)), "1.5 s from the first position must not count")
        XCTAssertTrue(isHolding(tracker.update(quad: page(dx: 0.05), at: 2.74)))
        XCTAssertEqual(tracker.update(quad: page(dx: 0.05), at: 2.75), .ready)
    }

    func testToleranceIsMeasuredFromWhereTheHoldStarted() {
        // A slow drift (0.005 per frame) is never "steady" even though each frame barely moves.
        var drift = StabilityTracker(holdDuration: 1.5)
        let phases = (1...90).map { frame in
            drift.update(quad: page(dx: CGFloat(frame) * 0.005 - 0.2), at: Double(frame) / fps)
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

    func testManualModeMovingPhoneIsAligning() {
        var tracker = StabilityTracker(holdDuration: 0)
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: false, at: 0), .aligning)
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 0.1), .holding(progress: 0))
    }

    func testManualShutterInManualModeWaitsForTheNextPage() {
        var tracker = StabilityTracker(holdDuration: 0)
        feed(&tracker, page(), from: 0, to: 1)
        tracker.didCapture(quad: page(), at: 1)
        XCTAssertTrue(feed(&tracker, page(), from: 1.1, to: 5).allSatisfy { $0 == .captured })
        // 0.70 s of movement (first step 4.967 → 5.0, then 10 frames of 1/15 s) re-arms.
        let moving = feed(&tracker, page(dx: 0.3), still: false, from: 5, to: 5.7)
        XCTAssertEqual(moving.last, .aligning)
        XCTAssertEqual(tracker.update(quad: page(dx: 0.3), deviceStill: true, at: 5.8), .holding(progress: 0))
    }

    // MARK: - Device motion (the phone must be still, not just the image)

    func testMovingPhoneIsAligningAndNeverAdvances() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        let phases = feed(&tracker, page(), still: false, from: 0, to: 5)
        XCTAssertTrue(phases.allSatisfy { $0 == .aligning },
                      "A steady image while the phone moves (slow hand drift) is not holding still")
    }

    func testBecomingStillRestartsTheHoldFromZero() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 1.2)
        XCTAssertGreaterThan(progress(tracker.phase) ?? 0, 0.7)
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: false, at: 1.2), .aligning, "One moving sample cancels the hold")
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 1.25), .holding(progress: 0),
                       "The hold restarts from 0, not from where it was")
        XCTAssertTrue(isHolding(tracker.update(quad: page(), deviceStill: true, at: 2.74)))
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 2.75), .ready)
    }

    func testIntermittentMotionNeverCaptures() {
        // A hand that stops for ~1 s, twitches, stops again…: never a full 1.5 s of stillness.
        var tracker = StabilityTracker(holdDuration: 1.5)
        var phases: [StabilityTracker.Phase] = []
        for frame in 0..<150 {
            let still = frame % 17 != 16
            phases.append(tracker.update(quad: page(), deviceStill: still, at: Double(frame) / fps))
        }
        XCTAssertFalse(phases.contains(.ready))
        XCTAssertTrue(phases.contains(.aligning))
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

    // MARK: - After a capture: re-arm only after a real "next page" action

    /// Page held still from t = 0 to ready at exactly 1.5, then captured at 1.5 (cooldown ends at 3.0).
    private func capturedTracker() -> StabilityTracker {
        var tracker = StabilityTracker(holdDuration: 1.5)
        tracker.update(quad: page(), at: 0)
        tracker.update(quad: page(), at: 0.75)
        XCTAssertEqual(tracker.update(quad: page(), at: 1.5), .ready)
        tracker.didCapture(quad: page(), at: 1.5)
        XCTAssertEqual(tracker.phase, .captured)
        XCTAssertFalse(tracker.isRearmed)
        return tracker
    }

    /// Page 2 sitting fully elsewhere in the frame: every corner 0.3 from the captured outline.
    private var relocated: Quad { page(dx: 0.3) }

    func testSamePageHeldStillIsNotCapturedTwice() {
        var tracker = capturedTracker()
        XCTAssertTrue(feed(&tracker, page(), from: 1.6, to: 10).allSatisfy { $0 == .captured })
        XCTAssertFalse(tracker.isRearmed)
    }

    /// The owner's bug (2026-10-29): after page 1 the outline shifted ≥ 15 % and page 1 was scanned again.
    func testOwnersBugShiftedOutlineOfTheSamePageNeverRecaptures() {
        var tracker = capturedTracker()
        var phases = feed(&tracker, page(dx: 0.2, dy: 0.1), from: 1.6, to: 6)
        // Even the outline sweeping across the frame (phone reported still) is not a new page.
        for frame in 0..<30 {
            phases.append(tracker.update(quad: page(dx: CGFloat(frame) * 0.01), deviceStill: true, at: 6 + Double(frame) / fps))
        }
        phases += feed(&tracker, relocated, from: 8, to: 12)
        XCTAssertFalse(phases.contains(.ready), "Without movement or absence the same sheet is never captured twice")
        XCTAssertTrue(phases.allSatisfy { $0 == .captured })
    }

    func testRelocatedOutlineWithoutMovementDoesNotRearm() {
        var tracker = capturedTracker()
        XCTAssertTrue(feed(&tracker, relocated, from: 1.6, to: 10).allSatisfy { $0 == .captured },
                      "The phone never moved: the sheet was slid, not a new page")
    }

    /// The risk found in review round 2: re-aiming the phone over page 1, then holding still on it.
    func testMovingThenHoldingStillOverTheSamePlaceDoesNotRecapture() {
        var tracker = capturedTracker()
        // 1.4 s of re-aiming: the outline wobbles around page 1's place (up to 0.1 off).
        var phases: [StabilityTracker.Phase] = []
        for frame in 0..<21 {
            let wobble = CGFloat(frame % 5) * 0.025
            phases.append(tracker.update(quad: page(dx: wobble, dy: -wobble / 2), deviceStill: false, at: 1.6 + Double(frame) / fps))
        }
        phases += feed(&tracker, page(dx: 0.05, dy: 0.03), from: 3.0, to: 10)
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertFalse(phases.contains(.ready), "Moved, but the same sheet in the same place: not captured twice")
        XCTAssertTrue(phases.allSatisfy { $0 == .captured })
    }

    func testMovingToAFullyNewPlacementRearmsButOnlyAfterTheCooldownAndAFullHold() {
        var tracker = capturedTracker()
        // 0.83 s of movement right after the capture (0.1 + 11 × 1/15), page 2 fully elsewhere.
        let moving = feed(&tracker, relocated, still: false, from: 1.6, to: 2.4)
        XCTAssertTrue(moving.allSatisfy { $0 == .captured }, "Still within minCaptureInterval")
        XCTAssertTrue(feed(&tracker, relocated, from: 2.4, to: 3.0).allSatisfy { $0 == .captured },
                      "Re-armed but the cooldown hasn't passed")
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: true, at: 3.0), .holding(progress: 0),
                       "Cooldown over: a new hold starts from 0")
        XCTAssertTrue(isHolding(tracker.update(quad: relocated, deviceStill: true, at: 4.49)))
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: true, at: 4.5), .ready)
    }

    func testMovingToANewPlacementLongAfterTheCaptureRearms() {
        var tracker = capturedTracker()
        feed(&tracker, page(), from: 1.6, to: 5)
        let moving = feed(&tracker, relocated, still: false, from: 5, to: 5.7)
        XCTAssertEqual(moving.last, .aligning, "Re-armed after the cooldown: page in view, phone moving")
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: true, at: 5.75), .holding(progress: 0))
        XCTAssertTrue(isHolding(tracker.update(quad: relocated, deviceStill: true, at: 7.24)))
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: true, at: 7.25), .ready)
    }

    func testNewPlacementNeedsEveryCornerToMove() {
        var tracker = capturedTracker()
        // Three corners 0.3 away, the top-left one still where page 1's was (e.g. a bigger sheet).
        var partly = relocated
        partly.topLeft = page().topLeft
        feed(&tracker, partly, still: false, from: 1.6, to: 2.6) // 1.03 s moved
        XCTAssertTrue(feed(&tracker, partly, from: 2.6, to: 8).allSatisfy { $0 == .captured })
    }

    func testNewPlacementDistanceBoundaryIsInclusive() {
        var below = capturedTracker()
        below.newPlacementDistance = 0.25
        feed(&below, page(dx: 0.2499), still: false, from: 3.0, to: 4.0)
        XCTAssertEqual(below.update(quad: page(dx: 0.2499), deviceStill: true, at: 4.0), .captured)
        var at = capturedTracker()
        at.newPlacementDistance = 0.25 // 0.25 and 0.5 are exact in binary
        feed(&at, page(dx: 0.25), still: false, from: 3.0, to: 4.0)
        XCTAssertEqual(at.update(quad: page(dx: 0.25), deviceStill: true, at: 4.0), .holding(progress: 0))
    }

    func testBriefTremorDoesNotRearmEvenAtANewPlacement() {
        var tracker = capturedTracker()
        var phases: [StabilityTracker.Phase] = []
        // Four 2-frame twitches: 0.1 + 7 × 1/15 = 0.57 s of movement in total, < rearmMotion 0.6.
        for frame in 0..<150 {
            let moving = frame % 20 < 2 && frame / 20 < 4
            phases.append(tracker.update(quad: relocated, deviceStill: !moving, at: 1.6 + Double(frame) / fps))
        }
        XCTAssertTrue(phases.allSatisfy { $0 == .captured }, "Hand tremor must not re-arm")
        // Movement adds up: one more 2-frame twitch passes 0.6 s.
        let t = 1.6 + 150 / fps
        tracker.update(quad: relocated, deviceStill: false, at: t)
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: t + 1 / fps), .aligning)
    }

    func testRearmMotionBoundaryIsInclusive() {
        var tracker = capturedTracker()
        tracker.rearmMotion = 0.5
        tracker.update(quad: relocated, deviceStill: true, at: 3.0)
        for time in [3.125, 3.25, 3.375] {
            XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: time), .captured)
        }
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: 3.5), .aligning, "Exactly 0.5 s moved re-arms")
    }

    func testLongGapBetweenUpdatesCountsAtMostAQuarterSecond() {
        var tracker = capturedTracker()
        tracker.update(quad: relocated, deviceStill: true, at: 3.0)
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: 8.0), .captured, "A 5 s gap counts as 0.25 s")
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: 8.125), .captured, "0.375 s")
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: 13.125), .aligning, "0.625 s ≥ 0.6")
    }

    func testTimeGoingBackwardsCountsNoMovement() {
        var tracker = capturedTracker()
        tracker.update(quad: relocated, deviceStill: true, at: 5)
        for _ in 0..<20 { tracker.update(quad: relocated, deviceStill: false, at: 4) } // dt < 0 → 0
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: true, at: 5), .captured)
    }

    func testMotionBeforeTheCaptureDoesNotCount() {
        var tracker = capturedTracker() // last update at 1.5
        tracker.minCaptureInterval = 0
        tracker.rearmMotion = 0.5
        tracker.didCapture(quad: page(), at: 1.75) // manual shutter 0.25 s after the last frame
        // Counted from 1.75: 0.125, 0.25, 0.375 … (from 1.5 it would already be 0.5 at 2.125).
        for time in [1.875, 2.0, 2.125] {
            XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: time), .captured)
        }
        XCTAssertEqual(tracker.update(quad: relocated, deviceStill: false, at: 2.25), .aligning)
    }

    func testMovementPlusDropoutRearmsEvenInTheSamePlace() {
        var tracker = capturedTracker()
        feed(&tracker, page(), still: false, from: 1.6, to: 2.0)          // last seen 1.933, 0.43 s moved
        feed(&tracker, nil, still: false, from: 2.0, to: 2.4)             // gone until 2.333: a 0.4 s gap
        XCTAssertTrue(tracker.isRearmed, "Moved ≥ 0.6 s and the old page dropped out of view")
        XCTAssertTrue(feed(&tracker, page(), from: 2.4, to: 3.0).allSatisfy { $0 == .captured }, "Cooldown")
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 3.0), .holding(progress: 0),
                       "Page 2 placed where page 1 was")
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 4.5), .ready)
    }

    func testMovementPlusShortDropoutInTheSamePlaceDoesNotRearm() {
        var tracker = capturedTracker()
        var phases = feed(&tracker, page(), still: false, from: 1.6, to: 2.0) // last seen 1.933
        phases += feed(&tracker, nil, still: false, from: 2.0, to: 2.25)       // nil until 2.2 (gap ≤ 0.35)
        phases += feed(&tracker, page(), still: false, from: 2.25, to: 3.0)    // seen again at 2.25 (0.32 s gap)
        phases += feed(&tracker, page(), from: 3.0, to: 10)
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertTrue(phases.allSatisfy { $0 == .captured }, "A detection blip while re-aiming is not a new page")
    }

    func testMovementWithAnOddRelocatedFrameDoesNotLetTheSamePageBeCapturedAgain() {
        var tracker = capturedTracker()
        // Re-aiming over page 1 for 1.6 s; at 3.2 Vision reports one rectangle elsewhere (another object).
        feed(&tracker, page(dx: 0.02), still: false, from: 1.6, to: 3.2)
        tracker.update(quad: relocated, deviceStill: false, at: 3.2)
        // Then page 1, same place, held still.
        let phases = feed(&tracker, page(dx: 0.02), from: 3.2 + 1 / fps, to: 8)
        // Regression: one stray relocated outline used to re-arm for good, so page 1 was captured again.
        // Now a hold that ends on the captured page's spot (page never left) goes back to `.captured`.
        XCTAssertFalse(phases.contains(.ready), "One odd outline after re-aiming re-armed capture of the same sheet")
    }

    func testPageAwayForCapturedAbsenceRearms() {
        var tracker = capturedTracker() // last seen at 1.5
        XCTAssertTrue(feed(&tracker, nil, from: 1.6, to: 2.3).allSatisfy { $0 == .captured })
        XCTAssertFalse(tracker.isRearmed, "Gone 0.77 s < capturedAbsence")
        XCTAssertEqual(tracker.update(quad: nil, deviceStill: true, at: 2.31), .captured, "Re-armed but still in the cooldown")
        XCTAssertTrue(tracker.isRearmed)
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 2.5), .captured)
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 3.0), .holding(progress: 0),
                       "The sheet was taken away and put back (or swapped): it counts again")
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 4.5), .ready)
    }

    func testPageAwayAfterTheCooldownGoesToSearching() {
        var tracker = capturedTracker()
        feed(&tracker, page(), from: 1.6, to: 5) // last seen at 4.9333
        XCTAssertEqual(tracker.update(quad: nil, deviceStill: true, at: 5.74), .searching, "Gone 0.81 s")
    }

    func testPageAwayShorterThanCapturedAbsenceDoesNotRearm() {
        var tracker = capturedTracker()
        var phases = feed(&tracker, page(), from: 1.6, to: 5)
        // Three gaps of 0.73 s each (a hand passing over the sheet, phone still): gaps don't add up.
        for cycle in 0..<3 {
            let start = 5 + Double(cycle)
            phases += feed(&tracker, nil, from: start, to: start + 0.7)
            phases += feed(&tracker, page(), from: start + 0.75, to: start + 1)
        }
        phases += feed(&tracker, page(), from: 8, to: 12)
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertTrue(phases.allSatisfy { $0 == .captured })
    }

    func testSingleOddFrameOrDropoutDoesNotRearm() {
        var tracker = capturedTracker()
        var phases = feed(&tracker, page(), from: 1.6, to: 4)
        phases.append(tracker.update(quad: nil, deviceStill: true, at: 4.0))                // missed detection
        phases.append(tracker.update(quad: relocated, deviceStill: true, at: 4.0 + 1 / fps)) // outline jumps
        phases.append(tracker.update(quad: page(), deviceStill: false, at: 4.0 + 2 / fps))   // one moving sample
        phases += feed(&tracker, page(), from: 4.2, to: 10)
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertFalse(phases.contains(.ready))
        XCTAssertTrue(phases.allSatisfy { $0 == .captured })
    }

    func testCaptureWithNoPageEverSeenRearmsOnTheFirstEmptyFrame() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        tracker.didCapture(quad: nil, at: 0) // manual shutter before anything was detected
        XCTAssertEqual(tracker.update(quad: nil, deviceStill: true, at: 0.1), .captured)
        XCTAssertTrue(tracker.isRearmed)
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 1.5), .holding(progress: 0))
    }

    // MARK: rearm() (the user removed the last page)

    func testRearmWhileCapturedWaitsForTheCooldownThenAFullHold() {
        var tracker = capturedTracker()
        tracker.update(quad: page(), deviceStill: true, at: 2.0)
        tracker.rearm()
        XCTAssertTrue(tracker.isRearmed)
        XCTAssertEqual(tracker.phase, .captured)
        XCTAssertTrue(feed(&tracker, page(), from: 2.0625, to: 3.0).allSatisfy { $0 == .captured }, "Cooldown still applies")
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 3.0), .holding(progress: 0),
                       "The same sheet can be scanned again, without moving")
        XCTAssertTrue(isHolding(tracker.update(quad: page(), deviceStill: true, at: 4.49)))
        XCTAssertEqual(tracker.update(quad: page(), deviceStill: true, at: 4.5), .ready)
    }

    func testRearmOutsideCapturedIsANoOp() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        tracker.rearm()
        XCTAssertEqual(tracker.phase, .searching)
        XCTAssertFalse(tracker.isRearmed)
        tracker.update(quad: page(), at: 0)
        tracker.update(quad: page(), at: 0.75)
        tracker.rearm()
        XCTAssertEqual(tracker.phase, .holding(progress: 0.5), "rearm() doesn't disturb a hold")
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertEqual(tracker.update(quad: page(), at: 1.5), .ready)
        tracker.didCapture(quad: page(), at: 1.5)
        XCTAssertTrue(feed(&tracker, page(), from: 1.6, to: 8).allSatisfy { $0 == .captured },
                      "A rearm() before the capture doesn't carry over")
    }

    // MARK: restartHold() / reset()

    func testRestartHoldWhileCapturedKeepsCapturedAndDoesNotRearm() {
        var tracker = capturedTracker()
        feed(&tracker, page(), from: 1.6, to: 2)
        tracker.restartHold() // interruption ended / delay changed
        XCTAssertEqual(tracker.phase, .captured)
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertTrue(feed(&tracker, page(), from: 2, to: 10).allSatisfy { $0 == .captured },
                      "The page still in view is not captured again")
    }

    func testRestartHoldWhileHoldingStartsOver() {
        var tracker = StabilityTracker(holdDuration: 1.5)
        feed(&tracker, page(), from: 0, to: 1.2)
        tracker.restartHold()
        XCTAssertEqual(tracker.phase, .searching)
        XCTAssertEqual(tracker.update(quad: page(), at: 1.25), .holding(progress: 0))
        XCTAssertTrue(isHolding(tracker.update(quad: page(), at: 2.74)))
        XCTAssertEqual(tracker.update(quad: page(), at: 2.75), .ready)
    }

    func testResetForgetsEverything() {
        var tracker = capturedTracker()
        feed(&tracker, relocated, still: false, from: 1.6, to: 1.9)
        tracker.reset()
        XCTAssertEqual(tracker.phase, .searching)
        XCTAssertFalse(tracker.isRearmed)
        XCTAssertEqual(tracker.update(quad: nil, at: 2.01), .searching, "No last-seen time survives a reset")
        XCTAssertEqual(tracker.update(quad: page(), at: 2.0625), .holding(progress: 0), "No cooldown survives a reset")
        XCTAssertEqual(tracker.update(quad: page(), at: 3.5625), .ready)
    }

    func testMinCornerDistance() {
        XCTAssertEqual(StabilityTracker.minCornerDistance(page(), page(dx: 0.3)), 0.3, accuracy: 1e-9)
        var partly = page(dx: 0.3)
        partly.bottomLeft = page().bottomLeft
        XCTAssertEqual(StabilityTracker.minCornerDistance(page(), partly), 0)
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
        XCTAssertLessThan(try XCTUnwrap(ready, "Hand shake should not prevent auto-capture"), 2.0)
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

final class StillnessDetectorTests: XCTestCase {
    private let rate = 30.0

    /// Adds samples every 1/30 s for frame indices `range`.
    private func add(_ detector: inout StillnessDetector, _ range: Range<Int>,
                     rotation: Double = 0.05, acceleration: Double = 0.01) {
        for k in range { detector.add(rotationRate: rotation, acceleration: acceleration, at: Double(k) / rate) }
    }

    func testNoSamplesIsNotStill() {
        XCTAssertFalse(StillnessDetector().isStill(at: 1))
    }

    func testNeedsTheWholeWindowCovered() {
        var detector = StillnessDetector() // window 0.35 s → first sample must be ≤ 0.2625 s before
        add(&detector, 0..<4) // 0 … 0.1 s
        XCTAssertFalse(detector.isStill(at: 0.1), "0.1 s of quiet samples is not enough")
        add(&detector, 4..<16) // up to 0.5 s
        XCTAssertTrue(detector.isStill(at: 0.5))
    }

    func testRightAfterStartIsNotStill() {
        var detector = StillnessDetector()
        add(&detector, 0..<8) // 0 … 0.233 s
        XCTAssertFalse(detector.isStill(at: 7 / rate))
        add(&detector, 8..<9) // 0.267 s
        XCTAssertTrue(detector.isStill(at: 8 / rate), "Covered once the first sample is 0.75 × window old")
    }

    func testOneFastRotationSampleIsNotStill() {
        var detector = StillnessDetector()
        add(&detector, 0..<10)
        add(&detector, 10..<11, rotation: 0.3)
        add(&detector, 11..<16)
        XCTAssertFalse(detector.isStill(at: 15 / rate))
        add(&detector, 16..<30)
        XCTAssertTrue(detector.isStill(at: 29 / rate), "Once the fast sample leaves the window the phone is still again")
    }

    func testOneAccelerationSampleIsNotStill() {
        var detector = StillnessDetector()
        add(&detector, 0..<10)
        add(&detector, 10..<11, acceleration: 0.08)
        add(&detector, 11..<16)
        XCTAssertFalse(detector.isStill(at: 15 / rate))
    }

    func testLimitsAreInclusive() {
        var detector = StillnessDetector()
        add(&detector, 0..<16, rotation: detector.maxRotationRate, acceleration: detector.maxAcceleration)
        XCTAssertTrue(detector.isStill(at: 15 / rate))
    }

    func testSlowSteadyDriftAboveTheRotationLimitIsNotStill() {
        // The case images can't catch: the hand pans smoothly, every frame looks steady.
        var detector = StillnessDetector()
        add(&detector, 0..<30, rotation: 0.25, acceleration: 0.0)
        XCTAssertFalse(detector.isStill(at: 29 / rate))
    }

    func testStaleSamplesAreNotStill() {
        var detector = StillnessDetector()
        add(&detector, 0..<16) // last sample at 0.5 s
        XCTAssertTrue(detector.isStill(at: 0.69), "0.19 s since the last sample is fine")
        XCTAssertFalse(detector.isStill(at: 0.71), "Motion updates stopped > 0.2 s ago: don't trust them")
        XCTAssertFalse(detector.isStill(at: 5))
    }

    func testSamplesAfterTheFrameTimeAreIgnored() {
        var detector = StillnessDetector()
        add(&detector, 0..<16)
        detector.add(rotationRate: 2, acceleration: 1, at: 0.6) // arrives after the frame at 0.55 was taken
        XCTAssertTrue(detector.isStill(at: 0.55))
        XCTAssertFalse(detector.isStill(at: 0.6))
    }

    func testReset() {
        var detector = StillnessDetector()
        add(&detector, 0..<16)
        detector.reset()
        XCTAssertFalse(detector.isStill(at: 0.5))
    }

    @MainActor
    func testMotionMonitorWithoutHardwareCountsAsStill() throws {
        let monitor = MotionMonitor()
        try XCTSkipIf(monitor.isAvailable, "Device has motion hardware")
        monitor.start()
        XCTAssertTrue(monitor.isStill(at: 0), "Simulator: image checks alone decide")
        monitor.stop()
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
        XCTAssertLessThan(StabilityTracker.maxCornerDistance(try XCTUnwrap(latest), page(0.1)), 1e-4)
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

// swiftlint:enable file_length type_body_length
