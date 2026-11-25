import AppKit
import ServiceManagement

/// "Open at Login" registration.
///
/// `SMAppService.mainApp` registers the *main app bundle*, which only makes
/// sense for a real `.app` at a stable path. A bare executable or a debug/temp
/// copy either cannot be registered usefully or leaves an entry that launches a
/// throwaway path at every login — those entries are how five copies of this app
/// ended up running at once, each with a camera session and a full-screen
/// overlay. Registration is therefore limited to a stable bundle, and the stored
/// intent defaults to off.
enum LoginItem {
    /// Whether "Open at Login" is meaningful for this launch.
    ///
    /// Debug builds (`.build/...`), temporary copies (`/tmp`, `$TMPDIR`) and
    /// bare executables are excluded: none of them is a durable thing to launch
    /// at login.
    static var isSupported: Bool {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return false }
        let unstable = ["/.build/", "/tmp/", "/private/tmp/", "/var/folders/"]
        return !unstable.contains { url.path.contains($0) }
    }

    static var isRegistered: Bool { SMAppService.mainApp.status == .enabled }

    /// Brings the real registration in line with the stored intent. Safe to call
    /// on every launch; a no-op when they already agree, and a no-op entirely
    /// for launch modes where registration is not meaningful.
    static func syncWithStoredIntent() {
        guard isSupported else { return }
        let wanted = Settings.openAtLoginEnabled
        guard wanted != isRegistered else { return }
        do {
            try applyThrowing(wanted)
            Log.state.notice("login item \(wanted ? "registered" : "unregistered", privacy: .public)")
        } catch {
            // Registration can be refused (signature, launch services); the app
            // is still usable, so this is a log line rather than an alert.
            Log.state.error("login item sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Flips the setting and records the new intent. Returns the error if macOS
    /// refused, so the caller can surface it rather than failing silently.
    @discardableResult
    static func toggle() -> Error? {
        guard isSupported else {
            return NSError(
                domain: "LockscreenDah",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "「登录时启动」仅在以 .app 包运行时可用——调试版或临时副本不支持。"]
            )
        }
        let enabling = !isRegistered
        do {
            try applyThrowing(enabling)
            Settings.openAtLoginEnabled = enabling
            return nil
        } catch {
            return error
        }
    }

    private static func applyThrowing(_ enabled: Bool) throws {
        // Always unregister first when enabling: a stale entry from a previous
        // build's signature would otherwise sit alongside the new one.
        try? SMAppService.mainApp.unregister()
        if enabled { try SMAppService.mainApp.register() }
    }
}
