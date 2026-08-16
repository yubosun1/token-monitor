import AppKit

/// 项目视图（原版 projectRows）：从 period.sessions 的 projectLabel 聚合
/// 项目，按 tokens 降序渲染；点击项目行展开各客户端占比（原版 accordion）。
final class ProjectsViewController: NSViewController, ContentUpdatable {
    private let scrollView = TopAnchoredScrollView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无项目数据")

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

    struct Project {
        let key: String
        var name: String
        var tokens: Int
        var cost: Double
        var clients: [(client: String, tokens: Int)]
    }

    func update(stats: [String: Any]?, period: String, settings: [String: Any]) {
        let periods = stats?["periods"] as? [String: Any]
        let periodDict = periods?[period] as? [String: Any]
        let sessions = periodDict?["sessions"] as? [String: Any] ?? [:]

        // 优先用 period.projects（若采集器将来提供），否则从 sessions 聚合。
        var projects: [Project] = []
        if let rawProjects = periodDict?["projects"] as? [String: Any], !rawProjects.isEmpty {
            for (rawKey, value) in rawProjects {
                guard let entry = value as? [String: Any] else { continue }
                let name = (entry["label"] as? String ?? rawKey).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let clients = (entry["clients"] as? [String: Any] ?? [:]).compactMap { (client, value) -> (String, Int)? in
                    let tokens = UsageCore.intValue(value)
                    return tokens > 0 ? (client, tokens) : nil
                }
                .sorted { $0.1 > $1.1 }
                projects.append(Project(
                    key: name.lowercased(),
                    name: name,
                    tokens: UsageCore.intValue(entry["tokens"]),
                    cost: UsageCore.doubleValue(entry["costUsd"]),
                    clients: clients
                ))
            }
        } else {
            var byKey: [String: Project] = [:]
            for (_, value) in sessions {
                guard let s = value as? [String: Any] else { continue }
                let label = (s["projectLabel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { continue }
                let key = label.lowercased()
                let tokens = UsageCore.intValue(s["totalTokens"])
                guard tokens > 0 else { continue }
                let client = s["client"] as? String ?? ""
                if byKey[key] == nil {
                    byKey[key] = Project(key: key, name: label, tokens: 0, cost: 0, clients: [])
                }
                byKey[key]?.tokens += tokens
                byKey[key]?.cost += UsageCore.doubleValue(s["costUsd"])
                if let idx = byKey[key]?.clients.firstIndex(where: { $0.client == client }) {
                    byKey[key]?.clients[idx].tokens += tokens
                } else {
                    byKey[key]?.clients.append((client, tokens))
                }
            }
            for key in byKey.keys {
                byKey[key]?.clients.sort { $0.tokens > $1.tokens }
            }
            projects = Array(byKey.values)
        }

        projects.sort { $0.tokens > $1.tokens || ($0.tokens == $1.tokens && $0.name < $1.name) }

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !projects.isEmpty
        for project in projects {
            let row = ProjectRowView()
            row.configure(project: project, settings: settings)
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

// MARK: - Project row

private final class ProjectRowView: NSView {
    private let mark = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let accordionStack = NSStackView()
    private var expanded = false
    private var tracking: NSTrackingArea?
    private var hover = false
    private var project: ProjectsViewController.Project?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear

        mark.wantsLayer = true
        mark.layer?.cornerRadius = 4
        mark.translatesAutoresizingMaskIntoConstraints = false

        configureLabel(nameLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configureLabel(tokensLabel, font: AppTheme.bodyFont, color: AppTheme.textPrimary)
        configureLabel(costLabel, font: AppTheme.microFont, color: AppTheme.textSecondary)
        costLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // 数值列不压缩，长项目名才截断（原版 .row-metrics max-content）。
        for label in [tokensLabel, costLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let head = NSStackView(views: [mark, nameLabel, tokensLabel, costLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8
        // 水平内缩来自 shell；行内只保留上下 padding（原版 .row padding-bottom 10px）。
        head.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        head.translatesAutoresizingMaskIntoConstraints = false
        addSubview(head)

        accordionStack.orientation = .vertical
        accordionStack.alignment = .leading
        accordionStack.spacing = 0
        accordionStack.translatesAutoresizingMaskIntoConstraints = false
        accordionStack.isHidden = true
        addSubview(accordionStack)

        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor),
            head.topAnchor.constraint(equalTo: topAnchor),
            accordionStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            accordionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            accordionStack.topAnchor.constraint(equalTo: head.bottomAnchor),
            accordionStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.widthAnchor.constraint(equalToConstant: 8),
            mark.heightAnchor.constraint(equalToConstant: 8),
        ])

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = AppTheme.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
    }

    func configure(project: ProjectsViewController.Project, settings: [String: Any]) {
        self.project = project
        nameLabel.stringValue = project.name
        tokensLabel.stringValue = Fmt.tokens(project.tokens)
        costLabel.stringValue = Fmt.money(project.cost, settings: settings)
        // 渐变 mark：客户端多时用主色，单客户端用其品牌色（原版 clientGradient 简化）。
        if let first = project.clients.first {
            mark.layer?.backgroundColor = AppTheme.clientColor(first.client).cgColor
        } else {
            mark.layer?.backgroundColor = AppTheme.accent.cgColor
        }
        renderAccordion()
    }

    private func renderAccordion() {
        accordionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let project else { return }
        let total = project.tokens
        for entry in project.clients {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = AppTheme.clientColor(entry.client).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: AppTheme.clientLabel(entry.client))
            name.font = AppTheme.smallFont
            name.textColor = AppTheme.textSecondary
            name.isBezeled = false
            name.drawsBackground = false
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let pct = NSTextField(labelWithString: total > 0 ? String(format: "%.0f%%", Double(entry.tokens) / Double(total) * 100) : "—")
            pct.font = AppTheme.smallFont
            pct.textColor = AppTheme.textTertiary
            pct.isBezeled = false
            pct.drawsBackground = false
            let tokens = NSTextField(labelWithString: Fmt.tokens(entry.tokens))
            tokens.font = AppTheme.monoFont
            tokens.textColor = AppTheme.textPrimary
            tokens.isBezeled = false
            tokens.drawsBackground = false
            row.addArrangedSubview(dot)
            row.addArrangedSubview(name)
            row.addArrangedSubview(pct)
            row.addArrangedSubview(tokens)
            row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
            accordionStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: accordionStack.widthAnchor).isActive = true
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
        }
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
        layer?.backgroundColor = AppTheme.hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.backgroundColor = .clear
    }

    override func mouseDown(with event: NSEvent) {
        guard project != nil, !project!.clients.isEmpty else { return }
        expanded.toggle()
        accordionStack.isHidden = !expanded
        needsLayout = true
        layer?.backgroundColor = expanded ? AppTheme.hoverColor.cgColor : (hover ? AppTheme.hoverColor.cgColor : .clear)
    }
}
