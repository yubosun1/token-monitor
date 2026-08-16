import AppKit

/// 底部视图切换条（原版 footer + view-switcher）：
/// 左侧 = 当前视图 + 展开箭头组成的分段控件（点击弹出视图菜单），
/// 右侧 = 刷新 / 设置 按钮（30px，原版 .icon-button 风格）。
final class ViewSwitcherBar: NSView {
    var onSelectView: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?

    private let switchButton = HoverButton(title: "")
    private let disclosureBtn = HoverButton(title: "")
    private let refreshBtn = HoverButton(title: "↻")
    private let settingsBtn = HoverButton(title: "⚙")
    private let popover = NSPopover()
    private let menuVC = ViewSwitcherMenuVC()

    private(set) var currentViewId = "home"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = .clear

        // 分段控件容器（原版 .view-switcher-current + .view-switcher-disclosure）
        let segmented = NSView()
        segmented.wantsLayer = true
        segmented.layer?.cornerRadius = 7
        segmented.layer?.borderWidth = 1
        segmented.layer?.borderColor = AppTheme.lineStrongColor.cgColor
        segmented.layer?.backgroundColor = AppTheme.controlColor.cgColor
        segmented.translatesAutoresizingMaskIntoConstraints = false

        switchButton.font = AppTheme.bodyFont
        switchButton.target = self
        switchButton.action = #selector(toggleMenu)
        switchButton.hoverBackground = AppTheme.accent.withAlphaComponent(0.08)
        switchButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        switchButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage()
        disclosureBtn.image = chevron.withTint(AppTheme.textSecondary)
        disclosureBtn.target = self
        disclosureBtn.action = #selector(toggleMenu)
        disclosureBtn.hoverBackground = AppTheme.accent.withAlphaComponent(0.08)
        disclosureBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        disclosureBtn.heightAnchor.constraint(equalToConstant: 30).isActive = true
        disclosureBtn.toolTip = "选择视图"

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = AppTheme.lineStrongColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        segmented.addSubview(switchButton)
        segmented.addSubview(divider)
        segmented.addSubview(disclosureBtn)
        NSLayoutConstraint.activate([
            switchButton.leadingAnchor.constraint(equalTo: segmented.leadingAnchor, constant: 1),
            switchButton.topAnchor.constraint(equalTo: segmented.topAnchor, constant: 1),
            switchButton.bottomAnchor.constraint(equalTo: segmented.bottomAnchor, constant: -1),
            divider.leadingAnchor.constraint(equalTo: switchButton.trailingAnchor),
            divider.topAnchor.constraint(equalTo: segmented.topAnchor, constant: 6),
            divider.bottomAnchor.constraint(equalTo: segmented.bottomAnchor, constant: -6),
            disclosureBtn.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            disclosureBtn.trailingAnchor.constraint(equalTo: segmented.trailingAnchor, constant: -1),
            disclosureBtn.topAnchor.constraint(equalTo: segmented.topAnchor, constant: 1),
            disclosureBtn.bottomAnchor.constraint(equalTo: segmented.bottomAnchor, constant: -1),
        ])
        segmented.heightAnchor.constraint(equalToConstant: 32).isActive = true

        // 右侧动作按钮（原版 .icon-button：26×26，圆角 6）
        for btn in [refreshBtn, settingsBtn] {
            btn.font = NSFont.systemFont(ofSize: 14, weight: .regular)
            btn.target = self
            btn.hoverBackground = AppTheme.hoverColor
            btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
            btn.layer?.borderWidth = 1
            btn.layer?.borderColor = AppTheme.lineColor.withAlphaComponent(0.35).cgColor
            btn.layer?.backgroundColor = AppTheme.controlColor.cgColor
            btn.layer?.cornerRadius = 7
        }
        refreshBtn.action = #selector(refreshClick)
        settingsBtn.action = #selector(settingsClick)

        let actions = NSStackView(views: [refreshBtn, settingsBtn])
        actions.orientation = .horizontal
        actions.spacing = 4

