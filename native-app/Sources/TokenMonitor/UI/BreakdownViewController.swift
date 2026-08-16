import AppKit

/// 按 client 或 model 维度的用量明细列表（取代原 breakdown 模块）。
///
/// 接收当前 stats / period / settings，从 period 的 clients/clientCosts 或
/// models/modelCosts 取出条目，按 tokens 降序渲染为「名称 + 进度条 + tokens +
/// 成本」行。client 行带客户端配色圆点；无数据时显示空态。
final class BreakdownViewController: NSViewController {
    var mode: String = "client" // "client" | "model"

    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无用量数据")

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
        scrollView.verticalScrollElasticity = .allowed
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

        var entries: [(id: String, tokens: Int, cost: Double, cacheRead: Int, output: Int)] = []
        if mode == "client" {
            let clients = periodDict?["clients"] as? [String: Any] ?? [:]
            let costs = periodDict?["clientCosts"] as? [String: Any] ?? [:]
            let cacheReads = periodDict?["clientCacheReads"] as? [String: Any] ?? [:]
            let outputs = periodDict?["clientOutputs"] as? [String: Any] ?? [:]
            for (id, value) in clients {
                entries.append((id, UsageCore.intValue(value), UsageCore.doubleValue(costs[id]),
                                UsageCore.intValue(cacheReads[id]), UsageCore.intValue(outputs[id])))
            }
        } else {
            let models = periodDict?["models"] as? [String: Any] ?? [:]
            let costs = periodDict?["modelCosts"] as? [String: Any] ?? [:]
            let cacheReads = periodDict?["modelCacheReads"] as? [String: Any] ?? [:]
            let outputs = periodDict?["modelOutputs"] as? [String: Any] ?? [:]
            for (id, value) in models {
                entries.append((id, UsageCore.intValue(value), UsageCore.doubleValue(costs[id]),
                                UsageCore.intValue(cacheReads[id]), UsageCore.intValue(outputs[id])))
            }
        }
        // client 维度按设置里的显示顺序优先排，再按 tokens 降序；model 直接按 tokens 降序。
        if mode == "client" {
            let order = ((settings["clientDisplayOrder"] as? String) ?? "")
                .split(separator: ",").map { String($0).lowercased() }
            let hidden = Set(AppViews.csvItems(settings["hiddenClients"]).map { $0.lowercased() })
            entries.sort { a, b in
                let ia = order.firstIndex(of: a.id) ?? Int.max
                let ib = order.firstIndex(of: b.id) ?? Int.max
                return ia == ib ? a.tokens > b.tokens : ia < ib
            }
            if !hidden.isEmpty {
                entries.removeAll { hidden.contains($0.id) }
            }
        } else {
            entries.sort { $0.tokens > $1.tokens }
        }

