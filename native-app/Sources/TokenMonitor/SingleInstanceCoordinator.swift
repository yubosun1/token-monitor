import Foundation
import Darwin

/// Enforces a single running app instance (PLAN.md Phase 1).
///
/// Ownership is a flock(2) exclusive lock on a file in Application Support:
/// the kernel releases the lock automatically when the owning process exits
/// or crashes, so there is no stale-owner recovery window and two processes
/// racing at launch are serialized atomically (an NSRunningApplication
/// check alone would leave a TOCTOU race). The lock file also records the
/// owning PID for diagnostics; the flock is the authority, not the PID.
///
/// A second launch that loses the race posts a DistributedNotificationCenter
/// notification asking the running instance to show its main window, then
/// exits without ever creating a window, WebView, status item or collector.
final class SingleInstanceCoordinator {
    static let shared = SingleInstanceCoordinator()

    /// Cross-process notification: a second launch asked us to surface.
    static let showMainWindowNotification = Notification.Name("com.javis.tokenmonitor.showMainWindow")

    private var lockFD: Int32 = -1

    private var lockURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Token Monitor", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    /// Acquire the instance lock. Returns true when this process owns it.
    /// Must run before any window/status item/collector is created.
    /// Fails open: a lock-directory error never blocks launch.
    func acquire() -> Bool {
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            PerfDiag.log("single-instance: lock dir unavailable, continuing (fail open)")
            return true
        }
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            PerfDiag.log("single-instance: lock open failed, continuing (fail open)")
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            PerfDiag.log("single-instance: another instance owns the lock")
            return false
        }
        lockFD = fd
        // Best-effort PID bookkeeping for diagnostics.
        _ = ftruncate(fd, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        PerfDiag.log(String(format: "single-instance: acquired lock pid=%d", getpid()))
        return true
    }

    /// Ask the running instance to show its main window.
    func notifyExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.showMainWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Release ownership on the normal termination path (idempotent).
    func release() {
        guard lockFD >= 0 else { return }
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
        PerfDiag.log("single-instance: released lock")
    }
}

