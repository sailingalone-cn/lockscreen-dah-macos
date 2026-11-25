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
    ///
    /// The full `checkDuration` is used even after a usable (non-flat) frame
    /// arrives. Closing on the first usable frame saved emitter time, but on
    /// this camera a face can first appear 1.0–1.25 s into a session (measured:
    /// quick checks see `faces=1` at 1.05 s and 1.23 s), so the early close was
    /// shutting the camera 0.1–0.3 s before the face was detectable. The cost is
    /// roughly two extra analyses per empty pulse; being seen is worth it.
    static func decideDimmed(
        cameraRunning: Bool,
        checkStartedAt: TimeInterval?,
        nextCheckAt: TimeInterval,
        now: TimeInterval,
        checkDuration: TimeInterval
    ) -> Action {
        if cameraRunning {
            guard let started = checkStartedAt else { return .nothing }
            return now - started >= checkDuration ? .stopCamera : .nothing
        }
        return now >= nextCheckAt ? .startBurst : .nothing
    }
}
