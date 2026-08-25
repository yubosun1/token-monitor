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

/// What a refresh must accomplish. Ordering by rawValue is the coalescing
/// strength: a stronger request covers a weaker pending one.
enum RefreshKind: Int {
    case cheap = 1      // adapters + merge only (fingerprint-gated)
    case full = 2       // + tokscale/history source check (fingerprint-gated reuse)
    case fullForced = 3 // diagnostic: bypass fingerprint reuse entirely
}

/// One pending refresh request (coordination state).
struct RefreshRequest {
    var kind: RefreshKind
    var reason: RefreshReason
    /// Only an explicit user refresh may contact pricing providers.
    var refreshPricing: Bool
}

/// Injectable seams for the collector (review-round Phase 0). Production
/// uses `live`; the fixture/state tests substitute fakes for file scanning,
/// tokscale runs, pricing lookups, settings and the clock, and assert call
/// counts (raw reads, derivations, tokscale spawns, ticks).
struct CollectorEnvironment {
    var now: () -> Date
    var settings: () -> [String: Any]
    var adapterFingerprint: (String) -> SourceScanner.Fingerprint
    var adapterRows: (String) -> [UsageCore.UsageRow]
    var pricingLookup: (String, PricingPolicy) -> TokscalePricing?
    var tokscaleFingerprint: ([String]) -> SourceScanner.Fingerprint
    var tokscaleAntigravitySync: () -> Bool
    var tokscalePricingRefresh: ([String]) -> Bool
    var tokscalePeriods: ([String], [String: Any], Date) -> [String: [String: Any]]?
    var tokscaleGraph: ([String]) -> (days: [HistoryCore.Day], activeTimeMs: Double?)?
    var push: (String, Any) -> Void
    var customPricingSync: ([String: Any]) -> Void
    var historyLedger: HistoryLedger?
    /// Test hook: observes every executed tick without touching caches.
    var tickObserver: (RefreshKind, RefreshReason) -> Void

    init(
        now: @escaping () -> Date,
        settings: @escaping () -> [String: Any],
        adapterFingerprint: @escaping (String) -> SourceScanner.Fingerprint,
        adapterRows: @escaping (String) -> [UsageCore.UsageRow],
        pricingLookup: @escaping (String, PricingPolicy) -> TokscalePricing?,
        tokscaleFingerprint: @escaping ([String]) -> SourceScanner.Fingerprint,
        tokscaleAntigravitySync: @escaping () -> Bool,
        tokscalePricingRefresh: @escaping ([String]) -> Bool,
        tokscalePeriods: @escaping ([String], [String: Any], Date) -> [String: [String: Any]]?,
        tokscaleGraph: @escaping ([String]) -> (days: [HistoryCore.Day], activeTimeMs: Double?)?,
        push: @escaping (String, Any) -> Void,
        customPricingSync: @escaping ([String: Any]) -> Void,
        historyLedger: HistoryLedger? = nil,
        tickObserver: @escaping (RefreshKind, RefreshReason) -> Void = { _, _ in }
    ) {
        self.now = now
        self.settings = settings
        self.adapterFingerprint = adapterFingerprint
        self.adapterRows = adapterRows
        self.pricingLookup = pricingLookup
        self.tokscaleFingerprint = tokscaleFingerprint
        self.tokscaleAntigravitySync = tokscaleAntigravitySync
        self.tokscalePricingRefresh = tokscalePricingRefresh
        self.tokscalePeriods = tokscalePeriods
        self.tokscaleGraph = tokscaleGraph
        self.push = push
        self.customPricingSync = customPricingSync
        self.historyLedger = historyLedger
        self.tickObserver = tickObserver
    }

    static func live() -> CollectorEnvironment {
        return CollectorEnvironment(
            now: { Date() },
            settings: { SettingsStore.shared.snapshot() },
            adapterFingerprint: { client in
                SourceScanner.fingerprint(client: client, roots: SourceScanner.adapterRoots(client))
            },
            adapterRows: { client in
                switch client {
                case "proma": return Adapters.collectPromaRows()
                case "hanako": return Adapters.collectHanakoRows()
                case "dsh": return Adapters.collectDshRows()
                case "antigravity": return Adapters.collectAntigravityRows()
                default: return []
                }
            },
            pricingLookup: { model, policy in
                TokscaleRunner.shared.pricing(for: model, policy: policy)
            },
            tokscaleFingerprint: { clients in
                SourceScanner.fingerprint(client: "tokscale", roots: clients.flatMap(SourceScanner.tokscaleRoots))
            },
            tokscaleAntigravitySync: {
                guard TokscaleRunner.antigravityDataPresent() else { return true }
                return TokscaleRunner.shared.syncAntigravity()
            },
            tokscalePricingRefresh: { clients in
                TokscaleRunner.shared.refreshUsagePricing(clients: clients)
            },
            tokscalePeriods: { clients, settings, now in
                Collector.scanTokscalePeriods(clients: clients, settings: settings, now: now)
            },
            tokscaleGraph: { clients in
                Collector.scanTokscaleGraph(clients: clients)
            },
            push: { event, payload in
                BridgeCore.shared.push(event, payload)
            },
            customPricingSync: { settings in
                CustomPricingSidecar.sync(
                    settingValue: settings["customModelPricing"],
                    settingsFileURL: SettingsStore.shared.fileURL
                )
            },
            historyLedger: HistoryLedger.shared,
            tickObserver: { _, _ in }
        )
    }
}

/// Usage collector: tokscale (claude/codex/opencode/kimi/workbuddy) plus the
/// local proma/hanako/dsh adapters, assembled into the aggregate stats
/// shape the renderer consumes.
///
/// Concurrency model (review round):
///  - a short coordination lock protects only {workerRunning, pending
///    refresh, pending invalidations};
///  - the real tick runs on the serial worker queue without holding the
///    lock, so requests arriving during a long tick merge into the pending
///    slot immediately instead of queueing behind it;
///  - every cache (raw/derived snapshots, tokscale snapshot, pricing) is
///    written only by the worker.
final class Collector {
    static let shared = Collector(environment: .live(), workerQueue: DispatchQueue(label: "collector", qos: .utility))

