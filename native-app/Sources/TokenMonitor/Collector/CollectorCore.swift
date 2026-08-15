import Foundation
import AppKit

/// Usage collector: tokscale (claude/codex/opencode/workbuddy) + the local
/// proma/hanako/dsh adapters, assembled into the exact aggregate stats shape
/// the Electron version's renderer consumes. Timer-driven: local adapters
/// refresh every refreshMs; tokscale full scans run at collectionIntervalMs
/// (5 min default) because each period scan reloads every session file.
final class Collector {
    static let shared = Collector()

    private let core = BridgeCore.shared
    private let queue = DispatchQueue(label: "collector", qos: .utility)
    private let stateLock = NSLock()

    private var timer: Timer?
    private var collecting = false
    private var statsCache: [String: Any]?
    private var lastFullTickAt = Date.distantPast
    private var cachedTokscale: [String: [String: Any]]?
    private var cachedHistory: [String: Any]?
    private var cachedAdapterRows: [String: [UsageCore.UsageRow]] = [:]
    private var cachedPricing: [String: TokscalePricing] = [:]
    private var cachedPeriods: (today: [String: Any], month: [String: Any], allTime: [String: Any])?
    private var cachedClients: [String] = []

    private let tokscaleClientIds = Set(["claude", "codex", "opencode", "workbuddy"])

    func start() {
        guard timer == nil else { return }
        let interval = refreshInterval()
        // The timer only triggers: every tick runs on the serial collector
        // queue (the initial full tick and refreshNow() use the same queue),
        // so scanning, parsing and the stats push never block the main thread.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.queue.async { [weak self] in self?.tick(full: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        queue.async { [weak self] in self?.tick(full: true) }
    }

    private func refreshInterval() -> TimeInterval {
        let ms = (core.settings.snapshot()["refreshMs"] as? Double) ?? 15000
        return max(3.0, ms / 1000.0)
    }

    private func fullInterval() -> TimeInterval {
        let ms = (core.settings.snapshot()["collectionIntervalMs"] as? Double) ?? 300000
        return max(refreshInterval(), ms / 1000.0)
    }

    func refreshNow() {
        queue.async { [weak self] in self?.tick(full: true) }
    }

    func latestStats() -> [String: Any]? {
        stateLock.lock(); defer { stateLock.unlock() }
        return statsCache
    }

