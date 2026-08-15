import AppKit

/// 独立 Dashboard 窗口内容：概览卡片（今日/本月/全部）+ 近 30 天趋势柱状图。
///
/// 取代原 dashboard.html。趋势图用 Core Graphics 自绘柱状图（按日 total tokens），
/// 简化掉原版的 K 线/热力图/堆叠分色。数据监听 DataBus.statsUpdated 与
/// historyUpdated，分别刷新卡片与图表。
final class DashboardViewController: NSViewController, WindowHostConsumer, WindowTeardownObserver {
    weak var host: WindowHost?

    private let cardsStack = NSStackView()
    private let chartView = TrendsChartView()
    private let chartSegmented = NSSegmentedControl(labels: ["Tokens", "Cost"], trackingMode: .selectOne, target: nil, action: nil)
    private let todayCard = PeriodCardView(title: "今日")
    private let monthCard = PeriodCardView(title: "本月")
    private let allTimeCard = PeriodCardView(title: "全部")
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = AppTheme.cardColor.cgColor

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
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        cardsStack.orientation = .horizontal
        cardsStack.alignment = .top
        cardsStack.distribution = .fillEqually
        cardsStack.spacing = 10
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        for c in [todayCard, monthCard, allTimeCard] { cardsStack.addArrangedSubview(c) }
        root.addSubview(cardsStack)

        let chartTitle = NSTextField(labelWithString: "近 30 天趋势")
        chartTitle.font = AppTheme.titleFont
        chartTitle.textColor = AppTheme.textPrimary
        chartTitle.isBezeled = false
        chartTitle.drawsBackground = false
        chartTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chartTitle)

        chartSegmented.target = self
        chartSegmented.action = #selector(metricChange)
        chartSegmented.selectedSegment = 0
        chartSegmented.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chartSegmented)

        chartView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chartView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            cardsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            cardsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            chartTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            chartTitle.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 18),
            chartSegmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            chartSegmented.centerYAnchor.constraint(equalTo: chartTitle.centerYAnchor),
            chartView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            chartView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            chartView.topAnchor.constraint(equalTo: chartTitle.bottomAnchor, constant: 10),
            chartView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: DataBus.statsUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.refreshCards()
        })
        observers.append(center.addObserver(forName: DataBus.historyUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.refreshChart()
        })
        refreshCards()
        refreshChart()
    }

    private func refreshCards() {
        let stats = Collector.shared.latestStats()
        let settings = BridgeCore.shared.settings.snapshot()
        let periods = stats?["periods"] as? [String: Any] ?? [:]
        todayCard.update(period: periods["today"] as? [String: Any], settings: settings)
        monthCard.update(period: periods["month"] as? [String: Any], settings: settings)
        allTimeCard.update(period: periods["allTime"] as? [String: Any], settings: settings)
    }

    private func refreshChart() {
        let history = Collector.shared.history()
        let daily = (history?["daily"] as? [[String: Any]]) ?? []
        let days = daily.suffix(30).map { (
            date: $0["date"] as? String ?? "",
            tokens: UsageCore.intValue($0["tokens"]),
            cost: UsageCore.doubleValue($0["cost"])
        ) }
        chartView.update(days: days, metric: chartSegmented.selectedSegment == 1 ? .cost : .tokens)
    }

    @objc private func metricChange() {
        refreshChart()
    }

    @objc private func refreshNow() {
        Collector.shared.refreshNow()
    }

    @objc private func close() {
        host?.hostRequestClose()
    }

    func windowWillTeardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

// MARK: - Period card

private final class PeriodCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "0")
    private let costLabel = NSTextField(labelWithString: "$0.00")

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = AppTheme.cardColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.cardBorderColor.cgColor

        configureLabel(titleLabel, font: AppTheme.smallFont, color: AppTheme.textTertiary)
        configureLabel(tokensLabel, font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium), color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.bodyFont, color: AppTheme.textSecondary)

        let stack = NSStackView(views: [titleLabel, tokensLabel, costLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
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

    func update(period: [String: Any]?, settings: [String: Any]) {
        let tokens = UsageCore.intValue(period?["totalTokens"])
        let cost = UsageCore.doubleValue(period?["costUsd"])
        tokensLabel.stringValue = Fmt.tokens(tokens)
        costLabel.stringValue = Fmt.money(cost, settings: settings)
    }
}

// MARK: - Trends chart (Core Graphics)

enum TrendsMetric { case tokens, cost }

final class TrendsChartView: NSView {
    private var days: [(date: String, tokens: Int, cost: Double)] = []
    private var metric: TrendsMetric = .tokens

    override var isFlipped: Bool { true }

    func update(days: [(date: String, tokens: Int, cost: Double)], metric: TrendsMetric) {
        self.days = days
        self.metric = metric
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        ctx.setFillColor(NSColor.clear.cgColor)
        ctx.fill(dirtyRect)

        let padTop: CGFloat = 8
        let padBottom: CGFloat = 22
        let padX: CGFloat = 4
        let chartHeight = bounds.height - padTop - padBottom
        let chartWidth = bounds.width - padX * 2

        guard !days.isEmpty, chartHeight > 0, chartWidth > 0 else {
            let attr: [NSAttributedString.Key: Any] = [
                .font: AppTheme.bodyFont, .foregroundColor: AppTheme.textTertiary,
            ]
            let text = NSAttributedString(string: "暂无趋势数据", attributes: attr)
            text.draw(at: NSPoint(x: bounds.midX - 40, y: bounds.midY))
            return
        }

        let maxValue: Double = metric == .tokens
            ? Double(days.map(\.tokens).max() ?? 1)
            : days.map(\.cost).max() ?? 1
        let safeMax = max(maxValue, 1)
        let count = days.count
        let barGap: CGFloat = 2
        let barWidth = max(1, (chartWidth - CGFloat(count - 1) * barGap) / CGFloat(count))

        // 基线
        ctx.setStrokeColor(AppTheme.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: padX, y: padTop + chartHeight))
        ctx.addLine(to: CGPoint(x: padX + chartWidth, y: padTop + chartHeight))
        ctx.strokePath()

        for (i, day) in days.enumerated() {
            let value = metric == .tokens ? Double(day.tokens) : day.cost
            let h = CGFloat(value / safeMax) * chartHeight
            let x = padX + CGFloat(i) * (barWidth + barGap)
            let r = CGRect(x: x, y: padTop + chartHeight - h, width: barWidth, height: h)
            ctx.setFillColor(AppTheme.accent.cgColor)
            ctx.fill(r)
        }

        // 日期标签（稀疏：首/中/末）
        let labelAttr: [NSAttributedString.Key: Any] = [
            .font: AppTheme.microFont, .foregroundColor: AppTheme.textTertiary,
        ]
        func labelAt(_ index: Int) {
            guard days.indices.contains(index) else { return }
            let date = days[index].date
            let short = date.count >= 5 ? String(date.suffix(5)) : date
            let x = padX + CGFloat(index) * (barWidth + barGap) + barWidth / 2
            let s = NSAttributedString(string: short, attributes: labelAttr)
            let size = s.size()
            s.draw(at: NSPoint(x: x - size.width / 2, y: padTop + chartHeight + 6))
        }
        labelAt(0)
        labelAt(count / 2)
        labelAt(count - 1)
    }
}
