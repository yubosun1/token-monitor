import AppKit

/// 设置面板（覆盖层）：采集客户端、刷新间隔、开机启动、起始日期、货币/汇率、
/// 视图与客户端显示顺序、会话归档、自定义定价、限额选项、DeepSeek API Key、
/// OpenCode Cookie、订阅记录、全局快捷键。直接读写 SettingsStore /
/// CredentialStore / ShortcutController / Subscriptions，不再经 IPC。
final class SettingsViewController: NSViewController {

    var onClose: (() -> Void)?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var clientCheckboxes: [(String, NSButton)] = []
    private let refreshPopUp = NSPopUpButton()
    private let startAtLoginBtn = NSButton(checkboxWithTitle: "开机时启动", target: nil, action: nil)
    private let allTimePicker = NSDatePicker()
    private let currencyPopUp = NSPopUpButton()
    private let currencyRateModeSeg = NSSegmentedControl(labels: ["自动", "手动"], trackingMode: .selectOne, target: nil, action: nil)
    private let currencyRateInput = NSTextField()
    private let currencyRateStatus = NSTextField(labelWithString: "")
    private var viewOrderRows: [(String, NSButton, HoverButton, HoverButton)] = []
    private var clientOrderRows: [(String, NSButton, HoverButton, HoverButton)] = []
    private let archiveToggle = NSButton(checkboxWithTitle: "保留已删除会话的用量", target: nil, action: nil)
    private let archiveStatus = NSTextField(labelWithString: "")
    private let pricingList = NSStackView()
    private let pricingForm = NSStackView()
    private let pricingModelField = NSTextField()
    private let pricingCacheField = NSTextField()
    private let pricingInputField = NSTextField()
    private let pricingOutputField = NSTextField()
    private let limitsRefreshPopUp = NSPopUpButton()
    private var limitProviderCheckboxes: [(String, NSButton)] = []
    private let showLimitSourceBtn = NSButton(checkboxWithTitle: "显示来源", target: nil, action: nil)
    private let maskLimitEmailsBtn = NSButton(checkboxWithTitle: "掩码账号邮箱", target: nil, action: nil)
    private let showLimitUsedSeg = NSSegmentedControl(labels: ["剩余", "已用"], trackingMode: .selectOne, target: nil, action: nil)
    private let deepseekStatus = NSTextField(labelWithString: "")
    private let deepseekInput = NSSecureTextField()
    private let opencodeList = NSStackView()
    private let opencodeNameField = NSTextField()
    private let opencodeCookieField = NSTextField()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let subscriptionList = NSStackView()
    private let subscriptionForm = NSStackView()
    private let subscriptionProviderPop = NSPopUpButton()
    private let subscriptionAccountPop = NSPopUpButton()
    private let subscriptionKindSeg = NSSegmentedControl(labels: ["订阅", "充值"], trackingMode: .selectOne, target: nil, action: nil)
    private let subscriptionPlanField = NSTextField()
    private let subscriptionAmountField = NSTextField()
    private let subscriptionCurrencyPop = NSPopUpButton()
    private let subscriptionIntervalCount = NSTextField()
    private let subscriptionIntervalPop = NSPopUpButton()
    private let subscriptionStartPicker = NSDatePicker()
    private let subscriptionAutoRenewBtn = NSButton(checkboxWithTitle: "自动续费", target: nil, action: nil)
    private let subscriptionNextPicker = NSDatePicker()
    private let subscriptionTopUpList = NSStackView()
    private let subscriptionTopUpDate = NSDatePicker()
    private let subscriptionTopUpAmount = NSTextField()
    private let subscriptionTotalLabel = NSTextField(labelWithString: "")
    private var subscriptionTopUps: [[String: Any]] = []
    private var pendingWidthConstraints: [NSLayoutConstraint] = []
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
        NSLayoutConstraint.activate(pendingWidthConstraints)
        pendingWidthConstraints.removeAll()
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

        // 通用
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

        let currencyRow = makeRow("货币")
        for (title, code) in [("USD - US Dollar", "USD"), ("TWD - 新台币", "TWD"), ("HKD - 港币", "HKD"), ("CNY - 人民币", "CNY")] {
            currencyPopUp.addItem(withTitle: title)
            currencyPopUp.itemArray.last?.representedObject = code
        }
        currencyPopUp.target = self
        currencyPopUp.action = #selector(currencyChange)
        stylePopUp(currencyPopUp)
        currencyRow.addArrangedSubview(currencyPopUp)
        general.addArrangedSubview(currencyRow)

        let rateRow = makeRow("汇率")
        currencyRateModeSeg.target = self
        currencyRateModeSeg.action = #selector(rateModeChange)
        currencyRateModeSeg.font = AppTheme.smallFont
        rateRow.addArrangedSubview(currencyRateModeSeg)
        general.addArrangedSubview(rateRow)

        currencyRateInput.placeholderString = "1 USD = ?"
        currencyRateInput.translatesAutoresizingMaskIntoConstraints = false
        currencyRateInput.heightAnchor.constraint(equalToConstant: 24).isActive = true
        currencyRateInput.target = self
        currencyRateInput.action = #selector(rateManualChange)
        general.addArrangedSubview(currencyRateInput)

