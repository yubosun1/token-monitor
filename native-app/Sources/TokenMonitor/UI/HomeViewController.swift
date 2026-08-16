import AppKit

/// 首页概览（原版 homePanel）：按 homeModuleOrder/hiddenHomeModules 渲染
/// limits / tool / model / trends 四个扁平模块（发丝线分隔，非卡片），
/// 点击模块头跳转到对应视图。
final class HomeViewController: NSViewController, ContentUpdatable {
    var onOpenView: ((String) -> Void)?

    private let scrollView = TopAnchoredScrollView()
    private let modulesStack = NSStackView()
    private var moduleViews: [(id: String, view: HomeModuleCard)] = []
    private var moduleSignature = ""

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        // 原版 .home-panel gap: 12px。
        modulesStack.orientation = .vertical
        modulesStack.alignment = .leading
        modulesStack.spacing = 12
        modulesStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = modulesStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // 原版把滚动条完全隐藏（scrollbar-width: none）；overlay 样式不占布局宽度，
        // 否则「经典」滚动条会挤掉行右侧的数值列。
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            modulesStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            modulesStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            modulesStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            modulesStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
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

        // 原版 HOME_MODULE_OPTIONS 的标签：LIMITS / TOOLS / MODELS / ACTIVITY。
        let title: String
        switch id {
        case "limits": title = "限额"
        case "tool": title = "工具"
        case "model": title = "模型"
        default: title = "活动"
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

        // 原版 .home-module-meta：10px muted，紧贴右侧的 › 之前。
        metaLabel.font = AppTheme.microFont
        metaLabel.textColor = AppTheme.textSecondary
        metaLabel.isBezeled = false
        metaLabel.drawsBackground = false
        metaLabel.alignment = .right
        metaLabel.isHidden = true

        // 原版 .home-module-head：space-between，标题在左、meta + › 在右。
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let head = NSStackView(views: [titleLabel, spacer, metaLabel, jump])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 7
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // 原版 .home-module gap 7px。
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 7

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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            // 原版 .home-module padding: 0 0 12px。
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            // 头部与正文都撑满，否则 space-between / 图表宽度都不成立。
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        setMeta("")
    }

    /// 模块头右侧的 muted 说明（原版 .home-module-meta）。
    private func setMeta(_ text: String) {
        metaLabel.stringValue = text
        metaLabel.isHidden = text.isEmpty
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
        var accounts: [(name: String, color: NSColor, asset: String?, windows: [[String: Any]], lowest: Double)] = []
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
                asset: IconCatalog.clientAsset(id),
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
            row.configure(name: account.name, color: account.color, asset: account.asset,
                          windows: account.windows, settings: settings)
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
        // 隐藏的客户端在首页也不该出现（与 breakdown 视图一致）。
        let hiddenClients = mode == "client"
            ? Set(AppViews.csvItems(settings["hiddenClients"]).map { $0.lowercased() })
            : Set<String>()
        var rows: [(name: String, value: Double, color: NSColor)] = []
        for (key, value) in source {
            let tokens = UsageCore.doubleValue(value)
            guard tokens > 0, !hiddenClients.contains(key.lowercased()) else { continue }
            let color = mode == "client" ? AppTheme.clientColor(key) : AppTheme.modelColor(key)
            rows.append((name: key, value: tokens, color: color))
        }
        rows.sort { $0.value > $1.value || ($0.value == $1.value && $0.name < $1.name) }
        if rows.count > 5 { rows.removeSubrange(5...) }

        guard !rows.isEmpty else {
            empty("暂无数据")
            return
        }
        let showIcons = settings["showToolIcons"] as? Bool ?? true
        for row in rows {
            let line = HomeListRow()
            line.configure(
                name: row.name,
                value: row.value,
                share: totalTokens > 0 ? row.value / totalTokens : 0,
                color: row.color,
                asset: mode == "client" ? IconCatalog.clientAsset(row.name) : IconCatalog.modelAsset(row.name),
                showIcons: showIcons,
                // 工具行显示客户端展示名（Claude Code），模型行保留原始模型名。
                displayName: mode == "client" ? AppTheme.clientLabel(row.name) : row.name
            )
            bodyStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }
    }

