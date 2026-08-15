import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, BridgeDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindowController: DashboardWindowController?
    private var dashboardWindowController: DashboardViewWindowController?
    private var showMainWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch that lost the single-instance lock asks us to
        // surface the main window (PLAN.md Phase 1).
        let center = DistributedNotificationCenter.default()
        showMainWindowObserver = center.addObserver(
            forName: SingleInstanceCoordinator.showMainWindowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showMainWindow(center: false)
        }
        // The renderer opens the dashboard from the Activity/Trends modules
        // via window.tokenMonitor.openDashboard() → dashboard:open → delegate.
        BridgeCore.shared.delegate = self
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
                // Same path the renderer close button takes.
                controller.bridgeDidRequestClose(controller.bridge)
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
        SingleInstanceCoordinator.shared.release()
        if let showMainWindowObserver {
            DistributedNotificationCenter.default().removeObserver(showMainWindowObserver)
        }
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
        mainWindowController?.bridge.pushLocal("settings:open", NSNull())
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

    // MARK: - BridgeDelegate

    func bridge(_ bridge: BridgeCore, didRequestOpenDashboard: Bool) {
        openDashboard()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Main window

    private func ensureMainWindow() {
        if mainWindowController == nil {
            mainWindowController = DashboardWindowController()
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
            window.orderOut(nil)
        } else {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

}