        currencyRateStatus.font = AppTheme.smallFont
        currencyRateStatus.textColor = AppTheme.textTertiary
        currencyRateStatus.isBezeled = false
        currencyRateStatus.drawsBackground = false
        general.addArrangedSubview(currencyRateStatus)
        contentStack.addArrangedSubview(general)

        // 视图
        let views = makeSection("视图")
        let viewsNote = note("选择主窗口出现的视图及其顺序（底部切换器）。")
        views.addArrangedSubview(viewsNote)
        let viewsActions = NSStackView()
        viewsActions.orientation = .horizontal
        viewsActions.spacing = 8
        let resetViews = HoverButton(title: "重置顺序")
        resetViews.font = AppTheme.smallFont
        resetViews.target = self; resetViews.action = #selector(resetViewOrder)
        let showAllViewsBtn = HoverButton(title: "显示全部")
        showAllViewsBtn.font = AppTheme.smallFont
        showAllViewsBtn.target = self; showAllViewsBtn.action = #selector(showAllViews)
        viewsActions.addArrangedSubview(resetViews)
        viewsActions.addArrangedSubview(showAllViewsBtn)
        views.addArrangedSubview(viewsActions)
        for v in AppViews.all {
            let row = makeOrderRow(label: v.label, symbol: v.symbol)
            viewOrderRows.append((v.id, row.check, row.up, row.down))
            views.addArrangedSubview(row.stack)
        }
        contentStack.addArrangedSubview(views)

        // 工具顺序
        let tools = makeSection("工具（客户端显示顺序）")
        let toolsNote = note("控制工具明细与首页模块中的客户端顺序。")
        tools.addArrangedSubview(toolsNote)
        let toolsActions = NSStackView()
        toolsActions.orientation = .horizontal
        toolsActions.spacing = 8
        let resetClients = HoverButton(title: "重置顺序")
        resetClients.font = AppTheme.smallFont
        resetClients.target = self; resetClients.action = #selector(resetClientOrder)
        let showAllClientsBtn = HoverButton(title: "显示全部")
        showAllClientsBtn.font = AppTheme.smallFont
        showAllClientsBtn.target = self; showAllClientsBtn.action = #selector(showAllClients)
        toolsActions.addArrangedSubview(resetClients)
        toolsActions.addArrangedSubview(showAllClientsBtn)
        tools.addArrangedSubview(toolsActions)
        for id in allClients {
            let row = makeOrderRow(label: AppTheme.clientLabel(id), symbol: nil)
            clientOrderRows.append((id, row.check, row.up, row.down))
            tools.addArrangedSubview(row.stack)
        }
        contentStack.addArrangedSubview(tools)

        // 会话归档
        let archive = makeSection("会话历史")
        archiveToggle.target = self
        archiveToggle.action = #selector(archiveToggleChange)
        styleCheckbox(archiveToggle)
        archive.addArrangedSubview(archiveToggle)
        archive.addArrangedSubview(note("保留源工具删除会话后的总量与每日活动。原生版采集器暂未实现归档保留，此开关仅记录设置。"))
        archiveStatus.font = AppTheme.smallFont
        archiveStatus.textColor = AppTheme.textTertiary
        archiveStatus.isBezeled = false
        archiveStatus.drawsBackground = false
        archive.addArrangedSubview(archiveStatus)
        contentStack.addArrangedSubview(archive)

        // 自定义定价
        let pricing = makeSection("自定义模型定价")
        pricing.addArrangedSubview(note("覆盖模型价格（USD / 1M tokens），作用于所有提供商。"))
        pricingList.orientation = .vertical
        pricingList.alignment = .leading
        pricingList.spacing = 4
        pricing.addArrangedSubview(pricingList)
        let addPricingBtn = HoverButton(title: "+ 添加覆盖")
        addPricingBtn.font = AppTheme.smallFont
        addPricingBtn.target = self; addPricingBtn.action = #selector(togglePricingForm)
        pricing.addArrangedSubview(addPricingBtn)
        pricingForm.orientation = .vertical
        pricingForm.alignment = .leading
        pricingForm.spacing = 6
        pricingForm.isHidden = true
        pricingForm.addArrangedSubview(fieldRow("模型", pricingModelField, "如 deepseek-chat"))
        pricingForm.addArrangedSubview(fieldRow("输入(缓存命中)", pricingCacheField, "USD / 1M"))
        pricingForm.addArrangedSubview(fieldRow("输入(未命中)", pricingInputField, "USD / 1M"))
        pricingForm.addArrangedSubview(fieldRow("输出", pricingOutputField, "USD / 1M"))
        let pricingActions = NSStackView()
        pricingActions.orientation = .horizontal
        pricingActions.spacing = 8
        let pricingSaveBtn = HoverButton(title: "保存"); pricingSaveBtn.font = AppTheme.smallFont
        pricingSaveBtn.target = self; pricingSaveBtn.action = #selector(pricingSave)
        let pricingCancel = HoverButton(title: "取消"); pricingCancel.font = AppTheme.smallFont
        pricingCancel.target = self; pricingCancel.action = #selector(togglePricingForm)
        pricingActions.addArrangedSubview(pricingSaveBtn)
        pricingActions.addArrangedSubview(pricingCancel)
        pricingForm.addArrangedSubview(pricingActions)
        pricing.addArrangedSubview(pricingForm)
        contentStack.addArrangedSubview(pricing)