    func history() -> [String: Any]? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedHistory
    }

    // MARK: - Ticks

    private func tick(full: Bool) {
        guard !collecting else { return }
        collecting = true
        defer { collecting = false }

        let settings = core.settings.snapshot()
        let clients = enabledClients(settings)
        guard !clients.isEmpty else { return }

        syncCustomPricing(settings["customModelPricing"])

        let fullTick = full || Date().timeIntervalSince(lastFullTickAt) >= fullInterval()
        let collectedAt = Date()

        // Local adapters: cheap, refresh every tick.
        var adapterRows: [String: [UsageCore.UsageRow]] = [:]
        for client in ["proma", "hanako", "dsh"] where clients.contains(client) {
            switch client {
            case "proma": adapterRows["proma"] = Adapters.collectPromaRows()
            case "hanako": adapterRows["hanako"] = Adapters.collectHanakoRows()
            case "dsh": adapterRows["dsh"] = Adapters.collectDshRows()
            default: break
            }
        }
        cachedAdapterRows = adapterRows

        var pricing = cachedPricing
        for (_, rows) in adapterRows {
            for (model, p) in Adapters.pricingMap(forRows: rows) where pricing[model] == nil {
                pricing[model] = p
            }
        }
        cachedPricing = pricing

        // tokscale clients: full scan at most every collectionIntervalMs.
        let tokscaleClients = clients.filter { tokscaleClientIds.contains($0) }
        if fullTick {
            if let periods = scanTokscalePeriods(clients: tokscaleClients, settings: settings, now: collectedAt) {
                cachedTokscale = periods
                lastFullTickAt = Date()
            }
        }

        let tokscalePeriods = cachedTokscale ?? ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]

        let adapterPeriods = adapterPeriodsFor(clients: clients, rowsByClient: adapterRows, pricing: pricing, now: collectedAt, allTimeSince: allTimeSinceMs(settings))

        let today = UsageCore.mergePeriods([tokscalePeriods["today"] ?? UsageCore.emptyPeriod()] + adapterPeriods.map { $0["today"] ?? UsageCore.emptyPeriod() })
        let month = UsageCore.mergePeriods([tokscalePeriods["month"] ?? UsageCore.emptyPeriod()] + adapterPeriods.map { $0["month"] ?? UsageCore.emptyPeriod() })
        let allTime = UsageCore.mergePeriods([tokscalePeriods["allTime"] ?? UsageCore.emptyPeriod()] + adapterPeriods.map { $0["allTime"] ?? UsageCore.emptyPeriod() })

        // History: graph scan on full ticks, adapter contributions every tick.
        if fullTick {
            let built = buildHistory(clients: clients, tokscaleClients: tokscaleClients, adapterRows: adapterRows, pricing: pricing, now: collectedAt)
            stateLock.lock()
            cachedHistory = built
            stateLock.unlock()
            core.push("dashboard:historyChanged", NSNull())
        }
        let history = cachedHistory

        let stats = buildStats(
            settings: settings,
            clients: clients,
            today: today,
            month: month,
            allTime: allTime,
            history: history,
            collectedAt: collectedAt
        )

        cachedPeriods = (today, month, allTime)
        cachedClients = clients
        // Content-signature comparison: when nothing about the periods or
        // client statuses changed, update the cache but skip the push so the
        // renderer is not forced through a full re-render every 15s. Limits
        // refreshes re-push through reemitStats() and are not affected.
        stateLock.lock()
        let previous = statsCache
        statsCache = stats
        stateLock.unlock()
        if previous == nil || contentSignature(stats) != contentSignature(previous!) {
            core.push("stats:push", stats)
        }

        if ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil {
            let t = today["totalTokens"] as? Int ?? 0
            let m = month["totalTokens"] as? Int ?? 0
            let a = allTime["totalTokens"] as? Int ?? 0
            let clients = (allTime["clients"] as? [String: Any] ?? [:]).mapValues { $0 }
            let costs = (allTime["clientCosts"] as? [String: Any] ?? [:]).mapValues { $0 }
            NSLog("[diag] collected: today=%d month=%d allTime=%d allTimeClients=%@ costs=%@", t, m, a, clients.description, costs.description)
        }
    }

    /// Re-wrap the last collected periods with the current settings/limits and
    /// push, so a limits refresh lands in the renderer without a usage tick.
    func reemitStats() {
        queue.async { [weak self] in
            guard let self, let periods = self.cachedPeriods else { return }
            let settings = self.core.settings.snapshot()
            let clients = self.cachedClients.isEmpty ? self.enabledClients(settings) : self.cachedClients
            let stats = self.buildStats(
                settings: settings,
                clients: clients,
                today: periods.today,
                month: periods.month,
                allTime: periods.allTime,
                history: self.cachedHistory,
                collectedAt: Date()
            )
            self.stateLock.lock()
            self.statsCache = stats
            self.stateLock.unlock()
            self.core.push("stats:push", stats)
        }
    }

    // MARK: - Components

    private func enabledClients(_ settings: [String: Any]) -> [String] {
        let csv = settings["clients"] as? String ?? "claude,codex,opencode,workbuddy,proma,hanako,dsh"
        return csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private func allTimeSinceMs(_ settings: [String: Any]) -> Double {
        let raw = settings["allTimeSince"] as? String ?? "2024-01-01"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: raw) {
            return date.timeIntervalSince1970 * 1000
        }
        return 0
    }

    private func scanTokscalePeriods(clients: [String], settings: [String: Any], now: Date) -> [String: [String: Any]]? {
        guard !clients.isEmpty else { return ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()] }
        do {
            var result: [String: [String: Any]] = [:]
            let since = settings["allTimeSince"] as? String ?? "2024-01-01"
            for (period, flag) in [("today", "today"), ("month", "month"), ("allTime", "allTime")] {
                let entries = try TokscaleRunner.shared.usage(clients: clients, period: period, allTimeSince: since)
                let rows = entries.map(UsageCore.rowFromTokscaleEntry)
                result[period] = UsageCore.extractPeriod(entries: rows)
                _ = flag
            }
            return result
        } catch {
            NSLog("[collector] tokscale scan failed: %@", String(describing: error))
            return nil
        }
    }

    private func adapterPeriodsFor(clients: [String], rowsByClient: [String: [UsageCore.UsageRow]], pricing: [String: TokscalePricing], now: Date, allTimeSince: Double) -> [[String: [String: Any]]] {
        var periods: [[String: [String: Any]]] = []
        for client in clients where rowsByClient[client] != nil {
            let rows = rowsByClient[client] ?? []
            let todayStart = Adapters.localDayStart(now)
            let monthStart = Adapters.localMonthStart(now)
            var entryRows: [String: [UsageCore.UsageRow]] = [:]
            entryRows["today"] = Adapters.periodRows(rows: rows, sinceMs: todayStart, client: client, includeUndated: false)
            entryRows["month"] = Adapters.periodRows(rows: rows, sinceMs: monthStart, client: client, includeUndated: false)
            entryRows["allTime"] = Adapters.periodRows(rows: rows, sinceMs: allTimeSince, client: client, includeUndated: true)

            var clientPeriods: [String: [String: Any]] = [:]
            for (period, rows) in entryRows {
                // Attach costs from the shared pricing map.
                var priced = rows
                for i in 0..<priced.count {
                    priced[i].cost = Adapters.estimatedRowCost(row: priced[i], pricingByModel: pricing) ?? 0
                }
                clientPeriods[period] = UsageCore.extractPeriod(entries: priced)
            }
            periods.append(clientPeriods)
        }
        return periods
    }

    private func buildHistory(clients: [String], tokscaleClients: [String], adapterRows: [String: [UsageCore.UsageRow]], pricing: [String: TokscalePricing], now: Date) -> [String: Any] {
        var days: [HistoryCore.Day] = []
        var totalActiveTimeOverride: Double? = nil
        if !tokscaleClients.isEmpty {
            if let graph = try? TokscaleRunner.shared.graph(clients: tokscaleClients) {
                days = HistoryCore.parseTokscaleGraph(graph)
                totalActiveTimeOverride = graph.timeMetrics?.totalActiveTimeMs
            }
        }
        var contributions: [Adapters.HistoryContribution] = []
        for client in clients where adapterRows[client] != nil {
            contributions += Adapters.historyContributions(rows: adapterRows[client] ?? [], client: client, pricingByModel: pricing)
        }
        HistoryCore.mergeAdapterContributions(contributions, into: &days)
        return HistoryCore.normalizeHistory(days: days, todayKey: nil, totalActiveTimeMsOverride: totalActiveTimeOverride)
    }

    private func buildStats(settings: [String: Any], clients: [String], today: [String: Any], month: [String: Any], allTime: [String: Any], history: [String: Any]?, collectedAt: Date) -> [String: Any] {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let nowIso = ISO8601DateFormatter().string(from: collectedAt)
        let windows = periodWindows(collectedAt)

        let clientStatus = deriveClientStatus(clients: clients, allTimePeriod: allTime)
        let limitsSummary = LimitsRuntime.shared.summary()

        let device: [String: Any] = [
            "deviceId": settings["deviceId"] as? String ?? "macbook-pro-local",
            "hostname": Host.current().localizedName ?? "MacBook Pro",
            "platform": "darwin-arm64",
            "osName": "macOS",
            "osVersion": osVersionString,
            "updatedAt": nowIso,
            "receivedAt": nowIso,
            "agentVersion": "0.44.0-native",
            "agentRuntime": "native",
            "projectsEnabled": false,
            "trackedClients": clients,
            "clientStatus": clientStatus,
            "periodWindows": windows,
            "ageMs": 0,
            "stale": false,
            "periods": ["today": today, "month": month, "allTime": allTime],
            "limits": limitsSummary
        ]

        var stats: [String: Any] = [
            "updatedAt": nowIso,
            "periods": ["today": today, "month": month, "allTime": allTime],
            "devices": [device],
            "projectsIncomplete": false,
            "limits": limitsSummary
        ]
        if let history {
            stats["history"] = history
            // Port of history.js historyPreview(): the trends view and the
            // home heatmap both consume state.stats.historyPreview.
            stats["historyPreview"] = historyPreview(from: history)
        }
        return stats
    }

    /// Port of src/shared/history.js historyPreview(history, {dailyDays: 30,
    /// monthlyMonths: 12}): keep the last 30 daily entries and 12 monthly
    /// entries with the four chart keys, plus the summary untouched.
    private func historyPreview(from history: [String: Any]) -> [String: Any] {
        let daily = (history["daily"] as? [[String: Any]] ?? []).suffix(30).map { day -> [String: Any] in
            return [
                "date": day["date"] ?? "",
                "tokens": UsageCore.doubleValue(day["tokens"]),
                "cost": UsageCore.doubleValue(day["cost"]),
                "activeTimeMs": UsageCore.doubleValue(day["activeTimeMs"])
            ]
        }
        let monthly = (history["monthly"] as? [[String: Any]] ?? []).suffix(12).map { month -> [String: Any] in
            return [
                "month": month["month"] ?? "",
                "tokens": UsageCore.doubleValue(month["tokens"]),
                "cost": UsageCore.doubleValue(month["cost"]),
                "activeTimeMs": UsageCore.doubleValue(month["activeTimeMs"])
            ]
        }
        return [
            "daily": Array(daily),
            "monthly": Array(monthly),
            "summary": history["summary"] ?? [String: Any]()
        ]
    }

    private func periodWindows(_ now: Date) -> [String: Any] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let monthComps = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: monthComps) ?? now
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart

        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"
        let monthKeyFormatter = DateFormatter()
        monthKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthKeyFormatter.dateFormat = "yyyy-MM"

        return [
            "today": [
                "key": dayKeyFormatter.string(from: now),
                "endsAt": ISO8601DateFormatter().string(from: nextDay)
            ],
            "month": [
                "key": monthKeyFormatter.string(from: now),
                "endsAt": ISO8601DateFormatter().string(from: nextMonth)
            ]
        ]
    }

    /// Stable content signature of a stats frame for the push gate: the three
    /// periods' token/cost totals, per-client costs and client statuses.
    /// Volatile keys (updatedAt/receivedAt/collectedAt) are intentionally
    /// excluded so an unchanged frame does not force a renderer re-render.
    private func contentSignature(_ stats: [String: Any]) -> String {
        var parts: [String] = []
        let periods = stats["periods"] as? [String: Any] ?? [:]
        for name in ["today", "month", "allTime"] {
            guard let period = periods[name] as? [String: Any] else { continue }
            parts.append("\(name)=\(UsageCore.intValue(period["totalTokens"])):\(String(format: "%.4f", UsageCore.doubleValue(period["costUsd"])))")
            if let costs = period["clientCosts"] as? [String: Any] {
                for (client, cost) in costs.sorted(by: { $0.key < $1.key }) {
                    parts.append("\(name).cc.\(client)=\(String(format: "%.4f", UsageCore.doubleValue(cost)))")
                }
            }
        }
        if let device = (stats["devices"] as? [[String: Any]])?.first,
           let statuses = device["clientStatus"] as? [String: Any] {
            for (client, status) in statuses.sorted(by: { $0.key < $1.key }) {
                parts.append("cs.\(client)=\(status)")
            }
        }
        return parts.joined(separator: "|")
    }

    private func deriveClientStatus(clients: [String], allTimePeriod: [String: Any]) -> [String: String] {
        let usageClients = allTimePeriod["clients"] as? [String: Any] ?? [:]
        var status: [String: String] = [:]
        for client in clients {
            if UsageCore.intValue(usageClients[client]) > 0 {
                status[client] = "active"
            } else if dataDirExists(client) {
                status[client] = "waiting"
            } else {
                status[client] = "missing"
            }
        }
        return status
    }

    private func dataDirExists(_ client: String) -> Bool {
        let home = NSHomeDirectory()
        let candidates: [String]
        switch client {
        case "claude": candidates = ["\(home)/.claude/projects", "\(home)/.claude"]
        case "codex": candidates = ["\(home)/.codex/sessions", "\(home)/.codex"]
        case "opencode": candidates = ["\(home)/.local/share/opencode/storage/message", "\(home)/.local/share/opencode"]
        case "workbuddy": candidates = ["\(home)/.workbuddy"]
        case "proma": candidates = ["\(home)/.proma/agent-sessions", "\(home)/.proma"]
        case "hanako": candidates = ["\(home)/.hanako/agents/hanako/sessions", "\(home)/.hanako"]
        case "dsh": candidates = ["\(home)/.dsh/sessions", "\(home)/.dsh"]
        default: candidates = []
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Custom pricing sidecar (port of tokscaleCustomPricing.js)

    private func syncCustomPricing(_ settingValue: Any?) {
        let entries = normalizeCustomPricing(settingValue)
        let pricingPath = NSHomeDirectory() + "/.config/tokscale/custom-pricing.json"
        let sidecarPath = core.settings.fileURL.deletingLastPathComponent().appendingPathComponent("tokscale-managed-pricing.json").path
        let managedModels = buildTokscaleModels(entries)

        let existing: [String: Any]? = (try? Data(contentsOf: URL(fileURLWithPath: pricingPath))).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let existingModels = existing?["models"] as? [String: Any] ?? [:]
        let sidecar: [String: Any]? = (try? Data(contentsOf: URL(fileURLWithPath: sidecarPath))).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let previousManagedIds = sidecar?["managedIds"] as? [String] ?? []

        if managedModels.isEmpty && previousManagedIds.isEmpty && existing == nil { return }

        var merged = existingModels
        for id in previousManagedIds where managedModels[id] == nil {
            merged.removeValue(forKey: id)
        }
        for (id, models) in managedModels {
            merged[id] = models
        }

        writeJsonAtomic(["models": merged], to: pricingPath)
        writeJsonAtomic(["version": 1, "managedIds": Array(managedModels.keys)], to: sidecarPath)
    }

    private func normalizeCustomPricing(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [[String: Any]] else { return [] }
        var byId: [String: [String: Any]] = [:]
        for raw in list {
            guard let modelId = (raw["modelId"] as? String)?.trimmingCharacters(in: .whitespaces), !modelId.isEmpty else { continue }
            let inputPerM = unitPrice(raw["inputPerM"])
            let outputPerM = unitPrice(raw["outputPerM"])
            let cacheReadPerM = unitPrice(raw["cacheReadPerM"])
            if inputPerM.isInvalid || outputPerM.isInvalid || cacheReadPerM.isInvalid { continue }
            if inputPerM.value == nil && outputPerM.value == nil { continue }
            var entry: [String: Any] = ["modelId": modelId]
            if let v = inputPerM.value { entry["inputPerM"] = v }
            if let v = outputPerM.value { entry["outputPerM"] = v }
            if let v = cacheReadPerM.value { entry["cacheReadPerM"] = v }
            byId[modelId] = entry
        }
        return Array(byId.values)
    }

    private func unitPrice(_ value: Any?) -> (value: Double?, isInvalid: Bool) {
        guard let value, !(value is NSNull) else { return (nil, false) }
        if let s = value as? String, s.isEmpty { return (nil, false) }
        if let n = value as? Double, n.isFinite, n >= 0 { return (n, false) }
        if let n = value as? Int, n >= 0 { return (Double(n), false) }
        return (nil, true)
    }

    private func buildTokscaleModels(_ entries: [[String: Any]]) -> [String: Any] {
        var models: [String: Any] = [:]
        for e in entries {
            guard let modelId = e["modelId"] as? String else { continue }
            var m: [String: Any] = [:]
            if let v = e["inputPerM"] as? Double { m["input_cost_per_million_tokens"] = v }
            if let v = e["outputPerM"] as? Double { m["output_cost_per_million_tokens"] = v }
            if let v = e["cacheReadPerM"] as? Double { m["cache_read_input_token_cost_per_million_tokens"] = v }
            models[modelId] = m
        }
        return models
    }

    private func writeJsonAtomic(_ object: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("[pricing] write failed: %@", String(describing: error))
        }
    }
}
