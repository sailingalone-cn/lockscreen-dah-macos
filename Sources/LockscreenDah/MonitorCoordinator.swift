import AppKit
import AVFoundation
import CoreGraphics
import LocalAuthentication

/// Owns the presence state machine. All state transitions happen on the main thread.
final class MonitorCoordinator {
    enum State: Equatable {
        case paused
        case watching
        case alerting(deadline: TimeInterval)
        /// Screens are blacked out but the session stays unlocked and the
        /// camera keeps looking, so the owner's face brings the screen back
        /// without a password. Entered instead of `.alerting` when
        /// `Settings.dimInsteadOfLock` is on.
        case dimmed
        case locked
        case enrolling
        /// The camera could not be started, and a retry is pending.
        ///
        /// Deliberately its own case rather than a flag on `.paused` or
        /// `.watching`. Not `.watching`, because nothing is being watched and
        /// the app must never claim protection it isn't providing. Not
        /// `.paused`, because the user didn't choose it: a pause consumes a
        /// schedule decision so it survives to the next boundary, which is right
        /// for a deliberate choice and badly wrong for a hardware stumble — it
        /// left a one-second camera hiccup disabling protection for the rest of
        /// the day.
        case cameraUnavailable
    }

    private(set) var state: State = .paused {
        didSet {
            if oldValue != state {
                Log.state.notice("\(oldValue.logName, privacy: .public) -> \(self.state.logName, privacy: .public)")
            }
            onStateChange?()
        }
    }
    var onStateChange: (() -> Void)?

    let recognizer = FaceRecognizer()
    private lazy var monitor: FaceMonitor = {
        let monitor = FaceMonitor(recognizer: recognizer)
        monitor.onResult = { [weak self] generationID, result in
            DispatchQueue.main.async {
                self?.handleDetection(result, from: generationID)
            }
        }
        return monitor
    }()
    private let overlay = CountdownOverlay()
    private lazy var enrollment: EnrollmentController = {
        let controller = EnrollmentController(recognizer: recognizer, monitor: monitor)
        controller.onFinished = { [weak self] in self?.enrollmentFinished() }
        controller.onProfileCommitted = { [weak self] in
            // A freshly saved profile is exactly what the requirement was
            // waiting for, and is also the condition for resuming.
            Settings.reenrollmentRequired = false
            Settings.consecutiveLocksWithoutMatch = 0 // fresh profile, clean slate
            self?.resumeAfterEnrollment = true
        }
        return controller
    }()

    private var tickTimer: Timer?
    /// Reconciliation timer. Unlike `tickTimer` this is never stopped by any
    /// state transition, because its entire job is to catch states that stopped
    /// something they shouldn't have.
    private var supervisorTimer: Timer?
    private let supervisionInterval: TimeInterval = 1
    /// Precise one-shot timer for firing the countdown exactly at the grace
    /// deadline — see `rescheduleGraceTimer()`. The 1 Hz `tickTimer` above
    /// only adjusts the adaptive sampling rate now; it no
    /// longer decides when to alert, since polling once a second can report
    /// an expired grace period up to ~1 s late.
    private lazy var graceTimer = DeadlineTimer { [weak self] in self?.handleGraceExpired() }
    /// Precise one-shot timer that fires the lock at the countdown deadline.
    /// Same reasoning as `graceTimer`: the 0.25 s `tickTimer` is for redrawing
    /// the overlay, and polling for the deadline on it landed the lock a
    /// measured ~0.13 s late on average (0.27 s worst case).
    private lazy var lockTimer = DeadlineTimer { [weak self] in self?.handleCountdownExpired() }
    /// Precise one-shot timer for the dim-mode pulse. The 1 s tick is far too
    /// coarse for a 1 s camera window — a 1 s setting measured 1.2–2.0 s of open
    /// time — and every extra 100 ms is emitter time the user can see.
    private lazy var dimTimer = DeadlineTimer { [weak self] in self?.advanceDimCycle() }
    /// The seat-continuity chain — see PresenceTracker for the model.
    private var presence = PresenceTracker()
    /// When the capture session was last asked to start. A countdown deadline
    /// can fall inside session spin-up on a short grace period, and "no frames
    /// yet" then means "too early to tell", not "camera broken" — see
    /// `handleGraceExpired`.
    private var cameraStartedAt = -Double.infinity
    /// A frame gap longer than this means a *running* pipeline has stopped.
    /// Frames arrive at the sensor's rate no matter how coarse the analysis
    /// throttle is, so this is unambiguous.
    ///
    /// It deliberately no longer doubles as the startup allowance. Fusing the two
    /// is what produced a restart loop: opening the device is far slower than a
    /// frame gap ever is, so a cold start was judged against a bar it could not
    /// meet, torn down, retried, and torn down again.
    private let cameraStaleAfter: TimeInterval = 3
    /// How long the device may take to produce its first frame before we call it
    /// broken.
    ///
    /// Measured on an M1 Pro built-in camera: ~3.7 s of session configuration,
    /// then 4.03 s from the daemon being asked to stream to frames actually
    /// flowing (ISP power-on alone is 1.8 s), and a worst observed first result
    /// of 19.85 s under contention. Against the 3 s bar the app declared the
    /// camera dead *0.66 s before the system had even been asked to stream*.
    /// Bounded rather than unlimited, so a device that never comes up is still
    /// caught — just not before it has had a fair chance.
    private let cameraStartupAllowance: TimeInterval = 15
    /// Consecutive failures to start the camera. Any delivered frame clears it.
    /// When the current capture session first produced an analysis result, as
    /// opposed to a frame. Nil until then; see `graceAnchor`.
    private var firstResultAt: TimeInterval?
    /// The most recent analysis result. Distinct from `firstResultAt`: that one
    /// answers "has recognition warmed up yet", this one answers "is anything
    /// still looking at the frames". Frames arriving proves only that the camera
    /// is alive.
    private var lastResultAt: TimeInterval?
    /// True while the capture session is deliberately stopped — input is proof
    /// of presence, or a quick check just finished. Liveness must not read this
    /// as a camera failure, and `handleGraceExpired` must not conclude absence
    /// from it.
    private var cameraGated = true
    /// Start of the in-flight quick check, if any.
    private var burstStartedAt: TimeInterval?
    /// Earliest instant the next quick check may open the camera.
    private var nextCheckAt: TimeInterval = 0
    /// How long analysis may go quiet before it counts as stalled. Derived from
    /// the current cadence rather than fixed, because results are throttled by
    /// design — at the idle interval of 2.5 s a fixed 3 s bar would call a
    /// healthy pipeline dead. Four intervals is the same margin the cadence
    /// itself is built on.
    private var analysisStaleAfter: TimeInterval {
        max(cameraStaleAfter, 4 * monitor.analysisInterval)
    }
    /// How long the whole startup may take to produce its first verdict. The
    /// worst observed result under contention was 19.85 s after start, so 25 s
    /// leaves measured headroom without allowing a frames-but-no-thinking
    /// pipeline to remain blind forever.
    ///
    /// Shared by liveness and `graceAnchor`: before this expires, no-result is
    /// warm-up and absence cannot be proved; after it expires, the exact same
    /// condition is an analysis stall and routes to recovery rather than a lock.
    private let firstAnalysisAllowance: TimeInterval = 25
    private var cameraFailures = 0
    /// Backoff before each retry, holding at the last value. Retrying never
    /// stops: the reason to keep trying — that the screen is unprotected — does
    /// not expire, and a camera held by another app for ten minutes must not
    /// cost protection for the rest of the day.
    private let cameraRetryDelays: [TimeInterval] = [30, 60, 300]
    /// Announced once per outage; after that the icon and status line carry it,
    /// because a modal every five minutes only trains people to dismiss it.
    private var cameraFailureAnnounced = false
    private lazy var cameraRetryTimer = DeadlineTimer { [weak self] in self?.retryCamera() }

