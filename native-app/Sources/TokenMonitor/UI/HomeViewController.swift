import AppKit

/// 首页概览（原版 homePanel）：按 homeModuleOrder/hiddenHomeModules 渲染
/// limits / tool / model / trends 四个扁平模块（发丝线分隔，非卡片），
/// 点击模块头跳转到对应视图。
final class HomeViewController: NSViewController, ContentUpdatable {
    var onOpenView: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let modulesStack = NSStackView()
    private var moduleViews: [(id: String, view: HomeModuleCard)] = []
    private var moduleSignature = ""

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        modulesStack.orientation = .vertical
        modulesStack.alignment = .leading
        modulesStack.spacing = 0
        modulesStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = modulesStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            modulesStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            modulesStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            modulesStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            modulesStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildModules()
    }

    private func buildModules() {
        let s = BridgeCore.shared.settings.snapshot()
        let order = (s["homeModuleOrder"] as? String ?? "limits,tool,model,trends")
            .split(separator: ",").map { String($0).lowercased() }
        let hidden = Set(AppViews.csvItems(s["hiddenHomeModules"]).map { $0.lowercased() })
        let known = ["limits", "tool", "model", "trends"]
        moduleViews.removeAll()
        modulesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for id in order where known.contains(id) && !hidden.contains(id) {
            let card = HomeModuleCard(id: id)
            card.onClick = { [weak self] in self?.onOpenView?(card.viewId) }
            modulesStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: modulesStack.widthAnchor).isActive = true
            moduleViews.append((id, card))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        modulesStack.addArrangedSubview(spacer)
    }

    func update(stats: [String: Any]?, period: String, settings: [String: Any]) {
        let signature = "\((settings["homeModuleOrder"] as? String) ?? "")|\((settings["hiddenHomeModules"] as? String) ?? "")"
        if signature != moduleSignature {
            moduleSignature = signature
            buildModules()
        }
        let periods = stats?["periods"] as? [String: Any]
        let periodDict = periods?[period] as? [String: Any]
        for (id, card) in moduleViews {
            switch id {
            case "limits": card.renderLimits(stats: stats, settings: settings)
            case "tool": card.renderRows(period: periodDict, settings: settings, mode: "client")
            case "model": card.renderRows(period: periodDict, settings: settings, mode: "model")
            case "trends": card.renderTrends(stats: stats, settings: settings)
            default: break
            }
        }
    }
}

// MARK: - Module（原版 .home-module：扁平 + 底部发丝线）

private final class HomeModuleCard: NSView {
    let viewId: String
    var onClick: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let bodyStack = NSStackView()
    private var tracking: NSTrackingArea?
    private var hover = false

