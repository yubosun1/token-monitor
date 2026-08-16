import AppKit

/// 主窗口内容控制器（home/tool/status/model/project/session/limits/trends）。
///
/// 取代原 index.html 的 shell：顶部 TotalBarView、底部 ViewSwitcherBar、
/// 内容区按当前视图切换子控制器；设置与会话详情以覆盖层弹出。
/// 数据直接监听 DataBus.statsUpdated 拉取 Collector.shared.latestStats()。
final class MainViewController: NSViewController, TotalBarDelegate, WindowHostConsumer, SettingsHost, WindowTeardownObserver, WindowVisibilityObserver {

    // MARK: - Host wiring

    weak var host: WindowHost?

    // MARK: - State

    private var period: String = "today"
    private var mode: String = "home" // home|tool|status|model|project|session|limits|trends

    /// Diag/snapshot readout of the currently installed view.
    var currentMode: String { mode }

    // MARK: - Subviews / children

    private let totalBar = TotalBarView()
    private let contentContainer = NSView()
    private let modalOverlay = NSView()
    private let switcherBar = ViewSwitcherBar()
    private var backRow: NSView?
    private var observers: [NSObjectProtocol] = []

    private let homeVC = HomeViewController()
    private let breakdownClientVC = BreakdownViewController()
    private let breakdownModelVC = BreakdownViewController()
    private let statusVC = StatusViewController()
    private let projectsVC = ProjectsViewController()
    private let sessionListVC = SessionListViewController()
    private let limitsVC = LimitsViewController()
    private let trendsVC = TrendsViewController()
    private var settingsVC: NSViewController?

    private var currentContentVC: NSViewController?
    private var presentedVC: NSViewController?
    private var contentTopConstraint: NSLayoutConstraint?
    /// Views whose data is behind the latest stats push; refreshed on switch.
    private var staleContentIds: Set<String> = []
    /// A stats push arrived while the window was hidden.
    private var needsRefreshOnShow = false

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear

