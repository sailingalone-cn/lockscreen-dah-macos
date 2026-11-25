import XCTest
@testable import LockscreenDah

/// The camera-gating rules. The whole point of these is that the emitters are
/// only lit when there is something to learn, so every branch is worth pinning:
/// a mistake here either strobes the LEDs continuously or leaves the screen
/// unwatched.
final class ActivityGateTests: XCTestCase {
    private let window: TimeInterval = 5
    private let interval: TimeInterval = 5
    private let duration: TimeInterval = 1.5

    private func decide(
        idle: TimeInterval,
        inputWindow: TimeInterval? = nil,
        running: Bool,
        burstStart: TimeInterval? = nil,
        nextCheck: TimeInterval = 0,
        now: TimeInterval = 100
    ) -> ActivityGate.Action {
        ActivityGate.decide(
            idle: idle,
            inputWindow: inputWindow ?? window,
            cameraRunning: running,
            burstStartedAt: burstStart,
            nextCheckAt: nextCheck,
            now: now,
            burstDuration: duration
        )
    }

    // MARK: - Input is presence

    func testRecentInputShutsTheCamera() {
        XCTAssertEqual(decide(idle: 1, running: true), .stopCamera)
    }

    func testRecentInputWithCameraAlreadyShutDoesNothing() {
        XCTAssertEqual(decide(idle: 1, running: false), .nothing)
    }

    /// A running *burst* is also ended by input — the user is back at the
    /// keyboard, so there is nothing left to look for.
    func testRecentInputEndsARunningBurst() {
        XCTAssertEqual(decide(idle: 1, running: true, burstStart: 99.8), .stopCamera)
    }

    func testInputWindowZeroDisablesGating() {
        XCTAssertEqual(decide(idle: 0, inputWindow: 0, running: true), .nothing)
    }

    // MARK: - Idle: quick checks

    func testIdleCameraShutStartsABurstWhenDue() {
        XCTAssertEqual(decide(idle: 30, running: false, nextCheck: 100), .startBurst)
    }

    func testIdleCameraShutWaitsForTheNextCheck() {
        XCTAssertEqual(decide(idle: 30, running: false, nextCheck: 105), .nothing)
    }

    func testBurstEndsWhenTheMaximumDurationExpires() {
        XCTAssertEqual(decide(idle: 30, running: true, burstStart: 98), .endBurst)
    }

    func testBurstStaysOpenUntilItsDurationExpires() {
        XCTAssertEqual(decide(idle: 30, running: true, burstStart: 99.5), .nothing)
    }

    /// Continuous watching (absence suspected) has no burst start, so nothing
    /// may shut it from here — the verdict or the grace deadline owns that.
    func testContinuousWatchingIsLeftAlone() {
        XCTAssertEqual(decide(idle: 30, running: true, burstStart: nil), .nothing)
    }

    /// Exactly at the boundary the burst is over, not still running.
    func testBurstDurationBoundary() {
        XCTAssertEqual(decide(idle: 30, running: true, burstStart: 98.5), .endBurst)
    }

    // MARK: - Dim mode pulses

    private func decideDim(
        running: Bool,
        start: TimeInterval? = nil,
        nextCheck: TimeInterval = 0,
        now: TimeInterval = 100,
        duration: TimeInterval = 1
    ) -> ActivityGate.Action {
        ActivityGate.decideDimmed(
            cameraRunning: running,
            checkStartedAt: start,
            nextCheckAt: nextCheck,
            now: now,
            checkDuration: duration
        )
    }

    func testDimmedStartsAPulseWhenDue() {
        XCTAssertEqual(decideDim(running: false, nextCheck: 100), .startBurst)
    }

    func testDimmedWaitsBetweenPulses() {
        XCTAssertEqual(decideDim(running: false, nextCheck: 103), .nothing)
    }

    func testDimmedPulseClosesWhenItsWindowExpires() {
        XCTAssertEqual(decideDim(running: true, start: 98.5), .stopCamera)
    }

    func testDimmedPulseStaysOpenUntilItsWindowExpires() {
        XCTAssertEqual(decideDim(running: true, start: 99.5), .nothing)
    }

    /// A dim pulse that found nobody is closed by the clock, never left open:
    /// the camera has nothing more to say until the next pulse.
    func testDimmedPulseDoesNotStayOpenForever() {
        XCTAssertEqual(decideDim(running: true, start: 0), .stopCamera)
    }

    /// A usable frame does **not** end the pulse. On this camera a face can
    /// first appear 1.0–1.25 s into a session, so closing on the first
    /// non-flat frame shut the camera 0.1–0.3 s before the face was detectable.
    /// The clock decides when an empty check ends.
    func testDimmedKeepsThePulseOpenDespiteAUsableFrame() {
        XCTAssertEqual(
            decideDim(running: true, start: 99.2, duration: 2),
            .nothing
        )
        XCTAssertEqual(
            decideDim(running: true, start: 97.5, duration: 2),
            .stopCamera
        )
    }

    /// An empty pulse runs to its maximum.
    func testDimmedMaxDuration() {
        XCTAssertEqual(
            decideDim(running: true, start: 98, duration: 2),
            .stopCamera
        )
    }

    func testDimmedWaitsBeforeTheMaximum() {
        XCTAssertEqual(
            decideDim(running: true, start: 99, duration: 2),
            .nothing
        )
    }
}