        // 限额
        let limits = makeSection("AI 限额")
        let limitsRefreshRow = makeRow("刷新间隔")
        for (title, ms) in [("1 min", "60000"), ("2 min", "120000"), ("5 min", "300000"), ("15 min", "900000"), ("30 min", "1800000")] {
            limitsRefreshPopUp.addItem(withTitle: title)
            limitsRefreshPopUp.itemArray.last?.representedObject = ms
        }
        limitsRefreshPopUp.target = self
        limitsRefreshPopUp.action = #selector(limitsRefreshChange)
        stylePopUp(limitsRefreshPopUp)
        limitsRefreshRow.addArrangedSubview(limitsRefreshPopUp)
        limits.addArrangedSubview(limitsRefreshRow)
        for id in ["deepseek", "opencode"] {
            let btn = NSButton(checkboxWithTitle: AppTheme.clientLabel(id), target: self, action: #selector(limitProviderToggle(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier(id)
            styleCheckbox(btn)
            limits.addArrangedSubview(btn)
            limitProviderCheckboxes.append((id, btn))
        }
        showLimitSourceBtn.target = self
        showLimitSourceBtn.action = #selector(showLimitSourceChange)
        styleCheckbox(showLimitSourceBtn)
        limits.addArrangedSubview(showLimitSourceBtn)
        maskLimitEmailsBtn.target = self
        maskLimitEmailsBtn.action = #selector(maskLimitEmailsChange)
        styleCheckbox(maskLimitEmailsBtn)
        limits.addArrangedSubview(maskLimitEmailsBtn)
        let barsRow = makeRow("条显示")
        showLimitUsedSeg.target = self
        showLimitUsedSeg.action = #selector(showLimitUsedChange)
        showLimitUsedSeg.font = AppTheme.smallFont
        barsRow.addArrangedSubview(showLimitUsedSeg)
        limits.addArrangedSubview(barsRow)
        contentStack.addArrangedSubview(limits)

        // 订阅
        let subs = makeSection("订阅")
        subs.addArrangedSubview(note("记录你为每个 AI 账号实际支付的费用。"))
        subscriptionList.orientation = .vertical
        subscriptionList.alignment = .leading
        subscriptionList.spacing = 4
        subs.addArrangedSubview(subscriptionList)
        subscriptionTotalLabel.font = AppTheme.smallFont
        subscriptionTotalLabel.textColor = AppTheme.textSecondary
        subscriptionTotalLabel.isBezeled = false
        subscriptionTotalLabel.drawsBackground = false
        subs.addArrangedSubview(subscriptionTotalLabel)
        let addSubBtn = HoverButton(title: "+ 添加订阅")
        addSubBtn.font = AppTheme.smallFont
        addSubBtn.target = self; addSubBtn.action = #selector(toggleSubscriptionForm)
        subs.addArrangedSubview(addSubBtn)

        subscriptionForm.orientation = .vertical
        subscriptionForm.alignment = .leading
        subscriptionForm.spacing = 6
        subscriptionForm.isHidden = true
        let providerRow = makeRow("提供商")
        for (title, id) in [("DeepSeek", "deepseek"), ("OpenCode", "opencode")] {
            subscriptionProviderPop.addItem(withTitle: title)
            subscriptionProviderPop.itemArray.last?.representedObject = id
        }
        subscriptionProviderPop.target = self
        subscriptionProviderPop.action = #selector(subscriptionProviderChange)
        stylePopUp(subscriptionProviderPop)
        providerRow.addArrangedSubview(subscriptionProviderPop)
        subscriptionForm.addArrangedSubview(providerRow)
        let accountRow = makeRow("账号")
        subscriptionAccountPop.target = self
        subscriptionAccountPop.action = #selector(subscriptionAccountChange)
        stylePopUp(subscriptionAccountPop)
        accountRow.addArrangedSubview(subscriptionAccountPop)
        subscriptionForm.addArrangedSubview(accountRow)
        let kindRow = makeRow("记录")
        subscriptionKindSeg.target = self
        subscriptionKindSeg.action = #selector(subscriptionKindChange)
        subscriptionKindSeg.selectedSegment = 0
        subscriptionKindSeg.font = AppTheme.smallFont
        kindRow.addArrangedSubview(subscriptionKindSeg)
        subscriptionForm.addArrangedSubview(kindRow)
        subscriptionForm.addArrangedSubview(fieldRow("套餐名", subscriptionPlanField, "可选，如 Plus"))
        subscriptionForm.addArrangedSubview(fieldRow("金额", subscriptionAmountField, "0.00"))
        let currencyRow2 = makeRow("货币")
        for (title, code) in [("USD", "USD"), ("CNY", "CNY"), ("HKD", "HKD"), ("TWD", "TWD")] {
            subscriptionCurrencyPop.addItem(withTitle: title)
            subscriptionCurrencyPop.itemArray.last?.representedObject = code
        }
        subscriptionCurrencyPop.selectItem(at: 0)
        stylePopUp(subscriptionCurrencyPop)
        currencyRow2.addArrangedSubview(subscriptionCurrencyPop)
        subscriptionForm.addArrangedSubview(currencyRow2)
        let intervalRow = makeRow("周期")
        subscriptionIntervalCount.placeholderString = "1"
        subscriptionIntervalCount.translatesAutoresizingMaskIntoConstraints = false
        subscriptionIntervalCount.widthAnchor.constraint(equalToConstant: 44).isActive = true
        subscriptionIntervalCount.heightAnchor.constraint(equalToConstant: 22).isActive = true
        for (title, value) in [("月", "month"), ("年", "year")] {
            subscriptionIntervalPop.addItem(withTitle: title)
            subscriptionIntervalPop.itemArray.last?.representedObject = value
        }
        subscriptionIntervalPop.selectItem(at: 0)
        stylePopUp(subscriptionIntervalPop)
        intervalRow.addArrangedSubview(subscriptionIntervalCount)
        intervalRow.addArrangedSubview(subscriptionIntervalPop)
        subscriptionForm.addArrangedSubview(intervalRow)
        let startRow = makeRow("首次扣费")
        subscriptionStartPicker.datePickerStyle = .textField
        subscriptionStartPicker.datePickerElements = .yearMonthDay
        subscriptionStartPicker.translatesAutoresizingMaskIntoConstraints = false
        startRow.addArrangedSubview(subscriptionStartPicker)
        subscriptionForm.addArrangedSubview(startRow)
        subscriptionAutoRenewBtn.state = .on
        styleCheckbox(subscriptionAutoRenewBtn)
        subscriptionForm.addArrangedSubview(subscriptionAutoRenewBtn)
        let nextRow = makeRow("下次扣费")
        subscriptionNextPicker.datePickerStyle = .textField
        subscriptionNextPicker.datePickerElements = .yearMonthDay
        subscriptionNextPicker.translatesAutoresizingMaskIntoConstraints = false
        nextRow.addArrangedSubview(subscriptionNextPicker)
        subscriptionForm.addArrangedSubview(nextRow)
        // 充值条目
        let topUpHeading = NSTextField(labelWithString: "充值记录")
        topUpHeading.font = AppTheme.smallFont
        topUpHeading.textColor = AppTheme.textSecondary
        topUpHeading.isBezeled = false
        topUpHeading.drawsBackground = false
        subscriptionForm.addArrangedSubview(topUpHeading)
        subscriptionTopUpList.orientation = .vertical
        subscriptionTopUpList.alignment = .leading
        subscriptionTopUpList.spacing = 3
        subscriptionForm.addArrangedSubview(subscriptionTopUpList)
        let topUpAddRow = NSStackView()
        topUpAddRow.orientation = .horizontal
        topUpAddRow.spacing = 6
        subscriptionTopUpDate.datePickerStyle = .textField
        subscriptionTopUpDate.datePickerElements = .yearMonthDay
        subscriptionTopUpDate.translatesAutoresizingMaskIntoConstraints = false
        subscriptionTopUpAmount.placeholderString = "0.00"
        subscriptionTopUpAmount.translatesAutoresizingMaskIntoConstraints = false
        subscriptionTopUpAmount.widthAnchor.constraint(equalToConstant: 70).isActive = true
        subscriptionTopUpAmount.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let topUpAddBtn = HoverButton(title: "+")
        topUpAddBtn.font = AppTheme.smallFont
        topUpAddBtn.target = self; topUpAddBtn.action = #selector(topUpAdd)
        topUpAddRow.addArrangedSubview(subscriptionTopUpDate)
        topUpAddRow.addArrangedSubview(subscriptionTopUpAmount)
        topUpAddRow.addArrangedSubview(topUpAddBtn)
        subscriptionForm.addArrangedSubview(topUpAddRow)
        let subActions = NSStackView()
        subActions.orientation = .horizontal
        subActions.spacing = 8
        let subSave = HoverButton(title: "保存订阅"); subSave.font = AppTheme.smallFont
        subSave.target = self; subSave.action = #selector(subscriptionSave)
        let subCancel = HoverButton(title: "取消"); subCancel.font = AppTheme.smallFont
        subCancel.target = self; subCancel.action = #selector(toggleSubscriptionForm)
        subActions.addArrangedSubview(subSave)
        subActions.addArrangedSubview(subCancel)
        subscriptionForm.addArrangedSubview(subActions)
        subs.addArrangedSubview(subscriptionForm)
        contentStack.addArrangedSubview(subs)

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

    // MARK: - Helpers

    private func makeSection(_ title: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        pendingWidthConstraints.append(stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor))
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
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
        pendingWidthConstraints.append(stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28))
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

