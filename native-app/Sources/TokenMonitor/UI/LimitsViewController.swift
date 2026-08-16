import AppKit

/// 限额面板：渲染 stats.limits.providers 的 DeepSeek 余额与 OpenCode 配额卡片。
///
/// 取代原 limits 视图。每个 provider 一张卡：标题 + 状态 pill + 余额/配额进度条
/// + 消费统计。无数据或未配置时显示对应空态。
final class LimitsViewController: NSViewController, ContentUpdatable {
    private let scrollView = NSScrollView()
    private let cardsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无限额数据")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 10
        cardsStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = cardsStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        configureLabel(emptyLabel, font: AppTheme.bodyFont, color: AppTheme.textTertiary)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            cardsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
        ])
        view = container
    }

    func update(stats: [String: Any]?, period: String, settings: [String: Any]) {
        let limits: [String: Any]
        if let l = stats?["limits"] as? [String: Any] {
            limits = l
        } else if let device = (stats?["devices"] as? [[String: Any]])?.first,
                  let l = device["limits"] as? [String: Any] {
            limits = l
        } else {
            limits = LimitsRuntime.shared.summary()
        }
        let providers = limits["providers"] as? [[String: Any]] ?? []
        // 按设置 limitProviderOrder 排序
        let order = ((settings["limitProviderOrder"] as? String) ?? "deepseek,opencode")
            .split(separator: ",").map { String($0).lowercased() }
        let ordered = providers.sorted { a, b in
            let ia = order.firstIndex(of: a["provider"] as? String ?? "") ?? Int.max
            let ib = order.firstIndex(of: b["provider"] as? String ?? "") ?? Int.max
            return ia == ib ? (a["provider"] as? String ?? "") < (b["provider"] as? String ?? "") : ia < ib
        }

        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !ordered.isEmpty

        for provider in ordered {
            let card = LimitCardView()
            card.configure(provider: provider, settings: settings)
            cardsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
        }
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }
}

// MARK: - Limit card

