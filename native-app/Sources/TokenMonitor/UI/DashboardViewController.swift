import AppKit

/// 独立 Dashboard 窗口（取代原 dashboard.html）：
/// - 「概览」tab：8 张统计卡 + Token Activity 热力图（tokens/cost 可切）+ 模型/工具 Top5 明细列
/// - 「趋势」tab：7/30/90/365/全部 范围 + 按工具/模型堆叠柱 + Bars/K线 模式 + 图例 + 悬停提示
final class DashboardViewController: NSViewController, WindowHostConsumer, WindowTeardownObserver {
    weak var host: WindowHost?

    // MARK: - Tabs / panes

    private let overviewTab = HoverButton(title: "概览")
    private let trendsTab = HoverButton(title: "趋势")
    private let overviewPane = NSView()
    private let trendsPane = NSView()

    // MARK: - Overview

    private let cardsStack = NSStackView()
    private let heatmapMetricSeg = NSSegmentedControl(labels: ["Tokens", "Cost"], trackingMode: .selectOne, target: nil, action: nil)
    private let heatmapScroll = NSScrollView()
    private let heatmapView = HeatmapView()
    private let heatmapLegend = NSStackView()
    private let breakdownColumns = NSStackView()

    // MARK: - Trends

    private let rangeStack = NSStackView()
    private let stackSeg = NSSegmentedControl(labels: ["按工具", "按模型"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeSeg = NSSegmentedControl(labels: ["柱状", "K线"], trackingMode: .selectOne, target: nil, action: nil)
    private let chartView = DashboardChartView()
    private let legendStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无历史数据")

    private var range = "30"
    private var stackBy = "client"
    private var mode = "bars"
    private var observers: [NSObjectProtocol] = []

    private let ranges = ["7", "30", "90", "365", "all"]

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = AppTheme.cardColor.cgColor

        // Header
        let title = NSTextField(labelWithString: "用量面板")
        title.font = AppTheme.titleFont
        title.textColor = AppTheme.textPrimary
        title.isBezeled = false
        title.drawsBackground = false
        let refreshBtn = HoverButton(title: "↻")
        refreshBtn.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshNow)
        let closeBtn = HoverButton(title: "×")
        closeBtn.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        closeBtn.target = self
        closeBtn.action = #selector(close)
        let header = NSStackView(views: [title, refreshBtn, closeBtn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        // Tabs
        overviewTab.font = AppTheme.tabFont
        overviewTab.target = self; overviewTab.action = #selector(tabClick(_:))
        overviewTab.identifier = NSUserInterfaceItemIdentifier("overview")
        trendsTab.font = AppTheme.tabFont
        trendsTab.target = self; trendsTab.action = #selector(tabClick(_:))
        trendsTab.identifier = NSUserInterfaceItemIdentifier("trends")
        let tabs = NSStackView(views: [overviewTab, trendsTab])
        tabs.orientation = .horizontal
        tabs.spacing = 2
        tabs.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)

        // Panes
        overviewPane.translatesAutoresizingMaskIntoConstraints = false
        trendsPane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overviewPane)
        root.addSubview(trendsPane)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            overviewPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overviewPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overviewPane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
            overviewPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            trendsPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            trendsPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            trendsPane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
            trendsPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        buildOverview()
        buildTrends()
        view = root
        applyTab("overview")
    }

    // MARK: - Overview pane

