import AppKit

protocol TotalBarDelegate: AnyObject {
    func totalBarDidSelectPeriod(_ period: String)
    func totalBarDidClickRefresh()
    func totalBarDidClickSettings()
    func totalBarDidClickClose()
}

/// 主窗口顶部（原版 titlebar + total-panel）：
/// 第一行 = 标题（Σ + Token Monitor + live dot + 速率揭示）+ 右侧周期胶囊
/// 切换（DAY/MONTH/TOTAL，带滑动指示块）+ 关闭按钮；第二行 = 总计面板
/// （TOTAL TOKENS 标签 + 大数字 + 成本）。
final class TotalBarView: NSView {
    weak var delegate: TotalBarDelegate?
    private(set) var period = "today"

    private let sigmaLabel = NSTextField(labelWithString: "Σ")
    private let titleLabel = NSTextField(labelWithString: "Token Monitor")
    private let liveDot = LiveDotView()
    private let rateReveal = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Starting")
    private let periodPill = PeriodPillView()
    private let closeBtn = HoverButton(title: "×")
    private let totalLabel = NSTextField(labelWithString: "0")
    private let costLabel = NSTextField(labelWithString: "$0.00")

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

        sigmaLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        sigmaLabel.textColor = AppTheme.textPrimary
        sigmaLabel.isBezeled = false
        sigmaLabel.drawsBackground = false
        sigmaLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = AppTheme.textPrimary
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rateReveal.font = AppTheme.microFont
        rateReveal.textColor = AppTheme.textSecondary
        rateReveal.isBezeled = false
        rateReveal.drawsBackground = false
        rateReveal.isHidden = true
        rateReveal.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        statusLabel.font = AppTheme.smallFont
        statusLabel.textColor = AppTheme.textSecondary
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false

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
        titleStack.spacing = 3

        // 周期胶囊 + 关闭（原版 title-controls）
        periodPill.onSelect = { [weak self] key in
            self?.selectPeriod(key)
        }
        periodPill.translatesAutoresizingMaskIntoConstraints = false
        periodPill.heightAnchor.constraint(equalToConstant: 28).isActive = true

        closeBtn.target = self
        closeBtn.action = #selector(closeClick)

        let controls = NSStackView(views: [periodPill, closeBtn])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4

        let topRow = NSStackView(views: [titleStack, controls])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 10

        // 总计面板（原版 total-panel）
        let labelRow = NSTextField(labelWithString: "TOTAL TOKENS")
        labelRow.font = AppTheme.smallFont
        labelRow.textColor = AppTheme.textSecondary
        labelRow.isBezeled = false
        labelRow.drawsBackground = false

        totalLabel.font = AppTheme.numberFont
        totalLabel.textColor = AppTheme.numberColor
        totalLabel.isBezeled = false
        totalLabel.drawsBackground = false
        totalLabel.usesSingleLineMode = true

        costLabel.font = AppTheme.smallFont
        costLabel.textColor = AppTheme.textSecondary
        costLabel.isBezeled = false
        costLabel.drawsBackground = false

        let stack = NSStackView(views: [topRow, labelRow, totalLabel, costLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(8, after: topRow)
        stack.setCustomSpacing(6, after: totalLabel)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            liveDot.widthAnchor.constraint(equalToConstant: 4),
            liveDot.heightAnchor.constraint(equalToConstant: 4),
            totalLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
        ])
    }

    private func selectPeriod(_ key: String) {
        guard key != period else { return }
        period = key
        periodPill.selected = key
        delegate?.totalBarDidSelectPeriod(key)
    }

    func setSelectedPeriod(_ p: String) {
        period = p
        periodPill.selected = p
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
        totalLabel.stringValue = Fmt.tokensExact(tokens)
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

    @objc private func closeClick() { delegate?.totalBarDidClickClose() }
}

// MARK: - 周期胶囊切换（原版 .tabs + .tab-indicator）

final class PeriodPillView: NSView {
    var onSelect: ((String) -> Void)?
    var selected = "today"

    private let indicator = NSView()
    private var buttons: [(key: String, button: HoverButton)] = []
    private var lastIndex: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.panelColor.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.lineColor.withAlphaComponent(0.65).cgColor

        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 6
        indicator.layer?.borderWidth = 1
        indicator.layer?.borderColor = AppTheme.lineColor.withAlphaComponent(0.95).cgColor
        indicator.layer?.backgroundColor = AppTheme.controlColor.cgColor
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (title, key) in [("DAY", "today"), ("MONTH", "month"), ("TOTAL", "allTime")] {
            let btn = HoverButton(title: title)
            btn.font = AppTheme.tabFont
            btn.target = self
            btn.action = #selector(click(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(key)
            btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
            stack.addArrangedSubview(btn)
            buttons.append((key, btn))
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        applySelection(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        applySelection(animated: false)
    }

    @objc private func click(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, key != selected else { return }
        selected = key
        applySelection(animated: true)
        onSelect?(key)
    }

    private func applySelection(animated: Bool) {
        guard bounds.width > 10 else { return }
        let index = buttons.firstIndex { $0.key == selected } ?? 0
        let width = (bounds.width - 8) / 3
        let target = CGPoint(x: 3 + CGFloat(index) * (width + 2), y: 3)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                indicator.animator().frame.origin = target
                indicator.animator().frame.size = CGSize(width: width, height: bounds.height - 6)
            }
        } else {
            indicator.frame = CGRect(x: target.x, y: target.y, width: width, height: bounds.height - 6)
        }
        for (key, btn) in buttons {
            let isSelected = key == selected
            btn.attributedTitle = NSAttributedString(string: btn.title, attributes: [
                .font: AppTheme.tabFont,
                .foregroundColor: isSelected ? AppTheme.accent : AppTheme.textSecondary,
            ])
        }
    }
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
        layer?.cornerRadius = 2
        layer?.backgroundColor = NSColor(calibratedWhite: 0.36, alpha: 1).cgColor
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
            layer?.backgroundColor = (live ? AppTheme.accent : NSColor(calibratedWhite: 0.36, alpha: 1)).cgColor
            if live {
                layer?.shadowColor = AppTheme.accent.cgColor
                layer?.shadowRadius = 3
                layer?.shadowOpacity = 0.55
            } else {
                layer?.shadowOpacity = 0
            }
        }
        if !boosting && !settling {
            onRateChange?(nil)
        }
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
