import Darwin
import Foundation

/// One instance per machine.
///
/// The app can legitimately be launched as a `.app`, as a bare executable, or as
/// a debug build, so a bundle-identifier check would miss most of those (a bare
/// binary has no bundle id at all). An exclusive lock on a fixed file works for
/// every launch mode and has no race: the descriptor stays open for the life of
/// the process, and the kernel releases the lock when it exits.
///
/// This exists because duplicate instances are not merely untidy: each one opens
/// the camera on its own schedule and creates its own full-screen overlay, and
/// several copies cycling the camera every few seconds is what preceded two
/// WindowServer watchdog panics.
enum SingleInstance {
    private static var lockDescriptor: Int32 = -1

    /// True when this process owns the lock. Fail-open: if the lock file cannot
    /// be created, the app runs rather than refusing to start over a filesystem
    /// problem.
    static func acquire() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LockscreenDah", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }
}
