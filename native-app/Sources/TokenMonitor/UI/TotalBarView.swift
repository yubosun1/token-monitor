import AppKit

protocol TotalBarDelegate: AnyObject {
    func totalBarDidSelectPeriod(_ period: String)
    func totalBarDidClickRefresh()
    func totalBarDidClickSettings()
    func totalBarDidClickClose()
}

/// 主窗口顶部条：Σ 标记 + 标题 + live dot（按住看 token 速率）+ 状态 +
/// 周期切换(DAY/MONTH/TOTAL) + Total tokens/cost + 刷新/设置/关闭按钮。
/// 取代原 index.html 的 titlebar + total-panel。
final class TotalBarView: NSView {
    weak var delegate: TotalBarDelegate?
    private(set) var period = "today"

    private let sigmaLabel = NSTextField(labelWithString: "Σ")
    private let titleLabel = NSTextField(labelWithString: "Token Monitor")
    private let liveDot = LiveDotView()
    private let rateReveal = NSTextField(labelWithString: "")
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

        sigmaLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        sigmaLabel.textColor = AppTheme.textTertiary
        sigmaLabel.isBezeled = false
        sigmaLabel.drawsBackground = false
        sigmaLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureLabel(titleLabel, font: AppTheme.titleFont, color: AppTheme.textPrimary)

        rateReveal.font = AppTheme.microFont
        rateReveal.textColor = AppTheme.accent
        rateReveal.isBezeled = false
        rateReveal.drawsBackground = false
        rateReveal.isHidden = true
        rateReveal.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configureLabel(statusLabel, font: AppTheme.microFont, color: AppTheme.textTertiary)
        configureLabel(totalLabel, font: AppTheme.bigNumberFont, color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.bodyFont, color: AppTheme.textSecondary)

        liveDot.translatesAutoresizingMaskIntoConstraints = false
        liveDot.onRateChange = { [weak self] text in
            self?.showRate(text)
        }

