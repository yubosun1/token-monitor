import AppKit

/// 会话详情弹窗：后台读取 SessionDetailCore，展示标题、总计与 exchanges 列表。
///
/// 取代原 session-detail 弹窗。读取在后台队列进行（首读可能要解析大 transcript），
/// 渲染回主队列。onClose 由主控制器的覆盖层关闭逻辑注入。
final class SessionDetailViewController: NSViewController {
    var onClose: (() -> Void)?

    private let client: String
    private let sessionId: String
    private let period: String
    private let sessionCost: Double

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let loadingLabel = NSTextField(labelWithString: "正在读取会话…")
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")

    init(client: String, sessionId: String, period: String, sessionCost: Double) {
        self.client = client
        self.sessionId = sessionId
        self.period = period
        self.sessionCost = sessionCost
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = AppTheme.cardColor.cgColor

        let backBtn = HoverButton(title: "‹ 返回")
        backBtn.font = AppTheme.bodyFont
        backBtn.target = self
        backBtn.action = #selector(close)
        let closeBtn = HoverButton(title: "×")
        closeBtn.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        closeBtn.target = self
        closeBtn.action = #selector(close)

        configureLabel(titleLabel, font: AppTheme.titleFont, color: AppTheme.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true

        let header = NSStackView(views: [backBtn, titleLabel, closeBtn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        configureLabel(summaryLabel, font: AppTheme.smallFont, color: AppTheme.textSecondary)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(summaryLabel)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        configureLabel(loadingLabel, font: AppTheme.bodyFont, color: AppTheme.textTertiary)
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(loadingLabel)

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sep)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.topAnchor.constraint(equalTo: header.bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
            summaryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            summaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            summaryLabel.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            loadingLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
        ])

        titleLabel.stringValue = "\(AppTheme.clientLabel(client)) · \(String(sessionId.prefix(10)))"
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()
    }

    private func load() {
        let client = self.client
        let sid = self.sessionId
        let period = self.period
        let cost = self.sessionCost
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = SessionDetailCore.read(client: client, sessionId: sid, period: period, sessionCost: cost)
            DispatchQueue.main.async {
                self?.render(detail)
            }
        }
    }

    private func render(_ detail: [String: Any]) {
        loadingLabel.isHidden = true
        let found = detail["found"] as? Bool ?? false
        guard found else {
            summaryLabel.stringValue = "未找到会话内容"
            return
        }
        let totals = detail["totals"] as? [String: Any] ?? [:]
        let totalTokens = UsageCore.intValue(totals["total"])
        let exchanges = detail["exchanges"] as? [[String: Any]] ?? []
        let turns = exchanges.reduce(0) { $0 + (UsageCore.intValue($1["turnCount"])) }
        summaryLabel.stringValue = "\(Fmt.tokens(totalTokens)) tokens · \(exchanges.count) 轮 · \(turns) 条消息 · \(Fmt.money(sessionCost, settings: BridgeCore.shared.settings.snapshot()))"

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for exchange in exchanges {
            let row = ExchangeRowView()
            row.configure(exchange: exchange, settings: BridgeCore.shared.settings.snapshot())
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        contentStack.addArrangedSubview(spacer)
    }

    @objc private func close() { onClose?() }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }
}

// MARK: - Exchange row

private final class ExchangeRowView: NSView {
    private let promptLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")

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

        configureLabel(promptLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 2
        promptLabel.cell?.truncatesLastVisibleLine = true
        configureLabel(metaLabel, font: AppTheme.microFont, color: AppTheme.textTertiary)
        configureLabel(tokensLabel, font: AppTheme.monoFont, color: AppTheme.textSecondary)

        let leftStack = NSStackView(views: [promptLabel, metaLabel])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        promptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [leftStack, tokensLabel])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        tokensLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tokensLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
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
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func configure(exchange: [String: Any], settings: [String: Any]) {
        let prompt = (exchange["promptPreview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        promptLabel.stringValue = prompt.isEmpty ? "(无提示预览)" : prompt
        let tokens = exchange["tokens"] as? [String: Any] ?? [:]
        let total = UsageCore.doubleValue(tokens["total"])
        tokensLabel.stringValue = Fmt.tokens(Int(total))
        let turnCount = UsageCore.intValue(exchange["turnCount"])
        let startedAt = exchange["startedAt"] as? String ?? ""
        let timeStr = formatTime(startedAt)
        metaLabel.stringValue = "\(turnCount) 条消息 · \(timeStr)"
    }

    private func formatTime(_ iso: String) -> String {
        let ms = UsageCore.timestampMs(iso)
        guard ms > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