    /// "Never Countdown" removes the overlay, and with it the Esc gesture — the
    /// only way out when recognition has stopped matching the owner. Being locked
    /// once is harmless: you log back in. Being locked again a second later,
    /// indefinitely, is a trap with no in-app way out. So once this many locks
    /// have fired with no match in between, a minimum countdown is forced back on
    /// purely so the escape gesture exists again.
    private let lockLoopThreshold = 2
    private let minimumEscapeCountdown: TimeInterval = 3

    /// The countdown length actually used: the setting, except while a lock loop
    /// is being detected.
    private var effectiveCountdownDuration: TimeInterval {
        guard Settings.consecutiveLocksWithoutMatch >= lockLoopThreshold else {
            return Settings.countdownDuration
        }
        return max(Settings.countdownDuration, minimumEscapeCountdown)
    }
    /// Cadence while absence is suspected / countdown running. Deliberately
    /// below the sensor's frame period (capped at 3 fps, so 0.333 s) to make
    /// sure every captured frame is actually analyzed: the previous 0.4 s
    /// rounded up to two frame periods, silently discarding every other frame
    /// already paid for, which doubled both the countdown's timing error and
    /// the time needed to cancel one.
    private let fastAnalysisInterval: TimeInterval = 0.25
    /// Cadence while dimmed, read live so a menu change applies on the next
    /// analysis tick instead of the next dim cycle.
    private var dimmedAnalysisInterval: TimeInterval { Settings.dimmedCheckInterval }
    /// Steady-state cadence while the presence chain is healthy. Scales with
    /// the countdown delay — a long delay doesn't need frequent sampling — and
    /// is capped at 2.5 s so the 3-frame stranger challenge always resolves
    /// within ~8 s of a stranger facing the screen. The divisor sets how many
    /// detection attempts fit inside the delay (~4), which is what keeps one
    /// bad frame from becoming a blackout.
    private var idleAnalysisInterval: TimeInterval {
        min(max(Settings.gracePeriod / 4, fastAnalysisInterval), 2.5)
    }

    /// Whether monitoring was active when enrollment began (restored after).
    private var resumeAfterEnrollment = false

    /// Start of the in-flight dim-mode check, if any.
    private var dimCheckStartedAt: TimeInterval?
    /// Earliest instant the next dim-mode check may open the camera.
    private var nextDimCheckAt: TimeInterval = 0

    // Esc is the escape hatch for when recognition has failed the real owner, so
    // it must exist — but a single un-checked press would also be exactly what an
    // intruder wants. It takes three presses on the *same* overlay, which then
    // asks the Mac to verify who's pressing. Scoped per overlay (the shortest
    // countdown is 3 s, ample for three presses), so nothing carries over.
    private var escPressesThisAlert = 0
    private let escPressLimit = 3
    /// Set while the Touch ID prompt is up.
    private var authenticatingEscape = false
    /// Held so an unanswered prompt can be torn down when its grace expires.
    private var escapeAuthContext: LAContext?
    /// How long the lock may be *deferred* while the owner authenticates —
    /// bounded on purpose. Cancelling the lock outright meant a prompt nobody
    /// ever answered held the machine open indefinitely behind what looks like a
    /// sleeping display, which turned the escape hatch into an off switch.
    private let escapeAuthGrace: TimeInterval = 15
    /// Verification attempts allowed per overlay. Without a cap, every press
    /// after the third re-prompted, so an intruder could keep deferring.
    private var escapeAuthAttempts = 0
    private let escapeAuthAttemptLimit = 2

    // Monitoring hours: a light timer re-derives the correct state directly
    // from elapsed wall-clock time (see resolveSchedule/lastDecisionAt) rather
    // than edge-detecting the previous tick's value — that's what lets a
    // boundary crossed while asleep/locked still resolve correctly, and lets
    // lock/unlock resolution (resumeFromLocked) share the exact same rule.
    // Between boundaries the user's manual Start/Pause always wins (a manual
    // pause at 10:00 stays paused until tomorrow's start time).
    private var scheduleTimer: Timer?
    /// Wall-clock time of the last real "start watching" / "stop watching"
    /// decision — manual (menu toggle) or schedule-driven. A schedule
    /// boundary is acted on only once it postdates this; see
    /// `resolveSchedule`. `nil` until `startPerSchedule()` stamps it at launch.
    private var lastDecisionAt: Date?

    init() {
        overlay.onEscape = { [weak self] in self?.handleEscPress() }
        observeLockAndSleepEvents()
        startScheduleTimer()
    }

    // MARK: - Public controls

    func startMonitoring() {
        // An outstanding re-enrollment outranks every automatic start — schedule
        // boundary, unlock, display wake. Recognition has already been shown not
        // to match the owner, so resuming without a fresh profile would just
        // replay the same countdown-and-Esc cycle. Only the manual menu action
        // proceeds, and it routes into enrollment instead (see AppDelegate).
        guard !Settings.reenrollmentRequired else {
            state = .paused
            return
        }
        // Stamp before the (possibly async) permission check so a denial
        // still consumes this decision — otherwise the schedule timer would
        // retry (and re-alert) every ~30s. beginWatching() stamps again on
        // success; redundant but harmless.
        lastDecisionAt = Date()
        withCameraPermission { [weak self] in self?.beginWatching() }
    }

    /// Launch entry point. No prior decision exists yet to compare a boundary
    /// against, so this always acts on the live schedule directly.
    func startPerSchedule() {
        startSupervisor()
        lastDecisionAt = Date()
        guard Settings.schedule.isActive(at: Date()) else {
            state = .paused // refreshes the status line to "off hours"
            return
        }
        ScreenLocker.sessionIsLocked ? enterLockedState() : startMonitoring()
    }

    /// Called when the user changes any monitoring-hours setting: enforce the
    /// new schedule immediately, regardless of lastDecisionAt — the user just
    /// explicitly asked to apply new hours.
    func scheduleSettingsChanged() {
        // Deliberately does NOT check `scheduleEnabled`. The panel writes that
        // flag before calling this, so ticking "Always on" — the one change that
        // *expands* coverage to 24/7 — used to guard itself out and leave the app
        // paused while the UI claimed it was always on. `withinMonitoringHours()`
        // already returns true when the schedule is off, so this does the right
        // thing either way.
        guard state != .enrolling else { return }
        applySchedule(within: Settings.schedule.isActive(at: Date()))
    }

