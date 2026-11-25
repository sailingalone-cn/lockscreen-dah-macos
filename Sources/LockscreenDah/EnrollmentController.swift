import Foundation

/// Owns the KYC-style enrollment flow: staged capture with settle countdowns,
/// candidate-profile build, automatic live verification, and the user-paced
/// button phases. Shares the coordinator's FaceMonitor/FaceRecognizer; the
/// coordinator gates entry (auth + camera permission + state) and gets
/// `onFinished` when the flow ends, whatever the outcome.
final class EnrollmentController {
    /// Enrollment is over (saved, failed-and-cancelled, or window closed).
    var onFinished: (() -> Void)?
    /// Fired only when a new profile was actually saved — distinct from
    /// `onFinished`, which also fires on cancel.
    var onProfileCommitted: (() -> Void)?

    private let recognizer: FaceRecognizer
    private let monitor: FaceMonitor
    private let panel = EnrollmentPanel()

    private let stages = EnrollmentStages.all
    private var totalSamples: Int { stages.reduce(0) { $0 + $1.target } }
    /// 3… 2… 1… countdown before each stage starts capturing.
    private let stageSettleTime: TimeInterval = 3

    /// User-paced KYC flow: Start begins capture, Continue advances stages,
    /// Verify runs the live post-save test, Save/Re-Enroll close it out.
    private enum Phase {
        case ready      // waiting for Start
        case capturing  // collecting samples for the current stage — no buttons
        case stageDone  // stage finished: Recapture / Continue
        case verifying  // automatic live test against the candidate — no buttons
        case succeeded  // verified: Verify (again) / Save
        case failed     // capture/verify failure: Cancel / Re-Enroll
    }
    private var phase: Phase = .ready
    /// Samples of finished stages, one array per stage. Kept grouped rather
    /// than flattened so each pose gate is handed exactly the stages that came
    /// before it — see `EnrollmentStage.accepts`.
    private var completedStageSamples: [[EnrollmentSample]] = []
    private var currentStageSamples: [EnrollmentSample] = []
    private var samples: [EnrollmentSample] { completedStageSamples.flatMap { $0 } + currentStageSamples }
    private var stageIndex = 0
    private var stageSettleUntil = Date.distantPast
    private var timeout: Timer?
    /// Built after the last stage, verified live, persisted only on Save.
    private var candidateProfile: FaceProfile?
    private var verifyStreak = 0
    private let verifyStreakTarget = 3

    init(recognizer: FaceRecognizer, monitor: FaceMonitor) {
        self.recognizer = recognizer
        self.monitor = monitor
        panel.onCancel = { [weak self] in self?.finish() }
        panel.onPrimary = { [weak self] in self?.handlePrimary() }
        panel.onSecondary = { [weak self] in self?.handleSecondary() }
    }

    /// Starts (or restarts, on Re-Enroll) the flow. The caller must already
    /// hold camera permission and have put the coordinator in .enrolling.
    func begin() {
        beginPoseLogRun()
        completedStageSamples = []
        currentStageSamples = []
        stageIndex = 0
        phase = .ready
        candidateProfile = nil
        verifyStreak = 0
        timeout?.invalidate()
        timeout = nil

        monitor.collectEnrollmentSamples = true
        monitor.analysisInterval = 0.25
        // The preview layer attaches to the same AVCaptureSession the monitor
        // configures on its own queue, so it must wait until that finishes —
        // see FaceMonitor.start(completion:). Guarded because the user can
        // cancel during the (brief) session setup: abort() clears this flag,
        // whereas `phase` returns to .ready either way and can't tell the two
        // apart.
        monitor.start { [weak self] in
            guard let self, self.monitor.collectEnrollmentSamples else { return }
            self.panel.show(session: self.monitor.session, totalSamples: self.totalSamples)
            self.panel.setInstruction(self.stages[0].instruction)
            self.panel.setStatus("请把脸放进椭圆框内。")
            self.panel.setPrimary(title: "开始")
            self.panel.setSecondary(title: nil)
            self.panel.setCancelVisible(true)
        }
    }