    let environment: CollectorEnvironment
    private let workerQueue: DispatchQueue
    private let stateLock = NSLock()

    // Coordination state (short lock only).
    private let coordLock = NSLock()
    private var workerRunning = false
    /// Kind of the tick currently executing, nil while idle (round-4
    /// Phase 4). Owned by coordLock; updated atomically when the worker
    /// takes an item and when it goes idle — including every early return.
    private var runningKind: RefreshKind?
    private var pendingQueue: [RefreshRequest] = []
    private var pendingInvalidations = CollectorInvalidations()
    /// True once the very first tick published stats (cheap-first startup
    /// gate). Owned by coordLock — read in requestRefresh and written when a
    /// tick commits its stats. requestRefresh must NOT read statsCache here:
    /// that cache belongs to stateLock and crossing the two locks is a data
    /// race (round-4 Phase 2.1).
    private var hasCompletedInitialStats = false

    private var timer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var _hasActiveWindows = true
    var hasActiveWindows: Bool {
        get {
            coordLock.lock(); defer { coordLock.unlock() }
            return _hasActiveWindows
        }
        set {
            coordLock.lock(); defer { coordLock.unlock() }
            _hasActiveWindows = newValue
        }
    }

    // Worker-owned results (read by the UI through stateLock).
    private var statsCache: [String: Any]?
    private var cachedHistory: [String: Any]?
    private var cachedPeriods: (today: [String: Any], month: [String: Any], allTime: [String: Any])?
    private var cachedClients: [String] = []

    // Worker-owned cache state. rawSnapshots/derivedSnapshots/tokscaleSnapshot
    // are internal (not private) so the fixture checker can assert cache
    // lifecycle directly; they are still written only by the worker queue.
    private var pricingGeneration = 0
    /// Per-model pricing cache: the resolved price plus the tick clock time
    /// it was fetched. Expired entries re-resolve on full ticks (round-4
    /// Phase 3.1) so a long-running app sees price changes; cheap ticks only
    /// read the cache and never spawn.
    // Internal (not private) so the fixture checker can assert TTL
    // lifecycle directly; still written only by the worker queue.
    var cachedPricing: [String: (pricing: TokscalePricing, fetchedAt: Date)] = [:]
    private let pricingTTL: TimeInterval = 6 * 60 * 60
    /// Per-model retry floor for failed resolves (first resolution and
    /// expired re-resolution alike); bounded, and a failed expiry keeps the
    /// last-known-good price instead of zeroing costs.
    private var pricingRetryAfter: [String: Date] = [:]
    /// Canonical signature of the customModelPricing setting: the sidecar
    /// syncs only when this changes (round-4 Phase 3.2), never every tick.
    private var lastCustomPricingSignature: String?
    var rawSnapshots: [String: RawSnapshot] = [:]
    var derivedSnapshots: [String: DerivedSnapshot] = [:]
    private var mergeContext: MergeContext?
    private var mergedAdapterPeriods: [String: [String: Any]]?
    var tokscaleSnapshot: TokscaleSnapshot?
    private var lastFullCheckAt = Date.distantPast
    // Per-client timestamp of the last actual source re-read. Used to smooth
    // CPU when a client (e.g. dsh) is actively appending: a changed
    // fingerprint within the re-read window is deferred to the next tick so
    // re-decompression/parsing happens at most once per adapterRecheckMs.
    private var lastAdapterReadAt: [String: Date] = [:]
    private var periodFailures = 0
    private var graphFailures = 0
    private var periodRetryAfter = Date.distantPast
    private var graphRetryAfter = Date.distantPast

    private let tokscaleClientIds = Set(["claude", "codex", "opencode", "kimi", "workbuddy"])
    private let adapterClientIds = ["proma", "hanako", "dsh", "antigravity"]
    private var refreshIdCounter = 0

    init(environment: CollectorEnvironment, workerQueue: DispatchQueue) {
        self.environment = environment
        self.workerQueue = workerQueue
    }

    // MARK: - Cache models (review round 3.1)

    /// Raw cache: fingerprint + parsed rows. Only a fingerprint change
    /// re-reads source files.
    struct RawSnapshot {
        var fingerprint: String
        var rows: [UsageCore.UsageRow]
        var models: [String]
    }

    /// Derived cache key: the raw fingerprint plus every query dimension
    /// that can change the derived periods/history without any file
    /// change (client, allTimeSince, local day/month, pricing).
    struct DerivedKey: Equatable {
        var client: String
        var fingerprint: String
        var allTimeSinceMs: Double
        var dayKey: String
        var monthKey: String
        var pricingSignature: String
    }

    struct DerivedSnapshot {
        var key: DerivedKey
        var periods: [String: [String: Any]]
        var history: [Adapters.HistoryContribution]
    }

    /// Merge context (review round 3.2): every input to the final merged
    /// periods/history. A change rebuilds the merge even when no file or
    /// scan changed, and disabled clients drop out immediately.
    struct MergeContext: Equatable {
        var clients: [String]
        var allTimeSinceMs: Double
        var dayKey: String
        var monthKey: String
        var adapterKeys: [String: DerivedKey]
        var pricingGeneration: Int
    }

    /// Tokscale snapshot: the last successful per-part results plus the
    /// context they were produced for. Periods and graph track success
    /// independently so a partial failure retries only the failed part.
    struct TokscaleSnapshot {
        var fingerprint: String
        var clients: [String]
        var allTimeSinceMs: Double
        var dayKey: String
        var monthKey: String
        var pricingGeneration: Int
        var periods: [String: [String: Any]]
        var periodsSuccess: Bool
        var graphDays: [HistoryCore.Day]
        var graphActiveTime: Double?
        var graphSuccess: Bool
    }

    struct CollectorInvalidations {
        var purgePricing = false
        var isEmpty: Bool { !purgePricing }
    }