    /// 活动模块（原版 home.activity）：滚动年热力图 + TREND 折线小节。
    /// 模块头右侧显示「N 活跃天数」，折线下方是首/中/末日期刻度与峰值。
    func renderTrends(stats: [String: Any]?, settings: [String: Any]) {
        resetBody()
        let preview = (stats?["historyPreview"] as? [String: Any]) ?? [:]
        let daily = (preview["daily"] as? [[String: Any]]) ?? []
        guard !daily.isEmpty else {
            empty("暂无活动数据")
            return
        }
        let summary = (preview["summary"] as? [String: Any]) ?? [:]
        let activeDays = Int(UsageCore.doubleValue(summary["activeDays"]))
        setMeta(activeDays > 0 ? "\(activeDays) 活跃天数" : "")

        // 热力图（metric 跟随设置里的 heatmapMetric）。
        let metric = (settings["heatmapMetric"] as? String) == "cost" ? "cost" : "tokens"
        let heatmap = HomeActivityHeatmap()
        heatmap.update(daily: daily, metric: metric)
        heatmap.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(heatmap)
        // 高度由 intrinsicContentSize 跟随算出的格子尺寸，不写死。
        heatmap.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // TREND 小节（原版 .home-trend-head）。
        let trendHead = NSTextField(labelWithString: "TREND")
        trendHead.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        trendHead.textColor = AppTheme.textPrimary
        trendHead.isBezeled = false
        trendHead.drawsBackground = false

        let peak = UsageCore.doubleValue(summary["peakDayTokens"])
        let peakLabel = NSTextField(labelWithString: peak > 0 ? "Peak \(Fmt.tokens(Int(peak)))" : "")
        peakLabel.font = AppTheme.microFont
        peakLabel.textColor = AppTheme.textSecondary
        peakLabel.alignment = .right
        peakLabel.isBezeled = false
        peakLabel.drawsBackground = false

        let headRow = NSStackView(views: [trendHead, peakLabel])
        headRow.orientation = .horizontal
        headRow.alignment = .lastBaseline
        headRow.spacing = 8
        trendHead.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bodyStack.addArrangedSubview(headRow)
        headRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        let days = Array(daily.suffix(30))
        let chart = HomeTrendChart()
        chart.update(days: days.map {
            (tokens: UsageCore.doubleValue($0["tokens"]), cost: UsageCore.doubleValue($0["cost"]))
        })
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 56).isActive = true
        bodyStack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // 日期刻度：首 / 中 / 末（原版 .home-trend-dates 三列栅格）。
        let dateRow = NSStackView()
        dateRow.orientation = .horizontal
        dateRow.distribution = .fillEqually
        let keys: [[String: Any]?] = [days.first, days[days.count / 2], days.last]
        for (index, entry) in keys.enumerated() {
            let raw = (entry?["date"] as? String) ?? ""
            let label = NSTextField(labelWithString: Self.shortDate(raw))
            label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            label.textColor = AppTheme.textSecondary
            label.isBezeled = false
            label.drawsBackground = false
            let alignment: NSTextAlignment = index == 0 ? .left : (index == 1 ? .center : .right)
            label.alignment = alignment
            dateRow.addArrangedSubview(label)
        }
        bodyStack.addArrangedSubview(dateRow)
        dateRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
    }

    /// yyyy-MM-dd → M/d（原版趋势轴刻度格式）。
    private static func shortDate(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count >= 3 else { return raw }
        let month = Int(parts[1]).map(String.init) ?? String(parts[1])
        let day = Int(parts[2]).map(String.init) ?? String(parts[2])
        return "\(month)/\(day)"
    }
}

// MARK: - 限额账户行（原版 .home-limit-account）

private final class HomeLimitAccountRow: NSView {
    private let mark = RowMarkView(size: 10)
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

        let nameRow = NSStackView(views: [mark, nameLabel])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 8

        windowsStack.orientation = .horizontal
        windowsStack.alignment = .top
        windowsStack.distribution = .fillEqually
        windowsStack.spacing = 12

