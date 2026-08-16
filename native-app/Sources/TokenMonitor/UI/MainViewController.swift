import AppKit

/// 主窗口内容控制器（home/tool/status/model/project/session/limits/trends）。
///
/// 取代原 index.html 的 shell：顶部 TotalBarView、底部 ViewSwitcherBar、
/// 内容区按当前视图切换子控制器；设置与会话详情以覆盖层弹出。
/// 数据直接监听 DataBus.statsUpdated 拉取 Collector.shared.latestStats()。
final class MainViewController: NSViewController, TotalBarDelegate, WindowHostConsumer, SettingsHost, WindowTeardownObserver {

    // MARK: - Host wiring

    weak var host: WindowHost?

    // MARK: - State

    private var period: String = "today"
    private var mode: String = "home" // home|tool|status|model|project|session|limits|trends

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

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear

        totalBar.delegate = self
        totalBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = .clear
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        switcherBar.onSelectView = { [weak self] id in self?.setMode(id) }
        switcherBar.onRefresh = { [weak self] in self?.totalBarDidClickRefresh() }
        switcherBar.onSettings = { [weak self] in self?.openSettings() }
        switcherBar.translatesAutoresizingMaskIntoConstraints = false

        let footerSeparator = NSView()
        footerSeparator.wantsLayer = true
        footerSeparator.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let mainStack = NSStackView(views: [totalBar, separator, contentContainer, footerSeparator, switcherBar])
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
            contentContainer.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor),
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
        observeData()
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
        mode = newMode
        switcherBar.setCurrentView(newMode, persist: true)
        installContent(viewController(for: newMode))
        refreshContent()
        updateBackRow()
    }

    private func installContent(_ vc: NSViewController) {
        if currentContentVC === vc { return }
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
            let btn = HoverButton(title: "‹ 返回首页")
            btn.font = AppTheme.smallFont
            btn.target = self
            btn.action = #selector(backHome)
            btn.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                btn.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
                btn.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            ])
            backRow = row
        }
        guard let backRow, backRow.superview !== contentContainer else { return }
        backRow.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(backRow)
        NSLayoutConstraint.activate([
            backRow.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            backRow.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            backRow.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            backRow.heightAnchor.constraint(equalToConstant: 24),
        ])
        if let current = currentContentVC {
            contentTopConstraint?.isActive = false
            let top = current.view.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 24)
            top.isActive = true
            contentTopConstraint = top
        }
    }

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

    func refresh() {
        let stats = Collector.shared.latestStats()
        let settings = BridgeCore.shared.settings.snapshot()
        totalBar.update(stats: stats, settings: settings)
        homeVC.update(stats: stats, period: period, settings: settings)
        breakdownClientVC.update(stats: stats, period: period, settings: settings)
        breakdownModelVC.update(stats: stats, period: period, settings: settings)
        sessionListVC.update(stats: stats, period: period, settings: settings)
        limitsVC.update(stats: stats, period: period, settings: settings)
        projectsVC.update(stats: stats, period: period, settings: settings)
        trendsVC.update(stats: stats, period: period, settings: settings)
        statusVC.refreshIfNeeded()
        refreshContent()
    }

    private func refreshContent() {
        let stats = Collector.shared.latestStats()
        let settings = BridgeCore.shared.settings.snapshot()
        if let vc = currentContentVC as? ContentUpdatable {
            vc.update(stats: stats, period: period, settings: settings)
        }
        if let statusVC = currentContentVC as? StatusViewController {
            statusVC.refreshIfNeeded()
        }
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
