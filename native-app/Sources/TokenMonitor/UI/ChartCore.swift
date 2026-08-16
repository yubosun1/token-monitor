import Foundation
import CoreGraphics

/// 图表模型层：把原版 usageCharts.js 的纯函数算法移植为 Swift 结构。
/// 视图层（TrendsChartView / HeatmapView 等）只负责把这些模型画出来，
/// 数值口径与原版一致（stacked bars、candle、贡献热力图、sparkline）。
enum ChartCore {

    // MARK: - 日期工具（与 usageCharts 相同的 UTC 锚定字符串算术）

    static func localDayKey(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func addDaysUTC(_ key: String, _ delta: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: String(key.prefix(10))) else { return key }
        let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: delta, to: date) ?? date
        return f.string(from: next)
    }

    static func daysBetweenKeys(_ a: String, _ b: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let da = f.date(from: String(a.prefix(10))), let db = f.date(from: String(b.prefix(10))) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86400).rounded())
    }

    /// 0 = Sunday … 6 = Saturday（GitHub 风格贡献热力图）。
    static func dayOfWeekSun(_ key: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: String(key.prefix(10))) else { return 0 }
        return Calendar(identifier: .gregorian).component(.weekday, from: date) - 1
    }

    // MARK: - 数值

    static func n(_ value: Any?) -> Double {
        guard let value else { return 0 }
        if let d = value as? Double, d.isFinite { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return 0
    }

    static func intN(_ value: Any?) -> Int {
        return max(0, Int(n(value).rounded()))
    }

    static func sumMetric(_ map: [String: Any]?, _ metric: String) -> Double {
        guard let map else { return 0 }
        var total = 0.0
        for v in map.values {
            if let entry = v as? [String: Any] { total += n(entry[metric]) }
        }
        return total
    }

    // MARK: - 热力图亮度（原版 computeHeatmapIntensities）

    /// Token 用绝对量分带（1M/10M/100M），cost 用相对 max 比例。
    static func tokenHeatmapIntensity(_ value: Double) -> Int {
        if value >= 100_000_000 { return 4 }
        if value >= 10_000_000 { return 3 }
        if value >= 1_000_000 { return 2 }
        return value > 0 ? 1 : 0
    }

    static func heatmapIntensity(_ value: Double, _ max: Double) -> Int {
        guard max > 0 else { return 0 }
        let ratio = value / max
        if ratio >= 0.75 { return 4 }
        if ratio >= 0.5 { return 3 }
        if ratio >= 0.25 { return 2 }
        return ratio > 0 ? 1 : 0
    }

    static func heatmapLevelForValue(_ value: Double, _ max: Double, metric: String) -> Int {
        return metric == "cost" ? heatmapIntensity(value, max) : tokenHeatmapIntensity(value)
    }

    // MARK: - Sparkline（原版 selectPreviewSeries / patchTodayBar / sparklinePreview）

    struct SparkBar {
        let value: Double
        let x: CGFloat
        let width: CGFloat
        let y: CGFloat
        let height: CGFloat
        let last: Bool
        let date: String
    }

    struct SparklineModel {
        let width: CGFloat
        let height: CGFloat
        let maxVal: Double
        let bars: [SparkBar]
    }

    /// 主窗口 Trends 视图取数：allTime→月线；month→当月逐日；today→最近 7 天。
    static func selectPreviewSeries(_ preview: [String: Any]?, period: String) -> (points: [[String: Any]], labelKey: String) {
        let daily = (preview?["daily"] as? [[String: Any]]) ?? []
        let monthly = (preview?["monthly"] as? [[String: Any]]) ?? []
        if period == "allTime" { return (monthly, "month") }
        if period == "month" {
            let latest = daily.last.flatMap { String(($0["date"] as? String ?? "").prefix(7)) } ?? ""
            return (daily.filter { String(($0["date"] as? String ?? "").prefix(7)) == latest }, "date")
        }
        return (Array(daily.suffix(7)), "date")
    }

    /// 把今日实时总量补进 7 天窗口（稀疏历史不把空天挤掉）。
    static func patchTodayBar(_ points: [[String: Any]], todayTotal: Double) -> [[String: Any]] {
        if points.isEmpty && todayTotal == 0 { return [] }
        let today = localDayKey()
        var byDate: [String: [String: Any]] = [:]
        for point in points {
            let key = String(point["date"] as? String ?? "")
            if key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                byDate[key] = point
            }
        }
        var result: [[String: Any]] = []
        for offset in (-6...0) {
            let key = addDaysUTC(today, offset)
            if var point = byDate[key] {
                if key == today { point["tokens"] = todayTotal }
                result.append(point)
            } else {
                result.append(["date": key, "tokens": key == today ? todayTotal : 0])
            }
        }
        return result
    }

    static func sparklineModel(_ points: [[String: Any]], width: CGFloat, height: CGFloat, gap: CGFloat = 0.25, metric: String = "tokens") -> SparklineModel {
        let maxVal = max(1, points.map { n($0[metric]) }.max() ?? 1)
        let slot = points.isEmpty ? width : width / CGFloat(points.count)
        let barWidth = slot * (1 - gap)
        let bars = points.enumerated().map { (i, p) -> SparkBar in
            let value = n(p[metric])
            let h = height * CGFloat(value / maxVal)
            return SparkBar(
                value: value,
                x: CGFloat(i) * slot + (slot - barWidth) / 2,
                width: barWidth,
                y: height - h,
                height: h,
                last: i == points.count - 1,
                date: p["date"] as? String ?? ""
            )
        }
        return SparklineModel(width: width, height: height, maxVal: maxVal, bars: bars)
    }

    // MARK: - 堆叠柱（原版 dailyBarsChart）

    struct BarSegment {
        let key: String
        let value: Double
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    struct DayBar {
        let label: String
        let total: Double
        let segments: [BarSegment]
    }

    struct BarsModel {
        let plot: CGRect
        let maxTotal: Double
        let keys: [String]
        let bars: [DayBar]
    }

    static func dailyBarsModel(_ series: [[String: Any]], width: CGFloat, height: CGFloat, padTop: CGFloat = 10, padRight: CGFloat = 14, padBottom: CGFloat = 24, padLeft: CGFloat = 46, gap: CGFloat = 0.3, stackBy: String = "client", metric: String = "tokens") -> BarsModel {
        let field = stackBy == "model" ? "perModel" : "perClient"
        var keyTotals: [String: Double] = [:]
        for e in series {
            let source = (e[field] as? [String: Any]) ?? [:]
            for (k, v) in source {
                if let entry = v as? [String: Any] {
                    keyTotals[k, default: 0] += n(entry[metric])
                }
            }
        }
        let keys = keyTotals.keys.sorted { (keyTotals[$0] ?? 0) > (keyTotals[$1] ?? 0) || ($0 < $1) }

        let totals = series.map { sumMetric($0[field] as? [String: Any], metric) }
        let maxTotal = max(1, totals.max() ?? 1)
        let innerW = width - padLeft - padRight
        let innerH = height - padTop - padBottom
        let slot = series.isEmpty ? innerW : innerW / CGFloat(series.count)
        let barWidth = slot * (1 - gap)

        let bars = series.enumerated().map { (i, e) -> DayBar in
            let x = padLeft + CGFloat(i) * slot + (slot - barWidth) / 2
            let source = (e[field] as? [String: Any]) ?? [:]
            var cum: CGFloat = 0
            var segments: [BarSegment] = []
            for k in keys {
                guard let entry = source[k] as? [String: Any] else { continue }
                let value = n(entry[metric])
                let h = innerH * CGFloat(value / maxTotal)
                segments.append(BarSegment(key: k, value: value, x: x, y: padTop + innerH - cum - h, width: barWidth, height: h))
                cum += h
            }
            return DayBar(label: e["date"] as? String ?? "", total: totals[i], segments: segments)
        }
        return BarsModel(plot: CGRect(x: padLeft, y: padTop, width: innerW, height: innerH), maxTotal: maxTotal, keys: keys, bars: bars)
    }

    // MARK: - K 线蜡烛（原版 candleChart）

    struct Candle {
        let key: String
        let endKey: String
        let days: Int
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let up: Bool
        let x: CGFloat
        let width: CGFloat
        let wickX: CGFloat
        let yHigh: CGFloat
        let yLow: CGFloat
        let bodyY: CGFloat
        let bodyHeight: CGFloat
    }

    struct CandleModel {
        let plot: CGRect
        let bucketDays: Int
        let maxVal: Double
        let candles: [Candle]
    }

    static func candleModel(_ daily: [[String: Any]], width: CGFloat, height: CGFloat, padTop: CGFloat = 10, padRight: CGFloat = 14, padBottom: CGFloat = 24, padLeft: CGFloat = 46, gap: CGFloat = 0.3, metric: String = "tokens", bucketDays: Int = 7) -> CandleModel {
        let days = daily
            .map { (date: String(($0["date"] as? String ?? "").prefix(10)), value: n($0[metric])) }
            .sorted { $0.date < $1.date }
        let bucket = max(1, bucketDays)

        var base: [(key: String, endKey: String, days: Int, open: Double, close: Double, high: Double, low: Double, up: Bool)] = []
        if let lastDate = days.last?.date {
            var groups: [Int: [(date: String, value: Double)]] = [:]
            for d in days {
                let idx = daysBetweenKeys(d.date, lastDate) / bucket
                groups[idx, default: []].append(d)
            }
            for idx in groups.keys.sorted(by: >) {
                let ds = groups[idx]!
                let values = ds.map { $0.value }
                base.append((
                    key: ds[0].date,
                    endKey: ds[ds.count - 1].date,
                    days: ds.count,
                    open: ds[0].value,
                    close: ds[ds.count - 1].value,
                    high: values.max() ?? 0,
                    low: values.min() ?? 0,
                    up: ds[ds.count - 1].value >= ds[0].value
                ))
            }
        }

        let maxVal = max(1, base.map { $0.high }.max() ?? 1)
        let innerW = width - padLeft - padRight
        let innerH = height - padTop - padBottom
        let slot = base.isEmpty ? innerW : innerW / CGFloat(base.count)
        let bodyW = slot * (1 - gap)
        let yOf = { (v: Double) -> CGFloat in padTop + innerH - innerH * CGFloat(v / maxVal) }

        let candles = base.enumerated().map { (i, c) -> Candle in
            let x = padLeft + CGFloat(i) * slot + (slot - bodyW) / 2
            let top = max(c.open, c.close)
            let bottom = min(c.open, c.close)
            let bodyY = yOf(top)
            return Candle(
                key: c.key, endKey: c.endKey, days: c.days,
                open: c.open, high: c.high, low: c.low, close: c.close, up: c.up,
                x: x, width: bodyW, wickX: x + bodyW / 2,
                yHigh: yOf(c.high), yLow: yOf(c.low),
                bodyY: bodyY, bodyHeight: max(1, yOf(bottom) - bodyY)
            )
        }
        return CandleModel(plot: CGRect(x: padLeft, y: padTop, width: innerW, height: innerH), bucketDays: bucket, maxVal: maxVal, candles: candles)
    }

    // MARK: - 贡献热力图（原版 contribHeatmap）

    struct HeatCell {
        let date: String
        let intensity: Int
        let tokens: Double
        let cost: Double
        let col: Int
        let row: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
    }

    struct HeatmapModel {
        let cells: [HeatCell]
        let weeks: Int
        let monthLabels: [(col: Int, label: String)]
        let cell: CGFloat
        let gap: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// 滚动年窗口：从 11 个月前月初到今天（原版 renderActivity 的 startDate 算法）。
    static func rollingYearWindow(endDate: String) -> (start: String, end: String) {
        let end = String(endDate.prefix(10))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let endDateObj = f.date(from: end) ?? Date()
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: endDateObj)
        let startOfMonth = Calendar(identifier: .gregorian).date(from: comps) ?? endDateObj
        let start = Calendar(identifier: .gregorian).date(byAdding: .month, value: -11, to: startOfMonth) ?? startOfMonth
        return (f.string(from: start), end)
    }

    static func contribHeatmap(_ daily: [[String: Any]], cell: CGFloat, gap: CGFloat, startDate: String?, endDate: String?, intensityKey: String) -> HeatmapModel {
        var intensities: [String: Double] = [:]
        var values: [String: (tokens: Double, cost: Double)] = [:]
        var minDate = startDate.map { String($0.prefix(10)) }
        var maxDate = endDate.map { String($0.prefix(10)) }
        for d in daily {
            let key = String((d["date"] as? String ?? "").prefix(10))
            guard !key.isEmpty else { continue }
            intensities[key] = n(d[intensityKey])
            values[key] = (n(d["tokens"]), n(d["cost"]))
            if startDate == nil && (minDate == nil || key < minDate!) { minDate = key }
            if endDate == nil && (maxDate == nil || key > maxDate!) { maxDate = key }
        }
        guard let minDate, let maxDate else {
            return HeatmapModel(cells: [], weeks: 0, monthLabels: [], cell: cell, gap: gap, width: 0, height: 0)
        }

        let start = addDaysUTC(minDate, -dayOfWeekSun(minDate))
        var cells: [HeatCell] = []
        var monthLabels: [(Int, String)] = []
        var key = start
        while key <= maxDate {
            let days = daysBetweenKeys(start, key)
            let col = days / 7
            let row = dayOfWeekSun(key)
            if key.hasSuffix("-01") { monthLabels.append((col, String(key.prefix(7)))) }
            let value = values[key] ?? (0, 0)
            cells.append(HeatCell(
                date: key,
                intensity: Int(intensities[key] ?? 0),
                tokens: value.tokens, cost: value.cost,
                col: col, row: row,
                x: CGFloat(col) * (cell + gap), y: CGFloat(row) * (cell + gap),
                size: cell
            ))
            key = addDaysUTC(key, 1)
        }
        let weeks = cells.isEmpty ? 0 : cells[cells.count - 1].col + 1
        return HeatmapModel(
            cells: cells, weeks: weeks, monthLabels: monthLabels,
            cell: cell, gap: gap,
            width: weeks > 0 ? CGFloat(weeks) * (cell + gap) - gap : 0,
            height: 7 * (cell + gap) - gap
        )
    }

    /// 今日实时值补进 daily（原版 patchDailyToday）。
    static func patchDailyToday(_ daily: [[String: Any]], todayDate: String, todayTotal: Double, todayCost: Double) -> [[String: Any]] {
        var rows = daily
        let date = String(todayDate.prefix(10))
        guard !date.isEmpty else { return rows }
        if let idx = rows.firstIndex(where: { String(($0["date"] as? String ?? "").prefix(10)) == date }) {
            var row = rows[idx]
            row["tokens"] = todayTotal
            row["cost"] = todayCost
            rows[idx] = row
        } else {
            rows.append(["date": date, "tokens": todayTotal, "cost": todayCost])
        }
        return rows
    }
}