    init(id: String) {
        self.viewId = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear

        let title: String
        switch id {
        case "limits": title = "限额"
        case "tool": title = "工具"
        case "model": title = "模型"
        default: title = "趋势"
        }
        titleLabel.stringValue = title.uppercased()
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = AppTheme.textPrimary
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false

        let jump = NSTextField(labelWithString: "›")
        jump.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        jump.textColor = AppTheme.textSecondary
        jump.isBezeled = false
        jump.drawsBackground = false
        jump.alphaValue = 0.8

        let head = NSStackView(views: [titleLabel, metaLabel, jump])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 7
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 6

        let stack = NSStackView(views: [head, bodyStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 底部发丝线（原版 .home-module border-bottom）
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.hairlineColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        layer?.opacity = 0.94
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.opacity = 1
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    // MARK: - Render

    private func resetBody() {
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func empty(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = AppTheme.microFont
        label.textColor = AppTheme.textSecondary
        label.isBezeled = false
        label.drawsBackground = false
        bodyStack.addArrangedSubview(label)
    }

    // 限额模块（原版 homeLimitAccounts：账户头 + 双列 window）
    func renderLimits(stats: [String: Any]?, settings: [String: Any]) {
        resetBody()
        var providers: [[String: Any]] = []
        if let limits = stats?["limits"] as? [String: Any] {
            providers = limits["providers"] as? [[String: Any]] ?? []
        } else if let device = (stats?["devices"] as? [[String: Any]])?.first,
                  let limits = device["limits"] as? [String: Any] {
            providers = limits["providers"] as? [[String: Any]] ?? []
        } else {
            providers = (LimitsRuntime.shared.summary()["providers"] as? [[String: Any]]) ?? []
        }

        let limit = UsageCore.intValue(settings["homeLimitAccountCount"]) > 0
            ? UsageCore.intValue(settings["homeLimitAccountCount"]) : 3
        var accounts: [(name: String, color: NSColor, windows: [[String: Any]], lowest: Double)] = []
        for p in providers {
            let id = p["provider"] as? String ?? ""
            let label = p["accountLabel"] as? String ?? ""
            let windows = homeWindows(p)
            guard !windows.isEmpty else { continue }
            var lowest = 100.0
            for w in windows {
                if let rp = w["remainingPercent"] as? Double { lowest = min(lowest, rp) }
                if let up = w["usedPercent"] as? Double { lowest = min(lowest, 100 - up) }
            }
            accounts.append((
                name: AppTheme.clientLabel(id) + (label.isEmpty ? "" : " · \(label)"),
                color: AppTheme.clientColor(id),
                windows: windows,
                lowest: lowest
            ))
        }
        accounts.sort { $0.lowest < $1.lowest || ($0.lowest == $1.lowest && $0.name < $1.name) }
        if accounts.count > limit { accounts.removeSubrange(limit...) }

        guard !accounts.isEmpty else {
            empty("暂无限额数据")
            return
        }
        for account in accounts {
            let row = HomeLimitAccountRow()
            row.configure(name: account.name, color: account.color, windows: account.windows, settings: settings)
            bodyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }
    }

    /// 每账户最多 2 个 window，按 session/weekly/billing/monthly 优先级排序。
    private func homeWindows(_ provider: [String: Any]) -> [[String: Any]] {
        let priority = ["session": 0, "weekly": 1, "billing": 2, "monthly": 3]
        let windows = (provider["windows"] as? [[String: Any]] ?? [])
            .sorted { (priority[$0["kind"] as? String ?? ""] ?? 10) < (priority[$1["kind"] as? String ?? ""] ?? 10) }
        return Array(windows.prefix(2))
    }

    // 工具/模型模块：Top 5 + 占比（原版 homeToolRows/homeModelRows）
    func renderRows(period: [String: Any]?, settings: [String: Any], mode: String) {
        resetBody()
        let totalTokens = UsageCore.doubleValue(period?["totalTokens"])
        let source: [String: Any]
        if mode == "client" {
            source = period?["clients"] as? [String: Any] ?? [:]
        } else {
            source = period?["models"] as? [String: Any] ?? [:]
        }
        var rows: [(name: String, value: Double, color: NSColor)] = []
        for (key, value) in source {
            let tokens = UsageCore.doubleValue(value)
            guard tokens > 0 else { continue }
            let color = mode == "client" ? AppTheme.clientColor(key) : AppTheme.modelColor(key)
            rows.append((name: key, value: tokens, color: color))
        }
        rows.sort { $0.value > $1.value || ($0.value == $1.value && $0.name < $1.name) }
        if rows.count > 5 { rows.removeSubrange(5...) }

        guard !rows.isEmpty else {
            empty("暂无数据")
            return
        }
        for row in rows {
            let line = HomeListRow()
            line.configure(name: row.name, value: row.value, share: totalTokens > 0 ? row.value / totalTokens : 0, color: row.color)
            bodyStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }
    }

    // 趋势模块：近 30 天 sparkline + 统计（原版 homeTrendsModule 简化）
    func renderTrends(stats: [String: Any]?, settings: [String: Any]) {
        resetBody()
        let preview = (stats?["historyPreview"] as? [String: Any]) ?? [:]
        let daily = (preview["daily"] as? [[String: Any]]) ?? []
        guard !daily.isEmpty else {
            empty("暂无趋势数据")
            return
        }
        let days = Array(daily.suffix(30))
        let chart = HomeTrendChart()
        chart.update(days: days.map { (tokens: UsageCore.doubleValue($0["tokens"]), cost: UsageCore.doubleValue($0["cost"])) })
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 46).isActive = true
        bodyStack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        let summary = (preview["summary"] as? [String: Any]) ?? [:]
        let statsRow = HomeTrendStats()
        statsRow.configure(summary: summary)
        bodyStack.addArrangedSubview(statsRow)
        statsRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
    }
}

// MARK: - 限额账户行（原版 .home-limit-account）

private final class HomeLimitAccountRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let windowsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear

        nameLabel.font = AppTheme.bodyFont
        nameLabel.textColor = AppTheme.textPrimary
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail

        windowsStack.orientation = .horizontal
        windowsStack.alignment = .top
        windowsStack.distribution = .fillEqually
        windowsStack.spacing = 12

        let stack = NSStackView(views: [nameLabel, windowsStack])
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
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, color: NSColor, windows: [[String: Any]], settings: [String: Any]) {
        nameLabel.stringValue = name
        windowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for window in windows {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 2
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .lastBaseline
            line.spacing = 6
            let label = NSTextField(labelWithString: window["label"] as? String ?? "")
            label.font = AppTheme.microFont
            label.textColor = AppTheme.textSecondary
            label.isBezeled = false
            label.drawsBackground = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let value = NSTextField(labelWithString: "")
            value.font = AppTheme.microFont
            value.textColor = AppTheme.textPrimary
            value.isBezeled = false
            value.drawsBackground = false
            value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            line.addArrangedSubview(label)
            line.addArrangedSubview(value)
            col.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            configureWindowValue(value, window: window, settings: settings)
            windowsStack.addArrangedSubview(col)
        }
        if windowsStack.arrangedSubviews.count == 1 {
            windowsStack.arrangedSubviews.first?.widthAnchor.constraint(equalTo: windowsStack.widthAnchor).isActive = true
        }
    }

    private func configureWindowValue(_ label: NSTextField, window: [String: Any], settings: [String: Any]) {
        let showUsed = settings["showLimitUsed"] as? Bool ?? false
        let currency = window["currency"] as? String ?? ""
        let sym = Fmt.currencySymbol(currency)
        let remaining = UsageCore.doubleValue(window["remaining"])
        let used = UsageCore.doubleValue(window["used"])
        let limit = UsageCore.doubleValue(window["limit"])
        let remainingPct = window["remainingPercent"] as? Double
        let usedPct = window["usedPercent"] as? Double
        if showUsed {
            if limit > 0 {
                label.stringValue = "\(sym)\(Fmt.tokensExact(Int(used))) / \(sym)\(Fmt.tokensExact(Int(limit)))"
            } else if let usedPct {
                label.stringValue = "\(Fmt.percent(usedPct / 100))"
            } else {
                label.stringValue = "\(sym)\(Fmt.tokensExact(Int(used)))"
            }
            let pct = usedPct ?? (limit > 0 ? used / limit * 100 : nil)
            if let pct {
                if pct >= 80 { label.textColor = AppTheme.danger }
                else if pct >= 50 { label.textColor = AppTheme.warning }
            }
        } else {
            if limit > 0 {
                label.stringValue = "\(sym)\(Fmt.tokensExact(Int(remaining))) / \(sym)\(Fmt.tokensExact(Int(limit)))"
            } else if let remainingPct {
                label.stringValue = "\(Fmt.percent(remainingPct / 100))"
            } else {
                label.stringValue = "\(sym)\(Fmt.tokensExact(Int(remaining)))"
            }
            let pct = remainingPct ?? (limit > 0 ? remaining / limit * 100 : nil)
            if let pct {
                if pct < 20 { label.textColor = AppTheme.danger }
                else if pct < 50 { label.textColor = AppTheme.warning }
            }
        }
        if let reset = window["resetsAt"] as? String, !reset.isEmpty {
            let ms = UsageCore.timestampMs(reset)
            if ms > 0 {
                let f = DateFormatter()
                f.dateFormat = "MM-dd"
                label.stringValue += " · \(f.string(from: Date(timeIntervalSince1970: ms / 1000))) 重置"
            }
        }
    }
}

// MARK: - 列表行（原版 .home-list-row：mark + name + value + share）

private final class HomeListRow: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let shareLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = AppTheme.bodyFont
        nameLabel.textColor = AppTheme.textPrimary
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        valueLabel.font = AppTheme.bodyFont
        valueLabel.textColor = AppTheme.textPrimary
        valueLabel.isBezeled = false
        valueLabel.drawsBackground = false
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        shareLabel.font = AppTheme.microFont
        shareLabel.textColor = AppTheme.textSecondary
        shareLabel.isBezeled = false
        shareLabel.drawsBackground = false
        shareLabel.alignment = .right
        shareLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [dot, nameLabel, valueLabel, shareLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            shareLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, value: Double, share: Double, color: NSColor) {
        dot.layer?.backgroundColor = color.cgColor
        nameLabel.stringValue = name
        valueLabel.stringValue = Fmt.tokens(Int(value))
        shareLabel.stringValue = String(format: "%.1f%%", share * 100)
    }
}

