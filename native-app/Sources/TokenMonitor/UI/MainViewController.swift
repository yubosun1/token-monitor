import AppKit

/// 主窗口内容控制器（用量卡 + breakdown + 会话 + 限额 + 设置/详情覆盖层）。
///
/// 取代原 index.html 的 shell：顶部 TotalBarView、模式切换条、内容区按当前
/// 模式切换 breakdown/session/limits 子控制器；设置与会话详情以覆盖层弹出。
/// 数据直接监听 DataBus.statsUpdated 拉取 Collector.shared.latestStats()。
final class MainViewController: NSViewController, TotalBarDelegate, WindowHostConsumer, SettingsHost, WindowTeardownObserver {

    // MARK: - Host wiring

    weak var host: WindowHost?

    // MARK: - State

    private var period: String = "today"
    private var mode: String = "tool" // tool|model|session|limits

    // MARK: - Subviews / children

    private let totalBar = TotalBarView()
    private let contentContainer = NSView()
    private let modalOverlay = NSView()
    private var modeButtons: [(String, HoverButton)] = []
    private var observers: [NSObjectProtocol] = []

    private let breakdownClientVC = BreakdownViewController()
    private let breakdownModelVC = BreakdownViewController()
    private let sessionListVC = SessionListViewController()
    private let limitsVC = LimitsViewController()
    private var settingsVC: NSViewController?

    private var currentContentVC: NSViewController?
    private var presentedVC: NSViewController?

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

        let modeBar = buildModeBar()
        modeBar.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = .clear
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [totalBar, separator, modeBar, contentContainer])
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
        sessionListVC.onSelect = { [weak self] client, sid, period, cost in
            self?.presentSessionDetail(client: client, sessionId: sid, period: period, cost: cost)
        }
        installContent(breakdownClientVC)
        observeData()
    }

    // MARK: - Mode bar

    private func buildModeBar() -> NSView {
        let bar = NSView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        for (title, key) in [("Tool", "tool"), ("Model", "model"), ("Session", "session"), ("Limits", "limits")] {
            let btn = HoverButton(title: title)
            btn.font = AppTheme.tabFont
            btn.target = self
            btn.action = #selector(modeClick(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(key)
            stack.addArrangedSubview(btn)
            modeButtons.append((key, btn))
        }
        applyModeSelection()
        return bar
    }

    private func applyModeSelection() {
        for (key, btn) in modeButtons {
            let selected = key == mode
            btn.attributedTitle = NSAttributedString(string: btn.title, attributes: [
                .font: AppTheme.tabFont,
                .foregroundColor: selected ? AppTheme.accent : AppTheme.textTertiary,
            ])
            btn.selectedBackground = selected ? AppTheme.accent.withAlphaComponent(0.16) : .clear
        }
    }

    @objc private func modeClick(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        setMode(key)
    }

    private func setMode(_ newMode: String) {
        guard newMode != mode else { return }
        mode = newMode
        applyModeSelection()
        let vc: NSViewController
        switch newMode {
        case "tool": vc = breakdownClientVC
        case "model": vc = breakdownModelVC
        case "session": vc = sessionListVC
        case "limits": vc = limitsVC
        default: vc = breakdownClientVC
        }
        installContent(vc)
        refreshContent()
    }

    private func installContent(_ vc: NSViewController) {
        if currentContentVC === vc { return }
        if let old = currentContentVC {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(vc)
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentContentVC = vc
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
        breakdownClientVC.update(stats: stats, period: period, settings: settings)
        breakdownModelVC.update(stats: stats, period: period, settings: settings)
        refreshContent()
    }

    private func refreshContent() {
        let stats = Collector.shared.latestStats()
        let settings = BridgeCore.shared.settings.snapshot()
        if let vc = currentContentVC as? ContentUpdatable {
            vc.update(stats: stats, period: period, settings: settings)
        }
    }

    // MARK: - TotalBarDelegate

    func totalBarDidSelectPeriod(_ period: String) {
        self.period = period
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
            // task5 替换为真实 SettingsViewController。
            settingsVC = PlaceholderViewController(label: "设置（开发中）")
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
