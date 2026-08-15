import Foundation

/// Window visibility state machine for the renderer bridge (review round
/// Phase 5). Every hide/show path goes through one pair of managed methods;
/// this type tracks the last visibility actually sent and dedupes repeated
/// events, so N hides in a row emit exactly one `false` and N shows exactly
/// one `true`.
struct ManagedVisibility {
    /// Emits visibility events (production: the window's local bridge).
    var sink: (Bool) -> Void

    /// Current native visibility (last managed state).
    private(set) var nativeVisible = false
    /// Last value sent through the sink; nil before the first send.
    private(set) var lastSent: Bool?

    init(sink: @escaping (Bool) -> Void) {
        self.sink = sink
    }

    mutating func show() {
        nativeVisible = true
        sendIfNeeded(true)
    }

    mutating func hide() {
        nativeVisible = false
        sendIfNeeded(false)
    }

    /// Re-sync after the page finished loading: a push sent before the
    /// renderer was ready is lost, so the current native state is sent
    /// again unconditionally.
    mutating func resync() {
        lastSent = nil
        sendIfNeeded(nativeVisible)
    }

    private mutating func sendIfNeeded(_ visible: Bool) {
        if lastSent == visible { return }
        lastSent = visible
        sink(visible)
    }
}