    /// Tears the flow down without firing `onFinished` — for when the
    /// coordinator itself is pausing and will set its own state.
    func abort() {
        timeout?.invalidate()
        timeout = nil
        panel.dismiss()
        monitor.collectEnrollmentSamples = false
        completedStageSamples = []
        currentStageSamples = []
        phase = .ready
        candidateProfile = nil
    }

    private func finish() {
        abort()
        onFinished?()
    }

    // MARK: - Buttons

    /// Primary button: Start / Continue / Save / Re-Enroll depending on phase.
    private func handlePrimary() {
        switch phase {
        case .ready, .stageDone:
            startCapturingStage()
        case .succeeded:
            guard let candidateProfile else { return }
            do {
                try recognizer.commit(candidateProfile)
                onProfileCommitted?()
                finish()
            } catch {
                showFailure("无法保存档案：\(error.localizedDescription)")
            }
        case .failed:
            begin() // Re-Enroll — already authenticated this session
        case .capturing, .verifying:
            break
        }
    }

    /// Secondary button: Recapture (stage done) / Verify again (succeeded).
    private func handleSecondary() {
        switch phase {
        case .stageDone:
            guard stageIndex > 0 else { return }
            stageIndex -= 1
            currentStageSamples = []
            if !completedStageSamples.isEmpty { completedStageSamples.removeLast() }
            panel.setProgress(samples.count)
            startCapturingStage()
        case .succeeded:
            beginVerification()
        case .ready, .capturing, .verifying, .failed:
            break
        }
    }

    // MARK: - Capture

    private func startCapturingStage() {
        phase = .capturing
        stageSettleUntil = Date().addingTimeInterval(stageSettleTime)
        panel.setInstruction(stages[stageIndex].instruction)
        panel.setStatus("准备中…")
        panel.setCountdown(Int(stageSettleTime))
        panel.setStageProgress(nil)
        panel.setPrimary(title: nil)
        panel.setSecondary(title: nil)
        panel.setCancelVisible(false)
        startStageTimeout()
    }

