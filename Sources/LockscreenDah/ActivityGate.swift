import Foundation

/// Decides when the capture session should actually be open.
///
/// Pure and total so the timing rules can be tested without a camera: the
/// coordinator owns the session, this owns only *when* it should run. The model
/// is a three-state cycle driven by input:
///
///   input recent        → camera shut, input itself is presence
///   idle, presence known→ short bursts every `quickCheckInterval`
///   burst inconclusive  → keep the camera open until presence or absence is
///                         settled (the coordinator ends it on a verdict or on
///                         the grace deadline)
///
/// `burstStartedAt` is non-nil only while a burst is in flight; a burst ends
/// early on a positive verdict (the coordinator stops the camera), and
/// `endBurst` here is what happens when the *maximum* duration expires with no
/// verdict — absence is then suspected and the camera must stay open.
enum ActivityGate {
    enum Action: Equatable {
        case nothing
        /// Input is recent: shut the sensor and treat input as presence.
        case stopCamera
        /// Idle and due: open the sensor for one quick check.
        case startBurst
        /// The quick check hit its time limit without a verdict; stop counting
        /// it as a burst and keep watching continuously.
        case endBurst
    }

    static func decide(
        idle: TimeInterval,
        inputWindow: TimeInterval,
        cameraRunning: Bool,
        burstStartedAt: TimeInterval?,
        nextCheckAt: TimeInterval,
        now: TimeInterval,
        burstDuration: TimeInterval
    ) -> Action {
        // Input wins over everything: someone is demonstrably at the machine.
        // `inputWindow == 0` means the user disabled gating entirely.
        if inputWindow > 0, idle < inputWindow {
            return cameraRunning ? .stopCamera : .nothing
        }
        if !cameraRunning {
            return now >= nextCheckAt ? .startBurst : .nothing
        }
        if let started = burstStartedAt, now - started >= burstDuration {
            return .endBurst
        }
        return .nothing
    }

    /// Dim mode's cycle. Same shape, but there is no input branch — the screen
    /// is black, so only a face (or Esc) ends it — and the end of a check always
    /// *closes* the camera: a check that found nobody has nothing more to say,
    /// and a check that found somebody is handled by the coordinator before this
    /// timer ever fires.
    static func decideDimmed(
        cameraRunning: Bool,
        checkStartedAt: TimeInterval?,
        nextCheckAt: TimeInterval,
        now: TimeInterval,
        checkDuration: TimeInterval,
        sawUsableFrame: Bool = false
    ) -> Action {
        if cameraRunning {
            guard let started = checkStartedAt else { return .nothing }
            let elapsed = now - started
            // A usable frame ends the check early — there is nothing more to
            // learn from keeping the camera open. The 0.5 s floor stops a
            // mid-warm-up frame (some variance, but not exposed yet) from ending
            // it before the sensor has settled.
            if sawUsableFrame, elapsed >= 0.5 { return .stopCamera }
            return elapsed >= checkDuration ? .stopCamera : .nothing
        }
        return now >= nextCheckAt ? .startBurst : .nothing
    }
}
