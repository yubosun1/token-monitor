import AppKit

/// 会话列表（session 维度明细）。从 period.sessions 取出会话，按最近使用时间
/// 降序渲染；点击某行请求打开会话详情（经 onSelect 回调交给主控制器弹出）。
final class SessionListViewController: NSViewController, ContentUpdatable {
    /// 行点击回调：(client, sessionId, period, sessionCost)。
    var onSelect: ((String, String, String, Double) -> Void)?

    private let scrollView = TopAnchoredScrollView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无会话")
    /// Pooled row views, reconfigured in place on every stats push.
    private var rowViews: [SessionRowView] = []
    private var bottomSpacer: NSView?

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
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
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

        emptyLabel.isHidden = !rows.isEmpty
        // 原版 renderRows：条宽相对列表内最大值，不是固定分母。
        let maxTokens = max(1, rows.map(\.tokens).max() ?? 1)

        // Session lists can run to hundreds of rows and refresh every 15s;
        // reuse the views instead of rebuilding the stack each push.
        while rowViews.count < rows.count {
            let row = SessionRowView()
            rowViews.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        for (index, row) in rowViews.enumerated() {
            guard index < rows.count else {
                row.isHidden = true
                row.onSelect = nil
                continue
            }
            let r = rows[index]
            row.isHidden = false
            row.configure(client: r.client, sessionId: r.sessionId, tokens: r.tokens,
                          cost: r.cost, messages: r.msgs, lastUsedMs: r.lastUsedMs,
                          projectLabel: r.projectLabel, models: r.models,
                          maxTokens: maxTokens, settings: settings)
            row.onSelect = { [weak self] in
                self?.onSelect?(r.client, r.sessionId, period, r.cost)
            }
        }

        if bottomSpacer == nil {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
            bottomSpacer = spacer
        }
        if let bottomSpacer {
            // Keep the spacer last as rows are appended above it. removeView
            // throws if the view was never added, so only move an attached one.
            if rowsStack.arrangedSubviews.contains(bottomSpacer) {
                rowsStack.removeView(bottomSpacer)
            }
            rowsStack.addArrangedSubview(bottomSpacer)
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

// MARK: - Row

private final class SessionRowView: NSView {
    var onSelect: (() -> Void)?

    private let mark = RowMarkView(size: 10)
    private let chevron = NSTextField(labelWithString: "›")
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

        // 原版 .row-metrics::after：可打开详情的会话行右侧有 › 提示。
        configureLabel(chevron, font: NSFont.systemFont(ofSize: 14, weight: .regular), color: AppTheme.textSecondary)

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
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // The intermediate stack keeps NSStackView's default (high) compression
        // resistance, which would out-rank the title's low setting and force the
        // metrics column to truncate instead of the title.
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView(views: [mark, labelStack])
        nameRow.orientation = .horizontal
        nameRow.alignment = .firstBaseline
        nameRow.spacing = 8

        // 数值列不许丢数字（标题才截断）。
        for label in [tokensLabel, costLabel] {
            label.lineBreakMode = .byClipping
            label.cell?.truncatesLastVisibleLine = false
        }

        let metrics = NSStackView(views: [tokensLabel, costLabel])
        metrics.orientation = .vertical
        metrics.alignment = .trailing
        metrics.spacing = 2

        // 原版 .row-head 是 space-between：标题靠左、数值 + › 靠右。
        let headSpacer = NSView()
        headSpacer.translatesAutoresizingMaskIntoConstraints = false
        headSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [nameRow, headSpacer, metrics, chevron])
        head.orientation = .horizontal
        head.alignment = .top
        head.spacing = 8
        nameRow.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // NSStackView ignores setContentCompressionResistancePriority — the
        // stack-level equivalent is setClippingResistancePriority. Without it
        // the metrics column shrinks and the numbers render truncated.
        metrics.setHuggingPriority(.required, for: .horizontal)
        metrics.setClippingResistancePriority(.required, for: .horizontal)
        labelStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        nameRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        // 原版 .row-metrics min-width: max-content —— 数值不压缩，标题才截断。
        for label in [tokensLabel, costLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = AppTheme.sunkenColor.withAlphaComponent(0.46).cgColor
        barBg.layer?.cornerRadius = 3
        barBg.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
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
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            barBg.heightAnchor.constraint(equalToConstant: 6),
            barBg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // 头行撑满，否则右侧数值列会被挤成省略号。
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    /// 原版只有这几个客户端有会话详情面板（.row.session-row[data-client=...]）。
    private static let detailCapableClients: Set<String> = ["claude", "codex", "opencode", "reasonix"]

    func configure(client: String, sessionId: String, tokens: Int, cost: Double, messages: Int, lastUsedMs: Double, projectLabel: String, models: [String: Any], maxTokens: Int, settings: [String: Any]) {
        mark.configure(
            asset: IconCatalog.clientAsset(client),
            color: AppTheme.clientColor(client),
            showIcons: settings["showToolIcons"] as? Bool ?? true
        )
        chevron.isHidden = !Self.detailCapableClients.contains(client.lowercased())
        // 原版会话行的条用客户端品牌色；此前漏设导致进度条不可见。
        barFill.layer?.backgroundColor = AppTheme.clientColor(client).cgColor
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

        let fraction = maxTokens > 0 ? min(1.0, CGFloat(tokens) / CGFloat(maxTokens)) : 0
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

    /// 原版只有能打开详情的客户端行才有 `cursor: pointer`；其余行不响应点击。
    override func mouseDown(with event: NSEvent) {
        guard !chevron.isHidden else { return }
        onSelect?()
    }
}
