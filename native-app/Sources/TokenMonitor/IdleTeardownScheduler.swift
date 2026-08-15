import Foundation

/// One-shot idle-teardown scheduling (round-4 Phase 6): a window hidden for
/// longer than its idle delay tears its WebView down to reclaim memory; any
/// show before the deadline cancels the pending teardown. Repeated hides
/// supersede (never more than one live work item), a stale scheduled fire is
/// a no-op, and a teardown fires at most once.
///
/// The executor seam keeps these rules unit-testable without a WKWebView;
/// production uses the main-queue asyncAfter default.
final class IdleTeardownScheduler {
    typealias Work = () -> Void

    /// Schedules the fire block after the given delay in seconds. Tests
    /// substitute an executor that records scheduled work so they can
    /// advance a fake clock instead of sleeping.
    private let executor: (TimeInterval, @escaping Work) -> Void
    private var pending: DispatchWorkItem?

    init(executor: @escaping (TimeInterval, @escaping Work) -> Void = { delay, fire in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
    }) {
        self.executor = executor
    }

    /// True while exactly one teardown is pending (test-observable invariant).
    var hasPending: Bool { pending != nil }

    /// Replace any pending teardown with a new one: repeated hides never
    /// create more than one live work item.
    func schedule(delay: TimeInterval, work: @escaping Work) {
        pending?.cancel()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self, let current = self.pending, current === item else { return }
            self.pending = nil
            work()
        }
        pending = item
        executor(delay) { [weak item] in item?.perform() }
    }

    /// Cancel the pending teardown (show path). A stale scheduled fire is a
    /// no-op because the item no longer matches pending.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