    func pause() {
        guard state != .paused else { return }
        overlay.dismiss()
        DisplayBrightness.restore()
        cancelEscapeAuth()
        enrollment.abort()
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        dimTimer.cancel()
        cameraRetryTimer.cancel()
        monitor.stop()
        lastDecisionAt = Date() // a real "not watching" decision — see resolveSchedule
        state = .paused
    }

    /// Process exit. Stops the stream synchronously so the camera daemon is not
    /// left with a half-open UVC session, which is what wedged the IR device.
    func shutdownCamera() {
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        dimTimer.cancel()
        cameraRetryTimer.cancel()
        overlay.dismiss()
        DisplayBrightness.restore()
        monitor.shutdown()
    }

    var statusDescription: String {
        switch state {
        case .cameraUnavailable:
            return "摄像头不可用，正在重试"
        case .paused:
            if Settings.reenrollmentRequired { return "已暂停（需要重新录入）" }
            if Settings.scheduleEnabled, !Settings.schedule.isActive(at: Date()) {
                // Distinguish the two reasons: "off hours" on a working day is
                // expected, whereas being paused because today isn't a selected
                // day is easy to forget you configured.
                let today = Calendar.current.component(.weekday, from: Date())
                return Settings.activeDays.contains(today)
                    ? "已暂停（非监测时段）"
                    : "已暂停（\(Weekday.name(today))未启用）"
            }
            return "已暂停"
        // Alerting/locked keep the watching text — the overlay or lock screen
        // is what the user sees; a special status would never be read.
        case .watching, .alerting, .locked:
            if recognizer.isPresenceOnly { return "监测中（任意人脸）" }
            return "监测中（等待你）"
        case .dimmed:
            return recognizer.isPresenceOnly
                ? "已灭屏（任意人脸唤醒）"
                : "已灭屏（等待你回来）"
        case .enrolling: return "正在录入人脸…"
        }
    }

    // MARK: - State transitions

    private func beginWatching() {
        cameraRetryTimer.cancel()
        dimTimer.cancel()
        overlay.dismiss()
        presence.reset()
        lastDecisionAt = Date() // a real "watching" decision — see resolveSchedule
        monitor.analysisInterval = fastAnalysisInterval
        cameraStartedAt = Uptime.now
        firstResultAt = nil
        lastResultAt = nil
        // Deliberately do not open the sensor here. The first tick decides, and
        // if someone is at the keyboard the answer is already known — opening it
        // at start is what made the emitters strobe from the moment monitoring
        // began.
        cameraGated = true
        burstStartedAt = nil
        nextCheckAt = Uptime.now
        Log.camera.notice("watching; camera gated until input goes idle")
        startTick(interval: 1)
        state = .watching
        rescheduleGraceTimer()
    }

    /// True when capture or analysis has stopped delivering. Startup, frame gaps
    /// and result gaps have separate bars because they are different failure
    /// signals with very different healthy timing.
    /// Delegates to `CameraLiveness`, which is pure and therefore testable —
    /// this rule previously lived here, where no test could reach it, and shipped
    /// a restart loop. One helper because two callers ask the question (the
    /// supervisor and the grace-expiry path), and a rule duplicated across both
    /// is a rule that eventually disagrees with itself.
    private func cameraLiveness(now: TimeInterval) -> CameraLiveness.Reading {
        CameraLiveness.evaluate(
            now: now,
            requestedAt: cameraStartedAt,
            streamingSince: monitor.streamingSinceAt,
            lastFrameAt: monitor.lastFrameAt,
            lastResultAt: lastResultAt,
            staleAfter: cameraStaleAfter,
            startupAllowance: cameraStartupAllowance,
            firstAnalysisAllowance: firstAnalysisAllowance,
            analysisStaleAfter: analysisStaleAfter
        )
    }

    private func cameraIsStale(now: TimeInterval) -> Bool {
        cameraLiveness(now: now).isStale
    }

    private var isAlerting: Bool {
        if case .alerting = state { return true }
        return false
    }

    /// The camera stopped delivering. Two things matter here, and they pull in
    /// opposite directions.
    ///
    /// Absence measured while blind is not evidence of absence — locking on it
    /// would punish the user for our failure, and repeatedly locking because our
    /// own camera is broken is a trap, not protection. But absence that had
    /// *already* passed the deadline before we went blind is real evidence,
    /// gathered while we could still see. So that case locks, once; every other
    /// case holds the screen and retries.
    private func handleCameraStopped(now: TimeInterval) {
        let liveness = cameraLiveness(now: now)
        // `gap` begins where sight stopped: the last frame, the last analysis
        // result, or the original request when no result ever arrived. Only a
        // grace deadline that had already passed by that instant is evidence of
        // absence gathered while sight still worked. Comparing against `now`
        // would charge the blind interval as absence and lock during recovery.
        let absenceWasAlreadyProven = liveness.absenceWasProven(
            now: now,
            graceAnchor: graceAnchor,
            gracePeriod: Settings.gracePeriod
        )
        Log.camera.error("pipeline stalled (\(String(describing: liveness.stall), privacy: .public)); absenceAlreadyProven=\(absenceWasAlreadyProven, privacy: .public)")

        overlay.dismiss()
        DisplayBrightness.restore()
        cancelEscapeAuth()
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        // teardown(), not stop(): the retry that follows must rebuild the capture
        // graph. `configureIfNeeded` short-circuits while `configured` is true,
        // so a plain stop/start only ever re-issues startRunning() against the
        // same inputs and outputs — which recovers a briefly-busy device and
        // nothing else.
        monitor.teardown()

        // Dim mode never locks: the user opted out of passwords on return, and
        // a camera fault must not be the thing that forces one. Park instead —
        // the retry ladder owns recovery.
        if absenceWasAlreadyProven && !Settings.dimInsteadOfLock {
            // We saw you leave before we went blind. Locking is warranted, and
            // the unlock path re-anchors presence so this can't become a loop.
            lockNow()
            return
        }

        state = .cameraUnavailable
        // `lastDecisionAt` is deliberately untouched: stamping it would tell the
        // scheduler a decision was made, and monitoring could then not resume
        // until the next boundary — turning a momentary fault into hours of
        // silent exposure.
        let delay = cameraRetryDelays[min(cameraFailures, cameraRetryDelays.count - 1)]
        cameraFailures += 1
        Log.camera.notice("retry \(self.cameraFailures, privacy: .public) in \(delay, privacy: .public)s")
        cameraRetryTimer.schedule(at: Uptime.now + delay)

        guard cameraFailures >= cameraRetryDelays.count, !cameraFailureAnnounced else { return }
        cameraFailureAnnounced = true
        showAlert(
            title: "摄像头不可用",
            message: "Lockscreen Dah 无法通过摄像头看到画面，你的屏幕目前没有受到保护。它会持续重试，摄像头恢复后自动继续——请检查是否有其他程序正在占用摄像头。期间菜单栏会显示带斜杠的摄像头图标。"
        )
    }

