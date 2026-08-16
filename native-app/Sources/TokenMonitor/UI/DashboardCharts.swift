import AppKit

// MARK: - 贡献热力图（原版 contribHeatmap + heatmapSvg）

final class HeatmapView: NSView {
    private var model: ChartCore.HeatmapModel?
    private var metric = "tokens"
    private var maxCost = 0.0

    override var isFlipped: Bool { true }

    static func levelColor(_ level: Int, metric: String) -> NSColor {
        switch level {
        case 4: return NSColor(calibratedRed: 180/255, green: 230/255, blue: 255/255, alpha: 1)
        case 3: return NSColor(calibratedRed: 150/255, green: 210/255, blue: 255/255, alpha: 0.8)
        case 2: return NSColor(calibratedRed: 120/255, green: 190/255, blue: 255/255, alpha: 0.45)
        case 1: return NSColor(calibratedRed: 90/255, green: 170/255, blue: 255/255, alpha: 0.18)
        default: return NSColor(white: 1, alpha: 0.03)
        }
    }

    private var lastDaily: [[String: Any]] = []
    private var lastMetric = "tokens"

    override func layout() {
        super.layout()
        if !lastDaily.isEmpty { rebuild() }
    }

    func update(daily: [[String: Any]], metric: String) {
        lastDaily = daily
        lastMetric = metric
        rebuild()
    }

    private func rebuild() {
        let daily = lastDaily
        let metric = lastMetric
        self.metric = metric
        maxCost = daily.map { ChartCore.n($0["cost"]) }.max() ?? 0
        let window = ChartCore.rollingYearWindow(endDate: ChartCore.localDayKey())
        let gap: CGFloat = 4
        let weeksEstimate = 53
        let avail: CGFloat = bounds.width > 10 ? bounds.width : 868
        let cell = max(9, min(22, (avail - CGFloat(weeksEstimate) * gap) / CGFloat(weeksEstimate)))

        let computed = daily.map { day -> [String: Any] in
            var d = day
            d["tokenIntensity"] = ChartCore.tokenHeatmapIntensity(ChartCore.n(day["tokens"]))
            d["costIntensity"] = ChartCore.heatmapIntensity(ChartCore.n(day["cost"]), maxCost)
            d["intensity"] = d["costIntensity"] ?? 0
            return d
        }
        model = ChartCore.contribHeatmap(
            computed, cell: cell, gap: gap,
            startDate: window.start, endDate: window.end,
            intensityKey: metric == "cost" ? "costIntensity" : "tokenIntensity"
        )
        if let model {
            frame.size = NSSize(width: model.width, height: model.height + 16)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let model else { return }
        ctx.clear(bounds)
        for cell in model.cells {
            let rect = CGRect(x: cell.x, y: cell.y, width: cell.size, height: cell.size)
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(Self.levelColor(cell.intensity, metric: metric).cgColor)
            ctx.fillPath()
        }
        // 月份标签
        let labelAttr: [NSAttributedString.Key: Any] = [
            .font: AppTheme.microFont, .foregroundColor: AppTheme.textTertiary,
        ]
        let pitch = model.cell + model.gap
        for (col, label) in model.monthLabels {
            let parts = label.split(separator: "-")
            guard parts.count >= 2 else { continue }
            let text = NSAttributedString(string: "\(Int(parts[1])!)月", attributes: labelAttr)
            text.draw(at: NSPoint(x: CGFloat(col) * pitch, y: model.height + 6))
        }
    }
}

// MARK: - Dashboard 趋势图（堆叠柱 / K线 + 悬停提示）

final class DashboardChartView: NSView {
    enum Kind { case bars, candles }
    private var kind: Kind = .bars
    private var barsModel: ChartCore.BarsModel?
    private var candleModel: ChartCore.CandleModel?
    private var stackBy = "client"
    private let tooltip = ChartTooltipView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        tooltip.isHidden = true
        addSubview(tooltip)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastDaily: [[String: Any]] = []
    private var lastStackBy = "client"
    private var lastBucketDays = 7

    override func layout() {
        super.layout()
        if !lastDaily.isEmpty {
            if kind == .candles {
                rebuildCandles()
            } else {
                rebuildBars()
            }
        }
    }

    func updateBars(daily: [[String: Any]], stackBy: String) {
        kind = .bars
        lastDaily = daily
        lastStackBy = stackBy
        rebuildBars()
    }

    func updateCandles(daily: [[String: Any]], bucketDays: Int) {
        kind = .candles
        lastDaily = daily
        lastBucketDays = bucketDays
        rebuildCandles()
    }