        let stack = NSStackView(views: [segmented, actions])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        popover.behavior = .transient
        popover.contentViewController = menuVC
        menuVC.onSelect = { [weak self] id in
            self?.popover.performClose(nil)
            self?.setCurrentView(id, persist: true)
            self?.onSelectView?(id)
        }
        menuVC.onToggleHidden = { [weak self] id in
            self?.toggleHidden(id)
        }
    }

    func setCurrentView(_ id: String, persist: Bool = false) {
        currentViewId = id
        let def = AppViews.def(id)
        let icon = NSImage(systemSymbolName: def.symbol, accessibilityDescription: def.label) ?? NSImage()
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(attachment: Self.attachment(image: icon.withTint(AppTheme.textPrimary))))
        attr.append(NSAttributedString(string: "  \(def.label)  ", attributes: [
            .font: AppTheme.bodyFont, .foregroundColor: AppTheme.textPrimary,
        ]))
        switchButton.attributedTitle = attr
        if persist {
            var lastView = BridgeCore.shared.settings.snapshot()["lastViewState"] as? [String: Any] ?? [:]
            lastView["breakdown"] = id
            BridgeCore.shared.settings.update(["lastViewState": lastView])
        }
    }

    private static func attachment(image: NSImage) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = image
        return attachment
    }

    private func toggleHidden(_ id: String) {
        let s = BridgeCore.shared.settings.snapshot()
        let hidden = AppViews.normalizeHiddenViews(s["hiddenViews"])
        let visible = AppViews.normalizeViewDisplayOrder(s["viewDisplayOrder"]).filter { !hidden.contains($0) }
        if hidden.contains(id) {
            BridgeCore.shared.settings.update(["hiddenViews": AppViews.toggleHidden(s["hiddenViews"], viewId: id, hide: false)])
        } else if visible.count > 1 {
            BridgeCore.shared.settings.update(["hiddenViews": AppViews.toggleHidden(s["hiddenViews"], viewId: id, hide: true)])
        }
        menuVC.reload()
    }

    @objc private func toggleMenu() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            menuVC.reload()
            popover.show(relativeTo: switchButton.bounds, of: switchButton, preferredEdge: .maxY)
        }
    }

    @objc private func refreshClick() { onRefresh?() }
    @objc private func settingsClick() { onSettings?() }
}

// MARK: - Menu content（原版 .view-switcher-menu）

private final class ViewSwitcherMenuVC: NSViewController {
    var onSelect: ((String) -> Void)?
    var onToggleHidden: ((String) -> Void)?

    private let stack = NSStackView()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.92).cgColor
        root.layer?.cornerRadius = 7
        root.layer?.borderWidth = 1
        root.layer?.borderColor = AppTheme.lineStrongColor.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func reload() {
        let s = BridgeCore.shared.settings.snapshot()
        let views = AppViews.visibleViews(orderValue: s["viewDisplayOrder"], hiddenValue: s["hiddenViews"])
        let current = (s["lastViewState"] as? [String: Any])?["breakdown"] as? String ?? "home"
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views {
            let row = MenuRowView(view: v, isCurrent: v.id == current)
            row.onClick = { [weak self] in self?.onSelect?(v.id) }
            row.onEye = { [weak self] in self?.onToggleHidden?(v.id) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        preferredContentSize = NSSize(width: 190, height: CGFloat(views.count) * 30 + 10)
    }
}

private final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    var onEye: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let eyeBtn = HoverButton(title: "")
    private var tracking: NSTrackingArea?
    private var hover = false

    init(view: AppViews.ViewDef, isCurrent: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = isCurrent ? AppTheme.accent.withAlphaComponent(0.08).cgColor : .clear
        layer?.cornerRadius = 5

        let icon = NSImage(systemSymbolName: view.symbol, accessibilityDescription: view.label) ?? NSImage()
        iconView.image = icon.withTint(isCurrent ? AppTheme.accent : AppTheme.textSecondary)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = view.label
        label.font = AppTheme.bodyFont
        label.textColor = isCurrent ? AppTheme.accent : AppTheme.textSecondary
        label.isBezeled = false
        label.drawsBackground = false

        let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "隐藏") ?? NSImage()
        eyeBtn.image = eye.withTint(AppTheme.textTertiary)
        eyeBtn.toolTip = "隐藏该视图（可在设置中恢复）"
        eyeBtn.target = self
        eyeBtn.action = #selector(eyeClick)
        eyeBtn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        eyeBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let stack = NSStackView(views: [iconView, label, eyeBtn])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func eyeClick() {
        onEye?()
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
        layer?.backgroundColor = (hover ? AppTheme.panelColor : AppTheme.accent.withAlphaComponent(0.08)).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.backgroundColor = AppTheme.accent.withAlphaComponent(0.08).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - NSImage tint

extension NSImage {
    func withTint(_ color: NSColor) -> NSImage {
        let image = self.copy() as? NSImage ?? self
        image.isTemplate = false
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }
}