private final class LimitCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyStack = NSStackView()

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
        layer?.backgroundColor = AppTheme.cardColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.cardBorderColor.cgColor

        configureLabel(titleLabel, font: AppTheme.titleFont, color: AppTheme.textPrimary)
        configureLabel(statusLabel, font: AppTheme.microFont, color: AppTheme.textTertiary)
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 4
        statusLabel.layer?.backgroundColor = AppTheme.cardBorderColor.cgColor
        statusLabel.alignment = .center

        let header = NSStackView(views: [titleLabel, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 6

        let stack = NSStackView(views: [header, bodyStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }

    func configure(provider: [String: Any], settings: [String: Any]) {
        let id = provider["provider"] as? String ?? ""
        var accountLabel = provider["accountLabel"] as? String ?? ""
        if settings["maskLimitAccountEmails"] as? Bool ?? false {
            accountLabel = maskEmail(accountLabel)
        }
        let status = provider["status"] as? String ?? ""
        var title = AppTheme.clientLabel(id) + (accountLabel.isEmpty ? "" : " · \(accountLabel)")
        if settings["showLimitSource"] as? Bool ?? false, let source = provider["source"] as? String, !source.isEmpty {
            title += "  [\(source)]"
        }
        titleLabel.stringValue = title
        statusLabel.stringValue = statusText(status)
        statusLabel.layer?.backgroundColor = statusColor(status).cgColor
        statusLabel.textColor = .white

        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let windows = provider["windows"] as? [[String: Any]] ?? []
        for window in windows {
            let row = LimitWindowRow()
            row.configure(window: window, settings: settings)
            bodyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }

        if let balance = provider["balance"] as? [String: Any] {
            let balRow = BalanceRow()
            balRow.configure(balance: balance, settings: settings)
            bodyStack.addArrangedSubview(balRow)
            balRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }

        if windows.isEmpty && provider["balance"] == nil {
            let hint = NSTextField(labelWithString: status == "notConfigured" ? "未配置，请在设置中添加凭证" : "暂无数据")
            hint.font = AppTheme.smallFont
            hint.textColor = AppTheme.textTertiary
            hint.isBezeled = false
            hint.drawsBackground = false
            bodyStack.addArrangedSubview(hint)
        }
    }

    private func maskEmail(_ value: String) -> String {
        guard value.contains("@") else { return value }
        let parts = value.split(separator: "@", maxSplits: 1)
        guard let local = parts.first, let domain = parts.last, local.count > 1 else { return value }
        let head = local.prefix(1)
        let tail = local.count > 3 ? local.suffix(1) : ""
        return "\(head)***\(tail)@\(domain)"
    }

    private func statusText(_ s: String) -> String {
        switch s {
        case "ok": return "正常"
        case "notConfigured": return "未配置"
        case "unauthorized": return "未授权"
        case "rateLimited", "sourceRateLimited": return "限流"
        case "unavailable", "error": return "不可用"
        case "disabled": return "已禁用"
        default: return s
        }
    }

    private func statusColor(_ s: String) -> NSColor {
        switch s {
        case "ok": return AppTheme.positive.withAlphaComponent(0.85)
        case "notConfigured", "disabled": return AppTheme.textTertiary.withAlphaComponent(0.5)
        case "rateLimited", "sourceRateLimited": return AppTheme.warning.withAlphaComponent(0.85)
        default: return AppTheme.danger.withAlphaComponent(0.85)
        }
    }
}

// MARK: - Window row (配额/余额条)

private final class LimitWindowRow: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let barBg = NSView()
    private let barFill = NSView()

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

        configureLabel(labelField, font: AppTheme.smallFont, color: AppTheme.textSecondary)
        configureLabel(valueField, font: AppTheme.monoFont, color: AppTheme.textPrimary)
        valueField.alignment = .right

        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = AppTheme.cardBorderColor.cgColor
        barBg.layer?.cornerRadius = 2
        barBg.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 2
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBg.addSubview(barFill)

        let topRow = NSStackView(views: [labelField, valueField])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [topRow, barBg])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            barBg.heightAnchor.constraint(equalToConstant: 4),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barBg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barFill.leadingAnchor.constraint(equalTo: barBg.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBg.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBg.bottomAnchor),
        ])
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }

    func configure(window: [String: Any], settings: [String: Any]) {
        let label = window["label"] as? String ?? ""
        let currency = window["currency"] as? String ?? ""
        let remaining = UsageCore.doubleValue(window["remaining"])
        let used = UsageCore.doubleValue(window["used"])
        let limit = UsageCore.doubleValue(window["limit"])
        let remainingPct = window["remainingPercent"]
        let usedPct = window["usedPercent"]
        let showUsed = settings["showLimitUsed"] as? Bool ?? false

        labelField.stringValue = label
        let sym = Fmt.currencySymbol(currency)
        if showUsed {
            if limit > 0 {
                valueField.stringValue = "\(sym)\(Fmt.tokens(Int(used))) / \(sym)\(Fmt.tokens(Int(limit)))"
            } else if let p = usedPct, !(p is NSNull) {
                valueField.stringValue = "\(Fmt.percent(UsageCore.doubleValue(p) / 100))"
            } else {
                valueField.stringValue = "\(sym)\(Fmt.tokens(Int(used)))"
            }
        } else {
            if remaining > 0 || limit > 0 {
                valueField.stringValue = limit > 0
                    ? "\(sym)\(Fmt.tokens(Int(remaining))) / \(sym)\(Fmt.tokens(Int(limit)))"
                    : "\(sym)\(Fmt.tokens(Int(remaining)))"
            } else {
                valueField.stringValue = "—"
            }
        }

        // 进度条：showLimitUsed 时显示已用比例，否则显示剩余比例。
        var fraction = 0.0
        if showUsed {
            if let p = usedPct, !(p is NSNull) {
                fraction = UsageCore.doubleValue(p)
            } else if limit > 0 {
                fraction = used / limit
            } else if let p = remainingPct, !(p is NSNull) {
                fraction = 1 - UsageCore.doubleValue(p)
            }
        } else {
            if let p = remainingPct, !(p is NSNull) {
                fraction = UsageCore.doubleValue(p)
            } else if let p = usedPct, !(p is NSNull) {
                fraction = 1 - UsageCore.doubleValue(p)
            } else if limit > 0 {
                fraction = 1 - used / limit
            }
        }
        fraction = max(0, min(1, fraction))
        let color = fraction < 0.2 ? AppTheme.danger : (fraction < 0.5 ? AppTheme.warning : AppTheme.accent)
        barFill.layer?.backgroundColor = color.cgColor
        barFillWidth?.isActive = false
        barFillWidth = barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor, multiplier: CGFloat(max(0.02, fraction)))
        barFillWidth?.isActive = true
    }

    private var barFillWidth: NSLayoutConstraint?
}

// MARK: - Balance row (DeepSeek 消费)

private final class BalanceRow: NSView {
    private let stack = NSStackView()

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
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.distribution = .fillEqually
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(balance: [String: Any], settings: [String: Any]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let currency = balance["currency"] as? String ?? ""
        let sym = Fmt.currencySymbol(currency)
        let items: [(String, Double)] = [
            ("今日", UsageCore.doubleValue(balance["todaySpend"])),
            ("本月", UsageCore.doubleValue(balance["monthSpend"])),
            ("全部", UsageCore.doubleValue(balance["allTimeSpend"])),
        ]
        for (name, amount) in items {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 1
            let v = NSTextField(labelWithString: "\(sym)\(String(format: "%.2f", amount))")
            v.font = AppTheme.monoFont
            v.textColor = AppTheme.textPrimary
            v.isBezeled = false
            v.drawsBackground = false
            let n = NSTextField(labelWithString: name)
            n.font = AppTheme.microFont
            n.textColor = AppTheme.textTertiary
            n.isBezeled = false
            n.drawsBackground = false
            col.addArrangedSubview(v)
            col.addArrangedSubview(n)
            stack.addArrangedSubview(col)
        }
    }
}
