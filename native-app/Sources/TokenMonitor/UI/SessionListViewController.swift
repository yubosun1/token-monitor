import AppKit

/// 会话列表（session 维度明细）。从 period.sessions 取出会话，按最近使用时间
/// 降序渲染；点击某行请求打开会话详情（经 onSelect 回调交给主控制器弹出）。
final class SessionListViewController: NSViewController, ContentUpdatable {
    /// 行点击回调：(client, sessionId, period, sessionCost)。
    var onSelect: ((String, String, String, Double) -> Void)?

    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无会话")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = rowsStack
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
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
        ])
        view = container
    }

    func update(stats: [String: Any]?, period: String, settings: [String: Any]) {
        let periods = stats?["periods"] as? [String: Any]
        let periodDict = periods?[period] as? [String: Any]
        let sessions = periodDict?["sessions"] as? [String: Any] ?? [:]

        var rows: [(client: String, sessionId: String, tokens: Int, cost: Double, msgs: Int, lastUsedMs: Double, projectLabel: String, models: [String: Any])] = []
        for (_, value) in sessions {
            guard let s = value as? [String: Any] else { continue }
            let client = s["client"] as? String ?? ""
            let sid = s["sessionId"] as? String ?? ""
            let lastMs = UsageCore.timestampMs(s["lastUsedAt"])
            rows.append((
                client, sid,
                UsageCore.intValue(s["totalTokens"]),
                UsageCore.doubleValue(s["costUsd"]),
                UsageCore.intValue(s["messageCount"]),
                lastMs,
                s["projectLabel"] as? String ?? "",
                s["models"] as? [String: Any] ?? [:]
            ))
        }
        rows.sort { $0.lastUsedMs > $1.lastUsedMs }

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !rows.isEmpty
        for r in rows {
            let row = SessionRowView()
            row.configure(client: r.client, sessionId: r.sessionId, tokens: r.tokens,
                          cost: r.cost, messages: r.msgs, lastUsedMs: r.lastUsedMs,
                          projectLabel: r.projectLabel, models: r.models, settings: settings)
            row.onSelect = { [weak self] in
                self?.onSelect?(r.client, r.sessionId, period, r.cost)
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        rowsStack.addArrangedSubview(spacer)
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }
}

// MARK: - Row

private final class SessionRowView: NSView {
    var onSelect: (() -> Void)?

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let barBg = NSView()
    private let barFill = NSView()
    private var barFillWidth: NSLayoutConstraint?
    private var hover = false
    private var tracking: NSTrackingArea?

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

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        configureLabel(titleLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(metaLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        configureLabel(detailLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        configureLabel(tokensLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.alphaValue = 0.84
        tokensLabel.alignment = .right
        costLabel.alignment = .right

        let labelStack = NSStackView(views: [titleLabel, metaLabel, detailLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView(views: [dot, labelStack])
        nameRow.orientation = .horizontal
        nameRow.alignment = .top
        nameRow.spacing = 7

        let metrics = NSStackView(views: [tokensLabel, costLabel])
        metrics.orientation = .vertical
        metrics.alignment = .trailing
        metrics.spacing = 2
        metrics.widthAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true

        let head = NSStackView(views: [nameRow, metrics])
        head.orientation = .horizontal
        head.alignment = .top
        head.spacing = 8
        nameRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metrics.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor(calibratedRed: 4/255, green: 8/255, blue: 13/255, alpha: 0.46).cgColor
        barBg.layer?.cornerRadius = 2.5
        barBg.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 2.5
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBg.addSubview(barFill)

        let stack = NSStackView(views: [head, barBg])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
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
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            barBg.heightAnchor.constraint(equalToConstant: 5),
            barBg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barFill.leadingAnchor.constraint(equalTo: barBg.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBg.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBg.bottomAnchor),
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

    func configure(client: String, sessionId: String, tokens: Int, cost: Double, messages: Int, lastUsedMs: Double, projectLabel: String, models: [String: Any], settings: [String: Any]) {
        dot.layer?.backgroundColor = AppTheme.clientColor(client).cgColor
        let label = AppTheme.clientLabel(client)

        // 标题：Client · Model（无模型信息时回落项目名，再回落会话 id 前 8 位）。
        let modelNames = models.keys.filter { UsageCore.doubleValue(models[$0]) > 0 }.sorted()
        let modelLabel = modelNames.count == 1 ? modelNames[0] : modelNames.count > 1 ? "\(modelNames.count) 个模型" : ""
        let suffix = !modelLabel.isEmpty ? modelLabel : (!projectLabel.isEmpty ? projectLabel : String(sessionId.prefix(8)))
        titleLabel.stringValue = "\(label) · \(suffix)"
        tokensLabel.stringValue = Fmt.tokensExact(tokens)
        costLabel.stringValue = Fmt.money(cost, settings: settings)

        let time = compactSessionTime(lastUsedMs)
        var meta = messages > 0 ? "\(Fmt.tokensExact(messages)) msgs" : ""
        if !time.isEmpty { meta = meta.isEmpty ? time : "\(time) · \(meta)" }
        metaLabel.stringValue = meta
        let detail = sessionIdLabel(sessionId)
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty

        let fraction = tokens > 0 ? min(1.0, CGFloat(tokens) / 500_000) : 0
        barFillWidth?.isActive = false
        barFillWidth = barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor, multiplier: max(0.02, fraction))
        barFillWidth?.isActive = true
    }

    /// 原版 compactSessionTime：今天显示 HH:mm，否则 MM/dd HH:mm。
    private func compactSessionTime(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let now = Date()
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if cal.isDate(date, inSameDayAs: now) {
            return time.string(from: date)
        }
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: date)
    }

    /// 原版 sessionIdLabel：去掉 rollout 前缀与时间戳型 id。
    private func sessionIdLabel(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        if value.range(of: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}[:-]\d{2}[:-]\d{2}-(.+)$"#, options: .regularExpression) != nil {
            return value.replacingOccurrences(
                of: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}[:-]\d{2}[:-]\d{2}-"#,
                with: "", options: .regularExpression
            )
        }
        if value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}[:-]\d{2}"#, options: .regularExpression) != nil {
            return ""
        }
        return value
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hover = true; layer?.backgroundColor = AppTheme.panelColor.cgColor }
    override func mouseExited(with event: NSEvent) { hover = false; layer?.backgroundColor = .clear }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}
