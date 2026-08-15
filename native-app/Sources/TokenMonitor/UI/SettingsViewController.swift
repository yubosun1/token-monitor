import AppKit

/// 设置面板（覆盖层）：采集客户端开关、刷新间隔、开机启动、起始日期、
/// DeepSeek API Key、OpenCode Cookie、全局快捷键。
///
/// 直接读写 SettingsStore / CredentialStore / ShortcutController，不再经 IPC。
/// onClose 由主控制器的覆盖层关闭逻辑注入。
final class SettingsViewController: NSViewController {

    var onClose: (() -> Void)?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var clientCheckboxes: [(String, NSButton)] = []
    private let refreshPopUp = NSPopUpButton()
    private let startAtLoginBtn = NSButton(checkboxWithTitle: "开机时启动", target: nil, action: nil)
    private let allTimePicker = NSDatePicker()
    private let deepseekStatus = NSTextField(labelWithString: "")
    private let deepseekInput = NSSecureTextField()
    private let opencodeList = NSStackView()
    private let opencodeNameField = NSTextField()
    private let opencodeCookieField = NSTextField()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var observers: [NSObjectProtocol] = []

    private let allClients = ["claude", "codex", "opencode", "workbuddy", "proma", "hanako", "dsh"]

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = AppTheme.cardColor.cgColor

