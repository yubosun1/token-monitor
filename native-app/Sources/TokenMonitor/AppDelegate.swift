import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, BridgeDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindowController: DashboardWindowController?
    private var dashboardWindowController: DashboardViewWindowController?
    private var windowVisibilityObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch that lost the single-instance lock asks us to
        // surface the main window. Requests that arrived before this point
        // were buffered by the coordinator and fire exactly once here
        // (review round Phase 6).
        SingleInstanceCoordinator.shared.installShowCallback { [weak self] in
            self?.showMainWindow(center: false)
        }
        // The renderer opens the dashboard from the Activity/Trends modules
        // via window.tokenMonitor.openDashboard() → dashboard:open → delegate.
        BridgeCore.shared.delegate = self
        buildMainMenu()
        updateStatusItemVisibility()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let keys = note.userInfo?["keys"] as? [String], keys.contains("showTrayIcon") {
                self?.updateStatusItemVisibility()
            }
        }
        // Global toggle hotkey (Carbon; works while the LSUIElement app is in
        // the background, like the Electron globalShortcut it replaces).
        ShortcutController.shared.onToggle = { [weak self] in self?.toggleMainWindow() }
        ShortcutController.shared.start(settings: BridgeCore.shared.settings.snapshot())
        // Re-apply the start-at-login registration: macOS drops SMAppService
        // registrations on app update, so the stored setting alone does not
        // survive an update without this reconcile.
        BridgeCore.shared.reconcileStartAtLogin()
        Collector.shared.start()
        LimitsRuntime.shared.start()

        windowVisibilityObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TokenMonitorWindowVisibilityChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateActiveWindowState()
        }
        updateActiveWindowState()
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
                    ?? "codex,kimi,antigravity,workbuddy,proma,hanako,dsh"
                BridgeCore.shared.settings.update(["clients": ""])
                NSLog("[diag] clients probe: disabled all clients (expect empty stats push)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    BridgeCore.shared.settings.update(["clients": previous])
                    NSLog("[diag] clients probe: restored clients (expect recovery push)")
                }
            }
        }
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
        SingleInstanceCoordinator.shared.unregisterActivationObserver()
        SingleInstanceCoordinator.shared.release()
    }

    // MARK: - Main menu

    /// Install the application main menu. The app is LSUIElement (no visible
    /// menu bar), but key equivalents resolve against NSApp.mainMenu, so the
    /// standard editing shortcuts (Cmd+C/V/X/A/Z etc.) only reach the
    /// WKWebView's field editor when an Edit menu exists — Electron shipped a
    /// default menu that did exactly this; without it, pasting into the
    /// settings inputs does nothing. Menu items target the responder chain
    /// (nil target) so the web view's own paste:/copy:/cut: handlers run.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Token Monitor")
        let about = appMenu.addItem(
            withTitle: "关于 Token Monitor",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        appMenu.addItem(NSMenuItem.separator())
        let hide = appMenu.addItem(
            withTitle: "隐藏 Token Monitor",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        appMenu.addItem(NSMenuItem.separator())
        let quit = appMenu.addItem(
            withTitle: "退出 Token Monitor",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu

        if ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil {
            let sections = (NSApp.mainMenu?.items ?? []).compactMap { item -> String? in
                guard let submenu = item.submenu else { return nil }
                let entries = submenu.items
                    .map { "\($0.title)[\($0.keyEquivalent)]" }
                    .joined(separator: ",")
                return "\(submenu.title): \(entries)"
            }
            NSLog("[diag] main menu installed: %@", sections.joined(separator: " | "))
        }
    }

    // MARK: - Status item

    private func updateStatusItemVisibility() {
        let showTrayIcon = BridgeCore.shared.settings.snapshot()["showTrayIcon"] as? Bool ?? true
        if showTrayIcon {
            if statusItem == nil {
                buildStatusItem()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func buildStatusItem() {
        guard statusItem == nil else { return }
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
        // Queued until the page finished loading: right after an idle
        // teardown the rebuilt page is not ready yet (round-4 Phase 6).
        mainWindowController?.pushLocalWhenLoaded("settings:open", NSNull())
    }

    @objc private func openDashboard() {
        if dashboardWindowController == nil {
            let controller = DashboardViewWindowController()
            // Drop the strong reference once the dashboard tears its WebView
            // down (PLAN.md Phase 5), so repeated open/close cycles release
            // the controller, window and WebView instead of accumulating.
            controller.onTeardown = { [weak self] in
                self?.dashboardWindowController = nil
                self?.updateActiveWindowState()
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
            let controller = DashboardWindowController()
            // Once the long-hidden window tears its WebView down, drop the
            // strong reference so the controller, window and WebView are
            // released; the next tray/hotkey/settings request rebuilds them
            // from scratch (round-4 Phase 6).
            controller.onTeardown = { [weak self] in
                self?.mainWindowController = nil
                self?.updateActiveWindowState()
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

    private func updateActiveWindowState() {
        let mainVisible = mainWindowController?.window?.isVisible == true
        let dashVisible = dashboardWindowController?.window?.isVisible == true
        let hasActive = mainVisible || dashVisible
        Collector.shared.setHasActiveWindows(hasActive)
        LimitsRuntime.shared.setHasActiveWindows(hasActive)
    }

}