    private func retryCamera() {
        guard state == .cameraUnavailable else { return }
        // Don't fight the schedule: if the window closed while retrying, settle
        // into a normal pause instead.
        guard Settings.schedule.isActive(at: Date()) else {
            state = .paused
            return
        }
        beginWatching()
    }

    private func beginAlert() {
        stopGraceTimer() // its job is done; lockTimer owns the next deadline
        presence.breakChain() // the countdown is the identity gate
        escPressesThisAlert = 0
        escapeAuthAttempts = 0
        cancelEscapeAuth()
        monitor.analysisInterval = fastAnalysisInterval
        overlay.show(remaining: effectiveCountdownDuration)
        // Anchored AFTER the overlay is up, not before: show() builds a window
        // per screen and does an app-activation round trip, and charging that
        // setup to the user's warning time made the lock fire early on every
        // single countdown.
        let deadline = Uptime.now + effectiveCountdownDuration
        startTick(interval: 0.25) // overlay redraw only
        state = .alerting(deadline: deadline)
        scheduleLockTimer(at: deadline)
    }

    private func cancelAlert() {
        guard case .alerting = state else { return }
        stopLockTimer()
        overlay.dismiss()
        presence.touch()
        monitor.analysisInterval = idleAnalysisInterval
        startTick(interval: 1)
        state = .watching
        rescheduleGraceTimer()
    }

    // MARK: - Dim mode

    /// Confirmed absence in dim mode: black every screen, keep the camera
    /// running at a low cadence, and wait for a face. Deliberately no lock —
    /// locking is what makes returning cost a password, which is the thing dim
    /// mode exists to avoid.
    private func enterDimmed() {
        stopGraceTimer()
        stopLockTimer()
        presence.breakChain()
        // Dim mode checks in pulses too: the screen is black, so the camera
        // only needs to be open long enough to spot a face. Leaving it running
        // is what kept the emitters and the camera LED lit at an empty desk.
        monitor.stop()
        cameraGated = true
        dimCheckStartedAt = nil
        nextDimCheckAt = Uptime.now
        dimTimer.schedule(at: nextDimCheckAt)
        monitor.analysisInterval = fastAnalysisInterval
        overlay.showBlank()
        DisplayBrightness.dim()
        state = .dimmed
        Log.state.notice("dimmed; waiting for a face")
    }

    /// A face (or, in presence-only mode, a body) is back. Restore the screen
    /// and restart the grace clock from now, so a head that immediately turns
    /// away does not black the screen out again on the next frame.
    /// Why the screen came back, so the log can distinguish "the camera saw
    /// you" from "you pressed Esc" — the old blanket "presence detected" made a
    /// blind camera look healthy.
    private enum WakeReason: String {
        case face
        case body
        case input
        case escape
        case setting
    }

    private func exitDimmed(reason: WakeReason) {
        guard state == .dimmed else { return }
        overlay.dismiss()
        DisplayBrightness.restore()
        presence.establish()
        Settings.consecutiveLocksWithoutMatch = 0
        if !cameraGated {
            monitor.stop()
            cameraGated = true
        }
        dimCheckStartedAt = nil
        dimTimer.cancel()
        monitor.analysisInterval = fastAnalysisInterval
        state = .watching
        rescheduleGraceTimer()
        // We just saw a face, so the next check is a full interval away — the
        // old "check now" made the camera reopen 0.5 s after undimming.
        nextCheckAt = Uptime.now + Settings.quickCheckInterval
        updateCameraGate(now: Uptime.now)
        Log.state.notice("undimmed; reason=\(reason.rawValue, privacy: .public)")
    }

    /// The user flipped the dim-mode switch while the screen was already black.
    /// Wake it rather than leaving a black screen whose setting no longer
    /// explains it; the next absence goes through the normal countdown.
    func dimModeSettingChanged() {
        guard state == .dimmed, !Settings.dimInsteadOfLock else { return }
        exitDimmed(reason: .setting)
    }

    /// One Esc press on the countdown overlay. Deliberately does **not** cancel:
    /// a single un-checked keypress that dismisses a countdown is exactly the
    /// bypass an intruder would use. Three presses ask the Mac who's pressing.
    /// Dismisses any in-flight verification prompt. Called whenever the alert it
    /// belongs to is abandoned, so a stale prompt can't answer into a new state.
    private func cancelEscapeAuth() {
        escapeAuthContext?.invalidate()
        escapeAuthContext = nil
        authenticatingEscape = false
    }

    private func handleEscPress() {
        if state == .dimmed {
            // Dim mode is not a lock: one Esc is an unauthenticated way back
            // for the case recognition can't see the owner (head down, hand
            // over the lens). It reveals a desktop that was never locked, so
            // there is no protection to defeat.
            exitDimmed(reason: .escape)
            return
        }
        guard case .alerting(let deadline) = state, !authenticatingEscape else { return }
        escPressesThisAlert += 1

        guard escapeAuthAttempts < escapeAuthAttemptLimit else {
            // Out of attempts: say so plainly and let the countdown finish.
            overlay.setHint("验证失败，锁屏后请重新登录")
            return
        }
        let remaining = escPressLimit - escPressesThisAlert
        guard remaining <= 0 else {
            // Only now reveal the gesture — a passerby sees a blank screen.
            overlay.setHint("再按 \(remaining) 次 Esc 以验证身份")
            return
        }
        confirmEscape(deadline: deadline)
    }

    /// Holds the lock, verifies with the Mac's own authentication, and only then
    /// stops fighting the user. Failing or dismissing the prompt restores the
    /// countdown exactly where it was, so an intruder gains nothing and the
    /// screen still locks; the owner passes it and monitoring pauses until they
    /// re-enroll, since recognition has demonstrably stopped matching them.
    private func confirmEscape(deadline: TimeInterval) {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // Nothing to verify against — leave the countdown running rather
            // than granting an unverified escape.
            overlay.setHint("此 Mac 无法验证身份")
            return
        }

