import AppKit

/// 服务状态视图（原版 serviceStatusPanel）：拉取 ServiceStatusRuntime 的
/// 各 provider 状态，行内显示状态点 + 名称 + 描述 + 事件数，点击行用浏览器
/// 打开 statuspage。可见时每 60s 自动刷新。
final class StatusViewController: NSViewController, ContentUpdatable {
    private let scrollView = TopAnchoredScrollView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无状态数据")
    private let checkedLabel = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?
    private var lastProviderSignature = ""

    override func loadView() {
        let container = WindowAwareView()
        container.onWindowChange = { [weak self] hasWindow in
            self?.viewDidMoveToWindow(hasWindow: hasWindow)
        }
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        checkedLabel.font = AppTheme.microFont
        checkedLabel.textColor = AppTheme.textTertiary
        checkedLabel.isBezeled = false
        checkedLabel.drawsBackground = false
        checkedLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkedLabel)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = rowsStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // 原版把滚动条完全隐藏（scrollbar-width: none）；overlay 样式不占布局宽度，
        // 否则「经典」滚动条会挤掉行右侧的数值列。
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        configureLabel(emptyLabel, font: AppTheme.bodyFont, color: AppTheme.textTertiary)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            checkedLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            checkedLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: checkedLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
        ])
        view = container
    }

    /// The status view is installed/removed as a plain subview by
    /// MainViewController, so `viewDidAppear` / `viewDidDisappear` never fire.
    /// The container view reports window changes here instead.
    fileprivate func viewDidMoveToWindow(hasWindow: Bool) {
        if hasWindow {
            startTimer()
            refreshIfNeeded(force: true)
        } else {
            stopTimer()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func startTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshIfNeeded(force: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func update(stats: [String: Any]?, period: String, settings: [String: Any]) {
        // 视图可见时由 refreshIfNeeded 驱动；这里无事可做。
    }

    func refreshIfNeeded(force: Bool = false) {
        guard view.window != nil, !view.isHidden else { return }
        // 用 ServiceStatusRuntime 自带 60s 缓存，只有强制刷新才真正重拉。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ServiceStatusRuntime.shared.status(force: force, providerIds: nil)
            DispatchQueue.main.async {
                self?.render(result)
            }
        }
    }

    private func render(_ result: [String: Any]) {
        let providers = result["providers"] as? [[String: Any]] ?? []
        let signature = providers.map { "\($0["id"] ?? ""):\($0["status"] ?? ""):\($0["incidentCount"] ?? 0)" }.joined(separator: "|")
        guard signature != lastProviderSignature else {
            updateCheckedLabel(result)
            return
        }
        lastProviderSignature = signature

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !providers.isEmpty
        for provider in providers {
            let row = StatusRowView()
            row.configure(provider: provider)
            row.onClick = { [weak self] in
                self?.openPage(provider)
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        rowsStack.addArrangedSubview(spacer)
        updateCheckedLabel(result)
    }

    private func updateCheckedLabel(_ result: [String: Any]) {
        if let checked = result["checkedAt"] as? String {
            let ms = UsageCore.timestampMs(checked)
            if ms > 0 {
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                checkedLabel.stringValue = "检查于 \(f.string(from: Date(timeIntervalSince1970: ms / 1000)))"
            }
        }
    }

    private func openPage(_ provider: [String: Any]) {
        guard let urlString = provider["pageUrl"] as? String, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }
}

// MARK: - Window-aware container

/// Reports window attach/detach to its owning controller — the substitute for
/// `viewDidAppear`/`viewDidDisappear`, which do not fire for the panel-hosted
/// child controllers in this window.
private final class WindowAwareView: NSView {
    var onWindowChange: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }
}

// MARK: - Row

private final class StatusRowView: NSView {
    var onClick: (() -> Void)?

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hover = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        configureLabel(nameLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configureLabel(descLabel, font: AppTheme.smallFont, color: AppTheme.textTertiary)
        descLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.font = AppTheme.microFont
        badgeLabel.textColor = .white
        badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 4
        badgeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let leftStack = NSStackView(views: [dot, nameLabel, badgeLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 6

        let stack = NSStackView(views: [leftStack, descLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        // 水平内缩来自 shell；行内只保留上下 padding。
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }

    func configure(provider: [String: Any]) {
        nameLabel.stringValue = provider["label"] as? String ?? provider["id"] as? String ?? ""
        let status = provider["status"] as? String ?? "unknown"
        dot.layer?.backgroundColor = statusColor(status).cgColor
        let incidentCount = UsageCore.intValue(provider["incidentCount"])
        let maintenanceCount = UsageCore.intValue(provider["maintenanceCount"])
        var badge = statusText(status)
        if incidentCount > 0 { badge += " · \(incidentCount) 事件" }
        if maintenanceCount > 0 { badge += " · \(maintenanceCount) 维护" }
        badgeLabel.stringValue = badge
        badgeLabel.layer?.backgroundColor = statusColor(status).withAlphaComponent(0.35).cgColor

        var desc = provider["description"] as? String ?? ""
        if let incidentTitle = provider["incidentTitle"] as? String, !incidentTitle.isEmpty {
            desc = incidentTitle
        }
        descLabel.stringValue = desc
    }

    private func statusColor(_ s: String) -> NSColor {
        switch s {
        case "ok": return AppTheme.positive
        case "degraded": return AppTheme.warning
        case "outage": return AppTheme.danger
        default: return AppTheme.textTertiary
        }
    }

    private func statusText(_ s: String) -> String {
        switch s {
        case "ok": return "正常"
        case "degraded": return "部分故障"
        case "outage": return "中断"
        default: return "未知"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        layer?.backgroundColor = AppTheme.hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.backgroundColor = .clear
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