        let title = NSTextField(labelWithString: "设置")
        title.font = AppTheme.titleFont
        title.textColor = AppTheme.textPrimary
        title.isBezeled = false
        title.drawsBackground = false
        let closeBtn = HoverButton(title: "×")
        closeBtn.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        closeBtn.target = self
        closeBtn.action = #selector(close)
        let header = NSStackView(views: [title, closeBtn])
        header.orientation = .horizontal
        header.alignment = .centerY
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildSections()
        populate()
        observers.append(NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.populate() })
    }

    // MARK: - Sections

    private func buildSections() {
        // 采集
        let collection = makeSection("采集")
        for id in allClients {
            let btn = NSButton(checkboxWithTitle: AppTheme.clientLabel(id), target: self, action: #selector(clientToggle(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier(id)
            styleCheckbox(btn)
            collection.addArrangedSubview(btn)
            clientCheckboxes.append((id, btn))
        }
        contentStack.addArrangedSubview(collection)

        // 刷新间隔
        let general = makeSection("通用")
        let refreshRow = makeRow("刷新间隔")
        for (title, ms) in [("15s", "15000"), ("30s", "30000"), ("1m", "60000"), ("2m", "120000"), ("5m", "300000")] {
            refreshPopUp.addItem(withTitle: title)
            refreshPopUp.itemArray.last?.representedObject = ms
        }
        refreshPopUp.target = self
        refreshPopUp.action = #selector(refreshChange)
        stylePopUp(refreshPopUp)
        refreshRow.addArrangedSubview(refreshPopUp)
        general.addArrangedSubview(refreshRow)

        startAtLoginBtn.target = self
        startAtLoginBtn.action = #selector(startAtLoginToggle)
        styleCheckbox(startAtLoginBtn)
        general.addArrangedSubview(startAtLoginBtn)

        let sinceRow = makeRow("统计起始日(allTime)")
        allTimePicker.datePickerStyle = .textField
        allTimePicker.datePickerElements = .yearMonthDay
        allTimePicker.target = self
        allTimePicker.action = #selector(sinceChange)
        allTimePicker.translatesAutoresizingMaskIntoConstraints = false
        sinceRow.addArrangedSubview(allTimePicker)
        general.addArrangedSubview(sinceRow)

        let shortcutRow = makeRow("全局快捷键")
        shortcutLabel.font = AppTheme.monoFont
        shortcutLabel.textColor = AppTheme.textPrimary
        shortcutLabel.isBezeled = false
        shortcutLabel.drawsBackground = false
        let clearBtn = HoverButton(title: "清除")
        clearBtn.font = AppTheme.smallFont
        clearBtn.target = self
        clearBtn.action = #selector(clearShortcut)
        shortcutRow.addArrangedSubview(shortcutLabel)
        shortcutRow.addArrangedSubview(clearBtn)
        general.addArrangedSubview(shortcutRow)
        contentStack.addArrangedSubview(general)

        // DeepSeek
        let deepseek = makeSection("DeepSeek")
        let dsStatusRow = makeRow("状态")
        dsStatusRow.addArrangedSubview(deepseekStatus)
        styleStatus(deepseekStatus)
        deepseek.addArrangedSubview(dsStatusRow)
        deepseekInput.placeholderString = "sk-..."
        deepseekInput.translatesAutoresizingMaskIntoConstraints = false
        deepseekInput.heightAnchor.constraint(equalToConstant: 24).isActive = true
        deepseek.addArrangedSubview(deepseekInput)
        let dsActions = NSStackView()
        dsActions.orientation = .horizontal
        dsActions.spacing = 8
        let dsSave = HoverButton(title: "保存"); dsSave.font = AppTheme.bodyFont
        dsSave.target = self; dsSave.action = #selector(deepseekSave)
        let dsClear = HoverButton(title: "清除"); dsClear.font = AppTheme.bodyFont
        dsClear.target = self; dsClear.action = #selector(deepseekClear)
        let dsRefresh = HoverButton(title: "刷新余额"); dsRefresh.font = AppTheme.bodyFont
        dsRefresh.target = self; dsRefresh.action = #selector(deepseekRefresh)
        dsActions.addArrangedSubview(dsSave)
        dsActions.addArrangedSubview(dsClear)
        dsActions.addArrangedSubview(dsRefresh)
        deepseek.addArrangedSubview(dsActions)
        contentStack.addArrangedSubview(deepseek)

        // OpenCode
        let opencode = makeSection("OpenCode")
        opencodeList.orientation = .vertical
        opencodeList.alignment = .leading
        opencodeList.spacing = 4
        opencode.addArrangedSubview(opencodeList)
        let ocNameRow = makeRow("账号名称")
        opencodeNameField.placeholderString = "例如: work"
        opencodeNameField.translatesAutoresizingMaskIntoConstraints = false
        opencodeNameField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        ocNameRow.addArrangedSubview(opencodeNameField)
        opencode.addArrangedSubview(ocNameRow)
        let cookieLabel = NSTextField(labelWithString: "Cookie (auth=...)")
        cookieLabel.font = AppTheme.smallFont
        cookieLabel.textColor = AppTheme.textSecondary
        cookieLabel.isBezeled = false
        cookieLabel.drawsBackground = false
        opencode.addArrangedSubview(cookieLabel)
        opencodeCookieField.placeholderString = "auth=..."
        opencodeCookieField.translatesAutoresizingMaskIntoConstraints = false
        opencodeCookieField.heightAnchor.constraint(equalToConstant: 48).isActive = true
        opencode.addArrangedSubview(opencodeCookieField)
        let ocSave = HoverButton(title: "保存账号"); ocSave.font = AppTheme.bodyFont
        ocSave.target = self; ocSave.action = #selector(opencodeSave)
        opencode.addArrangedSubview(ocSave)
        contentStack.addArrangedSubview(opencode)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        contentStack.addArrangedSubview(spacer)
    }

    private func makeSection(_ title: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = AppTheme.cardColor.cgColor
        stack.layer?.cornerRadius = 8
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = AppTheme.cardBorderColor.cgColor
        stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = AppTheme.titleFont
        label.textColor = AppTheme.textPrimary
        label.isBezeled = false
        label.drawsBackground = false
        stack.addArrangedSubview(label)
        return stack
    }

    private func makeRow(_ title: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = AppTheme.smallFont
        label.textColor = AppTheme.textSecondary
        label.isBezeled = false
        label.drawsBackground = false
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        return stack
    }

    private func styleCheckbox(_ btn: NSButton) {
        btn.font = AppTheme.bodyFont
        btn.contentTintColor = AppTheme.accent
    }

    private func stylePopUp(_ pop: NSPopUpButton) {
        pop.font = AppTheme.bodyFont
    }

    private func styleStatus(_ label: NSTextField) {
        label.font = AppTheme.smallFont
        label.isBezeled = false
        label.drawsBackground = false
    }

    // MARK: - Populate

    private func populate() {
        let s = BridgeCore.shared.settings.snapshot()
        let clients = ((s["clients"] as? String) ?? "").split(separator: ",").map { String($0).lowercased() }
        for (id, btn) in clientCheckboxes {
            btn.state = clients.contains(id) ? .on : .off
        }
        let refreshMs = String(Int(UsageCore.doubleValue(s["refreshMs"])))
        for item in refreshPopUp.itemArray {
            if (item.representedObject as? String) == refreshMs { refreshPopUp.select(item); break }
        }
        startAtLoginBtn.state = (s["startAtLogin"] as? Bool ?? false) ? .on : .off

        let allTimeSince = s["allTimeSince"] as? String ?? "2024-01-01"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: allTimeSince) { allTimePicker.dateValue = d }

        shortcutLabel.stringValue = (s["windowToggleShortcut"] as? String) ?? "（未设置）"

        let dsKey = CredentialStore.shared.deepseekApiKey()
        deepseekStatus.stringValue = dsKey.isEmpty ? "未配置" : "已配置"
        deepseekStatus.textColor = dsKey.isEmpty ? AppTheme.textTertiary : AppTheme.positive

        opencodeList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for profile in CredentialStore.shared.opencodeProfiles() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            let name = NSTextField(labelWithString: "\(profile.name)\(profile.enabled ? "" : " (停用)")")
            name.font = AppTheme.bodyFont
            name.textColor = AppTheme.textPrimary
            name.isBezeled = false
            name.drawsBackground = false
            let del = HoverButton(title: "删除"); del.font = AppTheme.smallFont
            del.identifier = NSUserInterfaceItemIdentifier(profile.name)
            del.target = self; del.action = #selector(opencodeDelete(_:))
            row.addArrangedSubview(name)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(del)
            row.widthAnchor.constraint(equalTo: opencodeList.widthAnchor).isActive = true
            opencodeList.addArrangedSubview(row)
        }
    }

    // MARK: - Actions

    @objc private func clientToggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let s = BridgeCore.shared.settings.snapshot()
        var list = ((s["clients"] as? String) ?? "").split(separator: ",").map { String($0).lowercased() }
        if sender.state == .on { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
        BridgeCore.shared.settings.update(["clients": list.joined(separator: ",")])
    }

    @objc private func refreshChange() {
        guard let ms = refreshPopUp.selectedItem?.representedObject as? String, let v = Int(ms) else { return }
        BridgeCore.shared.settings.update(["refreshMs": v])
    }

    @objc private func startAtLoginToggle() {
        let on = startAtLoginBtn.state == .on
        BridgeCore.shared.applyStartAtLogin(on)
        BridgeCore.shared.settings.update(["startAtLogin": on])
    }

    @objc private func sinceChange() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        BridgeCore.shared.settings.update(["allTimeSince": f.string(from: allTimePicker.dateValue)])
    }

    @objc private func clearShortcut() {
        BridgeCore.shared.settings.update(["windowToggleShortcut": ""])
        ShortcutController.shared.apply(settings: BridgeCore.shared.settings.snapshot())
    }

    @objc private func deepseekSave() {
        let key = deepseekInput.stringValue
        guard !key.isEmpty else { return }
        CredentialStore.shared.setDeepseekApiKey(key)
        deepseekInput.stringValue = ""
        populate()
        LimitsRuntime.shared.refreshNow()
    }

    @objc private func deepseekClear() {
        CredentialStore.shared.setDeepseekApiKey("")
        populate()
        LimitsRuntime.shared.refreshNow()
    }

    @objc private func deepseekRefresh() {
        LimitsRuntime.shared.refreshNow()
    }

    @objc private func opencodeSave() {
        let name = opencodeNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let cookie = opencodeCookieField.stringValue
        guard !name.isEmpty, !cookie.isEmpty else { return }
        CredentialStore.shared.saveOpencodeProfile(name: name, cookie: cookie)
        opencodeNameField.stringValue = ""
        opencodeCookieField.stringValue = ""
        populate()
        LimitsRuntime.shared.refreshNow()
    }

    @objc private func opencodeDelete(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        CredentialStore.shared.deleteOpencodeProfile(name: name)
        populate()
        LimitsRuntime.shared.refreshNow()
    }

    @objc private func close() { onClose?() }
}
