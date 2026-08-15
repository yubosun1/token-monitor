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

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

