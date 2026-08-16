import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindowController: DashboardWindowController?
    private var dashboardWindowController: DashboardViewWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch that lost the single-instance lock asks us to
        // surface the main window. Requests that arrived before this point
        // were buffered by the coordinator and fire exactly once here
        // (review round Phase 6).
        SingleInstanceCoordinator.shared.installShowCallback { [weak self] in
            self?.showMainWindow(center: false)
        }
        buildStatusItem()
        // Global toggle hotkey (Carbon; works while the LSUIElement app is in
        // the background, like the Electron globalShortcut it replaces).
        ShortcutController.shared.onToggle = { [weak self] in self?.toggleMainWindow() }
        ShortcutController.shared.start(settings: BridgeCore.shared.settings.snapshot())
        Collector.shared.start()
        LimitsRuntime.shared.start()
        // Tray-only by default (matches the user's Electron configuration):
        // the window appears on tray click or ⌘E, not at launch.
        let trayMode = BridgeCore.shared.settings.snapshot()["trayMode"] as? Bool ?? true
        // Dev aid: diag runs exercise the window (page probe, interaction
        // probe) even when trayMode keeps the app tray-only by default.
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        if !trayMode || diag {
            showMainWindow(center: true)
        }
        // Dev aid: TOKEN_MONITOR_DIAG_LIFECYCLE=1 opens/closes the dashboard
        // repeatedly, logging the footprint after every teardown so Phase 5
        // memory behavior is measurable without manual clicking.
        if diag, ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_LIFECYCLE"] != nil {
            runDashboardLifecycleProbe()
        }
        // Dev aid: TOKEN_MONITOR_DIAG_SETTINGS=1 lowers refreshMs at runtime
        // through the same settings:update path the renderer uses, so the
        // Phase 4 timer hot-reload is observable in the tick cadence.
        if diag, ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                BridgeCore.shared.settings.update(["refreshMs": 8000])
                NSLog("[diag] settings probe: refreshMs -> 8000 (expect 8s tick cadence)")
            }
        }
        // Dev aid: TOKEN_MONITOR_DIAG_MAIN_LIFECYCLE=1 hides the main window,
        // lets the idle teardown fire, then reopens it repeatedly, logging
        // the footprint after each teardown and rebuild (round-4 Phase 6).
        // Combine with TOKEN_MONITOR_MAIN_TEARDOWN_MS to shorten the delay.
        if diag, ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_MAIN_LIFECYCLE"] != nil {
            runMainWindowLifecycleProbe()
        }
        // Dev aid: TOKEN_MONITOR_DIAG_CLIENTS_PROBE=1 disables every client
        // through the real settings-update path, then restores the previous
        // value — the empty stats push and the recovery push both land in
        // the diag log (round-4 Phase 2.2 runtime check).
        if diag, ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_CLIENTS_PROBE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                let previous = BridgeCore.shared.settings.snapshot()["clients"] as? String
                    ?? "claude,codex,opencode,workbuddy,proma,hanako,dsh"
                BridgeCore.shared.settings.update(["clients": ""])
                NSLog("[diag] clients probe: disabled all clients (expect empty stats push)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    BridgeCore.shared.settings.update(["clients": previous])
                    NSLog("[diag] clients probe: restored clients (expect recovery push)")
                }
            }
        }
        // Dev aid: TOKEN_MONITOR_DIAG_VIEWS=1 cycles the main window through
        // every view (home/tool/status/model/project/session/limits/trends),
        // opens the settings overlay and the standalone dashboard once each —
        // exercises the full native UI tree (constraints, drawing, data reads)
        // so constraint/layout regressions surface in the diag log.
        if diag, ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_VIEWS"] != nil {
            runViewsProbe()
        }
        // Dev aid: TOKEN_MONITOR_DIAG_SNAPSHOT=1 renders every main-window view
        // offscreen to PNG, so layout can be diffed against the Electron UI's
        // reference screenshots without screen-recording permission.
        if SnapshotProbe.isEnabled {
            runSnapshotProbe()
        }
    }

    /// Diag-only: snapshot every main-window view offscreen, then quit.
    private func runSnapshotProbe() {
        ensureMainWindow()
        guard let wc = mainWindowController,
              let main = wc.contentController as? MainViewController else {
            NSLog("[diag] snapshot: main controller missing, aborting")
            return
        }
        let size = wc.window?.frame.size ?? NSSize(width: 363, height: 650)
        SnapshotProbe.run(main: main, size: size)
    }

    /// Diag-only: cycle all main-window views, then open settings and the
    /// dashboard window briefly (native UI smoke test).
    private func runViewsProbe() {
        let views = ["home", "tool", "status", "model", "project", "session", "limits", "trends"]
        var index = 0
        func step() {
            guard let wc = mainWindowController, let main = wc.contentController as? MainViewController else {
                NSLog("[diag] views probe: main controller missing, aborting")
                return
            }
            if index < views.count {
                let id = views[index]
                index += 1
                main.setMode(id)
                NSLog("[diag] views probe: switched to %@", id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: step)
                return
            }
            // Settings overlay
            main.openSettings()
            NSLog("[diag] views probe: settings opened")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                main.dismissOverlay()
                NSLog("[diag] views probe: settings closed")
                // Standalone dashboard window
                self.openDashboard()
                NSLog("[diag] views probe: dashboard opened")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    self.dashboardWindowController?.hostRequestClose()
                    NSLog("[diag] views probe: dashboard closed, done")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: step)
    }

    /// Diag-only: hide the main window (the same path the tray toggle takes),
    /// wait for the idle teardown to fire, then rebuild — per cycle.
    private func runMainWindowLifecycleProbe() {
        let total = Int(ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_LIFECYCLE_CYCLES"] ?? "20") ?? 20
        var cycles = 0
        func cycle() {
            guard cycles < total else {
                NSLog("[diag] main lifecycle probe done (%d cycles)", total)
                return
            }
            cycles += 1
            guard let wc = mainWindowController else {
                NSLog("[diag] main lifecycle probe: controller missing, aborting")
                return
            }
            // An auto-hide may already have hidden the window (and started
            // the teardown clock); only hide when still visible.
            if let window = wc.window, window.isVisible {
                PerfDiag.footprintMark(String(format: "main-lifecycle-%02d-hidden", cycles))
                wc.hideManagedWindow()
            }
            // The teardown fires after the (diag-shortened) idle delay; poll
            // once past it and log whether AppDelegate dropped the reference.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                if self.mainWindowController == nil {
                    NSLog("[diag] main lifecycle cycle %d: controller torn down", cycles)
                } else {
                    NSLog("[diag] main lifecycle cycle %d: controller still alive", cycles)
                }
                PerfDiag.footprintMark(String(format: "main-lifecycle-%02d-teardown", cycles))
                self.showMainWindow(center: false)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    PerfDiag.footprintMark(String(format: "main-lifecycle-%02d-rebuilt", cycles))
                    cycle()
                }
            }
        }
        // Wait for the startup scans to settle before the first cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: cycle)
    }

    /// Diag-only: open the dashboard, close it (same path as the renderer
    /// close button), and log the post-teardown footprint per cycle.
    private func runDashboardLifecycleProbe() {
        let total = Int(ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_LIFECYCLE_CYCLES"] ?? "20") ?? 20
        var cycles = 0
        func cycle() {
            guard cycles < total else {
                NSLog("[diag] lifecycle probe done (%d cycles)", total)
                return
            }
            cycles += 1
            PerfDiag.log(String(format: "lifecycle cycle %d open", cycles))
            openDashboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let controller = self.dashboardWindowController else {
                    NSLog("[diag] lifecycle probe: dashboard controller missing, aborting")
                    return
                }
                // Same path the native close button takes.
                controller.hostRequestClose()
                self.dashboardWindowController = nil
                PerfDiag.footprintMark(String(format: "lifecycle-cycle-%02d", cycles))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cycle() }
            }
        }
        // Wait for the startup scans to settle before the first cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: cycle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShortcutController.shared.stop()
        // No orphaned scanner processes (PLAN.md Phase 4 item 6).
        TokscaleRunner.shared.terminateAll()
        SingleInstanceCoordinator.shared.unregisterActivationObserver()
        SingleInstanceCoordinator.shared.release()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(contentsOf: Bundle.main.url(forResource: "tray-token-monitor", withExtension: "png")!)
            icon?.isTemplate = true
            icon?.size = NSSize(width: 20, height: 20)
            button.image = icon
            button.toolTip = "Token Monitor"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showTrayMenu()
        } else {
            toggleMainWindow()
        }
    }

    private func showTrayMenu() {
        let menu = NSMenu()
        let refresh = menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(NSMenuItem.separator())
        let dashboard = menu.addItem(withTitle: "打开用量面板", action: #selector(openDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(NSMenuItem.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(NSMenuItem.separator())
        let quit = menu.addItem(withTitle: "退出 Token Monitor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // detach so left-click toggles again
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        Collector.shared.refreshNow()
    }

    @objc private func openSettings() {
        showMainWindow(center: false)
        (mainWindowController?.contentController as? SettingsHost)?.openSettings()
    }

    @objc private func openDashboard() {
        if dashboardWindowController == nil {
            let controller = DashboardViewWindowController()
            // Drop the strong reference once the dashboard tears its WebView
            // down (PLAN.md Phase 5), so repeated open/close cycles release
            // the controller, window and WebView instead of accumulating.
            controller.onTeardown = { [weak self] in
                self?.dashboardWindowController = nil
            }
            dashboardWindowController = controller
        }
        dashboardWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - BridgeDelegate (removed with WebView IPC)

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Main window

    private func ensureMainWindow() {
        if mainWindowController == nil {
            let controller = DashboardWindowController()
            // Once the long-hidden window tears its content down, drop the
            // strong reference so the controller and window are released;
            // the next tray/hotkey/settings request rebuilds them.
            controller.onTeardown = { [weak self] in
                self?.mainWindowController = nil
            }
            // Main window's "open dashboard" button routes here (replaces
            // the old dashboard:open IPC).
            controller.onOpenDashboard = { [weak self] in
                self?.openDashboard()
            }
            mainWindowController = controller
        }
    }

    private func showMainWindow(center: Bool) {
        ensureMainWindow()
        guard let wc = mainWindowController else { return }
        if center {
            wc.restoreBounds()
        }
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleMainWindow() {
        ensureMainWindow()
        guard let wc = mainWindowController, let window = wc.window else { return }
        if window.isVisible {
            // Unified hide path (review round Phase 5): orders out and sends
            // window:visibility=false exactly once.
            wc.hideManagedWindow()
        } else {
            if window.isMiniaturized { window.deminiaturize(nil) }
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

}
