import AppKit

/// Diag-only: render the main window's views offscreen to PNG files.
///
/// Screen recording permission is not always granted (and CI has no display),
/// so layout regressions cannot be checked with `screencapture`. This walks the
/// real view tree instead: it sizes the content controller to the stored window
/// bounds, switches through every view, and writes a bitmap per view.
///
/// Enabled with `TOKEN_MONITOR_DIAG=1 TOKEN_MONITOR_DIAG_SNAPSHOT=1`; output
/// goes to `TOKEN_MONITOR_DIAG_SNAPSHOT_DIR` (default `~/Desktop/tm-snapshots`).
enum SnapshotProbe {
    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TOKEN_MONITOR_DIAG"] != nil && env["TOKEN_MONITOR_DIAG_SNAPSHOT"] != nil
    }

    static var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["TOKEN_MONITOR_DIAG_SNAPSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Desktop/tm-snapshots", isDirectory: true)
    }

    /// Switch `main` through every view and snapshot each one, then quit.
    static func run(main: MainViewController, size: NSSize) {
        let dir = outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSLog("[diag] snapshot: writing to %@", dir.path)

        // Snapshotting the window's own content view would capture the glass
        // panel too, which the offscreen path cannot rasterize. Host a detached
        // copy of the view tree on an opaque backdrop instead, so the bitmap
        // shows the same layout on the same dark base the glass produces.
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = AppTheme.snapshotBackdropColor.cgColor

        let content = main.view
        content.removeFromSuperview()
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)

        var views = ["home", "tool", "model", "session", "limits", "trends", "status", "project"]
        func step() {
            guard !views.isEmpty else {
                NSLog("[diag] snapshot: done")
                NSApp.terminate(nil)
                return
            }
            let id = views.removeFirst()
            main.setMode(id)
            main.refresh()
            backdrop.layoutSubtreeIfNeeded()
            // Let the run loop settle so async layout/draw lands in the bitmap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                write(view: backdrop, to: dir.appendingPathComponent("\(id).png"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: step)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: step)
    }

    /// Snapshot an arbitrary view (used for the settings overlay / dashboard).
    static func write(view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[diag] snapshot: no bitmap rep for %@", url.lastPathComponent)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("[diag] snapshot: png encode failed for %@", url.lastPathComponent)
            return
        }
        do {
            try data.write(to: url)
            NSLog("[diag] snapshot: wrote %@ (%dx%d)", url.lastPathComponent, rep.pixelsWide, rep.pixelsHigh)
        } catch {
            NSLog("[diag] snapshot: write failed for %@: %@", url.lastPathComponent, String(describing: error))
        }
    }
}
