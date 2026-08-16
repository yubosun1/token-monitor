import AppKit
import WebKit

protocol WindowDragController: AnyObject {
    func beginDrag()
}

/// Centralized window lifecycle constants (round-4 Phase 6).
enum WindowLifecycleConstants {
    /// The main widget tears its WebView down after being hidden this long.
    /// Short hides keep the WebView alive for instant tray/hotkey reopen;
    /// past this the ~60MB WebContent/GPU/Networking processes are reclaimed
    /// and the next show rebuilds the window from scratch (~0.2s).
    /// Tuned for memory: 120s reclaims the WebContent process far sooner than
    /// the original 600s, at the cost of a brief rebuild on reopen after 2min.
    static let mainWindowIdleTeardownDelay: TimeInterval = 120
}

/// Borderless floating panel with the HUD vibrancy the Electron version used
/// (`vibrancy: 'hud'`, visualEffectState active, always on top).
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Base window controller: transparent HUD-vibrancy panel hosting a
/// transparent WKWebView, with titlebar drag and bounds persistence.
class GlassWindowController: NSWindowController, WindowDragController, WKNavigationDelegate, WindowLifecycleDelegate {
    /// Shared process pool: lets the widget and dashboard webviews reuse one
    /// WebContent process instead of each owning one (~30-60MB when both
    /// windows are open).
    static let sharedProcessPool = WKProcessPool()
    let bridge = Bridge()
    private(set) var webView: WKWebView!
    private let boundsKey: String
    private let defaultSize: NSSize

    init(boundsKey: String, defaultSize: NSSize) {
        self.boundsKey = boundsKey
        self.defaultSize = defaultSize
        let panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configurePanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
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

        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool
        // Renderer probes (and any page fetch of bundled assets) may use
        // fetch() on file:// resources.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let controller = WKUserContentController()
        if let shimURL = Bundle.main.url(forResource: "tokenMonitorBridge", withExtension: "js"),
           let shim = try? String(contentsOf: shimURL, encoding: .utf8) {
            let script = WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            controller.addUserScript(script)
        }
        config.userContentController = controller

        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        container.addSubview(webView)
        self.webView = webView

        panel.contentView = container
        bridge.attach(to: webView, window: panel)
        bridge.dragController = self
        bridge.lifecycleDelegate = self
        startVisibilityTracking()
    }

    // MARK: - Managed visibility (review round Phase 5)

    /// Every hide/show path routes through this state machine so the
    /// renderer receives exactly one visibility event per transition, no
    /// matter how many hide/show triggers fire in a row.
    private(set) lazy var visibility = ManagedVisibility { [weak self] visible in
        self?.bridge.pushLocal("window:visibility", ["visible": visible])
    }

    private var visibilityObservers: [NSObjectProtocol] = []