    private func rebuildBars() {
        stackBy = lastStackBy
        let w = max(320, bounds.width)
        let h = max(180, bounds.height)
        barsModel = ChartCore.dailyBarsModel(lastDaily, width: w, height: h, stackBy: lastStackBy)
        candleModel = nil
        needsDisplay = true
    }

    private func rebuildCandles() {
        let w = max(320, bounds.width)
        let h = max(180, bounds.height)
        candleModel = ChartCore.candleModel(lastDaily, width: w, height: h, bucketDays: lastBucketDays)
        barsModel = nil
        needsDisplay = true
    }

    private func colorFor(_ key: String) -> NSColor {
        return stackBy == "model" ? AppTheme.modelColor(key) : AppTheme.clientColor(key)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        switch kind {
        case .bars: drawBars(ctx)
        case .candles: drawCandles(ctx)
        }
    }

    private func drawGrid(ctx: CGContext, plot: CGRect, maxVal: Double) {
        let gridColor = AppTheme.lineColor.withAlphaComponent(0.5)
        let axisColor = AppTheme.lineColor.withAlphaComponent(1.3)
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(1)
        for i in 0...4 {
            let y = plot.minY + plot.height * CGFloat(i) / 4
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.strokePath()
            let value = maxVal * Double(4 - i) / 4
            let text = NSAttributedString(string: Fmt.tokens(Int(value)), attributes: [
                .font: AppTheme.microFont, .foregroundColor: AppTheme.textSecondary.withAlphaComponent(0.5),
            ])
            text.draw(at: NSPoint(x: plot.minX - 4 - text.size().width, y: y - 4))
        }
        // 基线
        ctx.setStrokeColor(axisColor.cgColor)
        ctx.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.strokePath()
    }

    private func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count >= 3 else { return key }
        return "\(Int(parts[1])!)/\(Int(parts[2])!)"
    }

    private func drawBars(_ ctx: CGContext) {
        guard let model = barsModel else { return }
        let plot = model.plot
        drawGrid(ctx: ctx, plot: plot, maxVal: model.maxTotal)
        let padBottom: CGFloat = 20
        let chartHeight = bounds.height - padBottom
        let scaleY = chartHeight / max(1, bounds.height)
        _ = scaleY

        for (i, bar) in model.bars.enumerated() {
            let top = bar.segments.count - 1
            for (si, seg) in bar.segments.enumerated() {
                guard seg.height > 0 else { continue }
                let rect = CGRect(x: seg.x, y: seg.y, width: seg.width, height: seg.height)
                ctx.setFillColor(colorFor(seg.key).cgColor)
                if si == top {
                    let path = CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
                    ctx.addPath(path)
                    ctx.fillPath()
                } else {
                    ctx.fill(rect)
                }
            }
            // X 轴标签（每 ~9 个标一个）
            let count = model.bars.count
            let every = max(1, Int(ceil(Double(count) / 9)))
            if i % every == 0 {
                let slot = plot.width / CGFloat(max(1, count))
                let x = plot.minX + CGFloat(i) * slot
                let text = NSAttributedString(string: shortDate(bar.label), attributes: [
                    .font: AppTheme.microFont, .foregroundColor: AppTheme.textTertiary,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: x + slot / 2 - size.width / 2, y: bounds.height - padBottom + 8))
            }
        }
    }

