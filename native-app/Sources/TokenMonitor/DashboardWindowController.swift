import AppKit

// MARK: - Window host protocols

/// 内容控制器 → 窗口控制器：原生视图通过这个协议请求关闭窗口、打开独立
/// Dashboard 窗口（取代旧的 `dashboard:open` IPC）。
protocol WindowHost: AnyObject {
    func hostRequestClose()
    func hostRequestOpenDashboard()
}

/// 主窗口内容控制器可选实现：托盘菜单「设置…」与刷新按钮经此打开设置面板。
protocol SettingsHost: AnyObject {
    func openSettings()
}

// MARK: - Constants

enum WindowLifecycleConstants {
    /// 主窗口隐藏后保留内容多久再 teardown 回收。原生 view 树远小于 WebView，
    /// 但隐藏很久仍可释放重建，保持与旧版一致的回收节奏。
    static let mainWindowIdleTeardownDelay: TimeInterval = 120
}

// MARK: - Panel

final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Glass window controller

/// 透明 HUD 玻璃面板承载一个原生 `NSViewController`（取代 WKWebView）。
///
/// 保留：玻璃材质、圆角裁切、bounds 持久化、失焦自动隐藏（trayMode）、
/// 隐藏 idle teardown 回收、show 取消 teardown。移除：WebKit、IPC 桥、
/// 自定义 titlebar 拖拽循环（改用 `isMovableByWindowBackground`）。
class GlassWindowController: NSWindowController, WindowHost {
    private(set) var contentController: NSViewController
    var onOpenDashboard: (() -> Void)?
    var onTeardown: (() -> Void)?

    private let boundsKey: String
    private let defaultSize: NSSize
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var autoHideObservers: [NSObjectProtocol] = []
    private var lastShownAt = Date.distantPast

    let idleTeardown = IdleTeardownScheduler()

    var idleTeardownDelay: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["TOKEN_MONITOR_MAIN_TEARDOWN_MS"],
           let ms = Double(raw), ms > 0 { return ms / 1000.0 }
        return WindowLifecycleConstants.mainWindowIdleTeardownDelay
    }

    init(boundsKey: String, defaultSize: NSSize, contentController: NSViewController) {
        self.boundsKey = boundsKey
        self.defaultSize = defaultSize
        self.contentController = contentController
        let panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
        bindHost()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 把窗口控制器自身注入内容控制器（若它实现 WindowHostConsumer），让视图
    /// 能请求关闭窗口、打开 Dashboard。
    private func bindHost() {
        if let consumer = contentController as? WindowHostConsumer {
            consumer.host = self
        }
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        let overlay = NSView(frame: container.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = AppTheme.overlayColor.cgColor
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)

        let child = contentController.view
        child.frame = container.bounds
        child.autoresizingMask = [.width, .height]
        // 内容视图透明，露出下方玻璃 + 深色 overlay。
        if !child.wantsLayer { child.wantsLayer = true }
        child.layer?.backgroundColor = .clear
        container.addSubview(child)

        panel.contentView = container
    }

    // MARK: - Managed visibility / hide

    func hideManagedWindow() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        windowDidHide()
    }

    override func showWindow(_ sender: Any?) {
        idleTeardown.cancel()
        lastShownAt = Date()
        super.showWindow(sender)
    }

    /// 子类 hide 钩子：主窗口启动 idle teardown，dashboard 立即 teardown。
    func windowDidHide() {}

    // MARK: - Auto-hide on deactivate (trayMode)

    private func autoHideIfNeeded() {
        guard let window, window.isVisible else { return }
        let settings = BridgeCore.shared.settings.snapshot()
        let trayMode = settings["trayMode"] as? Bool ?? true
        guard trayMode else { return }
        guard Date().timeIntervalSince(lastShownAt) > 0.25 else { return }
        hideManagedWindow()
    }

    func enableAutoHideOnResign() {
        guard let window, autoHideObservers.isEmpty else { return }
        let center = NotificationCenter.default
        autoHideObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.autoHideIfNeeded() })
        autoHideObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.autoHideIfNeeded() })
    }

    // MARK: - Bounds persistence

    func restoreBounds() {
        guard let window else { return }
        let stored = BridgeCore.shared.settings.snapshot()[boundsKey] as? [String: Any]
        if let x = stored?["x"] as? Double, let y = stored?["y"] as? Double,
           let w = stored?["width"] as? Double, let h = stored?["height"] as? Double,
           w >= 240, h >= 240 {
            let frame = NSRect(x: x, y: y, width: w, height: h)
            if let screen = NSScreen.main, screen.visibleFrame.intersects(frame) {
                window.setFrame(frame, display: false)
                return
            }
        }
        centerOnScreen()
    }

    func centerOnScreen() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func saveBounds() {
        guard let window else { return }
        let frame = window.frame
        BridgeCore.shared.settings.update([boundsKey: [
            "x": Double(frame.origin.x), "y": Double(frame.origin.y),
            "width": Double(frame.width), "height": Double(frame.height)
        ]])
    }

    func startBoundsTracking() {
        guard let window else { return }
        let center = NotificationCenter.default
        resizeObserver = center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.saveBounds()
        }
        moveObserver = center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            self?.saveBounds()
        }
    }

    // MARK: - Idle teardown

    func scheduleIdleTeardown() {
        idleTeardown.schedule(delay: idleTeardownDelay) { [weak self] in
            guard let self else { return }
            self.tearDown()
            self.onTeardown?()
        }
    }

    /// 释放本控制器持有的内容：通知观察者、contentController、窗口。
    func tearDown() {
        for observer in autoHideObservers { NotificationCenter.default.removeObserver(observer) }
        autoHideObservers.removeAll()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver); self.moveObserver = nil }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver); self.resizeObserver = nil }
        idleTeardown.cancel()
        contentController.view.removeFromSuperview()
        if let host = contentController as? WindowTeardownObserver { host.windowWillTeardown() }
        contentController = PlaceholderViewController()
        window?.close()
    }

    // MARK: - WindowHost

    func hostRequestClose() {
        hideManagedWindow()
    }

    func hostRequestOpenDashboard() {
        onOpenDashboard?()
    }
}

/// 内容控制器可选实现：窗口 teardown 前取消订阅、释放资源。
protocol WindowTeardownObserver: AnyObject {
    func windowWillTeardown()
}

// MARK: - Subclasses

/// 主窗口（用量卡 + breakdown + 会话 + 限额 + 设置）。
final class DashboardWindowController: GlassWindowController {
    init() {
        super.init(boundsKey: "windowBounds", defaultSize: NSSize(width: 340, height: 650),
                   contentController: MainViewController())
        restoreBounds()
        startBoundsTracking()
        enableAutoHideOnResign()
    }

    override func windowDidHide() {
        scheduleIdleTeardown()
    }
}

/// 独立 Dashboard 窗口（趋势图 + 概览卡片）。
final class DashboardViewWindowController: GlassWindowController {
    override var idleTeardownDelay: TimeInterval { 60 }

    init() {
        super.init(boundsKey: "dashboardBounds", defaultSize: NSSize(width: 920, height: 720),
                   contentController: DashboardViewController())
        restoreBounds()
        startBoundsTracking()
        enableAutoHideOnResign()
    }

    /// Dashboard 关闭即 teardown（回收 view 树），与旧版 WebView 行为一致。
    override func hostRequestClose() {
        tearDown()
        onTeardown?()
    }

    override func windowDidHide() {
        scheduleIdleTeardown()
    }
}