        let stack = NSStackView(views: [nameRow, windowsStack])
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
            windowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, color: NSColor, asset: String?, windows: [[String: Any]], settings: [String: Any]) {
        mark.configure(asset: asset, color: color, showIcons: settings["showToolIcons"] as? Bool ?? true)
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
            let rawLabel = window["label"] as? String ?? ""
            let label = NSTextField(labelWithString: rawLabel.isEmpty
                ? (window["kind"] as? String ?? "").capitalized : rawLabel)
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
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            line.addArrangedSubview(label)
            line.addArrangedSubview(value)
            col.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            configureWindowValue(value, window: window, settings: settings)

            // 重置时间自成一行（原版首页 .home-limit-reset）。
            var resetText = ""
            if let reset = window["resetsAt"] as? String, !reset.isEmpty {
                resetText = LimitsFormat.resetText(reset)
            }
            if resetText.isEmpty { resetText = window["resetDescription"] as? String ?? "" }
            if !resetText.isEmpty {
                let resetLabel = NSTextField(labelWithString: resetText)
                resetLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
                resetLabel.textColor = AppTheme.textSecondary
                resetLabel.isBezeled = false
                resetLabel.drawsBackground = false
                resetLabel.lineBreakMode = .byTruncatingTail
                col.addArrangedSubview(resetLabel)
                resetLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            }
            windowsStack.addArrangedSubview(col)
        }
        if windowsStack.arrangedSubviews.count == 1 {
            windowsStack.arrangedSubviews.first?.widthAnchor.constraint(equalTo: windowsStack.widthAnchor).isActive = true
        }
    }

    /// 原版 formatHomeLimitWindowValue：首页也是「N% left」，与限额视图一致；
    /// 无百分比时回落到剩余额度。
    private func configureWindowValue(_ label: NSTextField, window: [String: Any], settings: [String: Any]) {
        let showUsed = settings["showLimitUsed"] as? Bool ?? false
        let currency = window["currency"] as? String ?? ""
        let sym = Fmt.currencySymbol(currency)
        let remainingPct = window["remainingPercent"] as? Double
        let usedPct = window["usedPercent"] as? Double

        var percent: Double?
        if let remainingPct {
            percent = showUsed ? 100 - remainingPct : remainingPct
        } else if let usedPct {
            percent = showUsed ? usedPct : 100 - usedPct
        }

        if let percent {
            let clamped = max(0, min(100, percent))
            label.stringValue = "\(Int(clamped.rounded()))% \(showUsed ? "used" : "left")"
            // 原版余量低时才染色（剩余 <20% 红、<50% 黄）。
            let remainingShare = showUsed ? 100 - clamped : clamped
            if remainingShare < 20 { label.textColor = AppTheme.danger }
            else if remainingShare < 50 { label.textColor = AppTheme.warning }
            else { label.textColor = AppTheme.textPrimary }
        } else if let raw = window["remaining"], !(raw is NSNull) {
            label.stringValue = "\(sym)\(Fmt.tokens(Int(UsageCore.doubleValue(raw))))"
            label.textColor = AppTheme.textPrimary
        } else {
            label.stringValue = "--"
            label.textColor = AppTheme.textSecondary
        }
    }
}

// MARK: - 列表行（原版 .home-list-row：mark + name + value + share）

private final class HomeListRow: NSView {
    private let mark = RowMarkView(size: 10)
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let shareLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear

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

        // 原版 .home-list-row：mark + 名称（撑开）+ 数值 + 占比。
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [mark, nameLabel, spacer, valueLabel, shareLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [valueLabel, shareLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            shareLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, value: Double, share: Double, color: NSColor, asset: String?, showIcons: Bool, displayName: String? = nil) {
        mark.configure(asset: asset, color: color, showIcons: showIcons)
        nameLabel.stringValue = displayName ?? name
        valueLabel.stringValue = Fmt.tokens(Int(value))
        shareLabel.stringValue = String(format: "%.1f%%", share * 100)
    }
}

// MARK: - 趋势折线图（原版 .home-area-chart：蓝色折线 + 面积填充）

/// 原版首页趋势模块画的是折线 + 渐隐面积（不是柱），线色用 --blue。
private final class HomeTrendChart: NSView {
    private var days: [(tokens: Double, cost: Double)] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(days: [(tokens: Double, cost: Double)]) {
        self.days = days
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard days.count > 1, bounds.width > 1, bounds.height > 1 else { return }
        let maxVal = max(1, days.map(\.tokens).max() ?? 1)
        let stepX = bounds.width / CGFloat(days.count - 1)
        // 顶部/底部各留 2pt，避免峰值贴边。
        let inset: CGFloat = 2
        let usableHeight = bounds.height - inset * 2

        func point(_ i: Int) -> CGPoint {
            let ratio = CGFloat(days[i].tokens / maxVal)
            return CGPoint(x: CGFloat(i) * stepX, y: inset + usableHeight * (1 - ratio))
        }

        let line = CGMutablePath()
        line.move(to: point(0))
        for i in 1..<days.count { line.addLine(to: point(i)) }

        // 面积填充：折线闭合到底边。
        let area = CGMutablePath()
        area.addPath(line)
        area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        area.addLine(to: CGPoint(x: 0, y: bounds.height))
        area.closeSubpath()
        ctx.saveGState()
        ctx.addPath(area)
        ctx.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                AppTheme.blue.withAlphaComponent(0.26).cgColor,
                AppTheme.blue.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: bounds.height),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.addPath(line)
        ctx.setStrokeColor(AppTheme.blue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
}

// MARK: - 活动热力图（原版 .home-activity-canvas：滚动年贡献图）

/// 原版首页 ACTIVITY 模块：滚动一年的日贡献热力图，蓝色四级渐变。
private final class HomeActivityHeatmap: NSView {
    private var model: ChartCore.HeatmapModel?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 原版 .heat.lvl-1..4 的蓝色渐变。
    private static let levelColors: [NSColor] = [
        NSColor(calibratedWhite: 1, alpha: 0.03),
        NSColor(calibratedRed: 90/255, green: 170/255, blue: 255/255, alpha: 0.18),
        NSColor(calibratedRed: 120/255, green: 190/255, blue: 255/255, alpha: 0.45),
        NSColor(calibratedRed: 150/255, green: 210/255, blue: 255/255, alpha: 0.80),
        NSColor(calibratedRed: 180/255, green: 230/255, blue: 255/255, alpha: 1.0),
    ]