    private func drawCandles(_ ctx: CGContext) {
        guard let model = candleModel else { return }
        let plot = model.plot
        drawGrid(ctx: ctx, plot: plot, maxVal: model.maxVal)
        let padBottom: CGFloat = 20

        for (i, c) in model.candles.enumerated() {
            let up = c.up
            let bodyColor = up ? AppTheme.candleUp : AppTheme.candleDown
            ctx.setStrokeColor(bodyColor.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1)
            // 影线
            ctx.move(to: CGPoint(x: c.wickX, y: c.bodyY))
            ctx.addLine(to: CGPoint(x: c.wickX, y: c.yHigh))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: c.wickX, y: c.bodyY + c.bodyHeight))
            ctx.addLine(to: CGPoint(x: c.wickX, y: c.yLow))
            ctx.strokePath()
            // 实体
            let rect = CGRect(x: c.x, y: c.bodyY, width: c.width, height: c.bodyHeight)
            ctx.setFillColor(bodyColor.withAlphaComponent(0.9).cgColor)
            ctx.fill(rect)
            let count = model.candles.count
            let every = max(1, Int(ceil(Double(count) / 9)))
            if i % every == 0 {
                let text = NSAttributedString(string: shortDate(c.key), attributes: [
                    .font: AppTheme.microFont, .foregroundColor: AppTheme.textTertiary,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: c.wickX - size.width / 2, y: bounds.height - padBottom + 8))
            }
        }
    }

    // MARK: - Hover tooltip

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch kind {
        case .bars:
            guard let model = barsModel else { hideTooltip(); return }
            let plot = model.plot
            guard point.y >= plot.minY, point.y <= plot.maxY + 30 else { hideTooltip(); return }
            let slot = plot.width / CGFloat(max(1, model.bars.count))
            let index = Int((point.x - plot.minX) / slot)
            guard model.bars.indices.contains(index) else { hideTooltip(); return }
            let bar = model.bars[index]
            let segments = bar.segments.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            var lines: [(color: NSColor, name: String, value: String)] = [
                (color: .clear, name: shortDate(bar.label), value: Fmt.tokens(Int(bar.total)))
            ]
            for seg in segments {
                lines.append((color: colorFor(seg.key), name: seg.key, value: Fmt.tokens(Int(seg.value))))
            }
            showTooltip(lines: lines, at: point)
        case .candles:
            guard let model = candleModel else { hideTooltip(); return }
            let plot = model.plot
            guard point.y >= plot.minY, point.y <= plot.maxY + 30 else { hideTooltip(); return }
            let slot = plot.width / CGFloat(max(1, model.candles.count))
            let index = Int((point.x - plot.minX) / slot)
            guard model.candles.indices.contains(index) else { hideTooltip(); return }
            let c = model.candles[index]
            let head = c.endKey != c.key ? "\(shortDate(c.key)) – \(shortDate(c.endKey))" : shortDate(c.key)
            var lines: [(color: NSColor, name: String, value: String)] = [(color: .clear, name: head, value: "")]
            for (k, v) in [("O", c.open), ("H", c.high), ("L", c.low), ("C", c.close)] {
                lines.append((color: .clear, name: k, value: Fmt.tokens(Int(v))))
            }
            showTooltip(lines: lines, at: point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hideTooltip()
    }

    private func showTooltip(lines: [(color: NSColor, name: String, value: String)], at point: NSPoint) {
        tooltip.update(lines: lines)
        tooltip.sizeToFit()
        let pad: CGFloat = 10
        var x = point.x + pad
        var y = point.y + pad
        if x + tooltip.frame.width > bounds.width - 4 { x = point.x - tooltip.frame.width - pad }
        if y + tooltip.frame.height > bounds.height - 4 { y = point.y - tooltip.frame.height - pad }
        tooltip.frame.origin = NSPoint(x: max(4, x), y: max(4, y))
        tooltip.isHidden = false
        tooltip.needsDisplay = true
    }

    private func hideTooltip() {
        tooltip.isHidden = true
    }
}

// MARK: - Tooltip view

final class ChartTooltipView: NSView {
    private var lines: [(color: NSColor, name: String, value: String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 16/255, green: 21/255, blue: 30/255, alpha: 0.96).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(lines: [(color: NSColor, name: String, value: String)]) {
        self.lines = lines
        needsDisplay = true
    }

    func sizeToFit() {
        let width = lines.map { (name: $0.name, value: $0.value) }
            .map { ($0.name as NSString).size(withAttributes: [.font: AppTheme.smallFont]).width
                + ($0.value as NSString).size(withAttributes: [.font: AppTheme.monoFont]).width }
            .max() ?? 100
        frame.size = NSSize(width: width + 24, height: CGFloat(lines.count) * 17 + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        var y: CGFloat = 6
        for line in lines {
            let name = NSAttributedString(string: line.name, attributes: [
                .font: AppTheme.smallFont, .foregroundColor: AppTheme.textSecondary,
            ])
            let value = NSAttributedString(string: line.value, attributes: [
                .font: AppTheme.monoFont, .foregroundColor: AppTheme.textPrimary,
            ])
            let nameSize = name.size()
            name.draw(at: NSPoint(x: 10, y: y + 2))
            if line.value.isEmpty {
                y += 17
                continue
            }
            value.draw(at: NSPoint(x: bounds.width - 10 - value.size().width, y: y + 2))
            if line.color != .clear {
                ctx.setFillColor(line.color.cgColor)
                ctx.fillEllipse(in: CGRect(x: bounds.width - 10 - value.size().width - 10, y: y + 6, width: 6, height: 6))
            }
            y += 17
        }
    }
}
