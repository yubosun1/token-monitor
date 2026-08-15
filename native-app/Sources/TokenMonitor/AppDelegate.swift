import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, BridgeDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindowController: DashboardWindowController?
    private var dashboardWindowController: DashboardViewWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShortcutController.shared.stop()
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
            dashboardWindowController = DashboardViewWindowController()
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
