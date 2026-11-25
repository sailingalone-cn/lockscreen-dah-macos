import AppKit
import AVFoundation

/// Ask for the camera while this process is still a plain command-line tool.
///
/// TCC answers a request differently depending on what the process *is*: a
/// child of a terminal inherits that terminal's camera grant, while an app
/// bundle is expected to carry its own record and gets "denied" without a
/// prompt if it has none. Once `NSApplication.shared` exists the process is an
/// app, and on a machine whose TCC cannot put up bundle prompts (this
/// hackintosh) that is the end of the road. Asking first makes terminal
/// launches work here and changes nothing on a Mac where the bundle has its own
/// grant: the status is already `.authorized`, so this is a no-op.
private func preauthorizeCameraIfNeeded() {
    let before = AVCaptureDevice.authorizationStatus(for: .video)
    Log.camera.notice("camera auth before NSApplication: \(before.rawValue, privacy: .public)")
    guard before == .notDetermined else { return }
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 5)
    Log.camera.notice("camera auth after pre-request: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue, privacy: .public)")
}

if CommandLine.arguments.dropFirst().first == "--evaluate-model" {
    do {
        try RecognitionEvaluator.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        FileHandle.standardError.write(Data("\(RecognitionEvaluator.usage)\n".utf8))
        exit(2)
    }
} else {
    // One copy per machine. A second instance opens the camera on its own
    // schedule and creates its own full-screen overlay; several of those cycling
    // at once is what preceded two WindowServer watchdog panics.
    guard SingleInstance.acquire() else {
        FileHandle.standardError.write(Data("Lockscreen Dah is already running; exiting.\n".utf8))
        exit(0)
    }
    // Make the stored values agree with what the app actually enforces, so
    // `defaults read` stops disagreeing with the menu.
    Settings.normalizeStoredValues()
    preauthorizeCameraIfNeeded()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