        // 清空旧行
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        emptyLabel.isHidden = !entries.isEmpty
        let maxTokens = entries.map(\.tokens).max() ?? 0
        for entry in entries {
            let row = BreakdownRowView()
            row.configure(
                id: entry.id,
                tokens: entry.tokens,
                cost: entry.cost,
                maxTokens: maxTokens,
                isClient: mode == "client",
                settings: settings,
                cacheRead: entry.cacheRead,
                output: entry.output
            )
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        // 底部留白
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

private final class BreakdownRowView: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let barBg = NSView()
    private let barFill = NSView()
    private let accordionStack = NSStackView()
    private var expanded = false
    private var tracking: NSTrackingArea?
    private var hover = false
    private var hasAccordion = false
    private var barFillWidth: NSLayoutConstraint?

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

        configureLabel(nameLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(subtitleLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        subtitleLabel.isHidden = true
        configureLabel(tokensLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        tokensLabel.alignment = .right
        costLabel.alignment = .right

        // 名称列（mark + 标题/副标题）
        let labelStack = NSStackView(views: [nameLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView(views: [dot, labelStack])
        nameRow.orientation = .horizontal
        nameRow.alignment = .top
        nameRow.spacing = 8
        nameRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 指标列（value + cost 右对齐堆叠）
        let metrics = NSStackView(views: [tokensLabel, costLabel])
        metrics.orientation = .vertical
        metrics.alignment = .trailing
        metrics.spacing = 2
        metrics.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let head = NSStackView(views: [nameRow, metrics])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10

        // 进度条（原版 .bar：6px 全宽）
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor(calibratedRed: 4/255, green: 8/255, blue: 13/255, alpha: 0.46).cgColor
        barBg.layer?.cornerRadius = 3
        barBg.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBg.addSubview(barFill)

        accordionStack.orientation = .vertical
        accordionStack.alignment = .leading
        accordionStack.spacing = 0
        accordionStack.translatesAutoresizingMaskIntoConstraints = false
        accordionStack.isHidden = true

        let stack = NSStackView(views: [head, barBg, accordionStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 底部发丝线（原版 .row border-bottom）
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
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            barBg.heightAnchor.constraint(equalToConstant: 6),
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
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
    }

    func configure(id: String, tokens: Int, cost: Double, maxTokens: Int, isClient: Bool, settings: [String: Any], cacheRead: Int = 0, output: Int = 0) {
        nameLabel.stringValue = isClient ? AppTheme.clientLabel(id) : id
        subtitleLabel.stringValue = ""
        subtitleLabel.isHidden = true
        tokensLabel.stringValue = Fmt.tokensExact(tokens)
        costLabel.stringValue = Fmt.money(cost, settings: settings)
        let color = isClient ? AppTheme.clientColor(id) : AppTheme.modelColor(id)
        dot.layer?.backgroundColor = color.cgColor
        barFill.layer?.backgroundColor = color.cgColor
        let fraction = maxTokens > 0 ? CGFloat(tokens) / CGFloat(maxTokens) : 0
        barFillWidth?.isActive = false
        barFillWidth = barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor, multiplier: max(0.02, fraction))
        barFillWidth?.isActive = true

        hasAccordion = tokens > 0 && (cacheRead > 0 || output > 0)
        if hasAccordion {
            renderAccordion(tokens: tokens, cacheRead: cacheRead, output: output)
        } else {
            accordionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            accordionStack.isHidden = true
            expanded = false
        }
    }

    private func renderAccordion(tokens: Int, cacheRead: Int, output: Int) {
        accordionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cacheMiss = max(0, tokens - cacheRead - output)
        let inputTokens = cacheRead + cacheMiss
        let hitPct = inputTokens > 0 ? Int((Double(cacheRead) / Double(inputTokens) * 100).rounded()) : 0
        let missPct = 100 - hitPct
        let rows: [(String, String, Int)] = [
            ("输入缓存命中", "\(hitPct)%", cacheRead),
            ("输入缓存未命中", "\(missPct)%", cacheMiss),
            ("输出", "", output),
        ]
        for (label, pct, value) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let l = NSTextField(labelWithString: pct.isEmpty ? label : "\(label) \(pct)")
            l.font = AppTheme.microFont
            l.textColor = AppTheme.textSecondary
            l.isBezeled = false
            l.drawsBackground = false
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let v = NSTextField(labelWithString: Fmt.tokensExact(value))
            v.font = AppTheme.microFont
            v.textColor = AppTheme.textPrimary
            v.isBezeled = false
            v.drawsBackground = false
            row.addArrangedSubview(l)
            row.addArrangedSubview(v)
            row.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 2, right: 0)
            accordionStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: accordionStack.widthAnchor).isActive = true
        }
        accordionStack.isHidden = !expanded
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        layer?.backgroundColor = AppTheme.panelColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.backgroundColor = .clear
    }

    override func mouseDown(with event: NSEvent) {
        guard hasAccordion else { return }
        expanded.toggle()
        accordionStack.isHidden = !expanded
        needsLayout = true
    }
}