    private func startVisibilityTracking() {
        guard let window, visibilityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // A minimized window is not visible to the user: pause the renderer
        // like any other hide path, and start the same idle-teardown clock
        // every hide path shares (round-4 Phase 6). Deminiaturizing is a
        // show: it cancels the pending teardown.
        visibilityObservers.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.visibility.hide()
            self?.windowDidHide()
        })
        visibilityObservers.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.idleTeardown.cancel()
            self?.visibility.show()
        })
    }

    /// Unified hide path: order out, notify the renderer once, then run the
    /// subclass hide hook. Repeated hides emit nothing extra.
    func hideManagedWindow() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        visibility.hide()
        windowDidHide()
    }

    func loadPage(_ name: String) {
        guard let webView,
              let www = Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "www") else {
            NSLog("[window] missing www/%@.html in bundle", name)
            return
        }
        webView.loadFileURL(www, allowingReadAccessTo: www.deletingLastPathComponent())
    }

    // MARK: - Bounds persistence

    private var settingsObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    func restoreBounds() {
        guard let window else { return }
        let stored = BridgeCore.shared.settings.snapshot()[boundsKey] as? [String: Any]
        if let x = stored?["x"] as? Double, let y = stored?["y"] as? Double,
           let w = stored?["width"] as? Double, let h = stored?["height"] as? Double,
           w >= 200, h >= 200 {
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
        let diagBounds = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        settingsObserver = center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            if diagBounds { NSLog("[diag] bounds resize frame=%@", NSStringFromRect(window.frame)) }
            self?.saveBounds()
        }
        // Store the move observer's token too: an unstored token deallocates
        // immediately, which silently unregisters the observer (the
        // block-based API unregisters when the token is released).
        moveObserver = center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            if diagBounds { NSLog("[diag] bounds move frame=%@", NSStringFromRect(window.frame)) }
            self?.saveBounds()
        }
    }

    // MARK: - Titlebar drag

    /// Electron used `-webkit-app-region: drag` on the titlebar; WKWebView
    /// ignores it, so the injected shim sends `window:dragStart` on a
    /// pointerdown over the titlebar and we drive the move here.
    func beginDrag() {
        guard let window else { return }
        // The native drag loop re-enters the main run loop; suppress the
        // resign-key auto-hide while it owns the mouse.
        isDragging = true
        defer { isDragging = false }
        let initialOrigin = window.frame.origin
        let initialMouse = NSEvent.mouseLocation
        while true {
            guard let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            if event.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(
                x: initialOrigin.x + (current.x - initialMouse.x),
                y: initialOrigin.y + (current.y - initialMouse.y)
            ))
        }
    }

    // MARK: - Auto-hide on deactivate

    /// Timestamp of the last showWindow, used to suppress the auto-hide right
    /// after the window appears (same 250ms guard the Electron version used).
    private var lastShownAt = Date.distantPast
    /// True while the titlebar drag loop runs.
    private var isDragging = false
    private var autoHideObservers: [NSObjectProtocol] = []

    /// Hide the popover when the app loses key/active status and trayMode is
    /// on (Electron: mainWindow blur → hidePopover). Only the main widget
    /// window opts in.
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

    /// Unified show path: display, notify the renderer once, and cancel
    /// any pending idle teardown — a show inside the delay reuses this
    /// controller and its WebView (round-4 Phase 6).
    override func showWindow(_ sender: Any?) {
        idleTeardown.cancel()
        lastShownAt = Date()
        visibility.show()
        super.showWindow(sender)
    }

    private func autoHideIfNeeded() {
        guard !isDragging else { return }
        guard let window, window.isVisible else { return }
        let settings = BridgeCore.shared.settings.snapshot()
        let trayMode = settings["trayMode"] as? Bool ?? true
        guard trayMode else { return }
        guard Date().timeIntervalSince(lastShownAt) > 0.25 else { return }
        hideManagedWindow()
    }

    /// Hook for subclasses after a managed hide (auto-hide / tray / close
    /// / miniaturize).
    func windowDidHide() {}

    // MARK: - Teardown (PLAN.md Phase 5, round-4 Phase 6)

    /// Idle teardown scheduler: a show cancels any pending teardown, a hide
    /// (re)schedules one. The pure rules live in IdleTeardownScheduler
    /// (unit-tested); this only wires the WebView work.
    let idleTeardown = IdleTeardownScheduler()

    /// How long a hidden window keeps its WebView before teardown. The main
    /// widget uses the central default; the dashboard overrides it with its
    /// shorter idle window. A diag-only env override shortens the delay so
    /// lifecycle probes don't wait ten minutes.
    var idleTeardownDelay: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["TOKEN_MONITOR_MAIN_TEARDOWN_MS"],
           let ms = Double(raw), ms > 0 {
            return ms / 1000.0
        }
        return WindowLifecycleConstants.mainWindowIdleTeardownDelay
    }

    /// Called once the teardown finished; AppDelegate drops its reference.
    var onTeardown: (() -> Void)?

    /// Default close semantics: the main widget only hides, so a hotkey or
    /// tray click reopens it instantly (the dashboard overrides this and
    /// tears its WebView down to reclaim memory).
    func bridgeDidRequestClose(_ bridge: Bridge) {
        hideManagedWindow()
    }

    /// (Re)schedule the idle teardown for a hide. Repeated hides supersede
    /// instead of stacking; the fired work tears down exactly once.
    func scheduleIdleTeardown() {
        idleTeardown.schedule(delay: idleTeardownDelay) { [weak self] in
            guard let self else { return }
            self.tearDown()
            self.onTeardown?()
        }
    }

    /// Release everything this controller owns: notification observers,
    /// bridge pusher + script handler, navigation, the WebView and the
    /// window. Callers (AppDelegate) drop their strong reference right
    /// after, which deallocates the controller and its WebView.
    func tearDown() {
        for observer in autoHideObservers { NotificationCenter.default.removeObserver(observer) }
        autoHideObservers.removeAll()
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver); self.settingsObserver = nil }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver); self.moveObserver = nil }
        idleTeardown.cancel()
        bridge.detach()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window?.close()
    }

    // MARK: - Pending local pushes (round-4 Phase 6)

    private var pendingLocalPushes: [(String, Any)] = []
    private var pageLoaded = false

    /// Push a window-local event, queueing it until the page finished
    /// loading: pushes issued right after a rebuild must not vanish into a
    /// half-loaded web view (e.g. settings:open).
    func pushLocalWhenLoaded(_ event: String, _ payload: Any) {
        if pageLoaded {
            bridge.pushLocal(event, payload)
        } else {
            pendingLocalPushes.append((event, payload))
        }
    }

    /// Mark the page loaded and deliver queued local pushes in order.
    func flushPendingLocalPushes() {
        pageLoaded = true
        let pending = pendingLocalPushes
        pendingLocalPushes.removeAll()
        for (event, payload) in pending {
            bridge.pushLocal(event, payload)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__tmOnLoad && window.__tmOnLoad()", completionHandler: nil)
        // A visibility push sent before the page finished loading is lost;
        // re-sync the current native state now (review round Phase 5).
        visibility.resync()
        // Deliver any local pushes queued while the page was loading, e.g.
        // settings:open issued right after a rebuild (round-4 Phase 6).
        flushPendingLocalPushes()
        dumpPageStateIfDiagnostics()
    }

    /// Dev aid: with TOKEN_MONITOR_DIAG set, log a structural snapshot of the
    /// rendered page so shell wiring can be verified without screenshots.
    private func dumpPageStateIfDiagnostics() {
        guard ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil else { return }
        let probe = """
        (() => {
          const broken = [];
          performance.getEntriesByType('resource').forEach(r => {
            if (r.name.endsWith('.js') && r.responseStatus === 0 && r.transferSize === 0 && !r.name.includes('?')) {}
          });
          return JSON.stringify({
            title: document.title,
            readyState: document.readyState,
            url: location.href.split('/').pop(),
            shell: !!document.querySelector('.shell'),
            settingsPanel: !!document.querySelector('#settingsPanel'),
            rows: document.querySelectorAll('.row, [class*="row"]').length,
            bodySize: [document.body.scrollWidth, document.body.scrollHeight],
            tokenMonitor: typeof window.tokenMonitor,
            scriptCount: document.scripts.length,
            totalTokens: document.getElementById('totalTokens')?.textContent || null,
            status: document.getElementById('status')?.textContent || null,
            breakdownBars: [...document.querySelectorAll('.dash-breakdown-col')].map(col =>
              [...col.querySelectorAll('.dash-bd-bar-bg')].map(bar => {
                const rect = bar.getBoundingClientRect();
                return [Math.round(rect.x), Math.round(rect.width)];
              })
            ),
            resources: performance.getEntriesByType('resource').map(r => ({ name: r.name.split('/').pop(), ok: r.transferSize > 0 || r.responseStatus > 0 })).filter(r => !r.ok).slice(0, 10)
          });
        })()
        """
        webView.evaluateJavaScript(probe) { result, error in
            if let error {
                NSLog("[diag] page probe failed: %@", String(describing: error))
            } else if let string = result as? String {
                NSLog("[diag] page state: %@", string)
            }
        }
        let resourceProbe = """
        (async () => {
          const out = [];
          for (const s of [...document.scripts]) {
            if (!s.src) continue;
            try { const r = await fetch(s.src); if (!r.ok) out.push({ name: s.src.split('/').pop(), status: r.status }); }
            catch (e) { out.push({ name: s.src.split('/').pop(), err: String(e) }); }
          }
          return JSON.stringify({ failedResources: out });
        })()
        """
        webView.evaluateJavaScript(resourceProbe) { result, error in
            if let string = result as? String {
                NSLog("[diag] resources: %@", string)
            } else if let error {
                NSLog("[diag] resource probe: %@", String(describing: error))
            }
        }
        if self is DashboardViewWindowController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let webView = self.webView else { return }
                let geometryProbe = """
                JSON.stringify([...document.querySelectorAll('.dash-breakdown-col')].map(col =>
                  [...col.querySelectorAll('.dash-bd-bar-bg')].map(bar => {
                    const rect = bar.getBoundingClientRect();
                    return [Math.round(rect.x), Math.round(rect.width)];
                  })
                ))
                """
                webView.evaluateJavaScript(geometryProbe) { result, _ in
                    if let string = result as? String {
                        NSLog("[diag] dashboard bars: %@", string)
                    }
                }
            }
        }
        // Dev aid: exercise the dashboard window so its own render errors
        // surface in the same log. Skipped during the main lifecycle probe,
        // whose auto-hide/teardown timing it would disturb.
        if self is DashboardWindowController,
           ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_MAIN_LIFECYCLE"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let webView = self.webView else { return }
                webView.evaluateJavaScript("window.tokenMonitor && window.tokenMonitor.openDashboard()", completionHandler: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                guard let self, let webView = self.webView else { return }
                let interactionProbe = """
                (async () => {
                  const out = {};
                  out.totalTokens = document.getElementById('totalTokens')?.textContent || null;
                  out.status = document.getElementById('status')?.textContent || null;
                  const settingsBtn = document.getElementById('settingsButton');
                  if (settingsBtn) settingsBtn.click();
                  await new Promise(r => setTimeout(r, 400));
                  out.settingsOpen = !document.getElementById('settingsPanel')?.classList.contains('hidden');
                  out.settingsSections = [...document.querySelectorAll('.settings-section-toggle')].map(b => b.getAttribute('data-settings-section'));
                  out.clientRows = [...document.querySelectorAll('#clientDisplayList [class*="row"]')].map(r => (r.querySelector('[class*="name"], [class*="label"]')?.textContent || '').trim()).slice(0, 10);
                  out.providerExpansion = {};
                  for (const id of ['deepseek', 'opencode']) {
                    const button = document.getElementById(`limitProviderDisclosure-${id}`);
                    if (button?.getAttribute('aria-expanded') !== 'true') button?.click();
                    await new Promise(r => setTimeout(r, 100));
                    const options = document.getElementById(`limitProviderOptions-${id}`);
                    out.providerExpansion[id] = {
                      expanded: button?.getAttribute('aria-expanded') || null,
                      hidden: options?.classList.contains('hidden') ?? null
                    };
                  }
                  if (settingsBtn) settingsBtn.click();
                  await new Promise(r => setTimeout(r, 200));
                  const limitsTab = document.querySelector('[data-view="limits"], .view-tab-limits');
                  if (limitsTab) limitsTab.click();
                  await new Promise(r => setTimeout(r, 500));
                  out.limitsProviders = [...document.querySelectorAll('.limit-provider-row')].map(r => (r.querySelector('[class*="name"], [class*="label"]')?.textContent || '').trim()).slice(0, 6);
                  const openCodeTitle = [...document.querySelectorAll('#limitsPanel .limit-name-title')].find(el => el.textContent.trim() === 'OpenCode');
                  const openCodeGroup = openCodeTitle?.closest('.limit-row-group');
                  out.openCodeAccountRows = openCodeGroup?.querySelectorAll('.limit-account-row').length ?? (openCodeTitle ? 1 : 0);
                  const toolTab = document.querySelector('[data-view="tool"], [data-breakdown="tool"]');
                  if (toolTab) toolTab.click();
                  await new Promise(r => setTimeout(r, 300));
                  window.webkit.messageHandlers.bridge.postMessage({ method: 'window:diagResult', args: [JSON.stringify(out)] });
                  // Session detail round trip: the first tokscale full scan can
                  // take minutes, so this probe runs later (see below).
                })()
                """
                webView.evaluateJavaScript(interactionProbe, completionHandler: nil)
            }
            // Dev aid: exercise the session-detail popup once the first full
            // tokscale scan has populated the session rows (it can take
            // minutes on a large history).
            DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self] in
                guard let self, let webView = self.webView else { return }
                let sessionDetailProbe = """
                (async () => {
                  const out = {};
                  // The view-switcher menu only renders after the first stats
                  // push, so wait for real data before switching views.
                  for (let i = 0; i < 180; i++) {
                    const text = document.getElementById('totalTokens')?.textContent || '';
                    if (text && text !== '0') break;
                    await new Promise(r => setTimeout(r, 1000));
                  }
                  const disclosure = document.querySelector('.view-switcher-disclosure');
                  if (disclosure) disclosure.click();
                  await new Promise(r => setTimeout(r, 300));
                  out.menuViews = [...document.querySelectorAll('.view-switcher-menu-item')].map(i => i.dataset.view);
                  // The settings panel also renders rows with data-view
                  // attributes; scope the query to the switcher menu.
                  const sessionTab = document.querySelector('#viewSwitcherMenu [data-view="session"]');
                  out.sessionTabFound = !!sessionTab;
                  out.totalTokensText = document.getElementById('totalTokens')?.textContent || null;
                  if (sessionTab) sessionTab.click();
                  await new Promise(r => setTimeout(r, 300));
                  out.viewAfterClick = document.querySelector('.view-switcher-menu-item.is-current')?.dataset.view || null;
                  await new Promise(r => setTimeout(r, 700));
                  out.viewAfterWait = document.querySelector('.view-switcher-menu-item.is-current')?.dataset.view || null;
                  const detailClients = ['claude', 'codex', 'opencode', 'proma', 'hanako', 'dsh'];
                  const sessionRow = [...document.querySelectorAll('.row[data-client]')]
                    .find(r => detailClients.includes(r.dataset.client));
                  if (!sessionRow) {
                    out.detailRow = null;
                    out.totalRows = document.querySelectorAll('.row').length;
                    out.currentView = document.querySelector('.view-switcher-menu-item.is-current')?.dataset.view || null;
                  } else {
                    out.detailRow = { client: sessionRow.dataset.client, key: sessionRow.dataset.key };
                    sessionRow.click();
                    await new Promise(r => setTimeout(r, 2000));
                    out.detailExchanges = document.querySelectorAll('.detail-exchange').length;
                    out.detailNote = document.querySelector('.detail-note')?.textContent || null;
                    const title = document.querySelector('.detail-ex-title');
                    out.detailTitle = title ? title.textContent.trim().slice(0, 60) : null;
                    const sub = document.querySelector('.detail-ex-sub');
                    out.detailSub = sub ? sub.textContent.trim().slice(0, 80) : null;
                    const firstTurn = document.querySelector('.detail-turn-title');
                    out.detailFirstTurn = firstTurn ? firstTurn.textContent.trim() : null;
                  }
                  // Trends view: consumes state.stats.historyPreview.
                  const trendsTab = document.querySelector('#viewSwitcherMenu [data-view="trends"]');
                  if (trendsTab) trendsTab.click();
                  await new Promise(r => setTimeout(r, 600));
                  out.trendsEmpty = !!document.querySelector('.trends-empty');
                  out.trendsBars = document.querySelectorAll('.spark-bar').length;
                  out.trendsStats = [...document.querySelectorAll('.trends-stat')].map(s => s.textContent.trim().replace(/\\s+/g, ' ')).slice(0, 4);
                  // Status view: fetches the four statuspage.io providers.
                  const statusTab = document.querySelector('#viewSwitcherMenu [data-view="status"]');
                  if (statusTab) statusTab.click();
                  await new Promise(r => setTimeout(r, 6000));
                  out.statusRows = [...document.querySelectorAll('.service-status-row')].map(r => ({
                    label: r.querySelector('strong')?.textContent || '',
                    pill: r.querySelector('.service-status-pill')?.textContent || '',
                    checked: r.querySelector('.service-status-checked')?.textContent || null
                  }));
                  window.webkit.messageHandlers.bridge.postMessage({ method: 'window:diagResult', args: [JSON.stringify(out)] });
                })()
                """
                webView.evaluateJavaScript(sessionDetailProbe, completionHandler: nil)
            }
        }
    }
}

