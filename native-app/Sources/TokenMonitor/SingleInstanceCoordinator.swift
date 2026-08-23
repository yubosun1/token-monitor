import Foundation
import AppKit
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
///
/// Activation buffering (review round Phase 6): every launch registers the
/// cross-process activation receiver BEFORE competing for the flock, so an
/// activation arriving while the winner's AppDelegate is still initializing
/// is buffered and consumed once the show callback is installed — the
/// request can no longer be lost to initialization timing.
final class SingleInstanceCoordinator {
    static let shared = SingleInstanceCoordinator()

    /// Cross-process notification: a second launch asked us to surface.
    static let showMainWindowNotification = Notification.Name("com.javis.tokenmonitor.showMainWindow")

    private let stateLock = NSLock()
    private var lockFD: Int32 = -1
    private var activationObserver: NSObjectProtocol?
    private var observerRegistered = false
    private var pendingActivation = false
    private var showCallback: (() -> Void)?

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

    // MARK: - Activation receiver / buffering (review round Phase 6)

    /// Register the cross-process activation receiver. Must be called before
    /// competing for the flock so early activation requests are buffered
    /// instead of dropped. Idempotent per process.
    func registerActivationObserver() {
        stateLock.lock()
        guard !observerRegistered else { stateLock.unlock(); return }
        observerRegistered = true
        stateLock.unlock()
        activationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.showMainWindowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleRemoteActivation()
        }
    }

    /// Remove the receiver (loser before exit; winner on termination).
    /// Idempotent; does not clear an installed show callback.
    func unregisterActivationObserver() {
        stateLock.lock()
        if let activationObserver {
            DistributedNotificationCenter.default().removeObserver(activationObserver)
        }
        activationObserver = nil
        observerRegistered = false
        stateLock.unlock()
    }

    /// Handle a remote activation request: fire the show callback when it is
    /// installed, otherwise buffer the request (multiple requests coalesce).
    func handleRemoteActivation() {
        stateLock.lock()
        if let callback = showCallback {
            stateLock.unlock()
            callback()
        } else {
            pendingActivation = true
            stateLock.unlock()
        }
    }

    /// Install the AppDelegate show callback and immediately consume any
    /// buffered activation (exactly once, no matter how many arrived).
    func installShowCallback(_ callback: @escaping () -> Void) {
        stateLock.lock()
        showCallback = callback
        let pending = pendingActivation
        pendingActivation = false
        stateLock.unlock()
        if pending { callback() }
    }

    /// Ask the running instance to show its main window. The distributed
    /// notification is the primary channel; activating the owner PID read
    /// from the lock file is a best-effort extra fallback (the flock — not
    /// the PID — remains the ownership authority).
    func notifyExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.showMainWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
        if let pidText = try? String(contentsOf: lockURL, encoding: .utf8),
           let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let running = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                running.activate()
            } else {
                running.activate(options: [.activateIgnoringOtherApps])
            }
        }
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
