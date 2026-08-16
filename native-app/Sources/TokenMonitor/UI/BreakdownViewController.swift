import AppKit

/// 按 client 或 model 维度的用量明细列表（取代原 breakdown 模块）。
///
/// 接收当前 stats / period / settings，从 period 的 clients/clientCosts 或
/// models/modelCosts 取出条目，按 tokens 降序渲染为「名称 + 进度条 + tokens +
/// 成本」行。client 行带客户端配色圆点；无数据时显示空态。
final class BreakdownViewController: NSViewController, ContentUpdatable {
    var mode: String = "client" // "client" | "model"

    private let scrollView = TopAnchoredScrollView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无用量数据")
    /// Pooled row views, reconfigured in place on every stats push.
    private var rowViews: [BreakdownRowView] = []
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
        scrollView.verticalScrollElasticity = .allowed
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

        emptyLabel.isHidden = !entries.isEmpty
        let maxTokens = entries.map(\.tokens).max() ?? 0

        // Reuse row views across refreshes. Stats push every 15s and tearing the
        // whole stack down each time re-runs Auto Layout over every row (and
        // drops accordion expansion state); reconfiguring in place does not.
        while rowViews.count < entries.count {
            let row = BreakdownRowView()
            rowViews.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        for (index, row) in rowViews.enumerated() {
            guard index < entries.count else {
                row.isHidden = true
                continue
            }
            let entry = entries[index]
            row.isHidden = false
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
        }

        // 底部留白（只建一次）。
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

private final class BreakdownRowView: NSView {
    private let mark = RowMarkView(size: 10)
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

        // 原版 .row-head font-size 12px、.row-cost 10px。
        configureLabel(nameLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(subtitleLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        subtitleLabel.isHidden = true
        configureLabel(tokensLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        tokensLabel.alignment = .right
        costLabel.alignment = .right
        // configureLabel truncates by default (for long model names); the value
        // column must never lose digits, so opt it back out.
        for label in [tokensLabel, costLabel] {
            label.lineBreakMode = .byClipping
            label.cell?.truncatesLastVisibleLine = false
        }

        // 名称列（mark + 标题/副标题）
        let labelStack = NSStackView(views: [nameLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // The intermediate stack keeps NSStackView's default (high) compression
        // resistance, which would out-rank the name label's low setting and
        // force the metrics column to truncate instead of the name.
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 原版 .row-name：align-items center、gap 8px。
        let nameRow = NSStackView(views: [mark, labelStack])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 8
        // 名字列按内容取宽（hug 高），多余空间交给 spacer，压缩时才截断标题。
        nameRow.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 指标列（value + cost 右对齐堆叠）。原版 .row-metrics 是
        // min-width: max-content —— 数值列不压缩，长名字才截断。
        let metrics = NSStackView(views: [tokensLabel, costLabel])
        metrics.orientation = .vertical
        metrics.alignment = .trailing
        metrics.spacing = 2
        // NSStackView ignores setContentCompressionResistancePriority — the
        // stack-level equivalent is setClippingResistancePriority. Without it
        // the metrics column shrinks and the numbers render as "11,794,4…".
        metrics.setHuggingPriority(.required, for: .horizontal)
        metrics.setClippingResistancePriority(.required, for: .horizontal)
        for label in [tokensLabel, costLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        nameRow.setClippingResistancePriority(.defaultLow, for: .horizontal)

        // 原版 .row-head 是 space-between：名字靠左、数值靠右。
        let headSpacer = NSView()
        headSpacer.translatesAutoresizingMaskIntoConstraints = false
        headSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [nameRow, headSpacer, metrics])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10

        // 进度条（原版 .bar：6px 全宽、bg rgba(--sunken-rgb, 0.46)）
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = AppTheme.sunkenColor.withAlphaComponent(0.46).cgColor
        barBg.layer?.cornerRadius = 3
        barBg.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBg.addSubview(barFill)

        // 原版 .row-accordion-inner：margin-left 4 + padding-left 12 + 左侧发丝线。
        accordionStack.orientation = .vertical
        accordionStack.alignment = .leading
        accordionStack.spacing = 3
        accordionStack.edgeInsets = NSEdgeInsets(top: 5, left: 16, bottom: 2, right: 0)
        accordionStack.translatesAutoresizingMaskIntoConstraints = false
        accordionStack.isHidden = true

        let rail = NSView()
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        rail.translatesAutoresizingMaskIntoConstraints = false
        accordionStack.addSubview(rail)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: accordionStack.leadingAnchor, constant: 4),
            rail.topAnchor.constraint(equalTo: accordionStack.topAnchor),
            rail.bottomAnchor.constraint(equalTo: accordionStack.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 1),
        ])

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
            barBg.heightAnchor.constraint(equalToConstant: 6),
            barBg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // 头行必须撑满，否则它按内容取宽、把右侧数值列挤成省略号。
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accordionStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        let asset = isClient ? IconCatalog.clientAsset(id) : IconCatalog.modelAsset(id)
        mark.configure(asset: asset, color: color, showIcons: settings["showToolIcons"] as? Bool ?? true)
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

    /// 原版 .row-accordion-inner：左侧发丝线竖轨 + 三行「标签 百分比 … 数值」。
    private func renderAccordion(tokens: Int, cacheRead: Int, output: Int) {
        accordionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cacheMiss = max(0, tokens - cacheRead - output)
        let inputTokens = cacheRead + cacheMiss
        let hitPct = inputTokens > 0 ? Int((Double(cacheRead) / Double(inputTokens) * 100).rounded()) : 0
        let missPct = 100 - hitPct
        let rows: [(label: String, pct: String, value: Int)] = [
            ("Input (Cache Hit)", "\(hitPct)%", cacheRead),
            ("Input (Cache Miss)", "\(missPct)%", cacheMiss),
            ("Output", "", output),
        ]
        for entry in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .lastBaseline
            row.spacing = 6

            // 标签 + 淡化的百分比（原版 .accordion-pct opacity 0.6）。
            let label = NSTextField(labelWithString: entry.label)
            label.font = AppTheme.smallFont
            label.textColor = AppTheme.textSecondary
            label.isBezeled = false
            label.drawsBackground = false
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            row.addArrangedSubview(label)

            if !entry.pct.isEmpty {
                let pct = NSTextField(labelWithString: entry.pct)
                pct.font = AppTheme.microFont
                pct.textColor = AppTheme.textSecondary
                pct.alphaValue = 0.6
                pct.isBezeled = false
                pct.drawsBackground = false
                pct.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                row.addArrangedSubview(pct)
            }

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)

            let value = NSTextField(labelWithString: Fmt.tokensExact(entry.value))
            value.font = AppTheme.smallFont
            value.textColor = AppTheme.textPrimary
            value.alphaValue = 0.85
            value.alignment = .right
            value.isBezeled = false
            value.drawsBackground = false
            value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            row.addArrangedSubview(value)

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
