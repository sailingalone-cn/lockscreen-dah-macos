import AppKit

/// App lifecycle only. The menu bar lives in `StatusMenuController`, login-item
/// reconciliation in `LoginItem`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = MonitorCoordinator()
    private var statusMenu: StatusMenuController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusMenu = StatusMenuController(coordinator: coordinator)
        LoginItem.syncWithStoredIntent()
        // A previous run may have died while the panel was dimmed; put the
        // saved brightness back before anything else decides to dim again.
        DisplayBrightness.recoverIfNeeded()
        coordinator.startPerSchedule()
        installSignalHandlers()
    }

    /// Installed only after `NSApplication` exists: AppKit sets its own SIGTERM
    /// disposition during launch, and a source installed before that never
    /// fired (measured: `pkill` was ignored and the process kept the
    /// single-instance lock).
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                // Close the stream first, bounded to 2 s, then leave regardless:
                // a wedged camera daemon must not turn "quit" into "ignore".
                self?.coordinator.shutdownCamera()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Close the capture session synchronously before the process goes away.
    /// A stream left half-open can wedge the IR module until the machine is
    /// rebooted — see `FaceMonitor.shutdown()`.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdownCamera()
    }
}