    /// A capture stage that can't finish within a minute is stuck (bad
    /// lighting, no face) — fail rather than sit forever. The button-gated
    /// phases deliberately never time out.
    private func startStageTimeout() {
        timeout?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            self?.showFailure("超时：采集帧数不足。请改善光线后重试。")
        }
        RunLoop.main.add(timer, forMode: .common)
        timeout = timer
    }

    /// Any capture/build/verify failure lands here: Cancel / Re-Enroll.
    private func showFailure(_ message: String) {
        timeout?.invalidate()
        timeout = nil
        phase = .failed
        panel.setCountdown(nil)
        panel.setStageProgress(nil)
        panel.showVerifyFailure(message)
        panel.setPrimary(title: "重新录入")
        panel.setSecondary(title: nil)
        panel.setCancelVisible(true)
    }

    // MARK: - Pose diagnostics

    /// Head angles only — never image data — for the current enrollment run,
    /// truncated at the start of each. Read this when a stage won't advance:
    /// every pose gate here is a threshold on real Vision output, and guessing
    /// at those numbers rather than measuring them has caused every enrollment
    /// bug in this flow so far.
    private static let poseLogURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/LockscreenDah/enrollment-poses.log")

    private func beginPoseLogRun() {
        guard let url = Self.poseLogURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        if size ?? 0 > 256_000 { try? Data().write(to: url) }
        logPose("--- enrollment run ---")
    }

    private func logPose(_ line: String) {
        guard let url = Self.poseLogURL,
              let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Detection

    /// Fed by the coordinator with every analyzed frame while enrolling.
    func handleDetection(_ result: DetectionResult) {
        switch phase {
        case .capturing:
            handleCaptureDetection(result)
        case .verifying:
            handleVerificationDetection(result)
        case .ready, .stageDone, .succeeded, .failed:
            break // waiting for a button — nothing to capture
        }
    }

    private func handleCaptureDetection(_ result: DetectionResult) {
        guard stageIndex < stages.count else { return }
        let stage = stages[stageIndex]
        panel.setInstruction(stage.instruction)

        guard result.enrollmentSample != nil || result.faceCount > 0 else {
            panel.setStatus("请移到椭圆框内", isProblem: true)
            return
        }

        let now = Date()
        if now < stageSettleUntil {
            let secondsLeft = Int(stageSettleUntil.timeIntervalSince(now).rounded(.up))
            panel.setCountdown(secondsLeft)
            return
        }
        panel.setCountdown(nil)

        guard let sample = result.enrollmentSample else {
            logPose("stage=\(stageIndex) no-sample (face in frame, embedding failed)")
            panel.setStatus("请保持不动…", isProblem: true)
            return
        }
        let accepted = stage.accepts(sample, completedStageSamples)
        logPose(String(
            format: "stage=%d %@ yaw=%+.3f pitch=%+.3f accepted=%@",
            stageIndex, stage.instruction, sample.yaw, sample.pitch,
            accepted ? "YES" : "no"
        ))
        guard accepted else {
            panel.setStatus(stage.correction, isProblem: true)
            return
        }

        currentStageSamples.append(sample)
        panel.setProgress(samples.count)
        panel.setStageProgress(currentStageSamples.count * 100 / stage.target)
        panel.setStatus("请保持不动…")

        if currentStageSamples.count >= stage.target {
            timeout?.invalidate()
            timeout = nil
            completedStageSamples.append(currentStageSamples)
            currentStageSamples = []
            stageIndex += 1
            if stageIndex >= stages.count {
                // All poses captured — build the candidate and verify
                // automatically; nothing is saved until the user hits Save.
                do {
                    candidateProfile = try recognizer.makeCandidateProfile(
                        poseSamples: completedStageSamples
                    )
                    beginVerification()
                } catch {
                    showFailure(error.localizedDescription)
                }
            } else {
                phase = .stageDone
                panel.setStageProgress(nil)
                panel.setInstruction(stages[stageIndex].instruction)
                panel.setStatus("准备好下一个姿势了吗？")
                panel.setPrimary(title: "继续")
                panel.setSecondary(title: "重新拍摄")
                panel.setCancelVisible(false)
            }
        }
    }

    // MARK: - Verification

    /// Live end-to-end test against the candidate profile: the user must be
    /// recognized `verifyStreakTarget` times in a row to succeed.
    private func beginVerification() {
        guard candidateProfile != nil else { return }
        phase = .verifying
        verifyStreak = 0
        panel.setCountdown(nil)
        panel.setStageProgress(nil)
        panel.setInstruction("请看向摄像头")
        panel.setStatus("正在验证…")
        panel.setPrimary(title: nil)
        panel.setSecondary(title: nil)
        panel.setCancelVisible(false)

        timeout?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.phase == .verifying else { return }
            self.showFailure(
                "用新档案无法识别你。请改善光线后重新录入；本次档案未保存。"
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        timeout = timer
    }

    private func handleVerificationDetection(_ result: DetectionResult) {
        guard phase == .verifying, let candidateProfile else { return }
        guard let sample = result.enrollmentSample else {
            panel.setStatus(
                result.faceCount > 0 ? "请保持不动…" : "请移到椭圆框内",
                isProblem: true
            )
            return
        }
        let similarity = recognizer.similarity(of: sample.embedding, to: candidateProfile)
        if similarity >= Settings.matchThreshold {
            verifyStreak += 1
            panel.setStatus(
                String(format: "匹配 %.2f ✓（%d / %d）", similarity, verifyStreak, verifyStreakTarget)
            )
            if verifyStreak >= verifyStreakTarget {
                phase = .succeeded
                timeout?.invalidate()
                timeout = nil
                panel.showVerified(score: similarity)
                // Surface what the profile actually scored across every captured
                // pose. The worst pose is the number that matters: it is the
                // headroom above the live threshold, and therefore how much that
                // threshold could safely be tightened.
                if let scores = recognizer.lastEnrollmentScores {
                    panel.setStatus(String(
                        format: "实时 %.2f · 档案最差姿势 %.2f，平均 %.2f（共 %d 个模板）",
                        similarity, scores.worst, scores.mean, scores.templates
                    ))
                }
                panel.setPrimary(title: "保存")
                panel.setSecondary(title: "验证")
                panel.setCancelVisible(false)
            }
        } else {
            verifyStreak = 0
            panel.setStatus(
                String(format: "匹配 %.2f，低于阈值 %.2f", similarity, Settings.matchThreshold),
                isProblem: true
            )
        }
    }
}