    private var daily: [[String: Any]] = []
    private var metric = "tokens"
    private var builtForWidth: CGFloat = 0

    func update(daily: [[String: Any]], metric: String) {
        self.daily = daily
        self.metric = metric
        builtForWidth = 0
        rebuildIfNeeded()
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    /// Cell size is derived from the available width so the rolling year fits
    /// without horizontal scrolling (the renderer scrolls its canvas instead;
    /// a scroll view nested in this stack would fight the outer one).
    private func rebuildIfNeeded() {
        let width = bounds.width
        guard width > 1, !daily.isEmpty, abs(width - builtForWidth) > 0.5 else { return }
        builtForWidth = width

        let end = ChartCore.localDayKey()
        let window = ChartCore.rollingYearWindow(endDate: end)
        let weeks = max(1, ChartCore.daysBetweenKeys(window.start, window.end) / 7 + 1)
        let gap: CGFloat = 2
        // width = weeks * cell + (weeks - 1) * gap  →  solve for cell.
        let cell = max(4, ((width - gap * CGFloat(weeks - 1)) / CGFloat(weeks)).rounded(.down))

        model = ChartCore.contribHeatmap(
            daily, cell: cell, gap: gap,
            startDate: window.start, endDate: window.end,
            intensityKey: metric
        )
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Height only — never a width. Reporting the grid's pixel width would widen
    /// the enclosing stack past the scroll view's clip width and push every
    /// other row's right-hand column out of view.
    override var intrinsicContentSize: NSSize {
        guard let model else { return NSSize(width: NSView.noIntrinsicMetric, height: 78) }
        // 7 rows of cells + gaps, plus the month tick row underneath.
        let grid = model.cell * 7 + model.gap * 6
        return NSSize(width: NSView.noIntrinsicMetric, height: grid + 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let model else { return }
        // 图比可用宽度长时右对齐（原版容器横向滚动到最新一天）。
        let offsetX = min(0, bounds.width - model.width)
        ctx.saveGState()
        ctx.translateBy(x: offsetX, y: 0)
        // contribHeatmap 的 intensity 是原始度量值，不是 0–4 等级；用与原版
        // 一致的分级函数换算（tokens 用固定档位，cost 相对峰值）。
        let peak = model.cells.map { metric == "cost" ? $0.cost : $0.tokens }.max() ?? 0
        for cell in model.cells {
            let value = metric == "cost" ? cell.cost : cell.tokens
            let level = max(0, min(
                Self.levelColors.count - 1,
                ChartCore.heatmapLevelForValue(value, peak, metric: metric)
            ))
            ctx.setFillColor(Self.levelColors[level].cgColor)
            let rect = CGRect(x: cell.x, y: cell.y, width: cell.size, height: cell.size)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
        }

        // 月份刻度（原版 .heat-month：9px，fill rgba(line, 0.5)）。
        let monthAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: AppTheme.textSecondary.withAlphaComponent(0.7),
        ]
        let gridHeight = model.cell * 7 + model.gap * 6
        // monthLabels 给的是 "yyyy-MM"，原版轴上只画短月名（Feb / Mar …）；
        // 且相邻刻度距离太近时跳过，避免叠字。
        var lastLabelEnd: CGFloat = -.greatestFiniteMagnitude
        for label in model.monthLabels {
            let x = CGFloat(label.col) * (model.cell + model.gap)
            guard x >= lastLabelEnd + 6 else { continue }
            let text = NSAttributedString(string: Self.monthName(label.label), attributes: monthAttrs)
            text.draw(at: CGPoint(x: x, y: gridHeight + 3))
            lastLabelEnd = x + text.size().width
        }
        ctx.restoreGState()
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "2026-08" → "Aug"。
    private static func monthName(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]), month >= 1, month <= 12 else { return key }
        return monthNames[month - 1]
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
