import AppKit

/// 底部视图切换条（取代原版 footer 的 viewSwitcher + utility actions）。
/// 左侧：当前视图按钮（点击弹出视图菜单），右侧：刷新/设置。
final class ViewSwitcherBar: NSView {
    var onSelectView: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?

    private let switchButton = HoverButton(title: "")
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

        switchButton.font = AppTheme.bodyFont
        switchButton.target = self
        switchButton.action = #selector(toggleMenu)
        switchButton.hoverBackground = AppTheme.hoverColor
        switchButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        refreshBtn.target = self; refreshBtn.action = #selector(refreshClick)
        settingsBtn.target = self; settingsBtn.action = #selector(settingsClick)

        let actions = NSStackView(views: [refreshBtn, settingsBtn])
        actions.orientation = .horizontal
        actions.spacing = 2

        let stack = NSStackView(views: [switchButton, actions])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
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
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage()
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(attachment: Self.attachment(image: icon.withTint(AppTheme.textSecondary))))
        attr.append(NSAttributedString(string: "  \(def.label)  ", attributes: [
            .font: AppTheme.bodyFont, .foregroundColor: AppTheme.textPrimary,
        ]))
        attr.append(NSAttributedString(attachment: Self.attachment(image: chevron.withTint(AppTheme.textTertiary))))
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

// MARK: - Menu content

private final class ViewSwitcherMenuVC: NSViewController {
    var onSelect: ((String) -> Void)?
    var onToggleHidden: ((String) -> Void)?

    private let stack = NSStackView()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = AppTheme.cardColor.cgColor
        root.layer?.cornerRadius = 8
        root.layer?.borderWidth = 1
        root.layer?.borderColor = AppTheme.cardBorderColor.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
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
        preferredContentSize = NSSize(width: 208, height: CGFloat(views.count) * 34 + 10)
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
        layer?.backgroundColor = .clear
        layer?.cornerRadius = 5

        let icon = NSImage(systemSymbolName: view.symbol, accessibilityDescription: view.label) ?? NSImage()
        iconView.image = icon.withTint(isCurrent ? AppTheme.accent : AppTheme.textSecondary)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = view.label
        label.font = AppTheme.bodyFont
        label.textColor = isCurrent ? AppTheme.accent : AppTheme.textPrimary
        label.isBezeled = false
        label.drawsBackground = false

        let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "隐藏") ?? NSImage()
        eyeBtn.image = eye.withTint(AppTheme.textTertiary)
        eyeBtn.toolTip = "隐藏该视图（可在设置中恢复）"
        eyeBtn.target = self
        eyeBtn.action = #selector(eyeClick)

        let stack = NSStackView(views: [iconView, label, eyeBtn])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
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
        layer?.backgroundColor = AppTheme.hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.backgroundColor = .clear
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