        totalBar.delegate = self
        totalBar.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = .clear
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        switcherBar.onSelectView = { [weak self] id in self?.setMode(id) }
        switcherBar.onRefresh = { [weak self] in self?.totalBarDidClickRefresh() }
        switcherBar.onSettings = { [weak self] in self?.openSettings() }
        switcherBar.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [totalBar, contentContainer, switcherBar])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 0
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        modalOverlay.wantsLayer = true
        modalOverlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        modalOverlay.translatesAutoresizingMaskIntoConstraints = false
        modalOverlay.isHidden = true
        root.addSubview(modalOverlay)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // 原版 .shell padding: 12px 14px 14px —— 内容区左右也要 14pt。
            contentContainer.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -14),
            modalOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            modalOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            modalOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            modalOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        breakdownModelVC.mode = "model"
        homeVC.onOpenView = { [weak self] id in
            self?.setMode(id)
        }
        sessionListVC.onSelect = { [weak self] client, sid, period, cost in
            self?.presentSessionDetail(client: client, sessionId: sid, period: period, cost: cost)
        }
        let saved = (BridgeCore.shared.settings.snapshot()["lastViewState"] as? [String: Any])?["breakdown"] as? String
        let savedPeriod = (BridgeCore.shared.settings.snapshot()["lastViewState"] as? [String: Any])?["period"] as? String
        if let savedPeriod, ["today", "month", "allTime"].contains(savedPeriod) {
            period = savedPeriod
            totalBar.setSelectedPeriod(savedPeriod)
        }
        let initial = AppViews.allIds.contains(saved ?? "") ? saved! : "home"
        mode = initial
        switcherBar.setCurrentView(initial)
        installContent(viewController(for: initial))
        // A restored non-home view needs its back row on first load too, not
        // only after the first setMode().
        updateBackRow()
        observeData()
    }

    /// Called by the window controller when the panel is shown. `viewDidAppear`
    /// does not fire here: the panel takes the controller's view as its
    /// `contentView` rather than using `contentViewController`.
    func windowDidShow() {
        guard needsRefreshOnShow else { return }
        needsRefreshOnShow = false
        refresh()
    }

    private func viewController(for id: String) -> NSViewController {
        switch id {
        case "tool": return breakdownClientVC
        case "model": return breakdownModelVC
        case "session": return sessionListVC
        case "limits": return limitsVC
        case "status": return statusVC
        case "project": return projectsVC
        case "trends": return trendsVC
        default: return homeVC
        }
    }

    // MARK: - Mode switching

    func setMode(_ newMode: String) {
        guard newMode != mode, AppViews.allIds.contains(newMode) else { return }
        let wasStale = staleContentIds.contains(newMode)
        mode = newMode
        switcherBar.setCurrentView(newMode, persist: true)
        let isNewInstall = installContent(viewController(for: newMode))
        // A freshly installed (or stale) view needs data; an already-current one
        // was refreshed by the last stats push.
        if wasStale || isNewInstall { refreshContent() }
        updateBackRow()
    }

    /// Returns true when the view controller was newly attached (so it has no
    /// data yet and needs a refresh).
    @discardableResult
    private func installContent(_ vc: NSViewController) -> Bool {
        if currentContentVC === vc { return false }
        if let old = currentContentVC {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(vc)
        if let consumer = vc as? WindowHostConsumer {
            consumer.host = host
        }
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        contentTopConstraint?.isActive = false
        let top = v.topAnchor.constraint(equalTo: contentContainer.topAnchor)
        top.isActive = true
        contentTopConstraint = top
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentContentVC = vc
        return true
    }

    // MARK: - Back row

    private func updateBackRow() {
        guard mode != "home" else {
            if backRow != nil {
                backRow?.removeFromSuperview()
                backRow = nil
                contentTopConstraint?.isActive = false
                if let current = currentContentVC {
                    let top = current.view.topAnchor.constraint(equalTo: contentContainer.topAnchor)
                    top.isActive = true
                    contentTopConstraint = top
                }
            }
            return
        }
        if backRow == nil {
            let row = NSView()
            row.wantsLayer = true
            row.layer?.backgroundColor = .clear
            // 原版 .back-home-button：26px 高、无边框、muted 11px、左对齐无内缩。
            let btn = HoverButton(title: "‹  返回首页")
            btn.font = AppTheme.smallFont
            btn.contentTintColor = AppTheme.textSecondary
            btn.hoverBackground = .clear
            btn.target = self
            btn.action = #selector(backHome)
            btn.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: -6),
                btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            backRow = row
        }
        guard let backRow else { return }
        if backRow.superview !== contentContainer {
            backRow.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(backRow)
            NSLayoutConstraint.activate([
                backRow.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                backRow.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                backRow.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                backRow.heightAnchor.constraint(equalToConstant: backRowHeight),
            ])
        }
        // Always re-anchor: installContent() resets the content top to 0 on every
        // view switch, so an early return here would leave the content sitting
        // underneath the back row.
        if let current = currentContentVC {
            contentTopConstraint?.isActive = false
            let top = current.view.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: backRowHeight)
            top.isActive = true
            contentTopConstraint = top
        }
    }

    /// 原版 .view-back-row：min-height 26px，margin-top -6px / bottom -2px。
    private let backRowHeight: CGFloat = 26

    @objc private func backHome() {
        setMode("home")
    }

    // MARK: - Data bus

    private func observeData() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: DataBus.statsUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(forName: SettingsStore.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
    }

    /// A stats push only needs to redraw what is on screen. The other seven
    /// view controllers are marked stale and re-render when switched to, so a
    /// refresh costs one view's worth of layout instead of eight.
    ///
    /// While the window is hidden (tray mode keeps it hidden most of the time)
    /// nothing is redrawn at all; the pending flag makes the next show catch up.
    func refresh() {
        guard view.window?.isVisible == true || SnapshotProbe.isEnabled else {
            needsRefreshOnShow = true
            return
        }
        let stats = Collector.shared.latestStats()
        let settings = BridgeCore.shared.settings.snapshot()
        totalBar.update(stats: stats, settings: settings)
        totalBar.applySettings(settings)
        staleContentIds = Set(AppViews.allIds).subtracting([mode])
        refreshContent(stats: stats, settings: settings)
    }

    private func refreshContent(stats: [String: Any]? = nil, settings: [String: Any]? = nil) {
        let stats = stats ?? Collector.shared.latestStats()
        let settings = settings ?? BridgeCore.shared.settings.snapshot()
        if let vc = currentContentVC as? ContentUpdatable {
            vc.update(stats: stats, period: period, settings: settings)
        }
        if let statusVC = currentContentVC as? StatusViewController {
            statusVC.refreshIfNeeded()
        }
        staleContentIds.remove(mode)
    }

    // MARK: - TotalBarDelegate

    func totalBarDidSelectPeriod(_ period: String) {
        self.period = period
        var lastView = BridgeCore.shared.settings.snapshot()["lastViewState"] as? [String: Any] ?? [:]
        lastView["period"] = period
        BridgeCore.shared.settings.update(["lastViewState": lastView])
        refresh()
    }

    func totalBarDidClickRefresh() {
        Collector.shared.refreshNow()
        LimitsRuntime.shared.refreshNow()
    }

    func totalBarDidClickSettings() {
        openSettings()
    }

    func totalBarDidClickClose() {
        host?.hostRequestClose()
    }

    func totalBarDidClickMinimize() {
        view.window?.miniaturize(nil)
    }

    /// 原版 pinButton 循环窗口层级：floating → desktop → normal。
    func totalBarDidClickPin() {
        let settings = BridgeCore.shared.settings.snapshot()
        let current = settings["windowBehavior"] as? String ?? "floating"
        let next: String
        switch current {
        case "floating": next = "desktop"
        case "desktop": next = "normal"
        default: next = "floating"
        }
        BridgeCore.shared.settings.update(["windowBehavior": next])
        host?.hostApplyWindowBehavior(next)
    }

    // MARK: - Modal overlay (settings / session detail)

    private func present(_ vc: NSViewController) {
        dismissOverlay()
        addChild(vc)
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        modalOverlay.subviews.forEach { $0.removeFromSuperview() }
        modalOverlay.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: modalOverlay.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: modalOverlay.trailingAnchor),
            v.topAnchor.constraint(equalTo: modalOverlay.topAnchor),
            v.bottomAnchor.constraint(equalTo: modalOverlay.bottomAnchor),
        ])
        presentedVC = vc
        modalOverlay.isHidden = false
    }

    @objc func dismissOverlay() {
        modalOverlay.isHidden = true
        modalOverlay.subviews.forEach { $0.removeFromSuperview() }
        presentedVC?.removeFromParent()
        presentedVC = nil
    }

    // MARK: - SettingsHost

    func openSettings() {
        if settingsVC == nil {
            let s = SettingsViewController()
            s.onClose = { [weak self] in self?.dismissOverlay() }
            settingsVC = s
        }
        guard let settingsVC else { return }
        present(settingsVC)
    }

    // MARK: - Session detail

    private func presentSessionDetail(client: String, sessionId: String, period: String, cost: Double) {
        let detail = SessionDetailViewController(client: client, sessionId: sessionId, period: period, sessionCost: cost)
        detail.onClose = { [weak self] in self?.dismissOverlay() }
        present(detail)
    }

    // MARK: - WindowTeardownObserver

    func windowWillTeardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        children.forEach { $0.removeFromParent() }
    }
}

// MARK: - Protocols

/// 内容子控制器刷新协议。
protocol ContentUpdatable: AnyObject {
    func update(stats: [String: Any]?, period: String, settings: [String: Any])
}

/// 让窗口控制器把自身注入为 host。
protocol WindowHostConsumer: AnyObject {
    var host: WindowHost? { get set }
}

// MARK: - Labeled placeholder

final class PlaceholderViewController: NSViewController {
    private let text: String

    init(label: String = "loading…") {
        self.text = label
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = AppTheme.bodyFont
        label.textColor = AppTheme.textTertiary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 28),
        ])
        view = v
    }
}
