import AppKit

/// 限额面板：渲染 stats.limits.providers 的 DeepSeek 余额与 OpenCode 配额卡片。
///
/// 取代原 limits 视图。每个 provider 一张卡：标题 + 状态 pill + 余额/配额进度条
/// + 消费统计。无数据或未配置时显示对应空态。
final class LimitsViewController: NSViewController, ContentUpdatable {
    private let scrollView = TopAnchoredScrollView()
    private let cardsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无限额数据")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        // 原版 .limits-panel：gap 12px、无内缩（水平内缩由 shell 提供）。
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 12
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = cardsStack
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
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            cardsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
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
    private let mark = RowMarkView(size: 12)
    private let titleLabel = NSTextField(labelWithString: "")
    private let planLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyStack = NSStackView()
    /// 每行两列（原版 .limit-windows grid-template-columns: 1fr 1fr）。
    private var windowRows: [NSStackView] = []

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

        // 原版 .limit-name 12px / .limit-meta 10px muted / .limit-plan 10px 右对齐。
        configureLabel(titleLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(metaLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        configureLabel(planLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        planLabel.alignment = .right
        configureLabel(statusLabel, font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), color: AppTheme.positive)
        // 原版 .limit-provider-tag-status：描边胶囊，不是实心色块。
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 5
        statusLabel.layer?.borderWidth = 1
        statusLabel.alignment = .center

        let nameLine = NSStackView(views: [mark, titleLabel, statusLabel])
        nameLine.orientation = .horizontal
        nameLine.alignment = .centerY
        nameLine.spacing = 8
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleColumn = NSStackView(views: [nameLine, metaLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2

        let header = NSStackView(views: [titleColumn, planLabel])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 8
        titleColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        planLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // 原版 .limit-row gap 10px。
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 10

        let stack = NSStackView(views: [header, bodyStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.hairlineColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            // 原版 .limit-row padding: 0 0 13px。
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
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
        // 原版把客户端名与账号分成两行：名字行 + muted 的 meta 行。
        titleLabel.stringValue = AppTheme.clientLabel(id)
        mark.configure(
            asset: IconCatalog.clientAsset(id),
            color: AppTheme.clientColor(id),
            showIcons: settings["showToolIcons"] as? Bool ?? true
        )

        var metaParts: [String] = []
        if !accountLabel.isEmpty { metaParts.append(accountLabel) }
        if let updated = provider["updatedAt"] as? String, !updated.isEmpty {
            let age = LimitsFormat.updatedAgeText(updated)
            if !age.isEmpty { metaParts.append(age) }
        }
        if settings["showLimitSource"] as? Bool ?? false,
           let source = provider["source"] as? String, !source.isEmpty {
            metaParts.append(source)
        }
        metaLabel.stringValue = metaParts.joined(separator: " · ")
        metaLabel.isHidden = metaParts.isEmpty

        // 原版 .limit-plan：右上角显示套餐名（如 Plus / Go）。
        let plan = provider["planLabel"] as? String ?? ""
        planLabel.stringValue = plan
        planLabel.isHidden = plan.isEmpty

        // 只有非正常状态才显示状态胶囊（原版正常时不挂 tag）。
        let showStatus = status != "ok"
        statusLabel.isHidden = !showStatus
        if showStatus {
            statusLabel.stringValue = " \(statusText(status)) "
            let color = statusColor(status)
            statusLabel.textColor = color
            statusLabel.layer?.borderColor = color.withAlphaComponent(0.32).cgColor
            statusLabel.layer?.backgroundColor = color.withAlphaComponent(0.06).cgColor
        }

        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        windowRows.removeAll()

        // 原版 .limit-windows 是 1fr 1fr 栅格：窗口两两成行。
        let windows = provider["windows"] as? [[String: Any]] ?? []
        var pending: NSStackView?
        for window in windows {
            let cell = LimitWindowRow()
            cell.configure(window: window, settings: settings, color: AppTheme.clientColor(id))
            if let row = pending {
                row.addArrangedSubview(cell)
                pending = nil
            } else {
                let row = NSStackView(views: [cell])
                row.orientation = .horizontal
                row.alignment = .top
                row.distribution = .fillEqually
                row.spacing = 10
                bodyStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
                windowRows.append(row)
                pending = row
            }
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
    private let resetField = NSTextField(labelWithString: "")
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

        // 原版 .limit-window-text 10px muted，值用 --text；.limit-reset 9px muted。
        configureLabel(labelField, font: AppTheme.microFont, color: AppTheme.textSecondary)
        configureLabel(valueField, font: AppTheme.microFont, color: AppTheme.textPrimary)
        configureLabel(resetField, font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), color: AppTheme.textSecondary)
        valueField.alignment = .right
        labelField.lineBreakMode = .byTruncatingTail
        resetField.lineBreakMode = .byTruncatingTail

        // 原版 .limit-meter：6px 高、圆角 3、bg rgba(--sunken-rgb, 0.44)。
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = AppTheme.sunkenColor.withAlphaComponent(0.44).cgColor
        barBg.layer?.cornerRadius = 3
        barBg.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBg.addSubview(barFill)

        let topRow = NSStackView(views: [labelField, valueField])
        topRow.orientation = .horizontal
        topRow.alignment = .lastBaseline
        topRow.spacing = 8
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 原版 .limit-window gap 5px。
        let stack = NSStackView(views: [topRow, barBg, resetField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            barBg.heightAnchor.constraint(equalToConstant: 6),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barBg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetField.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    func configure(window: [String: Any], settings: [String: Any], color: NSColor) {
        let currency = window["currency"] as? String ?? ""
        let remaining = window["remaining"]
        let limit = window["limit"]
        let remainingPct = window["remainingPercent"]
        let usedPct = window["usedPercent"]
        let showUsed = settings["showLimitUsed"] as? Bool ?? false
        let showMeter = window["showMeter"] as? Bool ?? true

        // 标签回退到 kind（原版 normalizeWindowLabel 可能返回空串）。
        let rawLabel = window["label"] as? String ?? ""
        labelField.stringValue = rawLabel.isEmpty
            ? (window["kind"] as? String ?? "").capitalized
            : rawLabel

        // 原版 limitFillPercent：默认看剩余，showLimitUsed 时翻成已用。
        let hasPercent = showMeter && !((remainingPct is NSNull || remainingPct == nil)
            && (usedPct is NSNull || usedPct == nil))
        var percent = 0.0
        if let p = remainingPct, !(p is NSNull) {
            percent = showUsed ? 100 - UsageCore.doubleValue(p) : UsageCore.doubleValue(p)
        } else if let p = usedPct, !(p is NSNull) {
            percent = showUsed ? UsageCore.doubleValue(p) : 100 - UsageCore.doubleValue(p)
        }
        percent = max(0, min(100, percent))

        // 原版 formatLimitWindowValue：有百分比就显示「N% left/used」，
        // 否则回落到剩余额度 / 上限。
        let sym = Fmt.currencySymbol(currency)
        let suffix = showUsed ? "used" : "left"
        if hasPercent {
            valueField.stringValue = "\(Int(percent.rounded()))% \(suffix)"
        } else if let r = remaining, !(r is NSNull) {
            let amount = "\(sym)\(Fmt.tokens(Int(UsageCore.doubleValue(r))))"
            valueField.stringValue = showMeter ? "\(amount) left" : amount
        } else if let l = limit, !(l is NSNull) {
            valueField.stringValue = "\(sym)\(Fmt.tokens(Int(UsageCore.doubleValue(l)))) cap"
        } else {
            valueField.stringValue = "--"
        }

        // 原版 .limit-reset：「Reset 5h 21m」，无重置时间则用 resetDescription。
        var resetText = ""
        if let reset = window["resetsAt"] as? String, !reset.isEmpty {
            resetText = LimitsFormat.resetText(reset)
        }
        if resetText.isEmpty {
            resetText = window["resetDescription"] as? String ?? ""
        }
        resetField.stringValue = resetText
        resetField.isHidden = resetText.isEmpty

        barBg.isHidden = !showMeter
        guard showMeter else { return }
        // 原版 limitMeterNode 用 provider 品牌色，不按余量改色。
        let fraction = hasPercent ? percent / 100 : 0
        barFill.layer?.backgroundColor = color.cgColor
        barFillWidth?.isActive = false
        barFillWidth = barFill.widthAnchor.constraint(
            equalTo: barBg.widthAnchor, multiplier: CGFloat(max(0.01, fraction))
        )
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