        authenticatingEscape = true
        escapeAuthContext = context
        stopTick()
        overlay.setHint("正在验证…")
        // Deferred, never cancelled. An unanswered prompt is not consent, so the
        // lock still fires once the grace runs out.
        scheduleLockTimer(at: max(deadline, Uptime.now + escapeAuthGrace))

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "阻止 Lockscreen Dah 锁屏"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authenticatingEscape = false
                self.escapeAuthContext = nil
                guard success else {
                    // Put the countdown back exactly where it was, dropping the
                    // deferral. A deadline already past fires at once, which is
                    // the correct outcome. Presses reset so a further attempt
                    // costs three again rather than one.
                    guard case .alerting = self.state else { return }
                    self.escapeAuthAttempts += 1
                    self.escPressesThisAlert = 0
                    self.overlay.setHint(nil)
                    self.startTick(interval: 0.25)
                    self.scheduleLockTimer(at: deadline)
                    return
                }
                Settings.reenrollmentRequired = true
                self.pause()
                self.showAlert(
                    title: "监测已暂停",
                    message: "人脸识别无法稳定匹配你，监测已暂停，你的屏幕目前没有受到保护。点击「开始监测」会引导你重新录入人脸；在新档案保存之前，旧档案仍然有效。"
                )
            }
        }
    }

    private func lockNow() {
        Log.lock.notice("locking; consecutiveWithoutMatch=\(Settings.consecutiveLocksWithoutMatch + 1, privacy: .public)")
        // Counted before the lock, since the lock itself ends this session.
        Settings.consecutiveLocksWithoutMatch += 1
        enterLockedState()
        ScreenLocker.lock()
        // Both lock APIs are best-effort — confirm the session really locked,
        // otherwise the app would sit in .locked (camera off, no unlock
        // notification ever coming) while the desktop stays exposed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state == .locked, !ScreenLocker.sessionIsLocked else { return }
            Log.lock.fault("macOS rejected the lock request; monitoring paused")
            self.pause()
            self.showAlert(
                title: "锁屏失败",
                message: "Lockscreen Dah 无法锁屏：倒计时已结束，但 macOS 拒绝了锁屏请求。监测已暂停，问题解决前你的屏幕没有受到保护。"
            )
        }
    }

    private func enterLockedState() {
        overlay.dismiss()
        DisplayBrightness.restore()
        cancelEscapeAuth()
        stopGraceTimer()
        stopLockTimer()
        dimTimer.cancel()
        monitor.stop()
        state = .locked
    }

    // MARK: - Detection handling

    private func handleDetection(_ result: DetectionResult, from generationID: Int) {
        // The generation checked this immediately before emitting, but delivery
        // crosses to the main queue. Teardown can invalidate it in that gap; a
        // second check here makes the refusal atomic with coordinator handling.
        guard monitor.generationIsActive(generationID) else { return }
        // Frames are arriving; the camera is demonstrably fine — but only if this
        // result belongs to the *current* session. Results from an already torn
        // down session still arrive — measured 5.6 s after teardown — and one is
        // evidence about a moment that has passed, not about now.
        //
        // Dropped outright rather than filtered per-consumer, because every
        // consumer is wrong to trust it: it cleared the failure counter so the
        // retry ladder never escalated ("retry 1 in 30s" seven times in a row);
        // `presence.observe` stamps `lastOwnerSeen` with the frame's own capture
        // instant, so a stale match moved the presence clock *backwards* and
        // could put the grace deadline in the past; and in `.alerting` a stale
        // match would cancel a countdown that is still legitimately running.
        guard result.capturedAt >= cameraStartedAt else { return }

        cameraFailures = 0
        cameraFailureAnnounced = false
        lastResultAt = Uptime.now
        if firstResultAt == nil {
            firstResultAt = Uptime.now
            Log.camera.notice("first analysis result \(self.firstResultAt! - self.cameraStartedAt, format: .fixed(precision: 2), privacy: .public)s after start")
            // The anchor just moved forward, so any deadline computed from the
            // old one is now wrong.
            rescheduleGraceTimer()
        }
        switch state {
        case .watching:
            // Cadence is owned by handleTick: fast sampling kicks in only when
            // absence is actually suspected, not merely because the current
            // frame didn't match (head turned to a second screen is the
            // steady state, and the chain keeps absence at ~0 there).
            // Stamped with the frame's own capture instant, not "now": the
            // analysis pipeline plus the hop onto this thread is 100-400 ms,
            // and charging that to absence made the countdown that much late.
            if presence.observe(result, now: result.capturedAt, presenceOnly: recognizer.isPresenceOnly) {
                Settings.consecutiveLocksWithoutMatch = 0
                // A positive verdict is the whole point of a quick check: keep
                // the sensor on for another frame or two is pure emitter time.
                // Gating off (`inputPresenceWindow == 0`) means the user asked
                // for continuous capture, so leave it running.
                if Settings.inputPresenceWindow > 0, !cameraGated {
                    stopCameraForPresence()
                }
            }
            // Every observation can move lastOwnerSeen forward (or leave it
            // put) — reschedule unconditionally rather than trying to detect
            // which; rescheduling to an unchanged deadline is a no-op cost.
            rescheduleGraceTimer()
        case .alerting:
            // Only a positive owner match (or Esc) dismisses the countdown —
            // an unmatched face alone can't keep the screen open.
            if result.ownerMatched {
                Settings.consecutiveLocksWithoutMatch = 0
                presence.establish()
                cancelAlert()
            }
        case .enrolling:
            enrollment.handleDetection(result)
        case .dimmed:
            // The check runs to its full duration: a face can first appear
            // 1.0–1.25 s into a session on this camera (measured: quick checks
            // see faces=1 at 1.05 s and 1.23 s), and the old early close shut
            // the camera 0.1–0.3 s before that. Only a face/body verdict ends
            // the pulse early; an empty frame no longer does.
            // A face is the primary way back; body-only frames count too in
            // presence-only mode, so someone who returns with their head turned
            // still gets their screen back.
            if result.ownerMatched {
                exitDimmed(reason: .face)
            } else if recognizer.isPresenceOnly, result.bodyCount > 0 {
                exitDimmed(reason: .body)
            }
        case .paused, .locked, .cameraUnavailable:
            break
        }
    }

    /// 1 s granularity is plenty against a multi-second grace period; only the
    /// countdown redraw during .alerting needs the fast 0.25 s cadence.
    // MARK: - Supervision

    /// Runs for the entire life of the app, at a fixed cadence, regardless of
    /// state. Every other timer here is started and stopped by transitions —
    /// which is exactly why they cannot be trusted to notice a transition that
    /// went wrong.
    private func startSupervisor() {
        supervisorTimer?.invalidate()
        let timer = Timer(timeInterval: supervisionInterval, repeats: true) { [weak self] _ in
            self?.superviseInvariants()
        }
        timer.tolerance = supervisionInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        supervisorTimer = timer
    }

    /// Re-derives what *should* be true from facts that can be read directly —
    /// the session's lock state and whether capture is actually running — and
    /// corrects anything that disagrees.
    ///
    /// This exists because "the camera is off while monitoring says it is on"
    /// was reported three times with three unrelated causes: a failure path that
    /// paused for the day, a retry ladder that gave up, and a missed unlock
    /// notification that stranded `.locked` with every timer stopped. Each was
    /// fixed where it happened, and the next one arrived somewhere else. The
    /// pattern is the finding: recovery was attached to whichever code path
    /// happened to stop the camera, so any path nobody anticipated had none.
    ///
    /// So this asks the two questions that matter — *should the camera be on,
    /// and is it?* — without caring how it got that way. Remedies are delegated
    /// to the existing paths so their backoff and lock-safety rules still apply;
    /// this only detects.
    /// The state, reduced to what a decision depends on.
    private var supervisedState: SupervisedState {
        switch state {
        case .paused: return .paused
        case .watching: return .watching
        case .alerting: return .alerting
        case .locked: return .locked
        case .enrolling: return .enrolling
        case .cameraUnavailable: return .cameraUnavailable
        case .dimmed: return .dimmed
        }
    }

    /// Re-derives what should be true and corrects whatever disagrees. Called
    /// on a fixed cadence *and* from every lock/sleep notification, so the two
    /// cannot drift apart — a notification is a prompt to re-decide, never a
    /// separate path with its own rules.
    private func superviseInvariants() {
        let now = Uptime.now
        // A camera stopped on purpose is not a camera failure. Only the session
        // lock still outranks the gate: a locked screen must park the state.
        if cameraGated, state == .watching || state == .dimmed {
            if ScreenLocker.sessionIsLocked || ScreenLocker.displayIsAsleep { enterLockedState() }
            return
        }
        // Both halves come from one helper: the bar varies with whether the
        // session is streaming yet, and passing a gap measured one way against a
        // bar meant for the other is the whole bug this replaced.
        let liveness = cameraLiveness(now: now)
        let decision = PresenceSupervisor.decide(
            state: supervisedState,
            conditions: SystemConditions(
                sessionLocked: ScreenLocker.sessionIsLocked,
                displayAsleep: ScreenLocker.displayIsAsleep,
                secondsSinceLastFrame: liveness.gap,
                secondsSinceOwnerSeen: now - graceAnchor
            ),
            gracePeriod: Settings.gracePeriod,
            staleAfter: liveness.bar,
            dimOnly: Settings.dimInsteadOfLock
        )
        if decision != .doNothing {
            // The conditions, not just the outcome: which fact drove it is the
            // whole question when a camera is unexpectedly off.
            Log.state.notice("supervisor decided \(String(describing: decision), privacy: .public) in \(self.state.logName, privacy: .public): sessionLocked=\(ScreenLocker.sessionIsLocked, privacy: .public) displayAsleep=\(ScreenLocker.displayIsAsleep, privacy: .public) gap=\(liveness.gap, format: .fixed(precision: 1), privacy: .public)s bar=\(liveness.bar, format: .fixed(precision: 0), privacy: .public)s stall=\(String(describing: liveness.stall), privacy: .public) streaming=\(self.monitor.streamingSinceAt != nil, privacy: .public)")
        }
        switch decision {
        case .doNothing: break
        case .resumeFromLocked: resumeFromLocked()
        case .enterLocked: enterLockedState()
        case .cameraStopped: handleCameraStopped(now: now)
        case .lockNow: lockNow()
        }
    }

    private func startTick(interval: TimeInterval) {
        stopTick()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleTick()
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Schedules (or reschedules) the precise one-shot timer that fires the
    /// countdown exactly `gracePeriod` seconds after presence was last
    /// confirmed. Call this every time `presence`'s `lastOwnerSeen` might
    /// have moved forward (a fresh observation or Esc-cancel) — rescheduling
    /// to the same deadline when nothing changed is
    /// harmless. No tolerance is set: unlike `tickTimer`, this one exists
    /// specifically to be on time.
    /// The instant the grace clock counts from: the later of confirmed presence
    /// and analysis readiness. `presence.reset()` stamps `beginWatching`, when
    /// the pipeline is provably blind; readiness advances until the first result
    /// or the bounded first-analysis allowance.
    private var graceAnchor: TimeInterval {
        // A frame nobody has analysed yet is as blind as no frame at all. The
        // first Core ML inference carries model load and ANE warm-up — measured
        // at ~2.3 s from first frame on this machine, while the first frame
        // itself arrived in ~150 ms — so anchoring to the frame let a 1 s grace
        // expire before recognition could possibly have answered, blacking out a
        // seated user on every start. Anchor to the first *verdict*.
        //
        // Bounded by the same allowance as analysis liveness. Until then the
        // pipeline is warming up and a no-result frame stream cannot prove
        // absence. Once it expires, liveness calls it an analysis stall and the
        // recovery path wins before a grace deadline can turn blindness into a
        // lock.
        let readiness = firstResultAt
            ?? min(Uptime.now, cameraStartedAt + firstAnalysisAllowance)
        return max(presence.lastOwnerSeen, readiness)
    }

    private func rescheduleGraceTimer() {
        scheduleGraceTimer(at: graceAnchor + Settings.gracePeriod)
    }

    /// `deadline` is a monotonic uptime instant, and the timer is scheduled as a
    /// *delay* off `DispatchTime` rather than an absolute wall-clock fire date:
    /// a `Timer(fire: Date)` stores CFAbsoluteTime, so a forward clock step
    /// fired it early. See Uptime.
    private func scheduleGraceTimer(at deadline: TimeInterval) {
        graceTimer.schedule(at: deadline)
    }

    private func stopGraceTimer() {
        graceTimer.cancel()
    }

    /// Fires at the scheduled deadline. Re-verifies absence has actually
    /// reached the grace period rather than trusting the timer blindly — a
    /// safety net in case some path ever refreshes presence without also
    /// rescheduling, which would otherwise risk a premature alert.
    private func handleGraceExpired() {
        guard state == .watching else { return }
        let now = Uptime.now
        // No frame can be had while the gate is shut, so absence cannot be
        // concluded from it. Wait for the next quick check instead of
        // re-firing this timer every second.
        if cameraGated {
            // Must be in the future: a zero-delay re-arm here spun the main
            // queue forever (the handler kept re-scheduling the same past
            // deadline). `now + 0.5` is the floor that makes that impossible.
            scheduleGraceTimer(
                at: max(Uptime.now + 0.5,
                        max(graceAnchor + Settings.gracePeriod,
                            nextCheckAt + Settings.quickCheckDuration))
            )
            return
        }
        guard now - graceAnchor >= Settings.gracePeriod else {
            rescheduleGraceTimer()
            return
        }
        // Absence only means something if the camera was actually looking. One
        // rule, shared with the tick supervisor, so the two can't disagree.
        guard !cameraIsStale(now: now) else {
            handleCameraStopped(now: now)
            return
        }
        // Dim mode: absence is confirmed, so black the screens out and keep
        // looking. No countdown — there is nothing to count down to, and no
        // lock, so coming back needs no password.
        if Settings.dimInsteadOfLock {
            enterDimmed()
            return
        }
        // "Never Countdown": nothing to show, so lock straight from here. Note
        // this reads the *effective* duration, so a detected lock loop restores a
        // minimum countdown and with it the Esc escape gesture.
        if effectiveCountdownDuration <= 0 {
            lockNow()
            return
        }
        beginAlert()
    }

    /// Schedules the precise one-shot lock at the countdown deadline. Monotonic
    /// for the same reason as the grace timer above.
    private func scheduleLockTimer(at deadline: TimeInterval) {
        lockTimer.schedule(at: deadline)
    }

    private func stopLockTimer() {
        lockTimer.cancel()
    }

    private func handleCountdownExpired() {
        guard case .alerting(let deadline) = state else { return }
        if authenticatingEscape {
            // The prompt outlived its grace without an answer. Tear it down and
            // lock: silence is not authorisation.
            cancelEscapeAuth()
            lockNow()
            return
        }
        // Same defensive re-check as handleGraceExpired: never lock early.
        guard Uptime.now >= deadline else {
            scheduleLockTimer(at: deadline)
            return
        }
        lockNow()
    }

    /// The grace-period setting changed live while already watching — the
    /// currently-scheduled deadline was computed from the old value, so
    /// recompute it against the new one immediately rather than waiting for
    /// the next real presence observation to happen to trigger a reschedule.
    func gracePeriodSettingChanged() {
        guard state == .watching else { return }
        rescheduleGraceTimer()
    }

    /// Maintains the adaptive analysis cadence while watching and redraws an
    /// active countdown. Session recovery is owned by `superviseInvariants`;
    /// this timer never stops or restarts capture.
    private func handleTick() {
        switch state {
        case .watching:
            // Typing is presence continuously, not just at the moment the camera
            // is shut. Without this renewal the grace deadline stayed in the
            // past during a long typing stretch, and handleGraceExpired re-armed
            // itself with a zero delay forever — measured at 58–117 % CPU with
            // the camera off, and it starved the main queue so detection
            // callbacks arrived late or not at all.
            let window = Settings.inputPresenceWindow
            if window > 0, InputIdle.seconds() < window {
                presence.touch()
                rescheduleGraceTimer()
            }
            updateCameraGate(now: Uptime.now)
        case .alerting(let deadline):
            // Redraw only — lockTimer owns the deadline, so this poll's
            // ~0.13 s average lag no longer delays the lock itself.
            overlay.update(remaining: max(0, deadline - Uptime.now))
        case .dimmed:
            // Any real keyboard/mouse activity is a wake signal. Dim mode is not
            // a lock — the screen was only blacked out — and the camera cannot
            // always see the owner (head down, hand over the lens, a session
            // that went blind). Without this the only way back was Esc, which is
            // what made a blind camera feel like a frozen app.
            if InputIdle.seconds() < 1.5 {
                exitDimmed(reason: .input)
                return
            }
            updateDimmedGate(now: Uptime.now)
        case .paused, .locked, .enrolling, .cameraUnavailable:
            break
        }
    }

    // MARK: - Camera gating

    /// Re-decides, once a second while watching, whether the sensor should be
    /// open. Every threshold is a setting read here, so a menu change applies on
    /// the next tick.
    private func updateCameraGate(now: TimeInterval) {
        let action = ActivityGate.decide(
            idle: InputIdle.seconds(),
            inputWindow: Settings.inputPresenceWindow,
            cameraRunning: !cameraGated,
            burstStartedAt: burstStartedAt,
            nextCheckAt: nextCheckAt,
            now: now,
            burstDuration: Settings.quickCheckDuration
        )
        switch action {
        case .nothing:
            break
        case .stopCamera:
            stopCameraForInput()
        case .startBurst:
            startQuickCheck(now: now)
        case .endBurst:
            // The burst hit its ceiling with no verdict. Absence is now
            // suspected, so keep the camera open and let the grace deadline —
            // or a face — settle it.
            burstStartedAt = nil
            monitor.analysisInterval = fastAnalysisInterval
            Log.camera.notice("quick check inconclusive; watching continuously")
        }
    }

    /// Input is recent: shut the camera and count the input as presence.
    private func stopCameraForInput() {
        guard !cameraGated else { return }
        monitor.stop()
        cameraGated = true
        burstStartedAt = nil
        nextCheckAt = Uptime.now + Settings.quickCheckInterval
        presence.touch()
        rescheduleGraceTimer()
        Log.camera.notice("camera off; input activity")
    }

    /// A verdict said "present": the quick check has done its job.
    private func stopCameraForPresence() {
        guard !cameraGated else { return }
        monitor.stop()
        cameraGated = true
        burstStartedAt = nil
        nextCheckAt = Uptime.now + Settings.quickCheckInterval
        Log.camera.notice("camera off; presence confirmed")
    }

    private func startQuickCheck(now: TimeInterval) {
        cameraGated = false
        burstStartedAt = now
        cameraStartedAt = now
        firstResultAt = nil
        lastResultAt = nil
        monitor.analysisInterval = fastAnalysisInterval
        Log.camera.notice("quick check: opening camera")
        monitor.start()
    }

    /// Dim mode's pulse: open the camera for `dimmedCheckDuration`, close it,
    /// wait `dimmedCheckInterval`, repeat. A face ends it immediately through
    /// `handleDetection` → `exitDimmed`, so the worst case is one pulse.
    private func updateDimmedGate(now: TimeInterval) {
        let action = ActivityGate.decideDimmed(
            cameraRunning: !cameraGated,
            checkStartedAt: dimCheckStartedAt,
            nextCheckAt: nextDimCheckAt,
            now: now,
            checkDuration: Settings.dimmedCheckDuration
        )
        switch action {
        case .startBurst:
            startDimCheck(now: now)
        case .stopCamera:
            stopDimCheck()
        case .nothing, .endBurst:
            break
        }
    }

    private func startDimCheck(now: TimeInterval) {
        guard cameraGated else { return }
        cameraGated = false
        dimCheckStartedAt = now
        cameraStartedAt = now
        firstResultAt = nil
        lastResultAt = nil
        monitor.analysisInterval = fastAnalysisInterval
        dimTimer.schedule(at: now + Settings.dimmedCheckDuration)
        Log.camera.notice("dim check: opening camera")
        monitor.start()
    }

    private func stopDimCheck() {
        guard !cameraGated else { return }
        monitor.stop()
        cameraGated = true
        dimCheckStartedAt = nil
        nextDimCheckAt = Uptime.now + Settings.dimmedCheckInterval
        dimTimer.schedule(at: nextDimCheckAt)
        Log.camera.notice("dim check: camera off")
    }

    /// One step of the pulse. `dimTimer` owns the timing so the window is the
    /// configured length rather than whatever the 1 s tick happened to round to.
    private func advanceDimCycle() {
        guard state == .dimmed else { return }
        if cameraGated {
            startDimCheck(now: Uptime.now)
        } else {
            stopDimCheck()
        }
    }

    /// Any gating timing changed in the menu. Applied immediately: a pending
    /// check is brought forward to the new interval and a running camera
    /// re-evaluates now instead of waiting out the settings that just changed.
    func timingSettingsChanged() {
        switch state {
        case .dimmed:
            if cameraGated {
                nextDimCheckAt = min(nextDimCheckAt, Uptime.now + Settings.dimmedCheckInterval)
                dimTimer.schedule(at: nextDimCheckAt)
            } else if let started = dimCheckStartedAt {
                // A shorter window applies to the check already running.
                dimTimer.schedule(at: started + Settings.dimmedCheckDuration)
            }
            updateDimmedGate(now: Uptime.now)
        case .watching:
            if cameraGated {
                nextCheckAt = min(nextCheckAt, Uptime.now + Settings.quickCheckInterval)
            }
            updateCameraGate(now: Uptime.now)
        default:
            break
        }
    }

    // MARK: - Enrollment

    func enrollFace(completion: ((Bool) -> Void)? = nil) {
        guard recognizer.hasModel else {
            showAlert(
                title: "缺少人脸模型",
                message: "未打包 FaceEmbedding.mlmodelc。请运行 scripts/fetch-model.sh 后重新构建。"
            )
            completion?(false)
            return
        }

        // Re-enrolling changes whose face keeps the screen unlocked — require
        // the Mac's own authentication (Touch ID / password) first.
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            showAlert(
                title: "无法验证身份",
                message: authError?.localizedDescription ?? "无法在此 Mac 上验证你的身份。"
            )
            completion?(false)
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "录入用于解锁屏幕的人脸"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard success else {
                    completion?(false)
                    return
                }
                self?.beginEnrollment()
                completion?(true)
            }
        }
    }

    private func beginEnrollment() {
        resumeAfterEnrollment = state == .watching || state == .dimmed || isAlerting
        overlay.dismiss()
        DisplayBrightness.restore()
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        state = .enrolling
        withCameraPermission { [weak self] in self?.enrollment.begin() }
    }

    /// The controller finished (saved, cancelled, or window closed) — restore
    /// whatever monitoring state enrollment interrupted.
    private func enrollmentFinished() {
        guard state == .enrolling else { return }
        if resumeAfterEnrollment {
            beginWatching()
        } else {
            monitor.stop()
            state = .paused
        }
    }

    // MARK: - Monitoring hours

    private func startScheduleTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.resolveSchedule()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    /// Runs on the periodic schedule timer. Only acts once a schedule
    /// boundary has been crossed since the last real watch/pause decision
    /// (see lastDecisionAt) — between boundaries the user's manual
    /// Start/Pause always wins.
    private func resolveSchedule(now: Date = Date()) {
        guard Settings.scheduleEnabled, state != .enrolling else { return }
        guard let at = lastDecisionAt, at < Settings.schedule.mostRecentBoundary(before: now) else { return }
        applySchedule(within: Settings.schedule.isActive(at: now))
    }

    /// Makes the one paused/watching transition the schedule calls for,
    /// given a fresh "should we be watching right now" answer. A session
    /// that's actually locked when the schedule wants to start is parked in
    /// .locked (harmless, idempotent from .paused) rather than starting the
    /// camera behind a locked screen; resumeFromLocked resolves it at the
    /// next unlock.
    private func applySchedule(within: Bool) {
        Log.schedule.notice("boundary crossed; withinActiveWindow=\(within, privacy: .public) state=\(self.state.logName, privacy: .public)")
        switch state {
        case .paused where within:
            // Stamp before attempting, even though the attempt below may not
            // land (camera permission denied reverts to .paused) — otherwise
            // the timer retries (and re-alerts) every 30s indefinitely.
            // Scoped to only this branch: stamping in `default` would
            // corrupt resumeFromLocked's staleness check for an unrelated
            // .locked session sitting through an unconnected boundary.
            lastDecisionAt = Date()
            ScreenLocker.sessionIsLocked ? enterLockedState() : startMonitoring()
        case .watching where !within, .alerting where !within,
             .dimmed where !within, .cameraUnavailable where !within:
            pause() // stamps lastDecisionAt itself
        default:
            break
        }
    }

    /// Session unlocked, or the display woke from a locked state. The
    /// `screenIsUnlocked` notification is forgeable by any local process, so
    /// confirm the session is genuinely unlocked before starting the camera —
    /// and go through startMonitoring() (not beginWatching() directly) so a
    /// permission revoked while locked is caught here too, instead of
    /// silently starting a capture session that can't actually see anything.
    ///
    /// Uses the same staleness rule as resolveSchedule: if no schedule
    /// boundary has passed since our last real decision, resume whatever
    /// regime we locked from — always watching, since .locked is only ever
    /// entered from .watching/.alerting. This is what keeps a manual start
    /// outside active hours (or an entire Always On session, where
    /// mostRecentBoundary is always .distantPast) alive across lock/unlock.
    /// If a boundary DID pass — possibly several, across a multi-day gap —
    /// re-decide fresh from the live schedule.
    private func resumeFromLocked() {
        guard state == .locked, !ScreenLocker.sessionIsLocked else { return }
        guard let at = lastDecisionAt, at < Settings.schedule.mostRecentBoundary(before: Date()) else {
            startMonitoring()
            return
        }
        Settings.schedule.isActive(at: Date()) ? startMonitoring() : pause()
    }

    // MARK: - Lock / sleep observation

    private func observeLockAndSleepEvents() {
        let distributed = DistributedNotificationCenter.default()
        // Each of these only prompts an immediate re-decision. The supervisor
        // would reach the same conclusion within a second anyway; the
        // notification just removes the delay, and cannot disagree with it.
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.superviseInvariants()
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.superviseInvariants()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.superviseInvariants()
        }
        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Display woke without a password unlock (e.g. lock screen disabled).
            self?.superviseInvariants()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Normally the sleep notification already moved us to .locked, so
            // this is a no-op. If it was missed we're still nominally .watching
            // over a capture session the OS may have torn down — restart from a
            // clean slate rather than measuring absence across time the camera
            // could not possibly have seen.
            guard let self, self.state == .watching else { return }
            self.beginWatching()
        }
    }

    // MARK: - Camera permission

    private func withCameraPermission(_ proceed: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        Log.camera.notice("camera auth at start: \(status.rawValue, privacy: .public)")
        switch status {
        case .authorized:
            proceed()
        case .notDetermined:
            // TCC hangs its prompt off the requesting app, and an accessory app
            // launched by launchd is not frontmost yet. Asking during
            // applicationDidFinishLaunching got an immediate "denied" with no
            // prompt ever shown on this machine; activating first and letting
            // the launch settle is what makes the request legitimate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.activate(ignoringOtherApps: true)
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            proceed()
                        } else {
                            self.showCameraDeniedAlert()
                        }
                    }
                }
            }
        default:
            showCameraDeniedAlert()
        }
    }

    private func showCameraDeniedAlert() {
        // Full teardown, not a bare `state = .paused`: reached from
        // beginEnrollment(), which deliberately leaves the capture session
        // running for the enrollment preview, so assigning the state directly
        // left the camera live behind a menu reading "已暂停" with no path
        // back (enrollmentFinished() only fires from .enrolling).
        pause()
        let alert = NSAlert()
        alert.messageText = "需要摄像头权限"
        alert.informativeText = "Lockscreen Dah 需要摄像头来判断你是否在屏幕前。请在「系统设置 → 隐私与安全性 → 摄像头」中允许访问。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        // This launch cannot monitor. Quitting releases the single-instance
        // lock; previously the denied .app sat behind this modal holding it, so
        // the .command launcher could not start a working instance.
        Log.camera.notice("camera access denied; quitting to release the instance lock")
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
