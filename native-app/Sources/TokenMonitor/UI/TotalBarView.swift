import AppKit

protocol TotalBarDelegate: AnyObject {
    func totalBarDidSelectPeriod(_ period: String)
    func totalBarDidClickRefresh()
    func totalBarDidClickSettings()
    func totalBarDidClickClose()
}

/// 主窗口顶部条：标题 + 状态 + 周期切换(DAY/MONTH/TOTAL) + Total tokens/cost +
/// 刷新/设置/关闭按钮。取代原 index.html 的 titlebar + total-panel。
final class TotalBarView: NSView {
    weak var delegate: TotalBarDelegate?
    private(set) var period = "today"

    private let titleLabel = NSTextField(labelWithString: "Token Monitor")
    private let statusLabel = NSTextField(labelWithString: "Starting")
    private let totalLabel = NSTextField(labelWithString: "0")
    private let costLabel = NSTextField(labelWithString: "$0.00")
    private let periodStack = NSStackView()
    private let refreshBtn = HoverButton(title: "↻")
    private let settingsBtn = HoverButton(title: "⚙")
    private let closeBtn = HoverButton(title: "×")
    private var periodButtons: [(String, HoverButton)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = .clear

        configureLabel(titleLabel, font: AppTheme.titleFont, color: AppTheme.textPrimary)
        configureLabel(statusLabel, font: AppTheme.microFont, color: AppTheme.textTertiary)
        configureLabel(totalLabel, font: AppTheme.bigNumberFont, color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.bodyFont, color: AppTheme.textSecondary)

        refreshBtn.target = self; refreshBtn.action = #selector(refreshClick)
        settingsBtn.target = self; settingsBtn.action = #selector(settingsClick)
        closeBtn.target = self; closeBtn.action = #selector(closeClick)

        let titleStack = NSStackView(views: [titleLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let actionStack = NSStackView(views: [refreshBtn, settingsBtn, closeBtn])
        actionStack.orientation = .horizontal
        actionStack.spacing = 2

        let topRow = NSStackView(views: [titleStack, actionStack])
        topRow.orientation = .horizontal
        topRow.distribution = .fill
        topRow.setHuggingPriority(NSLayoutConstraint.Priority.defaultHigh, for: .horizontal)

        periodStack.orientation = .horizontal
        periodStack.distribution = .fillEqually
        periodStack.spacing = 0
        for (title, key) in [("DAY", "today"), ("MONTH", "month"), ("TOTAL", "allTime")] {
            let btn = HoverButton(title: title)
            btn.font = AppTheme.tabFont
            btn.target = self
            btn.action = #selector(periodClick(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(key)
            periodStack.addArrangedSubview(btn)
            periodButtons.append((key, btn))
        }

        let totalRow = NSStackView(views: [totalLabel, costLabel])
        totalRow.orientation = .horizontal
        totalRow.alignment = .centerY
        totalRow.distribution = .fill
        costLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        costLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [topRow, periodStack, totalRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyPeriodSelection()
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func applyPeriodSelection() {
        for (key, btn) in periodButtons {
            let selected = key == period
            let color: NSColor = selected ? AppTheme.accent : AppTheme.textTertiary
            btn.attributedTitle = NSAttributedString(string: btn.title, attributes: [
                .font: AppTheme.tabFont, .foregroundColor: color,
            ])
            btn.selectedBackground = selected ? AppTheme.accent.withAlphaComponent(0.16) : .clear
        }
    }

    func setSelectedPeriod(_ p: String) {
        period = p
        applyPeriodSelection()
    }

    func update(stats: [String: Any]?, settings: [String: Any]) {
        let periods = stats?["periods"] as? [String: Any]
        let periodDict = periods?[period] as? [String: Any]
        let tokens = UsageCore.intValue(periodDict?["totalTokens"])
        let costUsd = UsageCore.doubleValue(periodDict?["costUsd"])
        totalLabel.stringValue = Fmt.tokens(tokens)
        costLabel.stringValue = Fmt.money(costUsd, settings: settings)

        if let device = (stats?["devices"] as? [[String: Any]])?.first,
           let statuses = device["clientStatus"] as? [String: String] {
            let active = statuses.values.filter { $0 == "active" }.count
            let total = statuses.count
            statusLabel.stringValue = total > 0 ? "\(active)/\(total) active" : "—"
        } else if stats == nil {
            statusLabel.stringValue = "Starting"
        } else {
            statusLabel.stringValue = "—"
        }
    }

    // MARK: - Actions

    @objc private func periodClick(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        period = key
        applyPeriodSelection()
        delegate?.totalBarDidSelectPeriod(key)
    }

    @objc private func refreshClick() { delegate?.totalBarDidClickRefresh() }
    @objc private func settingsClick() { delegate?.totalBarDidClickSettings() }
    @objc private func closeClick() { delegate?.totalBarDidClickClose() }
}

// MARK: - HoverButton

/// 无边框、悬停高亮的轻量按钮（深色玻璃面板上的图标/标签按钮统一用它）。
class HoverButton: NSButton {
    var hoverBackground: NSColor = AppTheme.hoverColor
    var selectedBackground: NSColor = .clear {
        didSet { needsDisplay = true; updateHover() }
    }
    private var hover = false
    private var tracking: NSTrackingArea?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        font = NSFont.systemFont(ofSize: 14, weight: .regular)
        contentTintColor = AppTheme.textSecondary
        bezelStyle = .inline
        translatesAutoresizingMaskIntoConstraints = false
        // 尺寸约束
        widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    private func updateHover() {
        if hover {
            layer?.backgroundColor = hoverBackground.cgColor
        } else {
            layer?.backgroundColor = selectedBackground.cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) { hover = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hover = false; updateHover() }
}