    // MARK: - Scheduling

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
        // Startup: a cheap tick publishes current adapter data immediately,
        // then the full tokscale/history work follows as the next coalesced
        // request. The cheap tick resolves pricing from caches only.
        requestRefresh(.cheap, reason: .startup)
        requestRefresh(.full, reason: .startup)
    }

    /// Adaptive window visibility: toggles between high-cadence active polling
    /// and low-power background polling to save CPU and memory when windows are hidden.
    func setHasActiveWindows(_ hasActive: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard hasActiveWindows != hasActive else { return }
        hasActiveWindows = hasActive
        rebuildTimer()
        if hasActive {
            requestRefresh(.cheap, reason: .manual)
        }
    }

    private func refreshInterval() -> TimeInterval {
        if !hasActiveWindows {
            // When all windows are closed/hidden, throttle background polling to 180s (3m)
            // to minimize background CPU wakeups and temporary memory allocations.
            return 180.0
        }
        let raw = UsageCore.doubleValue(environment.settings()["refreshMs"])
        let ms = raw > 0 ? raw : 15000
        return max(3.0, ms / 1000.0)
    }

    private func fullInterval() -> TimeInterval {
        let raw = UsageCore.doubleValue(environment.settings()["collectionIntervalMs"])
        let ms = raw > 0 ? raw : 300000
        return max(refreshInterval(), ms / 1000.0)
    }

    /// Minimum gap between actual source re-reads for adapter clients.
    /// Bound tight to the tick cadence so a 15s tick never re-reads more
    /// often than the window, but a longer window still applies.
    private func adapterRecheckInterval(_ settings: [String: Any]) -> TimeInterval {
        let raw = UsageCore.doubleValue(settings["adapterRecheckMs"])
        let ms = raw > 0 ? raw : 30000
        return max(1.0, ms / 1000.0)
    }

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
            var purgePricing = false
            var forceFull = false
            for key in keys {
                switch key {
                case "refreshMs", "collectionIntervalMs":
                    break
                case "customModelPricing":
                    purgePricing = true
                    forceFull = true
                case "clients", "allTimeSince":
                    forceFull = true
                default:
                    break
                }
            }
            guard purgePricing || forceFull else { return }
            // Invalidation flags ride the coordination state so the next
            // worker tick applies them atomically with the refresh; cache
            // data itself is still only touched by the worker.
            if purgePricing {
                self.coordLock.lock()
                self.pendingInvalidations.purgePricing = true
                self.coordLock.unlock()
            }
            if forceFull {
                self.requestRefresh(.full, reason: .settingsChange)
            }
        }
    }

    /// The user-facing refresh action. Routine collection remains local-only;
    /// this is the sole path that may refresh prices over the network.
    func refreshNow(refreshPricing: Bool = true) {
        requestRefresh(.full, reason: .manual, refreshPricing: refreshPricing)
    }

    // MARK: - Coalescing pump (review round Phase 4)

    /// Any thread. Merges into the pending queue under the short
    /// coordination lock immediately — no waiting for a running tick.
    ///
    /// Merge rules:
    ///  - while a full/fullForced tick is RUNNING, an arriving cheap
    ///    refresh is covered by it and dropped outright (round-4 Phase 4)
    ///    instead of queueing a redundant follow-up — unless an
    ///    invalidation arrived after the running tick consumed its
    ///    snapshot, in which case one follow-up still runs so the purge
    ///    applies;
    ///  - the very first startup cheap tick is never merged with: the
    ///    startup full request queues behind it so the first stats push
    ///    stays cheap (cheap-first startup);
    ///  - otherwise a request is dropped when an equally strong or stronger
    ///    request is already queued, and replaces the weakest queued
    ///    request otherwise, so bursts collapse to one necessary refresh;
    ///    strong requests (settings-change / manual full, fullForced) are
    ///    never dropped.
    func requestRefresh(_ kind: RefreshKind, reason: RefreshReason, refreshPricing: Bool = false) {
        coordLock.lock()
        var spawnWorker = false
        let request = RefreshRequest(kind: kind, reason: reason, refreshPricing: refreshPricing)
        if workerRunning, let running = runningKind,
           (running == .full || running == .fullForced), kind == .cheap {
            // Covered by the running source check; keep at most one cheap
            // follow-up when a purge invalidation still needs a tick.
            if pendingQueue.isEmpty && !pendingInvalidations.isEmpty {
                pendingQueue.append(request)
            }
        } else if pendingQueue.isEmpty {
            pendingQueue.append(request)
        } else {
            let firstStartupCheap = pendingQueue.count == 1
                && pendingQueue[0].kind == .cheap
                && pendingQueue[0].reason == .startup
                && !hasCompletedInitialStats
            if firstStartupCheap {
                // Queue behind the first startup cheap unless something at
                // least as strong is already queued behind it.
                if !pendingQueue.dropFirst().contains(where: { $0.kind.rawValue >= kind.rawValue }) {
                    pendingQueue.append(request)
                } else if refreshPricing,
                          let index = pendingQueue.indices.first(where: { pendingQueue[$0].kind.rawValue >= kind.rawValue }) {
                    pendingQueue[index].refreshPricing = true
                }
            } else if let index = pendingQueue.indices.first(where: { pendingQueue[$0].kind.rawValue >= kind.rawValue }) {
                // Covered by an existing queued request: drop.
                if refreshPricing {
                    pendingQueue[index].refreshPricing = true
                }
            } else if let index = pendingQueue.firstIndex(where: { $0.kind.rawValue < kind.rawValue }) {
                pendingQueue[index] = request
            } else {
                pendingQueue.append(request)
            }
        }
        if !workerRunning {
            spawnWorker = true
        }
        coordLock.unlock()
        if spawnWorker {
            workerQueue.async { [weak self] in self?.drainWorker() }
        }
    }

    /// Worker loop: atomically take pending work + invalidations under the
    /// lock, run the tick without the lock, repeat until nothing pending.
    private func drainWorker() {
        coordLock.lock()
        if workerRunning {
            // Another drain loop is already running; it will pick up the
            // pending work (extra spawns only happen across the idle
            // window and are harmless).
            coordLock.unlock()
            return
        }
        workerRunning = true
        coordLock.unlock()
        while true {
            coordLock.lock()
            guard let pending = pendingQueue.first else {
                workerRunning = false
                runningKind = nil
                coordLock.unlock()
                return
            }
            pendingQueue.removeFirst()
            // runningKind is updated atomically at take-time and at idle, so
            // requestRefresh always sees the kind actually executing; the
            // tick itself runs without the lock.
            runningKind = pending.kind
            let invalidations = pendingInvalidations
            pendingInvalidations = CollectorInvalidations()
            coordLock.unlock()
            if invalidations.purgePricing {
                cachedPricing.removeAll()
                pricingGeneration += 1
                PerfDiag.log("pricing purged (customModelPricing change), generation=\(pricingGeneration)")
            }
            autoreleasepool {
                tick(kind: pending.kind, reason: pending.reason, refreshPricing: pending.refreshPricing)
            }
        }
    }

    // MARK: - UI reads

    func latestStats() -> [String: Any]? {
        stateLock.lock(); defer { stateLock.unlock() }
        return statsCache
    }

    func history() -> [String: Any]? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedHistory
    }

    // MARK: - Ticks

    private func tick(kind: RefreshKind, reason: RefreshReason, refreshPricing: Bool) {
        environment.tickObserver(kind, reason)
        let id = nextRefreshId()
        PerfDiag.cpuMark(String(format: "tick-begin id=%d", id))
        PerfDiag.log(String(format: "refresh id=%d reason=%@ kind=%@", id, reason.rawValue, kindName(kind)))

        let settings = environment.settings()
        let clients = enabledClients(settings)
        // Round-4 Phase 2.2: an empty client set must not just return and
        // leave stale UI — it produces one legal empty wire shape below and
        // drops every client cache so re-enabling starts clean. Partial
        // disables remove only the disabled clients' caches: unreachable
        // rows must not stay pinned forever.
        if clients.isEmpty {
            rawSnapshots.removeAll()
            derivedSnapshots.removeAll()
            mergedAdapterPeriods = nil
            Adapters.dropClientCaches(Set(adapterClientIds))
        } else {
            let disabledAdapters = adapterClientIds.filter { !clients.contains($0) }
            if !disabledAdapters.isEmpty {
                for client in disabledAdapters {
                    rawSnapshots.removeValue(forKey: client)
                    derivedSnapshots.removeValue(forKey: client)
                }
                Adapters.dropClientCaches(Set(disabledAdapters))
            }
        }

        // Sidecar I/O only on the first tick and when the setting actually
        // changes (round-4 Phase 3.2): a canonical sorted-key signature makes
        // dictionary traversal order irrelevant, and a failed write records
        // the signature anyway so a cheap tick never retries in a loop.
        let customPricingSig = customPricingSignature(settings["customModelPricing"])
        if lastCustomPricingSignature != customPricingSig {
            environment.customPricingSync(settings)
            lastCustomPricingSignature = customPricingSig
        }

        // One clock reading for the whole tick (review round 3.1/3.2): the
        // day/month keys, period filtering and stats windows all use the
        // same `now`, so a tick that straddles midnight stays consistent.
        let now = environment.now()
        let dayKey = Self.dayKey(now)
        let monthKey = Self.monthKey(now)
        let allTimeSince = allTimeSinceMs(settings)

        let forced = kind == .fullForced
            || refreshPricing
            || ProcessInfo.processInfo.environment["TOKEN_MONITOR_FORCE_RESCAN"] != nil
        // Cheap ticks escalate to a full source check once
        // collectionIntervalMs has elapsed since the last completed check
        // — except the very first startup tick, which must stay cheap.
        let fullCheck: Bool
        switch kind {
        case .full, .fullForced:
            fullCheck = true
        case .cheap:
            fullCheck = statsCache != nil && now.timeIntervalSince(lastFullCheckAt) >= fullInterval()
        }
        // Pricing is intentionally local-only during routine collection.
        // Only a user-driven refresh is allowed to contact a pricing source.
        let pricingPolicy: PricingPolicy = refreshPricing ? .forceRefresh : .cacheOnly

        // Adapter clients: raw cache by fingerprint; derived cache by the
        // full derived key (fingerprint + day/month/allTimeSince/pricing).
        var adapterContributions: [String: DerivedSnapshot] = [:]
        // A model can appear in more than one adapter. A manual refresh must
        // still perform at most one network lookup for that shared model.
        var pricingLookedUpThisTick = Set<String>()
        if clients.contains("antigravity") {
            let syncSpan = PerfDiag.span("tokscale-antigravity-sync")
            let synced = environment.tokscaleAntigravitySync()
            PerfDiag.log("antigravity sync " + (synced ? "completed" : "failed"))
            syncSpan.end()
        }
        for client in adapterClientIds where clients.contains(client) {
            autoreleasepool {
                let span = PerfDiag.span("source-" + client)
                let fp = environment.adapterFingerprint(client)
                let raw: RawSnapshot
                if let cached = rawSnapshots[client], cached.fingerprint == fp.signature {
                    raw = cached
                } else if let prior = rawSnapshots[client],
                          now.timeIntervalSince(lastAdapterReadAt[client] ?? .distantPast) < adapterRecheckInterval(settings) {
                    // Low-CPU mode: the source changed while a session is actively
                    // appending, but a fresh read happened within the cooldown
                    // window — reuse the previous snapshot and let the next tick
                    // pick up the new data. Stats trail the source by at most the
                    // window; re-decompression/parsing is bounded to 1/window.
                    raw = prior
                    PerfDiag.log(String(format: "source %@: changed but within re-read cooldown (%.0fs), reusing previous rows", client, adapterRecheckInterval(settings)))
                } else {
                    let rows = environment.adapterRows(client)
                    raw = RawSnapshot(
                        fingerprint: fp.signature,
                        rows: rows,
                        models: Self.distinctModelIds(rows)
                    )
                    rawSnapshots[client] = raw
                    lastAdapterReadAt[client] = now
                    PerfDiag.log(String(format: "source %@: changed (%d files), re-read", client, fp.files.count))
                }
                resolvePricing(
                    models: raw.models,
                    policy: pricingPolicy,
                    now: now,
                    lookedUpThisTick: &pricingLookedUpThisTick
                )
                let pricingMap = pricingMapForDerivation()
                let key = DerivedKey(
                    client: client,
                    fingerprint: raw.fingerprint,
                    allTimeSinceMs: allTimeSince,
                    dayKey: dayKey,
                    monthKey: monthKey,
                    pricingSignature: pricingSignature(for: raw.models)
                )
                if let derived = derivedSnapshots[client], derived.key == key {
                    adapterContributions[client] = derived
                } else {
                    let periods = adapterPeriodsFor(
                        client: client, rows: raw.rows, pricing: pricingMap,
                        now: now, allTimeSince: allTimeSince
                    )
                    let history = Adapters.historyContributions(
                        rows: raw.rows, client: client, pricingByModel: pricingMap
                    )
                    if let ledger = environment.historyLedger {
                        let pricedRows: [UsageCore.UsageRow] = raw.rows.map { row in
                            var r = row
                            r.cost = Adapters.estimatedRowCost(row: row, pricingByModel: pricingMap) ?? 0
                            return r
                        }
                        ledger.recordUsageRows(pricedRows, defaultClient: client, now: now)
                        ledger.recordHistoryContributions(history, now: now)
                    }
                    let derived = DerivedSnapshot(key: key, periods: periods, history: history)
                    derivedSnapshots[client] = derived
                    adapterContributions[client] = derived
                    PerfDiag.log(String(format: "source %@: re-derived periods/history", client))
                }
                span.end()
            }
        }

        // Tokscale: one source check per collectionIntervalMs; reuse the
        // snapshot when nothing changed, retry only the failed part.
        let tokscaleClients = clients.filter { tokscaleClientIds.contains($0) }
        var tokscaleChanged = false
        if fullCheck {
            lastFullCheckAt = now
            if tokscaleClients.isEmpty {
                tokscaleSnapshot = nil
            } else {
                if refreshPricing {
                    let pricingSpan = PerfDiag.span("tokscale-pricing-refresh")
                    let refreshed = environment.tokscalePricingRefresh(tokscaleClients)
                    let pricingStatus = refreshed ? "completed" : "failed"
                    PerfDiag.log("manual tokscale pricing refresh \(pricingStatus)")
                    pricingSpan.end()
                }
                let fp = environment.tokscaleFingerprint(tokscaleClients)
                let sortedClients = tokscaleClients.sorted()
                var contextChanged = true
                if let snap = tokscaleSnapshot {
                    contextChanged = snap.fingerprint != fp.signature
                        || snap.clients != sortedClients
                        || snap.allTimeSinceMs != allTimeSince
                        || snap.dayKey != dayKey
                        || snap.monthKey != monthKey
                        || snap.pricingGeneration != pricingGeneration
                }
                if forced || contextChanged {
                    let span = PerfDiag.span("source-tokscale")
                    // Fresh validity for the new context (round-4 Phase 1):
                    // the VALUES start from the last-known-good snapshot so the
                    // UI can keep showing degraded data, but the SUCCESS flags
                    // restart as unknown. An old context's success must never
                    // mark the new context valid, or a part that failed under
                    // the new context would never retry (its flag would stay
                    // true forever). Each part flips its own flag: success
                    // stores the value and clears the failure count, failure
                    // keeps the last-known-good value but marks the part for
                    // retry and advances only its own backoff.
                    var next = TokscaleSnapshot(
                        fingerprint: fp.signature, clients: sortedClients,
                        allTimeSinceMs: allTimeSince, dayKey: dayKey, monthKey: monthKey,
                        pricingGeneration: pricingGeneration,
                        periods: tokscaleSnapshot?.periods ?? Self.emptyTokscalePeriods(),
                        periodsSuccess: false,
                        graphDays: tokscaleSnapshot?.graphDays ?? [],
                        graphActiveTime: tokscaleSnapshot?.graphActiveTime,
                        graphSuccess: false
                    )
                    let periodSpan = PerfDiag.span("tokscale-periods")
                    if let periods = environment.tokscalePeriods(tokscaleClients, settings, now) {
                        next.periods = periods
                        next.periodsSuccess = true
                        periodFailures = 0
                        tokscaleChanged = true
                    } else {
                        next.periodsSuccess = false
                        periodFailures += 1
                        periodRetryAfter = now.addingTimeInterval(Self.backoff(failures: periodFailures))
                    }
                    periodSpan.end()
                    let graphSpan = PerfDiag.span("tokscale-graph")
                    if let (days, activeTime) = environment.tokscaleGraph(tokscaleClients) {
                        next.graphDays = days
                        next.graphActiveTime = activeTime
                        next.graphSuccess = true
                        graphFailures = 0
                        tokscaleChanged = true
                    } else {
                        next.graphSuccess = false
                        graphFailures += 1
                        graphRetryAfter = now.addingTimeInterval(Self.backoff(failures: graphFailures))
                    }
                    graphSpan.end()
                    tokscaleSnapshot = next
                    span.end()
                } else {
                    PerfDiag.log("source tokscale: fingerprint unchanged, reusing snapshot (no subprocess)")
                    var snap = tokscaleSnapshot!
                    if !snap.periodsSuccess, now >= periodRetryAfter {
                        let span = PerfDiag.span("tokscale-periods-retry")
                        if let periods = environment.tokscalePeriods(tokscaleClients, settings, now) {
                            snap.periods = periods
                            snap.periodsSuccess = true
                            periodFailures = 0
                            tokscaleChanged = true
                        } else {
                            periodFailures += 1
                            periodRetryAfter = now.addingTimeInterval(Self.backoff(failures: periodFailures))
                        }
                        span.end()
                    }
                    if !snap.graphSuccess, now >= graphRetryAfter {
                        let span = PerfDiag.span("tokscale-graph-retry")
                        if let (days, activeTime) = environment.tokscaleGraph(tokscaleClients) {
                            snap.graphDays = days
                            snap.graphActiveTime = activeTime
                            snap.graphSuccess = true
                            graphFailures = 0
                            tokscaleChanged = true
                        } else {
                            graphFailures += 1
                            graphRetryAfter = now.addingTimeInterval(Self.backoff(failures: graphFailures))
                        }
                        span.end()
                    }
                    tokscaleSnapshot = snap
                }
            }
        } else if tokscaleClients.isEmpty {
            // No tokscale clients enabled: nothing to scan and nothing to
            // keep — a cheap tick after disabling every tokscale client must
            // not resurrect the old snapshot's data.
            tokscaleSnapshot = nil
        }

        let tokscalePeriods = tokscaleSnapshot?.periods ?? Self.emptyTokscalePeriods()

        // Merge context (review round 3.2): any context change rebuilds the
        // adapter merge, the final periods and the history — including a
        // disabled client disappearing or a day/month/allTimeSince rollover.
        var adapterKeys: [String: DerivedKey] = [:]
        for client in adapterClientIds where clients.contains(client) {
            if let contribution = adapterContributions[client] {
                adapterKeys[client] = contribution.key
            }
        }
        let context = MergeContext(
            clients: clients.sorted(),
            allTimeSinceMs: allTimeSince,
            dayKey: dayKey,
            monthKey: monthKey,
            adapterKeys: adapterKeys,
            pricingGeneration: pricingGeneration
        )
        let contextChanged = mergeContext != context
        if contextChanged || tokscaleChanged || cachedPeriods == nil {
            let mergeSpan = PerfDiag.span("merge-periods")
            var contributions: [[String: [String: Any]]] = []
            for client in adapterClientIds where clients.contains(client) {
                if let derived = adapterContributions[client] {
                    contributions.append(derived.periods)
                }
            }
            var merged: [String: [String: Any]] = [:]
            merged["today"] = UsageCore.mergePeriods(contributions.map { $0["today"] ?? UsageCore.emptyPeriod() })
            merged["month"] = UsageCore.mergePeriods(contributions.map { $0["month"] ?? UsageCore.emptyPeriod() })
            merged["allTime"] = UsageCore.mergePeriods(contributions.map { $0["allTime"] ?? UsageCore.emptyPeriod() })
            mergedAdapterPeriods = merged
            var today = UsageCore.mergePeriods([tokscalePeriods["today"] ?? UsageCore.emptyPeriod(), merged["today"] ?? UsageCore.emptyPeriod()])
            var month = UsageCore.mergePeriods([tokscalePeriods["month"] ?? UsageCore.emptyPeriod(), merged["month"] ?? UsageCore.emptyPeriod()])
            var allTime = UsageCore.mergePeriods([tokscalePeriods["allTime"] ?? UsageCore.emptyPeriod(), merged["allTime"] ?? UsageCore.emptyPeriod()])

            if let ledger = environment.historyLedger {
                let ledgerPeriods = ledger.fetchPeriods(clients: clients, now: now, allTimeSince: allTimeSince)
                if UsageCore.intValue(ledgerPeriods.today["totalTokens"]) > UsageCore.intValue(today["totalTokens"]) {
                    today = ledgerPeriods.today
                }
                if UsageCore.intValue(ledgerPeriods.month["totalTokens"]) > UsageCore.intValue(month["totalTokens"]) {
                    month = ledgerPeriods.month
                }
                if UsageCore.intValue(ledgerPeriods.allTime["totalTokens"]) > UsageCore.intValue(allTime["totalTokens"]) {
                    allTime = ledgerPeriods.allTime
                }
            }

            cachedPeriods = (today, month, allTime)
            mergeContext = context
            mergeSpan.end()
        }
        guard let periods = cachedPeriods else { return }
        let today = periods.today
        let month = periods.month
        let allTime = periods.allTime

        // History: rebuilt when the context or a tokscale part changed.
        if contextChanged || tokscaleChanged {
            let span = PerfDiag.span("history")
            var days = tokscaleSnapshot?.graphDays ?? []
            var historyContributions: [Adapters.HistoryContribution] = []
            for client in adapterClientIds where clients.contains(client) {
                if let derived = adapterContributions[client] {
                    historyContributions += derived.history
                }
            }
            HistoryCore.mergeAdapterContributions(historyContributions, into: &days)
            if let ledger = environment.historyLedger {
                let ledgerDays = ledger.fetchHistoryDays(clients: clients)
                if !ledgerDays.isEmpty {
                    days = HistoryLedger.mergeDays(liveDays: days, ledgerDays: ledgerDays)
                }
            }
            let built = HistoryCore.normalizeHistory(
                days: days, todayKey: nil,
                totalActiveTimeMsOverride: tokscaleSnapshot?.graphActiveTime
            )
            stateLock.lock()
            cachedHistory = built
            stateLock.unlock()
            span.end()
        }
        if fullCheck {
            environment.push("dashboard:historyChanged", NSNull())
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
            collectedAt: now
        )
        statsSpan.end()

        cachedClients = clients
        stateLock.lock()
        let previous = statsCache
        statsCache = stats
        stateLock.unlock()
        coordLock.lock()
        hasCompletedInitialStats = true
        coordLock.unlock()
        let pushed = previous == nil || contentSignature(stats) != contentSignature(previous!)
        if pushed {
            let pushSpan = PerfDiag.span("push-stats")
            environment.push("stats:push", BridgeCore.shared.statsPushPayload(stats))
            pushSpan.end()
            PerfDiag.log(String(format: "push stats:push id=%d", id))
            PerfDiag.dump(stats, name: String(format: "stats-%03d.json", id))
            PerfDiag.dump([
                "refreshId": id,
                "reason": reason.rawValue,
                "full": fullCheck,
                "collectedAtMs": now.timeIntervalSince1970 * 1000,
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

    /// Re-wrap the last collected periods with the current settings/limits
    /// and push, so a limits refresh lands in the renderer without a usage
    /// tick. Runs on the worker queue (single writer).
    func reemitStats() {
        workerQueue.async { [weak self] in
            autoreleasepool {
                guard let self, let periods = self.cachedPeriods else { return }
                let settings = self.environment.settings()
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
                let previous = self.statsCache
                self.statsCache = stats
                self.stateLock.unlock()
                // Gate like the main tick: only push when the payload actually
                // changed, so a limits refresh with no new data skips the push.
                let changed: Bool
                if let previous {
                    changed = !(previous as NSDictionary).isEqual(to: stats)
                } else {
                    changed = true
                }
                if changed {
                    self.environment.push("stats:push", BridgeCore.shared.statsPushPayload(stats))
                }
            }
        }
    }

    // MARK: - Pricing resolution (review round Phase 2)

    /// Pricing resolution per tick:
    ///  - routine ticks use the last-known-good local value and never spawn;
    ///  - a user refresh always attempts one lookup per distinct model;
    ///  - any failed lookup keeps the previous price, never zeroing costs.
    /// Resolved pricing feeds the derived signature, so affected clients
    /// re-derive from cached rows on the same tick without a raw re-read.
    private func resolvePricing(
        models: [String],
        policy: PricingPolicy,
        now: Date,
        lookedUpThisTick: inout Set<String>
    ) {
        for model in models {
            guard !lookedUpThisTick.contains(model) else { continue }
            let cached = cachedPricing[model]
            if let cached {
                switch policy {
                case .cacheOnly:
                    continue
                case .resolve:
                    let expired = now.timeIntervalSince(cached.fetchedAt) >= pricingTTL
                    if !expired { continue }
                    if let retry = pricingRetryAfter[model], now < retry { continue }
                case .forceRefresh:
                    break
                }
            } else if policy == .resolve, let retry = pricingRetryAfter[model], now < retry {
                continue
            }
            lookedUpThisTick.insert(model)
            if let pricing = environment.pricingLookup(model, policy) {
                cachedPricing[model] = (pricing, now)
                pricingRetryAfter.removeValue(forKey: model)
            } else if policy == .resolve {
                pricingRetryAfter[model] = now.addingTimeInterval(300)
            }
        }
    }

    /// Flat price map for the derivation helpers (worker-owned cache).
    private func pricingMapForDerivation() -> [String: TokscalePricing] {
        var map: [String: TokscalePricing] = [:]
        for (model, entry) in cachedPricing {
            map[model] = entry.pricing
        }
        return map
    }

    /// Canonical, sorted-key JSON signature of the custom pricing setting:
    /// stable across dictionary traversal orders, so two equivalent settings
    /// always compare equal.
    private func customPricingSignature(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Derived-key pricing signature: unresolved models are named so their
    /// later resolution invalidates the derived snapshot.
    private func pricingSignature(for models: [String]) -> String {
        var parts: [String] = []
        for key in models.sorted() {
            if let entry = cachedPricing[key] {
                parts.append(key + ":" + Self.pricingCostString(entry.pricing))
            } else {
                parts.append(key + ":UNRESOLVED")
            }
        }
        return parts.joined(separator: "|")
    }

    private static func pricingCostString(_ pricing: TokscalePricing) -> String {
        let p = pricing.pricing
        return String(format: "%.10g:%.10g:%.10g:%.10g",
                      p?.inputCostPerToken ?? -1,
                      p?.outputCostPerToken ?? -1,
                      p?.cacheReadInputTokenCost ?? -1,
                      p?.cacheCreationInputTokenCost ?? -1)
    }

    private static func distinctModelIds(_ rows: [UsageCore.UsageRow]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            let key = UsageCore.canonicalModelName((row.model ?? "").trimmingCharacters(in: .whitespaces).lowercased())
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
        }
        return out
    }

    private static func backoff(failures: Int) -> TimeInterval {
        let attempts = max(1, failures)
        return min(600, 30 * pow(2.0, Double(attempts - 1)))
    }

    // MARK: - Clock / calendar keys

    static func dayKey(_ date: Date) -> String {
        DateFormatUtil.dayKey(date)
    }

    static func monthKey(_ date: Date) -> String {
        DateFormatUtil.monthKey(date)
    }

    // MARK: - Components

    private func enabledClients(_ settings: [String: Any]) -> [String] {
        let csv = settings["clients"] as? String ?? "claude,codex,opencode,kimi,workbuddy,proma,hanako,dsh"
        return csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private func allTimeSinceMs(_ settings: [String: Any]) -> Double {
        let raw = settings["allTimeSince"] as? String ?? "2024-01-01"
        if let date = DateFormatUtil.parseDayKey(raw) {
            return date.timeIntervalSince1970 * 1000
        }
        return 0
    }

    private static func emptyTokscalePeriods() -> [String: [String: Any]] {
        return ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]
    }

    static func scanTokscalePeriods(clients: [String], settings: [String: Any], now: Date, ledger: HistoryLedger? = HistoryLedger.shared) -> [String: [String: Any]]? {
        guard !clients.isEmpty else { return emptyTokscalePeriods() }
        let since = settings["allTimeSince"] as? String ?? "2024-01-01"
        let periods = ["today", "month", "allTime"]

        // Parallel spawn: the three period scans read the same files but
        // are independent — running them concurrently cuts first-tick
        // wall-clock from ~3x single-scan to ~1x. TokscaleRunner.run is
        // thread-safe (runningProcesses/pricingCache are lock-guarded).
        let lock = NSLock()
        var results: [String: [String: Any]] = [:]
        var firstError: Error?
        let group = DispatchGroup()
        for period in periods {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let entries = try TokscaleRunner.shared.usage(clients: clients, period: period, allTimeSince: since)
                    let rows = entries.map(UsageCore.rowFromTokscaleEntry)
                    if period == "allTime" {
                        ledger?.recordUsageRows(rows, now: now)
                    }
                    let periodResult = UsageCore.extractPeriod(entries: rows)
                    lock.lock()
                    results[period] = periodResult
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        if let error = firstError {
            NSLog("[collector] tokscale scan failed: %@", String(describing: error))
            return nil
        }
        return results
    }

    static func scanTokscaleGraph(clients: [String], ledger: HistoryLedger? = HistoryLedger.shared) -> (days: [HistoryCore.Day], activeTimeMs: Double?)? {
        guard !clients.isEmpty else { return ([], nil) }
        guard let graph = try? TokscaleRunner.shared.graph(clients: clients) else { return nil }
        let days = HistoryCore.parseTokscaleGraph(graph)
        ledger?.recordTokscaleDays(days, now: Date())
        return (days, graph.timeMetrics?.totalActiveTimeMs)
    }

    /// Single-client period contributions (today/month/allTime) with costs
    /// attached from the shared pricing map.
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

    private func buildStats(settings: [String: Any], clients: [String], today: [String: Any], month: [String: Any], allTime: [String: Any], history: [String: Any]?, collectedAt: Date) -> [String: Any] {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let nowIso = DateFormatUtil.iso8601.string(from: collectedAt)
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
            "limits": limitsSummary
        ]
        if let history {
            stats["history"] = history
            stats["historyPreview"] = historyPreview(from: history)
        }
        return stats
    }

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

        return [
            "today": [
                "key": DateFormatUtil.dayKey(now),
                "endsAt": DateFormatUtil.iso8601.string(from: nextDay)
            ],
            "month": [
                "key": DateFormatUtil.monthKey(now),
                "endsAt": DateFormatUtil.iso8601.string(from: nextMonth)
            ]
        ]
    }

    private func contentSignature(_ stats: [String: Any]) -> UInt64 {
        // FNV-1a hash over the same fields the old string signature used.
        // Replaces [String] allocation + String(format:) + joined() with
        // a single UInt64 — cheaper to compute and compare. Quantization
        // to 4 decimal places matches the old %.4f string behavior.
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x100000001b3
        }
        func mixStr(_ s: String) {
            for byte in s.utf8 { mix(UInt64(byte)) }
        }
        func mixCost(_ v: Double) {
            let q = v.isFinite ? (v * 10000).rounded() : 0
            mix(q.bitPattern)
        }

        let periods = stats["periods"] as? [String: Any] ?? [:]
        for name in ["today", "month", "allTime"] {
            guard let period = periods[name] as? [String: Any] else { continue }
            mixStr(name)
            mix(UInt64(UsageCore.intValue(period["totalTokens"])))
            mixCost(UsageCore.doubleValue(period["costUsd"]))
            if let costs = period["clientCosts"] as? [String: Any] {
                for (client, cost) in costs.sorted(by: { $0.key < $1.key }) {
                    mixStr(client)
                    mixCost(UsageCore.doubleValue(cost))
                }
            }
        }
        if let device = (stats["devices"] as? [[String: Any]])?.first,
           let statuses = device["clientStatus"] as? [String: Any] {
            for (client, status) in statuses.sorted(by: { $0.key < $1.key }) {
                mixStr(client)
                mixStr(String(describing: status))
            }
        }
        return hash
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
        case "kimi": candidates = [
            "\(home)/.kimi/sessions",
            "\(home)/.kimi",
            SourceScanner.kimiCodeHome() + "/sessions",
            SourceScanner.kimiCodeHome()
        ]
        case "workbuddy": candidates = ["\(home)/.workbuddy"]
        case "proma": candidates = ["\(home)/.proma/agent-sessions", "\(home)/.proma"]
        case "hanako": candidates = ["\(home)/.hanako/agents", "\(home)/.hanako/agents/hanako/sessions", "\(home)/.hanako"]
        case "dsh": candidates = ["\(home)/.dsh/sessions", "\(home)/.dsh"]
        case "antigravity": candidates = [
            "\(home)/.gemini/antigravity",
            "\(home)/.gemini/antigravity-ide",
            "\(home)/.gemini/antigravity-backup",
            "\(home)/.gemini/antigravity-cli/conversations",
            "\(home)/.gemini/antigravity-cli",
            "\(home)/.config/tokscale/antigravity-cache",
            "\(home)/Library/Application Support/tokscale/antigravity-cache",
            "\(home)/Library/Application Support/Antigravity"
        ]
        default: candidates = []
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Custom pricing sidecar (port of tokscaleCustomPricing.js)

enum CustomPricingSidecar {
    static func sync(settingValue: Any?, settingsFileURL: URL) {
        let entries = normalizeCustomPricing(settingValue)
        let configDir: String = {
            if let env = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"], !env.isEmpty {
                return env
            }
            return NSHomeDirectory() + "/.config/tokscale"
        }()
        let pricingPath = configDir + "/custom-pricing.json"
        let sidecarPath = settingsFileURL.deletingLastPathComponent().appendingPathComponent("tokscale-managed-pricing.json").path
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

        // Sorted keys make the canonical bytes stable across dictionary
        // traversal orders; identical target bytes skip the write entirely
        // (no pointless mtime churn / SSD I/O on unchanged ticks).
        writeJsonAtomicIfChanged(["models": merged], to: pricingPath)
        writeJsonAtomicIfChanged(["version": 1, "managedIds": managedModels.keys.sorted()], to: sidecarPath)
    }

    private static func normalizeCustomPricing(_ value: Any?) -> [[String: Any]] {
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
        // Sort by modelId: dictionary iteration order must never leak into
        // the signature or the written files (round-4 Phase 3.2).
        return byId.keys.sorted().map { byId[$0]! }
    }

    private static func unitPrice(_ value: Any?) -> (value: Double?, isInvalid: Bool) {
        guard let value, !(value is NSNull) else { return (nil, false) }
        if let s = value as? String, s.isEmpty { return (nil, false) }
        if let n = value as? Double, n.isFinite, n >= 0 { return (n, false) }
        if let n = value as? Int, n >= 0 { return (Double(n), false) }
        return (nil, true)
    }

    private static func buildTokscaleModels(_ entries: [[String: Any]]) -> [String: Any] {
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

    private static func writeJsonAtomicIfChanged(_ object: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        // Content identical to the target file: skip the write. The caller
        // still records the attempt (Collector signature gate), so a failed
        // write below is logged but never retried on every cheap tick.
        if let existing = try? Data(contentsOf: URL(fileURLWithPath: path)), existing == data {
            return
        }
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("[pricing] write failed: %@", String(describing: error))
        }
    }
}