    private func buildOverview() {
        // Stat cards
        cardsStack.orientation = .horizontal
        cardsStack.alignment = .centerY
        cardsStack.distribution = .fillEqually
        cardsStack.spacing = 8
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        overviewPane.addSubview(cardsStack)

        // Heatmap block
        let heatTitle = NSTextField(labelWithString: "Token Activity")
        heatTitle.font = AppTheme.titleFont
        heatTitle.textColor = AppTheme.textPrimary
        heatTitle.isBezeled = false
        heatTitle.drawsBackground = false

        heatmapMetricSeg.target = self
        heatmapMetricSeg.action = #selector(heatmapMetricChange)
        heatmapMetricSeg.selectedSegment = 0
        heatmapMetricSeg.font = AppTheme.smallFont
        heatmapMetricSeg.translatesAutoresizingMaskIntoConstraints = false

        let heatHeader = NSStackView(views: [heatTitle, heatmapMetricSeg])
        heatHeader.orientation = .horizontal
        heatHeader.alignment = .centerY
        heatTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heatHeader.translatesAutoresizingMaskIntoConstraints = false
        overviewPane.addSubview(heatHeader)

        heatmapLegend.orientation = .horizontal
        heatmapLegend.alignment = .centerY
        heatmapLegend.spacing = 10
        heatmapLegend.translatesAutoresizingMaskIntoConstraints = false
        overviewPane.addSubview(heatmapLegend)

        // 文档视图用 frame 定位（宽度随内容变化，由 update 设置）
        heatmapView.translatesAutoresizingMaskIntoConstraints = true
        heatmapScroll.documentView = heatmapView
        heatmapScroll.drawsBackground = false
        heatmapScroll.hasHorizontalScroller = true
        heatmapScroll.autohidesScrollers = true
        heatmapScroll.translatesAutoresizingMaskIntoConstraints = false
        overviewPane.addSubview(heatmapScroll)

        // Breakdown columns
        breakdownColumns.orientation = .horizontal
        breakdownColumns.alignment = .top
        breakdownColumns.distribution = .fillEqually
        breakdownColumns.spacing = 24
        breakdownColumns.translatesAutoresizingMaskIntoConstraints = false
        overviewPane.addSubview(breakdownColumns)

        NSLayoutConstraint.activate([
            cardsStack.leadingAnchor.constraint(equalTo: overviewPane.leadingAnchor, constant: 16),
            cardsStack.trailingAnchor.constraint(equalTo: overviewPane.trailingAnchor, constant: -16),
            cardsStack.topAnchor.constraint(equalTo: overviewPane.topAnchor, constant: 10),
            cardsStack.heightAnchor.constraint(equalToConstant: 52),
            heatHeader.leadingAnchor.constraint(equalTo: overviewPane.leadingAnchor, constant: 16),
            heatHeader.trailingAnchor.constraint(equalTo: overviewPane.trailingAnchor, constant: -16),
            heatHeader.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 14),
            heatmapLegend.leadingAnchor.constraint(equalTo: overviewPane.leadingAnchor, constant: 16),
            heatmapLegend.topAnchor.constraint(equalTo: heatHeader.bottomAnchor, constant: 6),
            heatmapScroll.leadingAnchor.constraint(equalTo: overviewPane.leadingAnchor, constant: 16),
            heatmapScroll.trailingAnchor.constraint(equalTo: overviewPane.trailingAnchor, constant: -16),
            heatmapScroll.topAnchor.constraint(equalTo: heatmapLegend.bottomAnchor, constant: 6),
            heatmapScroll.heightAnchor.constraint(equalToConstant: 128),
            breakdownColumns.leadingAnchor.constraint(equalTo: overviewPane.leadingAnchor, constant: 16),
            breakdownColumns.trailingAnchor.constraint(equalTo: overviewPane.trailingAnchor, constant: -16),
            breakdownColumns.topAnchor.constraint(equalTo: heatmapScroll.bottomAnchor, constant: 12),
            breakdownColumns.bottomAnchor.constraint(equalTo: overviewPane.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Trends pane

    private func buildTrends() {
        // Range buttons
        rangeStack.orientation = .horizontal
        rangeStack.spacing = 4
        rangeStack.translatesAutoresizingMaskIntoConstraints = false
        for r in ranges {
            let label = r == "all" ? "全部" : "\(r)天"
            let btn = HoverButton(title: label)
            btn.font = AppTheme.smallFont
            btn.identifier = NSUserInterfaceItemIdentifier(r)
            btn.target = self
            btn.action = #selector(rangeClick(_:))
            rangeStack.addArrangedSubview(btn)
        }

        stackSeg.target = self
        stackSeg.action = #selector(stackChange)
        stackSeg.selectedSegment = 0
        stackSeg.font = AppTheme.smallFont
        modeSeg.target = self
        modeSeg.action = #selector(modeChange)
        modeSeg.selectedSegment = 0
        modeSeg.font = AppTheme.smallFont

        let controls = NSStackView(views: [rangeStack, stackSeg, modeSeg])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        trendsPane.addSubview(controls)

        chartView.translatesAutoresizingMaskIntoConstraints = false
        trendsPane.addSubview(chartView)

        legendStack.orientation = .vertical
        legendStack.alignment = .leading
        legendStack.spacing = 3
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        trendsPane.addSubview(legendStack)

        emptyLabel.font = AppTheme.bodyFont
        emptyLabel.textColor = AppTheme.textTertiary
        emptyLabel.isBezeled = false
        emptyLabel.drawsBackground = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        trendsPane.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: trendsPane.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: trendsPane.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: trendsPane.topAnchor, constant: 10),
            chartView.leadingAnchor.constraint(equalTo: trendsPane.leadingAnchor, constant: 16),
            chartView.trailingAnchor.constraint(equalTo: trendsPane.trailingAnchor, constant: -16),
            chartView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            legendStack.leadingAnchor.constraint(equalTo: trendsPane.leadingAnchor, constant: 16),
            legendStack.trailingAnchor.constraint(equalTo: trendsPane.trailingAnchor, constant: -16),
            legendStack.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 8),
            legendStack.bottomAnchor.constraint(equalTo: trendsPane.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: trendsPane.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: trendsPane.topAnchor, constant: 60),
        ])
        applyRangeSelection()
    }

    // MARK: - Data

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: DataBus.statsUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.refreshCards()
        })
        observers.append(center.addObserver(forName: DataBus.historyUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    private func refreshCards() {
        // 统计卡数据在 refreshOverview 中渲染；此处仅保留钩子。
    }

    private func refresh() {
        refreshCards()
        refreshOverview()
        refreshTrends()
    }

    private func history() -> [String: Any]? {
        return Collector.shared.history()
    }

    // MARK: - Overview render

    private func refreshOverview() {
        let history = history() ?? [:]
        let daily = (history["daily"] as? [[String: Any]]) ?? []
        let summary = (history["summary"] as? [String: Any]) ?? [:]
        let settings = BridgeCore.shared.settings.snapshot()

        // Stat cards
        let stats: [(String, String)] = [
            ("总 Token", Fmt.tokens(Int(UsageCore.doubleValue(summary["totalTokens"])))),
            ("总成本", Fmt.money(UsageCore.doubleValue(summary["totalCost"]), settings: settings)),
            ("活跃天数", Fmt.tokensExact(Int(UsageCore.doubleValue(summary["activeDays"])))),
            ("连续天数", Fmt.tokensExact(Int(UsageCore.doubleValue(summary["currentStreak"])))),
            ("活跃时长", durationText(UsageCore.doubleValue(summary["activeTimeMs"]))),
            ("峰值日", Fmt.tokens(Int(UsageCore.doubleValue(summary["peakDayTokens"])))),
            ("常用模型", (summary["favoriteModel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
            ("消息数", Fmt.tokensExact(Int(UsageCore.doubleValue(summary["messages"])))),
        ]
        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (key, value) in stats {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.backgroundColor = AppTheme.cardColor.cgColor
            card.layer?.cornerRadius = 6
            card.layer?.borderWidth = 1
            card.layer?.borderColor = AppTheme.cardBorderColor.cgColor
            let v = NSTextField(labelWithString: value)
            v.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            v.textColor = AppTheme.textPrimary
            v.isBezeled = false
            v.drawsBackground = false
            v.lineBreakMode = .byTruncatingTail
            let k = NSTextField(labelWithString: key)
            k.font = AppTheme.microFont
            k.textColor = AppTheme.textTertiary
            k.isBezeled = false
            k.drawsBackground = false
            let stack = NSStackView(views: [v, k])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                stack.topAnchor.constraint(equalTo: card.topAnchor),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ])
            cardsStack.addArrangedSubview(card)
        }

        // Heatmap（今日实时值补进最后一格）
        let metric = heatmapMetricSeg.selectedSegment == 1 ? "cost" : "tokens"
        var todayTotal = 0.0
        var todayCost = 0.0
        if let stats = Collector.shared.latestStats(),
           let periods = stats["periods"] as? [String: Any],
           let today = periods["today"] as? [String: Any] {
            todayTotal = UsageCore.doubleValue(today["totalTokens"])
            todayCost = UsageCore.doubleValue(today["costUsd"])
        }
        let finalDaily = ChartCore.patchDailyToday(
            daily, todayDate: ChartCore.localDayKey(),
            todayTotal: todayTotal, todayCost: todayCost
        )
        heatmapView.update(daily: finalDaily, metric: metric)
        renderHeatmapLegend(daily: daily, metric: metric, settings: settings)

        // Breakdown columns
        breakdownColumns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var modelTotals: [String: Double] = [:]
        var clientTotals: [String: Double] = [:]
        var grand = 0.0
        for d in daily {
            if let perClient = d["perClient"] as? [String: Any] {
                for (k, v) in perClient {
                    if let entry = v as? [String: Any] {
                        clientTotals[k, default: 0] += UsageCore.doubleValue(entry["tokens"])
                    }
                }
            }
            if let perModel = d["perModel"] as? [String: Any] {
                for (k, v) in perModel {
                    if let entry = v as? [String: Any] {
                        modelTotals[k, default: 0] += UsageCore.doubleValue(entry["tokens"])
                    }
                }
            }
            grand += UsageCore.doubleValue(d["tokens"])
        }
        let modelCol = buildBreakdownColumn(title: "模型", totals: modelTotals, grand: grand, isClient: false)
        let clientCol = buildBreakdownColumn(title: "工具", totals: clientTotals, grand: grand, isClient: true)
        if let modelCol { breakdownColumns.addArrangedSubview(modelCol) }
        if let clientCol { breakdownColumns.addArrangedSubview(clientCol) }
    }

    private func buildBreakdownColumn(title: String, totals: [String: Double], grand: Double, isClient: Bool) -> NSView? {
        let sorted = totals.filter { $0.value > 0 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        guard !sorted.isEmpty else { return nil }
        let maxVal = sorted.first?.value ?? 1
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.titleFont
        titleLabel.textColor = AppTheme.textPrimary
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        col.addArrangedSubview(titleLabel)
        for (key, value) in sorted.prefix(5) {
            let row = NSView()
            row.wantsLayer = true
            row.layer?.backgroundColor = .clear
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 3
            let color = isClient ? AppTheme.clientColor(key) : AppTheme.modelColor(key)
            swatch.layer?.backgroundColor = color.cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: key)
            name.font = AppTheme.bodyFont
            name.textColor = AppTheme.textPrimary
            name.isBezeled = false
            name.drawsBackground = false
            name.lineBreakMode = .byTruncatingTail
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let barBg = NSView()
            barBg.wantsLayer = true
            barBg.layer?.backgroundColor = AppTheme.cardBorderColor.cgColor
            barBg.layer?.cornerRadius = 2
            barBg.translatesAutoresizingMaskIntoConstraints = false
            let barFill = NSView()
            barFill.wantsLayer = true
            barFill.layer?.backgroundColor = color.cgColor
            barFill.layer?.cornerRadius = 2
            barFill.translatesAutoresizingMaskIntoConstraints = false
            barBg.addSubview(barFill)
            let valueLabel = NSTextField(labelWithString: Fmt.tokens(Int(value)))
            valueLabel.font = AppTheme.monoFont
            valueLabel.textColor = AppTheme.textPrimary
            valueLabel.isBezeled = false
            valueLabel.drawsBackground = false
            valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let pctLabel = NSTextField(labelWithString: grand > 0 ? String(format: "%.1f%%", value / grand * 100) : "—")
            pctLabel.font = AppTheme.smallFont
            pctLabel.textColor = AppTheme.textTertiary
            pctLabel.isBezeled = false
            pctLabel.drawsBackground = false
            let line = NSStackView(views: [swatch, name, barBg, valueLabel, pctLabel])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 5
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                line.topAnchor.constraint(equalTo: row.topAnchor),
                line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                swatch.widthAnchor.constraint(equalToConstant: 6),
                swatch.heightAnchor.constraint(equalToConstant: 6),
                barBg.widthAnchor.constraint(equalToConstant: 46),
                barBg.heightAnchor.constraint(equalToConstant: 4),
                barFill.leadingAnchor.constraint(equalTo: barBg.leadingAnchor),
                barFill.topAnchor.constraint(equalTo: barBg.topAnchor),
                barFill.bottomAnchor.constraint(equalTo: barBg.bottomAnchor),
                barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor, multiplier: CGFloat(max(0.02, value / maxVal))),
            ])
            col.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }
        return col
    }

    private func renderHeatmapLegend(daily: [[String: Any]], metric: String, settings: [String: Any]) {
        heatmapLegend.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let maxValue = daily.map { UsageCore.doubleValue($0[metric]) }.max() ?? 0
        let levels: [(Int, String)] = [
            (0, "0"),
            (1, metric == "cost" ? "≤ " + Fmt.money(maxValue * 0.25, settings: settings) : "≤ 1M"),
            (2, metric == "cost" ? "≤ " + Fmt.money(maxValue * 0.5, settings: settings) : "≤ 10M"),
            (3, metric == "cost" ? "≤ " + Fmt.money(maxValue * 0.75, settings: settings) : "≤ 100M"),
            (4, metric == "cost" ? Fmt.money(maxValue, settings: settings) : Fmt.tokens(Int(maxValue))),
        ]
        for (level, label) in levels {
            let item = NSStackView()
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 3
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 2
            swatch.layer?.backgroundColor = HeatmapView.levelColor(level, metric: metric).cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: label)
            text.font = AppTheme.microFont
            text.textColor = AppTheme.textTertiary
            text.isBezeled = false
            text.drawsBackground = false
            item.addArrangedSubview(swatch)
            item.addArrangedSubview(text)
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 10),
                swatch.heightAnchor.constraint(equalToConstant: 10),
            ])
            heatmapLegend.addArrangedSubview(item)
        }
    }

    // MARK: - Trends render

    private func refreshTrends() {
        let history = history() ?? [:]
        var daily = (history["daily"] as? [[String: Any]]) ?? []
        if let range = Int(range) {
            daily = Array(daily.suffix(range))
        }
        if daily.isEmpty {
            emptyLabel.isHidden = false
            chartView.isHidden = true
            legendStack.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        chartView.isHidden = false
        legendStack.isHidden = mode == "kline"

        if mode == "kline" {
            let span = ChartCore.daysBetweenKeys(daily.first?["date"] as? String ?? "", daily.last?["date"] as? String ?? "") + 1
            let target = max(8, Int((chartView.bounds.width - 60) / 24))
            let bucketDays = span <= 10 ? 2 : max(3, Int(round(Double(span) / Double(target))))
            chartView.updateCandles(daily: daily, bucketDays: bucketDays)
        } else {
            chartView.updateBars(daily: daily, stackBy: stackBy)
            renderLegend(daily: daily)
        }
    }

    private func renderLegend(daily: [[String: Any]]) {
        let field = stackBy == "model" ? "perModel" : "perClient"
        var totals: [String: Double] = [:]
        for d in daily {
            let source = (d[field] as? [String: Any]) ?? [:]
            for (k, v) in source {
                if let entry = v as? [String: Any] {
                    totals[k, default: 0] += UsageCore.doubleValue(entry["tokens"])
                }
            }
        }
        let grand = totals.values.reduce(0, +)
        let rows = totals.filter { $0.value > 0 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        legendStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (key, value) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 3
            let color = stackBy == "model" ? AppTheme.modelColor(key) : AppTheme.clientColor(key)
            swatch.layer?.backgroundColor = color.cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: key)
            name.font = AppTheme.smallFont
            name.textColor = AppTheme.textSecondary
            name.isBezeled = false
            name.drawsBackground = false
            name.lineBreakMode = .byTruncatingTail
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let valueLabel = NSTextField(labelWithString: Fmt.tokens(Int(value)))
            valueLabel.font = AppTheme.monoFont
            valueLabel.textColor = AppTheme.textPrimary
            valueLabel.isBezeled = false
            valueLabel.drawsBackground = false
            let pctLabel = NSTextField(labelWithString: grand > 0 ? String(format: "%.1f%%", value / grand * 100) : "—")
            pctLabel.font = AppTheme.smallFont
            pctLabel.textColor = AppTheme.textTertiary
            pctLabel.isBezeled = false
            pctLabel.drawsBackground = false
            row.addArrangedSubview(swatch)
            row.addArrangedSubview(name)
            row.addArrangedSubview(valueLabel)
            row.addArrangedSubview(pctLabel)
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 8),
                swatch.heightAnchor.constraint(equalToConstant: 8),
            ])
            legendStack.addArrangedSubview(row)
        }
    }

    // MARK: - Controls

    private func applyTab(_ tab: String) {
        let overview = tab == "overview"
        overviewPane.isHidden = !overview
        trendsPane.isHidden = overview
        overviewTab.selectedBackground = overview ? AppTheme.accent.withAlphaComponent(0.16) : .clear
        trendsTab.selectedBackground = overview ? .clear : AppTheme.accent.withAlphaComponent(0.16)
        if overview { refreshOverview() } else { refreshTrends() }
    }

    private func applyRangeSelection() {
        for btn in rangeStack.arrangedSubviews.compactMap({ $0 as? HoverButton }) {
            let selected = btn.identifier?.rawValue == range
            btn.selectedBackground = selected ? AppTheme.accent.withAlphaComponent(0.16) : .clear
            btn.attributedTitle = NSAttributedString(string: btn.title, attributes: [
                .font: AppTheme.smallFont,
                .foregroundColor: selected ? AppTheme.accent : AppTheme.textTertiary,
            ])
        }
    }

    @objc private func tabClick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        applyTab(id)
    }

    @objc private func rangeClick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id != range else { return }
        range = id
        applyRangeSelection()
        refreshTrends()
    }

    @objc private func stackChange() {
        stackBy = stackSeg.selectedSegment == 1 ? "model" : "client"
        refreshTrends()
    }

    @objc private func modeChange() {
        mode = modeSeg.selectedSegment == 1 ? "kline" : "bars"
        refreshTrends()
    }

    @objc private func heatmapMetricChange() {
        let metric = heatmapMetricSeg.selectedSegment == 1 ? "cost" : "tokens"
        BridgeCore.shared.settings.update(["heatmapMetric": metric, "heatmapMetricExplicit": true])
        refreshOverview()
    }

    @objc private func refreshNow() {
        Collector.shared.refreshNow()
    }

    @objc private func close() {
        host?.hostRequestClose()
    }

    private func durationText(_ ms: Double) -> String {
        let totalMinutes = max(0, Int((ms / 60000).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    func windowWillTeardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