// MARK: - 趋势小图（原版 .home-area-chart 简化：accent 色柱）

private final class HomeTrendChart: NSView {
    private var days: [(tokens: Double, cost: Double)] = []
    override var isFlipped: Bool { true }

    func update(days: [(tokens: Double, cost: Double)]) {
        self.days = days
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        guard !days.isEmpty else { return }
        let maxVal = max(1, days.map(\.tokens).max() ?? 1)
        let barWidth = max(1, bounds.width / CGFloat(days.count) - 1)
        let gap: CGFloat = 1
        for (i, day) in days.enumerated() {
            let h = bounds.height * CGFloat(day.tokens / maxVal)
            let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: bounds.height - h, width: barWidth, height: h)
            let color = i == days.count - 1 ? AppTheme.accent : AppTheme.blue.withAlphaComponent(0.55)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        }
    }
}

private final class HomeTrendStats: NSView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(summary: [String: Any]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let activeDays = UsageCore.doubleValue(summary["activeDays"])
        let streak = UsageCore.doubleValue(summary["currentStreak"])
        let peak = UsageCore.doubleValue(summary["peakDayTokens"])
        let favorite = summary["favoriteModel"] as? String ?? ""
        let items: [(String, String)] = [
            ("活跃天数", "\(Int(activeDays))"),
            ("连续天数", "\(Int(streak))"),
            ("峰值日", Fmt.tokens(Int(peak))),
            ("常用模型", favorite.isEmpty ? "—" : String(favorite.prefix(18))),
        ]
        for (key, value) in items {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 1
            let v = NSTextField(labelWithString: value)
            v.font = AppTheme.bodyFont
            v.textColor = AppTheme.textPrimary
            v.isBezeled = false
            v.drawsBackground = false
            v.lineBreakMode = .byTruncatingTail
            let k = NSTextField(labelWithString: key)
            k.font = AppTheme.microFont
            k.textColor = AppTheme.textSecondary
            k.isBezeled = false
            k.drawsBackground = false
            col.addArrangedSubview(v)
            col.addArrangedSubview(k)
            stack.addArrangedSubview(col)
        }
    }
}
