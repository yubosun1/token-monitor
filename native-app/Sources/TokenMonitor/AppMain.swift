import AppKit

// Entry point for the thin TokenMonitor executable target (Package.swift
// splits the module so the fixture checker can exercise the aggregation
// code without linking the app). All app wiring stays internal to
// TokenMonitorCore; the executable's main.swift only calls this function.

/// Boot the app: process marker, NSApplication setup, delegate, run loop.
public func runTokenMonitorApp() {
    // Perf baseline marker (PLAN.md Phase 0): the first stats push
    // timestamp minus this line's timestamp is the
    // "startup to first usable stats" figure.
    PerfDiag.log(String(format: "process launched pid=%d", getpid()))
    PerfDiag.cpuMark("launch")

    // Single-instance ownership (PLAN.md Phase 1) must be settled before
    // any status item, window, WebView or collector is created. A losing
    // second launch asks the running instance to surface its window and
    // exits without touching AppKit or starting any background work.
    guard SingleInstanceCoordinator.shared.acquire() else {
        SingleInstanceCoordinator.shared.notifyExistingInstance()
        return
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()

    // Normal termination path: release ownership so the next launch wins
    // the flock immediately (crash/force-quit releases it via the kernel).
    SingleInstanceCoordinator.shared.release()
}

