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

        var rows: [(client: String, sessionId: String, tokens: Int, cost: Double, msgs: Int, lastUsedMs: Double, projectLabel: String)] = []
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
                s["projectLabel"] as? String ?? ""
            ))
        }
        rows.sort { $0.lastUsedMs > $1.lastUsedMs }

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !rows.isEmpty
        for r in rows {
            let row = SessionRowView()
            row.configure(client: r.client, sessionId: r.sessionId, tokens: r.tokens,
                          cost: r.cost, messages: r.msgs, lastUsedMs: r.lastUsedMs,
                          projectLabel: r.projectLabel, settings: settings)
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
    private let tokensLabel = NSTextField(labelWithString: "")
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
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        configureLabel(titleLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(metaLabel, font: AppTheme.microFont, color: AppTheme.textTertiary)
        configureLabel(tokensLabel, font: AppTheme.monoFont, color: AppTheme.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true

        let leftStack = NSStackView(views: [dot, titleLabel, metaLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 6
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [leftStack, tokensLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        tokensLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tokensLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }

    func configure(client: String, sessionId: String, tokens: Int, cost: Double, messages: Int, lastUsedMs: Double, projectLabel: String, settings: [String: Any]) {
        dot.layer?.backgroundColor = AppTheme.clientColor(client).cgColor
        let label = AppTheme.clientLabel(client)
        let suffix = projectLabel.isEmpty ? String(sessionId.prefix(8)) : projectLabel
        titleLabel.stringValue = "\(label) · \(suffix)"
        tokensLabel.stringValue = Fmt.tokens(tokens)
        metaLabel.stringValue = "\(messages) msg · \(relativeTime(lastUsedMs))"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hover = true; layer?.backgroundColor = AppTheme.hoverColor.cgColor }
    override func mouseExited(with event: NSEvent) { hover = false; layer?.backgroundColor = .clear }
    override func mouseDown(with event: NSEvent) { onSelect?() }

    private func relativeTime(_ ms: Double) -> String {
        guard ms > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600))小时前" }
        if diff < 86400 * 2 { return "昨天" }
        if diff < 86400 * 7 { return "\(Int(diff / 86400))天前" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }
}
