import AppKit

/// 趋势视图（主窗口 trendsPanel）：按当前周期渲染 sparkline 柱状图 +
/// 统计卡片（活跃天数/连续天数/活跃时长/峰值日），右上「打开面板」跳转
/// 独立 Dashboard 窗口（原版 renderTrends）。
final class TrendsViewController: NSViewController, ContentUpdatable, WindowHostConsumer {
    weak var host: WindowHost?

    private let rangeLabel = NSTextField(labelWithString: "")
    private let openBtn = HoverButton(title: "↗")
    private let chartView = TrendsSparklineView()
    private let axisStack = NSStackView()
    private let statsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无趋势数据")
    private var lastSignature = ""

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear

        rangeLabel.font = AppTheme.smallFont
        rangeLabel.textColor = AppTheme.textTertiary
        rangeLabel.isBezeled = false
        rangeLabel.drawsBackground = false
        rangeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openBtn.font = AppTheme.bodyFont
        openBtn.toolTip = "打开用量面板"
        openBtn.target = self
        openBtn.action = #selector(openDashboard)

        let capRow = NSStackView(views: [rangeLabel, openBtn])
        capRow.orientation = .horizontal
        capRow.alignment = .centerY
        capRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(capRow)

        chartView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chartView)

        axisStack.orientation = .horizontal
        axisStack.distribution = .equalSpacing
        axisStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(axisStack)

        statsStack.orientation = .horizontal
        statsStack.alignment = .centerY
        statsStack.distribution = .fillEqually
        statsStack.spacing = 8
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statsStack)

        emptyLabel.font = AppTheme.bodyFont
        emptyLabel.textColor = AppTheme.textTertiary
        emptyLabel.isBezeled = false
        emptyLabel.drawsBackground = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        // 水平内缩由 shell（contentContainer）统一提供，这里不再叠加。
        NSLayoutConstraint.activate([
            capRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            capRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            capRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            chartView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chartView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chartView.topAnchor.constraint(equalTo: capRow.bottomAnchor, constant: 8),
            chartView.heightAnchor.constraint(equalToConstant: 90),
            axisStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            axisStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            axisStack.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 2),
            statsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statsStack.topAnchor.constraint(equalTo: axisStack.bottomAnchor, constant: 14),
            statsStack.heightAnchor.constraint(equalToConstant: 40),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
        ])
        view = root
    }

    func update(stats: [String: Any]?, period: String, settings: [String: Any]) {
        let preview = (stats?["historyPreview"] as? [String: Any]) ?? [:]
        var (points, labelKey) = ChartCore.selectPreviewSeries(preview, period: period)
        let periods = stats?["periods"] as? [String: Any]
        let todayDict = periods?["today"] as? [String: Any]
        let todayTotal = UsageCore.doubleValue(todayDict?["totalTokens"])
        if period == "today" {
            points = ChartCore.patchTodayBar(points, todayTotal: todayTotal)
        }

        let signature = "\(period):\(points.count):\(points.last?["tokens"] ?? 0)"
        guard !points.isEmpty else {
            emptyLabel.isHidden = false
            chartView.isHidden = true
            axisStack.isHidden = true
            statsStack.isHidden = true
            rangeLabel.stringValue = ""
            lastSignature = signature
            return
        }
        emptyLabel.isHidden = true
        chartView.isHidden = false
        axisStack.isHidden = false
        statsStack.isHidden = false

        let rangeLabelText: String
        switch period {
        case "allTime": rangeLabelText = "近 12 个月"
        case "month": rangeLabelText = "近 30 天"
        default: rangeLabelText = "近 7 天"
        }
        rangeLabel.stringValue = rangeLabelText

        let model = ChartCore.sparklineModel(points, width: 600, height: 90, gap: 0.3)
        chartView.update(model: model, showZeroMarkers: period == "today")

        axisStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let first = shortLabel(points.first?[labelKey] as? String ?? "", labelKey: labelKey)
        let last = shortLabel(points.last?[labelKey] as? String ?? "", labelKey: labelKey)
        for text in [first, last] {
            let label = NSTextField(labelWithString: text)
            label.font = AppTheme.microFont
            label.textColor = AppTheme.textTertiary
            label.isBezeled = false
            label.drawsBackground = false
            axisStack.addArrangedSubview(label)
        }

        let summary = (preview["summary"] as? [String: Any]) ?? [:]
        let stats: [(String, String)] = [
            ("活跃天数", Fmt.tokensExact(Int(UsageCore.doubleValue(summary["activeDays"])))),
            ("连续天数", Fmt.tokensExact(Int(UsageCore.doubleValue(summary["currentStreak"])))),
            ("活跃时长", durationText(UsageCore.doubleValue(summary["activeTimeMs"]))),
            ("峰值日", Fmt.tokens(Int(UsageCore.doubleValue(summary["peakDayTokens"])))),
        ]
        statsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (key, value) in stats {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 1
            let v = NSTextField(labelWithString: value)
            v.font = AppTheme.monoFont
            v.textColor = AppTheme.textPrimary
            v.isBezeled = false
            v.drawsBackground = false
            let k = NSTextField(labelWithString: key)
            k.font = AppTheme.microFont
            k.textColor = AppTheme.textTertiary
            k.isBezeled = false
            k.drawsBackground = false
            col.addArrangedSubview(v)
            col.addArrangedSubview(k)
            statsStack.addArrangedSubview(col)
        }
        lastSignature = signature
    }

    private func shortLabel(_ raw: String, labelKey: String) -> String {
        if labelKey == "month" {
            let parts = raw.split(separator: "-")
            guard parts.count >= 2 else { return raw }
            return "\(parts[1])月"
        }
        let parts = raw.split(separator: "-")
        guard parts.count >= 3 else { return raw }
        return "\(parts[1])/\(parts[2])"
    }

    private func durationText(_ ms: Double) -> String {
        let totalMinutes = max(0, Int((ms / 60000).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    @objc private func openDashboard() {
        host?.hostRequestOpenDashboard()
    }
}

// MARK: - Sparkline view

private final class TrendsSparklineView: NSView {
    private var model: ChartCore.SparklineModel?
    private var showZeroMarkers = false
    override var isFlipped: Bool { true }

    func update(model: ChartCore.SparklineModel, showZeroMarkers: Bool) {
        self.model = model
        self.showZeroMarkers = showZeroMarkers
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let model else { return }
        // ctx.clear() 会在 cacheDisplay/离屏合成时留下白底；这里本来就透明，
        // 不需要主动清除。
        let scaleX = bounds.width / max(1, model.width)
        let scaleY = bounds.height / max(1, model.height)
        for bar in model.bars {
            let rect = CGRect(x: bar.x * scaleX, y: bar.y * scaleY, width: max(1, bar.width * scaleX), height: max(0, bar.height * scaleY))
            if showZeroMarkers && bar.value == 0 {
                ctx.setStrokeColor(AppTheme.separatorColor.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: rect.minX, y: bounds.height - 0.5))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: bounds.height - 0.5))
                ctx.strokePath()
            } else {
                let color = bar.last ? AppTheme.accent : AppTheme.accent.withAlphaComponent(0.6)
                ctx.setFillColor(color.cgColor)
                let path = CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}
