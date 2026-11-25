import CoreGraphics
import Foundation

/// Turns the physical backlight off while the dim overlay is up.
///
/// The overlay blacks out the pixels but leaves the panel lit — still several
/// watts, and visibly glowing in a dark room. DisplayServices is private API, so
/// every call here is best-effort: if any of it is unavailable, the overlay is
/// still the source of truth and the app behaves exactly as before.
///
/// The original brightness is persisted before the first write and a marker is
/// left set. A crash (or `kill -9`) therefore cannot leave the panel dark
/// forever: the next launch restores the saved value, and if someone has already
/// raised the brightness by hand, the saved value is discarded instead of
/// fighting them.
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW
    )
    private static let getFn: GetFn? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }
    private static let canFn: CanFn? = handle
        .flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
        .map { unsafeBitCast($0, to: CanFn.self) }

    private static let markerKey = "displayBrightnessDimmed"
    private static let backupPrefix = "displayBrightnessBackup."
    /// Below this the panel is effectively dark. Used to tell "still our zero"
    /// from "someone already raised it".
    private static let darkThreshold: Float = 0.02

    private static var saved: [CGDirectDisplayID: Float] = [:]
    private static var isDimmed = false

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func brightness(of id: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(id, &value) == 0 else { return nil }
        return value
    }

    private static func setBrightness(_ value: Float, of id: CGDirectDisplayID) {
        _ = setFn?(id, value)
    }

    /// Fades every controllable panel to zero. The overlay has already been
    /// ordered in, so a failure here costs nothing visually.
    static func dim() {
        guard isAvailable, !isDimmed else { return }
        var snapshot: [CGDirectDisplayID: Float] = [:]
        for id in activeDisplays() {
            if let canFn, !canFn(id) { continue }
            guard let current = brightness(of: id), current > 0.001 else { continue }
            snapshot[id] = current
            setBrightness(0, of: id)
        }
        guard !snapshot.isEmpty else { return }
        saved = snapshot
        isDimmed = true
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: markerKey)
        for (id, value) in snapshot {
            defaults.set(Double(value), forKey: backupPrefix + String(id))
        }
        Log.state.notice("display backlight off for \(snapshot.count, privacy: .public) display(s)")
    }

    /// Puts the saved brightness back. Safe to call from any state, and twice.
    static func restore() {
        if !isDimmed {
            recoverIfNeeded()
            return
        }
        for (id, value) in saved where (brightness(of: id) ?? 0) < darkThreshold {
            setBrightness(value, of: id)
        }
        saved.removeAll()
        isDimmed = false
        clearMarker()
        Log.state.notice("display backlight restored")
    }

    /// Called once at launch. A marker means a previous run dimmed the panel and
    /// never got to restore it (crash, kill -9, power loss).
    static func recoverIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: markerKey) else { return }
        for id in activeDisplays() {
            let key = backupPrefix + String(id)
            guard let stored = defaults.object(forKey: key) as? NSNumber else { continue }
            let savedValue = Float(truncating: stored)
            // Only undo a zero we still own; a brighter value means the user
            // already fixed it, and overriding their choice is worse than a
            // stale key.
            if let current = brightness(of: id), current < darkThreshold, savedValue > 0.001 {
                setBrightness(savedValue, of: id)
            }
        }
        clearMarker()
        Log.state.notice("recovered display brightness from a previous run")
    }

    private static func clearMarker() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: markerKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(backupPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