    private func fieldRow(_ title: String, _ field: NSTextField, _ placeholder: String) -> NSStackView {
        let row = makeRow(title)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(field)
        return row
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppTheme.smallFont
        label.textColor = AppTheme.textTertiary
        label.isBezeled = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 240
        return label
    }

    /// 顺序行：勾选框(显示) + 上移 + 下移。
    private func makeOrderRow(label: String, symbol: String?) -> (stack: NSStackView, check: NSButton, up: HoverButton, down: HoverButton) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        pendingWidthConstraints.append(row.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28))
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        check.target = self
        check.action = #selector(orderVisibleToggle(_:))
        styleCheckbox(check)
        let name = NSTextField(labelWithString: label)
        name.font = AppTheme.bodyFont
        name.textColor = AppTheme.textPrimary
        name.isBezeled = false
        name.drawsBackground = false
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let up = HoverButton(title: "↑")
        up.font = AppTheme.smallFont
        up.target = self
        up.action = #selector(orderMoveUp(_:))
        let down = HoverButton(title: "↓")
        down.font = AppTheme.smallFont
        down.target = self
        down.action = #selector(orderMoveDown(_:))
        row.addArrangedSubview(check)
        row.addArrangedSubview(name)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(up)
        row.addArrangedSubview(down)
        return (row, check, up, down)
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

        // 货币/汇率
        let currency = (s["currency"] as? String ?? "USD").uppercased()
        for item in currencyPopUp.itemArray {
            if (item.representedObject as? String) == currency { currencyPopUp.select(item); break }
        }
        let rateMode = s["currencyRateMode"] as? String ?? "auto"
        currencyRateModeSeg.selectedSegment = rateMode == "manual" ? 1 : 0
        let rates = s["currencyRates"] as? [String: Any] ?? [:]
        let rateKey = "USD->\(currency)"
        let rate = rates[rateKey] as? Double
        currencyRateInput.isHidden = rateMode != "manual"
        if let rate, rate > 0, currencyRateInput.stringValue.isEmpty {
            currencyRateInput.stringValue = String(format: "%.4f", rate)
        }
        if rateMode == "manual" {
            if let rate, rate > 0 {
                currencyRateStatus.stringValue = String(format: "1 USD = %.4f %@", rate, currency)
            } else {
                currencyRateStatus.stringValue = "手动汇率未设置，将使用 1:1"
            }
        } else {
            if let rate, rate > 0 {
                currencyRateStatus.stringValue = String(format: "自动汇率: 1 USD = %.4f %@", rate, currency)
            } else {
                currencyRateStatus.stringValue = "汇率未配置"
            }
        }

        // 视图顺序
        let viewOrder = AppViews.normalizeViewDisplayOrder(s["viewDisplayOrder"])
        let hiddenViews = Set(AppViews.normalizeHiddenViews(s["hiddenViews"]))
        for (id, check, _, _) in viewOrderRows {
            check.state = hiddenViews.contains(id) ? .off : .on
        }
        reorderRows(viewOrderRows, order: viewOrder)

        // 客户端顺序
        let clientOrder = AppViews.normalizeViewDisplayOrder(s["clientDisplayOrder"])
        let hiddenClients = Set(AppViews.csvItems(s["hiddenClients"]).map { $0.lowercased() })
        for (id, check, _, _) in clientOrderRows {
            check.state = hiddenClients.contains(id) ? .off : .on
        }
        reorderRows(clientOrderRows, order: clientOrder)

        // 归档
        archiveToggle.state = (s["sessionUsageArchiveEnabled"] as? Bool ?? true) ? .on : .off
        archiveStatus.stringValue = "原生版采集器未实现归档保留"

        // 自定义定价
        renderPricingList()

        // 限额
        let limitsRefreshMs = String(Int(UsageCore.doubleValue(s["limitsRefreshMs"])))
        for item in limitsRefreshPopUp.itemArray {
            if (item.representedObject as? String) == limitsRefreshMs { limitsRefreshPopUp.select(item); break }
        }
        let limitProviders = ((s["limitProviders"] as? String) ?? "deepseek,opencode").split(separator: ",").map { String($0).lowercased() }
        for (id, btn) in limitProviderCheckboxes {
            btn.state = limitProviders.contains(id) ? .on : .off
        }
        showLimitSourceBtn.state = (s["showLimitSource"] as? Bool ?? false) ? .on : .off
        maskLimitEmailsBtn.state = (s["maskLimitAccountEmails"] as? Bool ?? false) ? .on : .off
        showLimitUsedSeg.selectedSegment = (s["showLimitUsed"] as? Bool ?? false) ? 1 : 0

        // 订阅
        renderSubscriptionList()

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
            opencodeList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: opencodeList.widthAnchor).isActive = true
        }
    }

    private func reorderRows(_ rows: [(String, NSButton, HoverButton, HoverButton)], order: [String]) {
        for (id, check, up, down) in rows {
            guard let index = order.firstIndex(of: id) else { continue }
            up.isEnabled = index > 0
            down.isEnabled = index < order.count - 1
        }
    }

    // MARK: - Custom pricing

    private func renderPricingList() {
        pricingList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = BridgeCore.shared.settings.snapshot()
        let entries = s["customModelPricing"] as? [[String: Any]] ?? []
        for entry in entries {
            let modelId = entry["modelId"] as? String ?? ""
            let input = entry["inputPerM"] as? Double
            let output = entry["outputPerM"] as? Double
            let cache = entry["cacheReadPerM"] as? Double
            var parts: [String] = []
            if let cache { parts.append("读 \(String(format: "%.4f", cache))") }
            if let input { parts.append("入 \(String(format: "%.4f", input))") }
            if let output { parts.append("出 \(String(format: "%.4f", output))") }
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let name = NSTextField(labelWithString: "\(modelId) — \(parts.joined(separator: " · "))")
            name.font = AppTheme.smallFont
            name.textColor = AppTheme.textPrimary
            name.isBezeled = false
            name.drawsBackground = false
            name.lineBreakMode = .byTruncatingTail
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let del = HoverButton(title: "删除")
            del.font = AppTheme.smallFont
            del.identifier = NSUserInterfaceItemIdentifier(modelId)
            del.target = self
            del.action = #selector(pricingDelete(_:))
            row.addArrangedSubview(name)
            row.addArrangedSubview(del)
            pricingList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: pricingList.widthAnchor).isActive = true
        }
    }

    @objc private func togglePricingForm() {
        pricingForm.isHidden.toggle()
    }

    @objc private func pricingDelete(_ sender: NSButton) {
        guard let modelId = sender.identifier?.rawValue else { return }
        let s = BridgeCore.shared.settings.snapshot()
        let entries = (s["customModelPricing"] as? [[String: Any]] ?? []).filter { ($0["modelId"] as? String) != modelId }
        BridgeCore.shared.settings.update(["customModelPricing": entries])
    }

    @objc private func pricingSave() {
        let modelId = pricingModelField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !modelId.isEmpty else { return }
        func price(_ field: NSTextField) -> Double? {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            guard let v = Double(text), v >= 0, v.isFinite else { return nil }
            return v
        }
        var entry: [String: Any] = ["modelId": modelId]
        if let v = price(pricingCacheField) { entry["cacheReadPerM"] = v }
        if let v = price(pricingInputField) { entry["inputPerM"] = v }
        if let v = price(pricingOutputField) { entry["outputPerM"] = v }
        let s = BridgeCore.shared.settings.snapshot()
        var entries = (s["customModelPricing"] as? [[String: Any]] ?? []).filter { ($0["modelId"] as? String) != modelId }
        entries.append(entry)
        BridgeCore.shared.settings.update(["customModelPricing": entries])
        pricingModelField.stringValue = ""
        pricingCacheField.stringValue = ""
        pricingInputField.stringValue = ""
        pricingOutputField.stringValue = ""
        pricingForm.isHidden = true
    }

    // MARK: - Subscriptions

    private func renderSubscriptionList() {
        subscriptionList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = BridgeCore.shared.settings.snapshot()
        let subscriptions = Subscriptions.normalizeSubscriptions(s["subscriptions"])
        for record in subscriptions {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let provider = record["provider"] as? String ?? ""
            let planName = record["planName"] as? String ?? ""
            let kind = record["kind"] as? String ?? "subscription"
            let amountMinor = UsageCore.intValue(record["amountMinor"])
            let currency = record["currency"] as? String ?? "USD"
            let sym = Fmt.currencySymbol(currency)
            let interval = record["interval"] as? String ?? "month"
            let intervalCount = UsageCore.intValue(record["intervalCount"])
            let labelText = "\(AppTheme.clientLabel(provider))\(planName.isEmpty ? "" : " · \(planName)") — \(sym)\(String(format: "%.2f", Double(amountMinor) / 100))/\(intervalCount)\(interval == "month" ? "月" : "年")"
            let label = NSTextField(labelWithString: labelText)
            label.font = AppTheme.smallFont
            label.textColor = AppTheme.textPrimary
            label.isBezeled = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let del = HoverButton(title: "删除")
            del.font = AppTheme.smallFont
            del.identifier = NSUserInterfaceItemIdentifier(record["id"] as? String ?? "")
            del.target = self
            del.action = #selector(subscriptionDelete(_:))
            row.addArrangedSubview(label)
            row.addArrangedSubview(del)
            subscriptionList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: subscriptionList.widthAnchor).isActive = true
        }
        // 合计：订阅月均 + 充值总额
        let monthSum = subscriptions.filter { $0["kind"] as? String == "subscription" }.reduce(0.0) { sum, r in
            let amount = UsageCore.doubleValue(r["amountMinor"]) / 100
            let count = UsageCore.doubleValue(r["intervalCount"]) > 0 ? UsageCore.doubleValue(r["intervalCount"]) : 1
            let interval = r["interval"] as? String ?? "month"
            return sum + amount / (interval == "year" ? 12 : 1) * count
        }
        let topUpSum = subscriptions.filter { $0["kind"] as? String == "topup" }.reduce(0.0) { sum, r in
            return sum + (r["topUps"] as? [[String: Any]] ?? []).reduce(0.0) { $0 + UsageCore.doubleValue($1["amountMinor"]) / 100 }
        }
        subscriptionTotalLabel.stringValue = subscriptions.isEmpty
            ? ""
            : "共 \(subscriptions.count) 条 · 订阅月均 $\(String(format: "%.2f", monthSum)) · 充值合计 $\(String(format: "%.2f", topUpSum))"
    }

    @objc private func toggleSubscriptionForm() {
        subscriptionForm.isHidden.toggle()
        if !subscriptionForm.isHidden {
            subscriptionTopUps.removeAll()
            renderTopUps()
            refreshSubscriptionAccounts()
            subscriptionStartPicker.dateValue = Date()
            subscriptionNextPicker.dateValue = Date()
        }
    }

    private func refreshSubscriptionAccounts() {
        subscriptionAccountPop.removeAllItems()
        let provider = subscriptionProviderPop.selectedItem?.representedObject as? String ?? "deepseek"
        if provider == "deepseek" {
            subscriptionAccountPop.addItem(withTitle: "Pay-as-you-go")
            subscriptionAccountPop.itemArray.last?.representedObject = ""
        } else {
            for profile in CredentialStore.shared.opencodeProfiles() where profile.enabled {
                subscriptionAccountPop.addItem(withTitle: profile.name)
                subscriptionAccountPop.itemArray.last?.representedObject = profile.name
            }
            if subscriptionAccountPop.numberOfItems == 0 {
                subscriptionAccountPop.addItem(withTitle: "（无已启用账号）")
                subscriptionAccountPop.itemArray.last?.representedObject = ""
            }
        }
    }

    private func renderTopUps() {
        subscriptionTopUpList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, entry) in subscriptionTopUps.enumerated() {
            let date = entry["date"] as? String ?? ""
            let amount = UsageCore.doubleValue(entry["amountMinor"]) / 100
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let label = NSTextField(labelWithString: "\(date)  $\(String(format: "%.2f", amount))")
            label.font = AppTheme.smallFont
            label.textColor = AppTheme.textPrimary
            label.isBezeled = false
            label.drawsBackground = false
            let del = HoverButton(title: "×")
            del.font = AppTheme.smallFont
            del.tag = index
            del.target = self
            del.action = #selector(topUpRemove(_:))
            row.addArrangedSubview(label)
            row.addArrangedSubview(del)
            subscriptionTopUpList.addArrangedSubview(row)
        }
    }

    private func dateString(_ picker: NSDatePicker) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: picker.dateValue)
    }

    @objc private func topUpAdd() {
        let amount = Double(subscriptionTopUpAmount.stringValue) ?? 0
        guard amount > 0 else { return }
        subscriptionTopUps.append([
            "date": dateString(subscriptionTopUpDate),
            "amountMinor": Int((amount * 100).rounded()),
        ])
        subscriptionTopUpAmount.stringValue = ""
        renderTopUps()
    }

    @objc private func topUpRemove(_ sender: NSButton) {
        guard subscriptionTopUps.indices.contains(sender.tag) else { return }
        subscriptionTopUps.remove(at: sender.tag)
        renderTopUps()
    }

    @objc private func subscriptionSave() {
        let provider = subscriptionProviderPop.selectedItem?.representedObject as? String ?? ""
        let account = subscriptionAccountPop.selectedItem?.representedObject as? String ?? ""
        let kind = subscriptionKindSeg.selectedSegment == 1 ? "topup" : "subscription"
        let currency = subscriptionCurrencyPop.selectedItem?.representedObject as? String ?? "USD"
        let interval = subscriptionIntervalPop.selectedItem?.representedObject as? String ?? "month"
        let intervalCount = Int(subscriptionIntervalCount.stringValue) ?? 1

        var record: [String: Any] = [
            "provider": provider,
            "kind": kind,
            "currency": currency,
            "interval": interval,
            "intervalCount": intervalCount,
            "binding": ["profileName": account],
        ]
        if kind == "topup" {
            guard !subscriptionTopUps.isEmpty else { return }
            record["topUps"] = subscriptionTopUps
        } else {
            let amount = Double(subscriptionAmountField.stringValue) ?? 0
            guard amount > 0 else { return }
            record["amountMinor"] = Int((amount * 100).rounded())
            record["planName"] = subscriptionPlanField.stringValue.trimmingCharacters(in: .whitespaces)
            record["startDate"] = dateString(subscriptionStartPicker)
            record["autoRenew"] = subscriptionAutoRenewBtn.state == .on
            record["nextRenewalOverride"] = dateString(subscriptionNextPicker)
        }
        guard let normalized = Subscriptions.normalizeSubscription(record) else { return }
        let s = BridgeCore.shared.settings.snapshot()
        var list = Subscriptions.normalizeSubscriptions(s["subscriptions"])
        list.append(normalized)
        BridgeCore.shared.settings.update(["subscriptions": list])
        subscriptionForm.isHidden = true
        subscriptionPlanField.stringValue = ""
        subscriptionAmountField.stringValue = ""
        subscriptionIntervalCount.stringValue = ""
    }

    @objc private func subscriptionDelete(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        let s = BridgeCore.shared.settings.snapshot()
        let list = Subscriptions.normalizeSubscriptions(s["subscriptions"]).filter { ($0["id"] as? String) != id }
        BridgeCore.shared.settings.update(["subscriptions": list])
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

    @objc private func currencyChange() {
        guard let code = currencyPopUp.selectedItem?.representedObject as? String else { return }
        BridgeCore.shared.settings.update(["currency": code])
        populate()
    }

    @objc private func rateModeChange() {
        let mode = currencyRateModeSeg.selectedSegment == 1 ? "manual" : "auto"
        BridgeCore.shared.settings.update(["currencyRateMode": mode])
        populate()
    }

    @objc private func rateManualChange() {
        guard let v = Double(currencyRateInput.stringValue), v > 0 else { return }
        let s = BridgeCore.shared.settings.snapshot()
        let currency = (s["currency"] as? String ?? "USD").uppercased()
        var rates = s["currencyRates"] as? [String: Any] ?? [:]
        rates["USD->\(currency)"] = v
        BridgeCore.shared.settings.update(["currencyRates": rates])
        populate()
    }

    // 顺序/隐藏（视图与客户端共用）

    @objc private func orderVisibleToggle(_ sender: NSButton) {
        let s = BridgeCore.shared.settings.snapshot()
        let isView = viewOrderRows.contains { $0.1 === sender }
        if isView {
            guard let entry = viewOrderRows.first(where: { $0.1 === sender }) else { return }
            BridgeCore.shared.settings.update([
                "hiddenViews": AppViews.toggleHidden(s["hiddenViews"], viewId: entry.0, hide: sender.state == .off)
            ])
        } else {
            guard let entry = clientOrderRows.first(where: { $0.1 === sender }) else { return }
            var hidden = AppViews.csvItems(s["hiddenClients"]).map { $0.lowercased() }
            if sender.state == .off {
                if !hidden.contains(entry.0) { hidden.append(entry.0) }
            } else {
                hidden.removeAll { $0 == entry.0 }
            }
            BridgeCore.shared.settings.update(["hiddenClients": hidden.joined(separator: ",")])
        }
    }

    @objc private func orderMoveUp(_ sender: NSButton) {
        let s = BridgeCore.shared.settings.snapshot()
        if let entry = viewOrderRows.first(where: { $0.2 === sender }) {
            BridgeCore.shared.settings.update(["viewDisplayOrder": AppViews.moveView(s["viewDisplayOrder"], viewId: entry.0, direction: -1)])
        } else if let entry = clientOrderRows.first(where: { $0.2 === sender }) {
            BridgeCore.shared.settings.update(["clientDisplayOrder": AppViews.moveView(s["clientDisplayOrder"], viewId: entry.0, direction: -1)])
        }
    }

    @objc private func orderMoveDown(_ sender: NSButton) {
        let s = BridgeCore.shared.settings.snapshot()
        if let entry = viewOrderRows.first(where: { $0.3 === sender }) {
            BridgeCore.shared.settings.update(["viewDisplayOrder": AppViews.moveView(s["viewDisplayOrder"], viewId: entry.0, direction: 1)])
        } else if let entry = clientOrderRows.first(where: { $0.3 === sender }) {
            BridgeCore.shared.settings.update(["clientDisplayOrder": AppViews.moveView(s["clientDisplayOrder"], viewId: entry.0, direction: 1)])
        }
    }

    @objc private func resetViewOrder() {
        BridgeCore.shared.settings.update(["viewDisplayOrder": ""])
    }

    @objc private func showAllViews() {
        BridgeCore.shared.settings.update(["hiddenViews": ""])
    }

    @objc private func resetClientOrder() {
        BridgeCore.shared.settings.update(["clientDisplayOrder": ""])
    }

    @objc private func showAllClients() {
        BridgeCore.shared.settings.update(["hiddenClients": ""])
    }

    @objc private func archiveToggleChange() {
        BridgeCore.shared.settings.update(["sessionUsageArchiveEnabled": archiveToggle.state == .on])
    }

    @objc private func limitsRefreshChange() {
        guard let ms = limitsRefreshPopUp.selectedItem?.representedObject as? String, let v = Int(ms) else { return }
        BridgeCore.shared.settings.update(["limitsRefreshMs": v])
    }

    @objc private func limitProviderToggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let s = BridgeCore.shared.settings.snapshot()
        var list = ((s["limitProviders"] as? String) ?? "deepseek,opencode").split(separator: ",").map { String($0).lowercased() }
        if sender.state == .on { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
        BridgeCore.shared.settings.update(["limitProviders": list.joined(separator: ",")])
        LimitsRuntime.shared.refreshNow()
    }

    @objc private func showLimitSourceChange() {
        BridgeCore.shared.settings.update(["showLimitSource": showLimitSourceBtn.state == .on])
    }

    @objc private func maskLimitEmailsChange() {
        BridgeCore.shared.settings.update(["maskLimitAccountEmails": maskLimitEmailsBtn.state == .on])
    }

    @objc private func showLimitUsedChange() {
        BridgeCore.shared.settings.update(["showLimitUsed": showLimitUsedSeg.selectedSegment == 1])
    }

    @objc private func subscriptionProviderChange() {
        refreshSubscriptionAccounts()
    }

    @objc private func subscriptionAccountChange() {}

    @objc private func subscriptionKindChange() {
        let topUp = subscriptionKindSeg.selectedSegment == 1
        subscriptionAmountField.isHidden = topUp
        subscriptionPlanField.isHidden = topUp
        subscriptionCurrencyPop.isHidden = false
        subscriptionIntervalCount.isHidden = topUp
        subscriptionIntervalPop.isHidden = topUp
        subscriptionStartPicker.isHidden = topUp
        subscriptionAutoRenewBtn.isHidden = topUp
        subscriptionNextPicker.isHidden = topUp
        subscriptionTopUpList.isHidden = !topUp
        subscriptionTopUpDate.isHidden = !topUp
        subscriptionTopUpAmount.isHidden = !topUp
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