/// Main widget window (index.html — the glass card with tabs, settings,
/// session rows, limits and subscriptions).
///
/// Lifecycle (round-4 Phase 6): closing and tray/hotkey toggles hide the
/// window as before, but a window hidden for the central idle delay tears
/// its WebView down so the ~60MB WebContent process is reclaimed. A show
/// inside the delay reuses the controller instantly; after the timeout the
/// next show rebuilds it — the page pulls stats/settings/history/limits
/// itself on boot via the bridge invokes, so no native replay is needed.
final class DashboardWindowController: GlassWindowController {
    init() {
        super.init(boundsKey: "windowBounds", defaultSize: NSSize(width: 340, height: 650))
        loadPage("index")
        restoreBounds()
        startBoundsTracking()
        // The widget popover hides when the app loses focus (trayMode);
        // the dashboard window stays put.
        enableAutoHideOnResign()
    }

    /// Every managed hide (tray/hotkey/close/auto-hide/miniaturize) starts
    /// the idle-teardown clock; showWindow cancels it.
    override func windowDidHide() {
        scheduleIdleTeardown()
    }
}

/// The separate Usage Dashboard window (dashboard.html — charts/heatmap).
///
/// Lifecycle (PLAN.md Phase 5): the dashboard's WebView is a significant
/// chunk of memory, so unlike the main widget it is torn down when closed.
/// An explicit close tears down immediately; an auto-hide (focus loss) keeps
/// the controller alive for a short idle window for instant reopen, then
/// tears down. Reopening always rebuilds the controller from scratch: the
/// dashboard page fetches settings and history itself on boot, so state is
/// restored without any native replay.
final class DashboardViewWindowController: GlassWindowController {
    /// Auto-hide keeps the window in memory this long before teardown
    /// (unchanged from review round Phase 5; the main widget uses the
    /// central 600s default instead).
    override var idleTeardownDelay: TimeInterval { 60 }

    init() {
        super.init(boundsKey: "dashboardBounds", defaultSize: NSSize(width: 920, height: 720))
        loadPage("dashboard")
        restoreBounds()
        startBoundsTracking()
        // Dashboard follows the same focus behavior as the widget popover:
        // hide when the app loses key/active status.
        enableAutoHideOnResign()
    }

    override func bridgeDidRequestClose(_ bridge: Bridge) {
        tearDown()
        onTeardown?()
    }

    override func windowDidHide() {
        scheduleIdleTeardown()
    }
}
