import Foundation
import AppKit

/// Why a refresh started. Recorded per refresh in the diag log and in the
/// fixture dump sidecar so every expensive tick can be attributed.
enum RefreshReason: String {
    case startup
    case timer
    case manual
    case settingsChange
}

/// What a refresh must accomplish (PLAN.md Phase 4). Ordering by rawValue is
/// the coalescing strength: a stronger request covers a weaker pending one.
enum RefreshKind: Int {
    case cheap = 1     // adapters + merge only (fingerprint-gated)
    case full = 2      // + tokscale/history (fingerprint-gated reuse)
    case fullForced = 3 // diagnostic: bypass fingerprint reuse entirely
}

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
    private var pendingRefresh: (kind: RefreshKind, reason: RefreshReason)?
    private var settingsObserver: NSObjectProtocol?
    private var statsCache: [String: Any]?
    private var lastFullTickAt = Date.distantPast
    private var cachedTokscale: [String: [String: Any]]?
    private var cachedHistory: [String: Any]?
    private var cachedPricing: [String: TokscalePricing] = [:]
    private var cachedPeriods: (today: [String: Any], month: [String: Any], allTime: [String: Any])?
    private var cachedClients: [String] = []

    // Phase 3 per-client snapshots (collector-queue confined): fingerprint +
    // rows + precomputed period/history contributions + the pricing signature
    // they were computed with. An unchanged fingerprint AND pricing
    // signature means the cached contributions are still valid.
    private struct ClientSnapshot {
        var fingerprint: String
        var rows: [UsageCore.UsageRow]
        var pricingSignature: String
        var periods: [String: [String: Any]]
        var history: [Adapters.HistoryContribution]
    }
    private var clientSnapshots: [String: ClientSnapshot] = [:]

    // Phase 3 tokscale-side reuse: when the data files are unchanged, the
    // last successful periods/history are reused without any subprocess.
    private var tokscaleFingerprint: String?
    private var cachedTokscaleDays: [HistoryCore.Day] = []
    private var cachedTokscaleActiveTime: Double?

    // Merged adapter periods, rebuilt only when an adapter client changes.
    private var mergedAdapterPeriods: [String: [String: Any]]?

    private let tokscaleClientIds = Set(["claude", "codex", "opencode", "workbuddy"])

    private var refreshIdCounter = 0

    /// Monotonic per-process refresh ID (diag attribution only).
    private func nextRefreshId() -> Int {
        refreshIdCounter += 1
        return refreshIdCounter
    }

    private func kindName(_ kind: RefreshKind) -> String {
        switch kind {
        case .cheap: return "cheap"
        case .full: return "full"
        case .fullForced: return "fullForced"
        }
    }

    func start() {
        rebuildTimer()
        observeSettings()
        // Startup path (PLAN.md Phase 4 item 4): a cheap tick publishes
        // current adapter data immediately, and the expensive full
        // tokscale/history work follows as the next coalesced request — the
        // first push no longer waits for the full scan.
        requestRefresh(.cheap, reason: .startup)
        requestRefresh(.full, reason: .startup)
    }

    private func refreshInterval() -> TimeInterval {
        // doubleValue tolerates Int/Double/String payloads: renderer patches
        // arrive as JSON NSNumbers, but in-process callers may store Swift
        // Ints, which an as? Double read would reject and silently fall back
        // to the default (PLAN.md Phase 4 timer hot-reload).
        let raw = UsageCore.doubleValue(core.settings.snapshot()["refreshMs"])
        let ms = raw > 0 ? raw : 15000
        return max(3.0, ms / 1000.0)
    }

    private func fullInterval() -> TimeInterval {
        let raw = UsageCore.doubleValue(core.settings.snapshot()["collectionIntervalMs"])
        let ms = raw > 0 ? raw : 300000
        return max(refreshInterval(), ms / 1000.0)
    }

    /// Main-thread timer creation; rebuilds whenever refreshMs changes.
    private func rebuildTimer() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        let interval = refreshInterval()
        PerfDiag.log(String(format: "timer rebuild interval=%.1fs", interval))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestRefresh(.cheap, reason: .timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Settings-change handling (PLAN.md Phase 4): rebuild the timer for
    /// refreshMs and coalesce a settings-change refresh for keys that affect
    /// collection. Pricing-affecting keys invalidate the cached pricing and
    /// snapshots so the next full tick recomputes costs and rescans tokscale.
    private func observeSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self, let keys = note.userInfo?["keys"] as? [String] else { return }
            if keys.contains("refreshMs") {
                DispatchQueue.main.async { [weak self] in self?.rebuildTimer() }
            }
            var invalidatePricing = false
            var forceFull = false
            for key in keys {
                switch key {
                case "refreshMs", "collectionIntervalMs":
                    break // intervals are re-read per tick / by rebuildTimer
                case "customModelPricing":
                    invalidatePricing = true
                    forceFull = true
                case "clients", "allTimeSince":
                    forceFull = true
                default:
                    break
                }
            }
            guard invalidatePricing || forceFull else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                if invalidatePricing {
                    self.cachedPricing.removeAll()
                    self.clientSnapshots.removeAll()
                    self.tokscaleFingerprint = nil
                    self.mergedAdapterPeriods = nil
                }
                if forceFull {
                    self.enqueue(.full, reason: .settingsChange)
                }
            }
        }
    }

    func refreshNow() {
        requestRefresh(.full, reason: .manual)
    }

    // MARK: - Coalescing pump (PLAN.md Phase 4)

    func requestRefresh(_ kind: RefreshKind, reason: RefreshReason) {
        queue.async { [weak self] in self?.enqueue(kind, reason: reason) }
    }

    /// Queue-confined: keep at most one pending refresh; a stronger request
    /// replaces a weaker one so manual/timer/settings collisions never queue
    /// multiple full scans.
    private func enqueue(_ kind: RefreshKind, reason: RefreshReason) {
        if var pending = pendingRefresh {
            if kind.rawValue > pending.kind.rawValue {
                pendingRefresh = (kind, reason)
            }
            return
        }
        pendingRefresh = (kind, reason)
        pump()
    }

    private func pump() {
        while !collecting, let (kind, reason) = pendingRefresh {
            pendingRefresh = nil
            collecting = true
            tick(kind: kind, reason: reason)
            collecting = false
        }
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

    private func tick(kind: RefreshKind, reason: RefreshReason) {
        let id = nextRefreshId()
        PerfDiag.cpuMark(String(format: "tick-begin id=%d", id))
        PerfDiag.log(String(format: "refresh id=%d reason=%@ kind=%@", id, reason.rawValue, kindName(kind)))

        let settings = core.settings.snapshot()
        let clients = enabledClients(settings)
        guard !clients.isEmpty else { return }

        syncCustomPricing(settings["customModelPricing"])

        // fullForced and the diagnostic env var bypass fingerprint reuse.
        let forced = kind == .fullForced
            || ProcessInfo.processInfo.environment["TOKEN_MONITOR_FORCE_RESCAN"] != nil
        // cheap ticks escalate to a full scan once collectionIntervalMs has
        // elapsed since the last full tick — except the very first startup
        // tick, which must stay cheap so the first push is not delayed by
        // the tokscale/history work (PLAN.md Phase 4 item 4).
        let fullTick: Bool
        switch kind {
        case .full, .fullForced:
            fullTick = true
        case .cheap:
            fullTick = statsCache != nil && Date().timeIntervalSince(lastFullTickAt) >= fullInterval()
        }
        // First startup tick: resolve pricing from the disk cache only and
        // never spawn (cold lookups were measured at ~5s each); the follow-up
        // full tick resolves whatever the disk cache missed.
        let resolvePricing = !(reason == .startup && statsCache == nil)
        TokscaleRunner.shared.allowSubprocessLookup = resolvePricing
        defer { TokscaleRunner.shared.allowSubprocessLookup = true }
        let collectedAt = Date()

        // Adapter clients: fingerprint first (Phase 3). Only clients whose
        // source files changed are re-read and recomputed; unchanged clients
        // keep their cached rows and period/history contributions.
        var adapterChanged = false
        var adapterRows: [String: [UsageCore.UsageRow]] = [:]
        for client in ["proma", "hanako", "dsh"] where clients.contains(client) {
            let span = PerfDiag.span("source-" + client)
            let fp = SourceScanner.fingerprint(client: client, roots: SourceScanner.adapterRoots(client))
            if let snap = clientSnapshots[client],
               snap.fingerprint == fp.signature,
               pricingSignature(for: snap.rows) == snap.pricingSignature {
                adapterRows[client] = snap.rows
                span.end()
                continue
            }
            let rows = collectAdapterRows(client)
            for (model, p) in Adapters.pricingMap(forRows: rows) where cachedPricing[model] == nil {
                cachedPricing[model] = p
            }
            let pricing = cachedPricing
            let periods = adapterPeriodsFor(client: client, rows: rows, pricing: pricing, now: collectedAt, allTimeSince: allTimeSinceMs(settings))
            let history = Adapters.historyContributions(rows: rows, client: client, pricingByModel: pricing)
            clientSnapshots[client] = ClientSnapshot(
                fingerprint: fp.signature,
                rows: rows,
                pricingSignature: pricingSignature(for: rows),
                periods: periods,
                history: history
            )
            adapterChanged = true
            adapterRows[client] = rows
            PerfDiag.log(String(format: "source %@: changed (%d files), recomputed", client, fp.files.count))
            span.end()
        }
        // Merge the adapter contributions only when one of them changed.
        if adapterChanged {
            let span = PerfDiag.span("aggregate-adapter-periods")
            var contributions: [[String: [String: Any]]] = []
            for client in ["proma", "hanako", "dsh"] where clients.contains(client) {
                if let snap = clientSnapshots[client] {
                    contributions.append(snap.periods)
                }
            }
            var merged: [String: [String: Any]] = [:]
            merged["today"] = UsageCore.mergePeriods(contributions.map { $0["today"] ?? UsageCore.emptyPeriod() })
            merged["month"] = UsageCore.mergePeriods(contributions.map { $0["month"] ?? UsageCore.emptyPeriod() })
            merged["allTime"] = UsageCore.mergePeriods(contributions.map { $0["allTime"] ?? UsageCore.emptyPeriod() })
            mergedAdapterPeriods = merged
            span.end()
        }

        // tokscale clients: full scan at most every collectionIntervalMs.
        // When the source files are unchanged, reuse the previous snapshot
        // without starting any subprocess (Phase 3). TOKEN_MONITOR_FORCE_RESCAN
        // (diagnostic level only, not on the normal refresh path) forces a
        // real rescan.
        let tokscaleClients = clients.filter { tokscaleClientIds.contains($0) }
        var tokscaleChanged = false
        if fullTick {
            let span = PerfDiag.span("source-tokscale")
            let roots = tokscaleClients.flatMap { SourceScanner.tokscaleRoots($0) }
            let fp = SourceScanner.fingerprint(client: "tokscale", roots: roots)
            if !forced, fp.signature == tokscaleFingerprint, cachedTokscale != nil {
                PerfDiag.log("source tokscale: fingerprint unchanged, reusing snapshot (no subprocess)")
            } else {
                let periodSpan = PerfDiag.span("tokscale-periods")
                var periodScanSucceeded = false
                if let periods = scanTokscalePeriods(clients: tokscaleClients, settings: settings, now: collectedAt) {
                    cachedTokscale = periods
                    tokscaleChanged = true
                    periodScanSucceeded = true
                }
                periodSpan.end()
                let graphSpan = PerfDiag.span("tokscale-graph")
                if let (days, activeTime) = scanTokscaleGraph(clients: tokscaleClients) {
                    cachedTokscaleDays = days
                    cachedTokscaleActiveTime = activeTime
                    tokscaleChanged = true
                }
                graphSpan.end()
                // Record the fingerprint only after a successful period scan:
                // a failed scan keeps the old fingerprint so the next tick
                // retries instead of reusing stale data forever.
                if periodScanSucceeded || tokscaleClients.isEmpty {
                    tokscaleFingerprint = fp.signature
                }
                lastFullTickAt = Date()
            }
            span.end()
        }

        let tokscalePeriods = cachedTokscale ?? ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]

        // Final merge only when an input changed; a no-change tick reuses the
        // previously merged periods outright (the ~1s merge was the largest
        // steady-state cost).
        let mergeSpan = PerfDiag.span("merge-periods")
        let today: [String: Any]
        let month: [String: Any]
        let allTime: [String: Any]
        if adapterChanged || tokscaleChanged || cachedPeriods == nil {
            let adapterToday = mergedAdapterPeriods?["today"] ?? UsageCore.emptyPeriod()
            let adapterMonth = mergedAdapterPeriods?["month"] ?? UsageCore.emptyPeriod()
            let adapterAllTime = mergedAdapterPeriods?["allTime"] ?? UsageCore.emptyPeriod()
            today = UsageCore.mergePeriods([tokscalePeriods["today"] ?? UsageCore.emptyPeriod(), adapterToday])
            month = UsageCore.mergePeriods([tokscalePeriods["month"] ?? UsageCore.emptyPeriod(), adapterMonth])
            allTime = UsageCore.mergePeriods([tokscalePeriods["allTime"] ?? UsageCore.emptyPeriod(), adapterAllTime])
            cachedPeriods = (today, month, allTime)
        } else {
            let cached = cachedPeriods!
            today = cached.today
            month = cached.month
            allTime = cached.allTime
        }
        mergeSpan.end()

        // History: rebuilt from cached contributions (no subprocess) whenever
        // an input changed; the dashboard event only fires on full ticks.
        let historyChanged = adapterChanged || tokscaleChanged
        if fullTick || historyChanged {
            let span = PerfDiag.span("history")
            var days = cachedTokscaleDays
            var contributions: [Adapters.HistoryContribution] = []
            for client in ["proma", "hanako", "dsh"] where clients.contains(client) {
                if let snap = clientSnapshots[client] {
                    contributions += snap.history
                }
            }
            HistoryCore.mergeAdapterContributions(contributions, into: &days)
            let built = HistoryCore.normalizeHistory(days: days, todayKey: nil, totalActiveTimeMsOverride: cachedTokscaleActiveTime)
            stateLock.lock()
            cachedHistory = built
            stateLock.unlock()
            span.end()
            if fullTick {
                core.push("dashboard:historyChanged", NSNull())
            }
        }
        let history = cachedHistory

        let statsSpan = PerfDiag.span("build-stats")
        let stats = buildStats(
            settings: settings,
            clients: clients,
            today: today,
            month: month,
            allTime: allTime,
            history: history,
            collectedAt: collectedAt
        )
        statsSpan.end()

        cachedClients = clients
        // Content-signature comparison: when nothing about the periods or
        // client statuses changed, update the cache but skip the push so the
        // renderer is not forced through a full re-render every 15s. Limits
        // refreshes re-push through reemitStats() and are not affected.
        stateLock.lock()
        let previous = statsCache
        statsCache = stats
        stateLock.unlock()
        let pushed = previous == nil || contentSignature(stats) != contentSignature(previous!)
        if pushed {
            let pushSpan = PerfDiag.span("push-stats")
            core.push("stats:push", stats)
            pushSpan.end()
            PerfDiag.log(String(format: "push stats:push id=%d", id))
            // Fixture dumps for before/after comparison (diag runs only).
            PerfDiag.dump(stats, name: String(format: "stats-%03d.json", id))
            PerfDiag.dump([
                "refreshId": id,
                "reason": reason.rawValue,
                "full": fullTick,
                "collectedAtMs": collectedAt.timeIntervalSince1970 * 1000,
                "clients": clients
            ], name: String(format: "meta-%03d.json", id))
        }

        PerfDiag.log({
            let t = today["totalTokens"] as? Int ?? 0
            let m = month["totalTokens"] as? Int ?? 0
            let a = allTime["totalTokens"] as? Int ?? 0
            let clients = (allTime["clients"] as? [String: Any] ?? [:]).mapValues { $0 }
            let costs = (allTime["clientCosts"] as? [String: Any] ?? [:]).mapValues { $0 }
            return String(format: "collected id=%d today=%d month=%d allTime=%d allTimeClients=%@ costs=%@", id, t, m, a, clients.description, costs.description)
        }())
        PerfDiag.cpuMark(String(format: "tick-end id=%d", id))
        PerfDiag.footprintMark(String(format: "post-tick id=%d", id))
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

    private func collectAdapterRows(_ client: String) -> [UsageCore.UsageRow] {
        switch client {
        case "proma": return Adapters.collectPromaRows()
        case "hanako": return Adapters.collectHanakoRows()
        case "dsh": return Adapters.collectDshRows()
        default: return []
        }
    }

    /// Single-client period contributions (today/month/allTime) with costs
    /// attached from the shared pricing map — cached per client in Phase 3.
    private func adapterPeriodsFor(client: String, rows: [UsageCore.UsageRow], pricing: [String: TokscalePricing], now: Date, allTimeSince: Double) -> [String: [String: Any]] {
        let todayStart = Adapters.localDayStart(now)
        let monthStart = Adapters.localMonthStart(now)
        var entryRows: [String: [UsageCore.UsageRow]] = [:]
        entryRows["today"] = Adapters.periodRows(rows: rows, sinceMs: todayStart, client: client, includeUndated: false)
        entryRows["month"] = Adapters.periodRows(rows: rows, sinceMs: monthStart, client: client, includeUndated: false)
        entryRows["allTime"] = Adapters.periodRows(rows: rows, sinceMs: allTimeSince, client: client, includeUndated: true)

        var clientPeriods: [String: [String: Any]] = [:]
        for (period, periodRows) in entryRows {
            var priced = periodRows
            for i in 0..<priced.count {
                priced[i].cost = Adapters.estimatedRowCost(row: priced[i], pricingByModel: pricing) ?? 0
            }
            clientPeriods[period] = UsageCore.extractPeriod(entries: priced)
        }
        return clientPeriods
    }

    /// Stable signature of the pricing entries relevant to a client's rows.
    /// When it changes (e.g. a model's pricing resolved for the first time),
    /// the cached contributions are recomputed from the cached rows — no
    /// file re-read needed.
    private func pricingSignature(for rows: [UsageCore.UsageRow]) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        for row in rows {
            let key = (row.model ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard seen.insert(key).inserted, let p = cachedPricing[key] else { continue }
            let pricing = p.pricing
            parts.append(String(format: "%@:%.10g:%.10g:%.10g:%.10g",
                                key,
                                pricing?.inputCostPerToken ?? -1,
                                pricing?.outputCostPerToken ?? -1,
                                pricing?.cacheReadInputTokenCost ?? -1,
                                pricing?.cacheCreationInputTokenCost ?? -1))
        }
        return parts.joined(separator: "|")
    }

    /// One graph scan for the tokscale clients: per-day contributions plus
    /// the total-active-time override (Phase 3 caches both).
    private func scanTokscaleGraph(clients: [String]) -> (days: [HistoryCore.Day], activeTimeMs: Double?)? {
        guard !clients.isEmpty else { return ([], nil) }
        guard let graph = try? TokscaleRunner.shared.graph(clients: clients) else { return nil }
        return (HistoryCore.parseTokscaleGraph(graph), graph.timeMetrics?.totalActiveTimeMs)
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