        let titleRow = NSStackView(views: [sigmaLabel, titleLabel, liveDot, rateReveal])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 5
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView(views: [titleRow, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        refreshBtn.target = self; refreshBtn.action = #selector(refreshClick)
        settingsBtn.target = self; settingsBtn.action = #selector(settingsClick)
        closeBtn.target = self; closeBtn.action = #selector(closeClick)

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
            liveDot.widthAnchor.constraint(equalToConstant: 8),
            liveDot.heightAnchor.constraint(equalToConstant: 8),
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

    private func showRate(_ text: String?) {
        rateReveal.stringValue = text ?? ""
        rateReveal.isHidden = text == nil || text!.isEmpty
    }

    func update(stats: [String: Any]?, settings: [String: Any]) {
        let periods = stats?["periods"] as? [String: Any]
        let periodDict = periods?[period] as? [String: Any]
        let tokens = UsageCore.intValue(periodDict?["totalTokens"])
        let costUsd = UsageCore.doubleValue(periodDict?["costUsd"])
        totalLabel.stringValue = Fmt.tokens(tokens)
        costLabel.stringValue = Fmt.money(costUsd, settings: settings)

        liveDot.update(period: periodDict, settings: settings)

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

// MARK: - Live dot + token rate reveal

/// 绿点 = 有实时数据；按住 ≥180ms 触发速率 boost 显示，短按切换
/// speed/burn 模式（原版 createTokenRateBoostController 的简化实现）。
final class LiveDotView: NSView {
    var onRateChange: ((String?) -> Void)?

    private var period: [String: Any]?
    private var mode = "speed"
    private var baseRate: Double = 0
    private var boosting = false
    private var settling = false
    private var holdTimer: Timer?
    private var boostTimer: Timer?
    private var boostStartedAt: TimeInterval = 0
    private var settleFrom: Double = 0
    private var settleStartedAt: TimeInterval = 0
    private var live = false

    private let holdThresholdMs: TimeInterval = 0.18
    private let boostDoublingMs: TimeInterval = 0.52
    private let settleMs: TimeInterval = 0.72
    private let maxRate = 1e12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 1).cgColor
        toolTip = "按住显示 token 速率；点击切换 秒/分钟"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(period: [String: Any]?, settings: [String: Any]) {
        self.period = period
        mode = (settings["tokenRateMode"] as? String) == "burn" ? "burn" : "speed"
        let durationMs = UsageCore.doubleValue(period?["timedDurationMs"])
        if mode == "burn" {
            let timed = UsageCore.doubleValue(period?["timedTokens"])
            baseRate = durationMs > 0 && timed > 0 ? min(maxRate, timed * 60000 / durationMs) : 0
        } else {
            let timedOutput = UsageCore.doubleValue(period?["timedOutputTokens"])
            baseRate = durationMs > 0 && timedOutput > 0 ? min(maxRate, timedOutput * 1000 / durationMs) : 0
        }
        let wasLive = live
        live = period != nil && (UsageCore.intValue(period?["totalTokens"]) > 0 || baseRate > 0)
        if live != wasLive {
            layer?.backgroundColor = (live ? AppTheme.positive : NSColor(calibratedWhite: 0.35, alpha: 1)).cgColor
        }
        if !boosting && !settling {
            onRateChange?(nil)
        }
    }

    private func currentRate() -> Double {
        return baseRate
    }

    override func mouseDown(with event: NSEvent) {
        guard baseRate > 0 else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThresholdMs, repeats: false) { [weak self] _ in
            guard let self, self.baseRate > 0 else { return }
            self.boosting = true
            self.settling = false
            self.boostStartedAt = ProcessInfo.processInfo.systemUptime
            self.startBoostTimer()
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard baseRate > 0 else { return }
        if boosting {
            boosting = false
            settling = true
            settleFrom = boostedRate()
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            startBoostTimer()
            return
        }
        if settling {
            // 上次的回落动画被打断：直接重新开始新的回落。
            settling = false
            stopBoostTimer()
            onRateChange?(nil)
            return
        }
        // 短按：切换 speed/burn。
        let next = mode == "burn" ? "speed" : "burn"
        BridgeCore.shared.settings.update(["tokenRateMode": next])
        if let period {
            update(period: period, settings: BridgeCore.shared.settings.snapshot())
        }
    }

    override func mouseExited(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        if boosting || settling {
            boosting = false
            settling = false
            stopBoostTimer()
            onRateChange?(nil)
        }
    }

    private func boostedRate() -> Double {
        let elapsed = ProcessInfo.processInfo.systemUptime - boostStartedAt
        let cap = maxRate
        guard baseRate > 0 else { return 0 }
        if baseRate >= cap { return cap }
        let maxElapsed = boostDoublingMs * log2(cap / baseRate)
        let bounded = min(elapsed, maxElapsed)
        return min(cap, baseRate * pow(2, bounded / boostDoublingMs))
    }

    private func settleRate() -> Double {
        let elapsed = ProcessInfo.processInfo.systemUptime - settleStartedAt
        let progress = min(1, elapsed / settleMs)
        let eased = 1 - pow(1 - progress, 3)
        return settleFrom + (baseRate - settleFrom) * eased
    }

    private func startBoostTimer() {
        stopBoostTimer()
        boostTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.settling && ProcessInfo.processInfo.systemUptime - self.settleStartedAt >= self.settleMs {
                self.settling = false
                self.stopBoostTimer()
                self.onRateChange?(nil)
                return
            }
            self.publishRate()
        }
        publishRate()
    }

    private func stopBoostTimer() {
        boostTimer?.invalidate()
        boostTimer = nil
    }

    private func publishRate() {
        let value = settling ? settleRate() : boostedRate()
        let display = value >= 1000 ? String(format: "%.1fK", value / 1000) : String(format: "%.0f", value)
        let unit = mode == "burn" ? "tok/min" : "tok/s"
        onRateChange?("≈ \(display) \(unit)")
    }
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
