import Foundation
import CZstd
@testable import TokenMonitorCore

// TokenMonitorFixtureCheck: fixed-input aggregation fixture checker
// (PLAN.md Phase 0 item 3/4). Mirrors CollectorCore.tick's composition
// against committed fixtures, a fixed clock and a fixed time zone, and
// compares the output with committed golden files so any aggregation
// change across optimization phases is caught automatically.
//
//   swift run TokenMonitorFixtureCheck                  # compare against goldens
//   TM_GOLDEN_UPDATE=1 swift run TokenMonitorFixtureCheck  # regenerate goldens
//
// Exits non-zero when any check fails.

var checkCount = 0
var failureCount = 0

func check(_ condition: Bool, _ message: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(message)")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    checkCount += 1
    if a != b {
        failureCount += 1
        print("FAIL: \(message) (\(a) != \(b))")
    }
}

func checkClose(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
    check(abs(a - b) <= tolerance, "\(message) (\(a) != \(b))")
}

enum FixtureHarness {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    static let todayKey = "2026-08-15"

    static var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 15))!
    }

    static var allTimeSinceMs: Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        return start.timeIntervalSince1970 * 1000
    }

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func json(_ name: String) -> Any {
        let url = fixturesDir.appendingPathComponent(name)
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data)
    }

    static func loadRows() -> [UsageCore.UsageRow] {
        guard let dict = json("adapter-rows.json") as? [String: Any],
              let list = dict["rows"] as? [[String: Any]] else { return [] }
        return list.map { row in
            UsageCore.UsageRow(
                client: row["client"] as? String,
                sessionId: row["sessionId"] as? String,
                model: row["model"] as? String,
                provider: row["provider"] as? String,
                input: UsageCore.doubleValue(row["input"]),
                output: UsageCore.doubleValue(row["output"]),
                cacheRead: UsageCore.doubleValue(row["cacheRead"]),
                cacheWrite: UsageCore.doubleValue(row["cacheWrite"]),
                reasoning: UsageCore.doubleValue(row["reasoning"]),
                messageCount: UsageCore.doubleValue(row["messageCount"]),
                cost: UsageCore.doubleValue(row["cost"]),
                startedAt: row["startedAt"] as? String ?? "",
                lastUsedAt: row["lastUsedAt"] as? String ?? "",
                projectId: row["projectId"] as? String ?? "",
                projectLabel: row["projectLabel"] as? String ?? "",
                performance: nil
            )
        }
    }

    static func loadPricing() -> [String: TokscalePricing] {
        guard let dict = json("pricing.json") as? [String: Any] else { return [:] }
        var out: [String: TokscalePricing] = [:]
        let decoder = JSONDecoder()
        for (key, value) in dict {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let pricing = try? decoder.decode(TokscalePricing.self, from: data) else { continue }
            out[key] = pricing
        }
        return out
    }

    static func loadTokscalePeriods() -> (today: [TokscaleEntry], month: [TokscaleEntry], allTime: [TokscaleEntry]) {
        guard let dict = json("tokscale-periods.json") as? [String: Any] else { return ([], [], []) }
        let decoder = JSONDecoder()
        func entries(_ key: String) -> [TokscaleEntry] {
            guard let list = dict[key] as? [Any] else { return [] }
            return list.compactMap { item in
                guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? decoder.decode(TokscaleEntry.self, from: data)
            }
        }
        return (entries("today"), entries("month"), entries("allTime"))
    }

    static func loadGraph() -> TokscaleGraph {
        let object = json("tokscale-graph.json")
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(TokscaleGraph.self, from: data)
    }

    /// The tick-composition mirror. Returns the merged periods and history
    /// dictionaries exactly as CollectorCore assembles them.
    static func build() -> (periods: [String: Any], history: [String: Any]) {
        let rows = loadRows()
        let pricing = loadPricing()
        let tokscale = loadTokscalePeriods()

        var adapterPeriods: [[String: [String: Any]]] = []
        for client in ["proma", "hanako", "dsh"] {
            let clientRows = rows.filter { $0.client == client }
            guard !clientRows.isEmpty else { continue }
            let todayStart = Adapters.localDayStart(now, timeZone: timeZone)
            let monthStart = Adapters.localMonthStart(now, timeZone: timeZone)
            var entryRows: [String: [UsageCore.UsageRow]] = [:]
            entryRows["today"] = Adapters.periodRows(rows: clientRows, sinceMs: todayStart, client: client, includeUndated: false, timeZone: timeZone)
            entryRows["month"] = Adapters.periodRows(rows: clientRows, sinceMs: monthStart, client: client, includeUndated: false, timeZone: timeZone)
            entryRows["allTime"] = Adapters.periodRows(rows: clientRows, sinceMs: allTimeSinceMs, client: client, includeUndated: true, timeZone: timeZone)

            var clientPeriods: [String: [String: Any]] = [:]
            for (period, periodRows) in entryRows {
                var priced = periodRows
                for i in 0..<priced.count {
                    priced[i].cost = Adapters.estimatedRowCost(row: priced[i], pricingByModel: pricing) ?? 0
                }
                clientPeriods[period] = UsageCore.extractPeriod(entries: priced)
            }
            adapterPeriods.append(clientPeriods)
        }

        func period(_ name: String) -> [String: Any] {
            let tokscaleEntries = name == "today" ? tokscale.today : (name == "month" ? tokscale.month : tokscale.allTime)
            let tokscalePeriod = UsageCore.extractPeriod(entries: tokscaleEntries.map(UsageCore.rowFromTokscaleEntry))
            let adapterOnes = adapterPeriods.map { $0[name] ?? UsageCore.emptyPeriod() }
            return UsageCore.mergePeriods([tokscalePeriod] + adapterOnes)
        }

        let today = period("today")
        let month = period("month")
        let allTime = period("allTime")

        // History: graph scan + adapter contributions, like buildHistory.
        var days: [HistoryCore.Day] = []
        var activeTimeOverride: Double? = nil
        let graph = loadGraph()
        days = HistoryCore.parseTokscaleGraph(graph)
        activeTimeOverride = graph.timeMetrics?.totalActiveTimeMs
        var contributions: [Adapters.HistoryContribution] = []
        for client in ["proma", "hanako", "dsh"] {
            contributions += Adapters.historyContributions(rows: rows.filter { $0.client == client },
                                                            client: client,
                                                            pricingByModel: pricing,
                                                            timeZone: timeZone)
        }
        HistoryCore.mergeAdapterContributions(contributions, into: &days)
        let history = HistoryCore.normalizeHistory(days: days, todayKey: todayKey, totalActiveTimeMsOverride: activeTimeOverride)

        return (["today": today, "month": month, "allTime": allTime], history)
    }

    static func canonical(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func compareGolden(_ value: [String: Any], name: String) {
        let url = fixturesDir.appendingPathComponent("golden").appendingPathComponent(name)
        // Debug aid: TM_DUMP_DIR=<dir> writes the computed value out so two
        // runs can be diffed to find nondeterminism.
        if let dumpDir = ProcessInfo.processInfo.environment["TM_DUMP_DIR"], !dumpDir.isEmpty {
            try? canonical(value).write(to: URL(fileURLWithPath: dumpDir).appendingPathComponent(name))
        }
        if ProcessInfo.processInfo.environment["TM_GOLDEN_UPDATE"] == "1" {
            let data = canonical(value)
            try! data.write(to: url, options: .atomic)
            print("wrote golden \(name)")
            return
        }
        let expected = try! Data(contentsOf: url)
        check(canonical(value) == expected, "golden mismatch for \(name)")
    }
}

// MARK: - Checks

func runChecks() {
    // Date boundaries (PLAN.md Phase 0 item 4)
    do {
        let (periods, _) = FixtureHarness.build()
        let today = periods["today"] as! [String: Any]
        let month = periods["month"] as! [String: Any]
        let allTime = periods["allTime"] as! [String: Any]

        // Hand-computed from the committed fixtures:
        // today   = adapter 650 + tokscale 41,782,131 = 41,782,781
        // month   = adapter 2,450 + tokscale 41,782,131 = 41,784,581
        // allTime = adapter 33,650 + tokscale 41,782,431 = 41,816,081
        checkEqual(UsageCore.intValue(today["totalTokens"]), 41_782_781, "today totalTokens")
        checkEqual(UsageCore.intValue(month["totalTokens"]), 41_784_581, "month totalTokens")
        checkEqual(UsageCore.intValue(allTime["totalTokens"]), 41_816_081, "allTime totalTokens")

        // Costs: today 43.548536, month 47.148536, allTime 309.798536.
        checkClose(UsageCore.doubleValue(today["costUsd"]), 43.548536, "today costUsd")
        checkClose(UsageCore.doubleValue(month["costUsd"]), 47.148536, "month costUsd")
        checkClose(UsageCore.doubleValue(allTime["costUsd"]), 309.798536, "allTime costUsd")

        // Session boundaries: today 5 (3 adapter + 2 tokscale), month 7
        // (today + s3 + s4), allTime 11 (month + s5 + s7 + undated s8 +
        // tokscale session-c3; s6 predates allTimeSince and never appears).
        func sessionCount(_ period: [String: Any]) -> Int {
            (period["sessions"] as? [String: Any] ?? [:]).count
        }
        checkEqual(sessionCount(today), 5, "today sessions")
        checkEqual(sessionCount(month), 7, "month sessions")
        checkEqual(sessionCount(allTime), 11, "allTime sessions")
    }

    do {
        let rows = FixtureHarness.loadRows()
        let proma = rows.filter { $0.client == "proma" }
        let todayStart = Adapters.localDayStart(FixtureHarness.now, timeZone: FixtureHarness.timeZone)
        let monthStart = Adapters.localMonthStart(FixtureHarness.now, timeZone: FixtureHarness.timeZone)

        let today = Adapters.periodRows(rows: proma, sinceMs: todayStart, client: "proma", includeUndated: false, timeZone: FixtureHarness.timeZone)
        checkEqual(today.count, 3, "proma today rows (s1, s2, merged s9)")

        let month = Adapters.periodRows(rows: proma, sinceMs: monthStart, client: "proma", includeUndated: false, timeZone: FixtureHarness.timeZone)
        checkEqual(month.count, 4, "proma month rows (s3 joins)")

        let allTime = Adapters.periodRows(rows: proma, sinceMs: FixtureHarness.allTimeSinceMs, client: "proma", includeUndated: true, timeZone: FixtureHarness.timeZone)
        checkEqual(allTime.count, 4, "proma allTime rows")

        // The s9 pair merges into one session+model row with summed tokens.
        let s9 = today.first { $0.sessionId == "s9" }
        check(s9 != nil, "s9 merged row exists")
        checkEqual(s9?.input ?? 0, 100, "s9 merged input")
        checkEqual(s9?.output ?? 0, 100, "s9 merged output")
        checkEqual(s9?.messageCount ?? 0, 2, "s9 merged messageCount")

        // Undated rows: excluded from today/month, included in allTime only.
        let dsh = rows.filter { $0.client == "dsh" }
        let dshToday = Adapters.periodRows(rows: dsh, sinceMs: todayStart, client: "dsh", includeUndated: false, timeZone: FixtureHarness.timeZone)
        check(!dshToday.contains { $0.sessionId == "s8" }, "undated s8 excluded from today")
        let dshAll = Adapters.periodRows(rows: dsh, sinceMs: FixtureHarness.allTimeSinceMs, client: "dsh", includeUndated: true, timeZone: FixtureHarness.timeZone)
        check(dshAll.contains { $0.sessionId == "s8" }, "undated s8 included in allTime")
        check(!dshAll.contains { $0.sessionId == "s6" }, "pre-allTimeSince s6 excluded everywhere")
    }

    // Golden fixtures (PLAN.md Phase 0 item 3)
    let (periods, history) = FixtureHarness.build()
    FixtureHarness.compareGolden(periods, name: "periods.json")
    FixtureHarness.compareGolden(history, name: "history.json")

    // Tokscale decode robustness
    do {
        let ts = FixtureHarness.loadTokscalePeriods()
        let rows = ts.today.map(UsageCore.rowFromTokscaleEntry)
        checkEqual(rows.count, 2, "tokscale today entries")
        checkEqual(rows[0].startedAt, "", "missing startedAt decodes empty")
        checkEqual(rows[0].lastUsedAt, "", "missing lastUsedAt decodes empty")

        let period = UsageCore.extractPeriod(entries: rows)
        checkEqual(UsageCore.intValue(period["totalTokens"]), 41_782_131, "tokscale today totalTokens")
        checkClose(UsageCore.doubleValue(period["costUsd"]), 42.648536, "tokscale today costUsd")
        checkEqual(UsageCore.intValue(period["timedTokens"]), 15_493_206, "tokscale timedTokens")
        checkEqual(UsageCore.intValue(period["timedOutputTokens"]), 47_665, "tokscale timedOutputTokens")
        checkEqual(UsageCore.intValue(period["timedDurationMs"]), 1_721_792, "tokscale timedDurationMs")

        let allRows = ts.allTime.map(UsageCore.rowFromTokscaleEntry)
        checkEqual(allRows.count, 3, "tokscale allTime entries")
        check(allRows[2].performance == nil, "entry without performance decodes")
    }

    // History normalization
    do {
        var days: [HistoryCore.Day] = []
        for i in 0..<3 {
            var day = HistoryCore.Day(date: "2026-08-\(String(format: "%02d", 13 + i))", tokens: 100, cost: 1, messages: 2)
            day.perModel["model-a"] = (tokens: 100, cost: 1)
            day.perClient["proma"] = (tokens: 100, cost: 1, messages: 2)
            days.append(day)
        }
        days.append(HistoryCore.Day(date: "2020-01-01", tokens: 999, cost: 9, messages: 1))

        let history = HistoryCore.normalizeHistory(days: days, todayKey: "2026-08-15", totalActiveTimeMsOverride: 4242)
        let daily = history["daily"] as? [[String: Any]] ?? []
        checkEqual(daily.count, 3, "daily capped window drops 2020 day")
        check(!daily.contains { ($0["date"] as? String) == "2020-01-01" }, "out-of-window day absent")
        let summary = history["summary"] as? [String: Any] ?? [:]
        checkClose(UsageCore.doubleValue(summary["activeTimeMs"]), 4242, "active time override")
        checkEqual(UsageCore.intValue(summary["currentStreak"]), 3, "current streak")
        checkEqual(UsageCore.intValue(summary["longestStreak"]), 3, "longest streak")
        // activeDays counts the FULL day set (the 2020 day is outside the
        // daily window but still contributes to the summary, as in history.js).
        checkEqual(UsageCore.intValue(summary["activeDays"]), 4, "active days")
        checkEqual((history["monthly"] as? [[String: Any]])?.count, 2, "monthly rollup count")
    }

    checkEqual(HistoryCore.dayKeyAddDays("2026-08-01", delta: -1), "2026-07-31", "day key minus across month")
    checkEqual(HistoryCore.dayKeyAddDays("2026-07-31", delta: 1), "2026-08-01", "day key plus across month")
    checkEqual(HistoryCore.dayKeyAddDays("2026-01-01", delta: -1), "2025-12-31", "day key minus across year")

    // DST boundary (PLAN.md Phase 0 item 4)
    do {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        // 2026-03-08 12:00 EDT; DST began that morning at 02:00 EST.
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let dayStart = Adapters.localDayStart(now, timeZone: tz)
        checkEqual(dayStart, cal.startOfDay(for: now).timeIntervalSince1970 * 1000, "DST day start equals calendar startOfDay")
        checkEqual(dayStart, 1_772_946_000_000, "2026-03-08T00:00 EST == 05:00Z")

        var row = UsageCore.UsageRow(client: "dsh", sessionId: "d1", model: "m", provider: "dsh",
                                     input: 1, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0,
                                     messageCount: 1, cost: 0, startedAt: "", lastUsedAt: "",
                                     projectId: "", projectLabel: "", performance: nil)
        // DST began 2026-03-08 02:00 EST in New York: 00:00-01:59 on that
        // day are still EST (UTC-5); 03:00+ is EDT (UTC-4). The "before"
        // row is the last second of the previous local day.
        row.startedAt = "2026-03-07T23:59:59-05:00" // 04:59:59Z, before local midnight
        row.lastUsedAt = row.startedAt
        let before = Adapters.periodRows(rows: [row], sinceMs: dayStart, client: "dsh", includeUndated: false, timeZone: tz)
        checkEqual(before.count, 0, "DST: pre-midnight row excluded from today")

        row.startedAt = "2026-03-08T00:00:00-05:00" // 05:00Z == local midnight exactly
        row.lastUsedAt = row.startedAt
        let atMidnight = Adapters.periodRows(rows: [row], sinceMs: dayStart, client: "dsh", includeUndated: false, timeZone: tz)
        checkEqual(atMidnight.count, 1, "DST: exact-midnight row included in today")

        row.startedAt = "2026-03-08T03:30:00-04:00" // after the switch, EDT
        row.lastUsedAt = row.startedAt
        let after = Adapters.periodRows(rows: [row], sinceMs: dayStart, client: "dsh", includeUndated: false, timeZone: tz)
        checkEqual(after.count, 1, "DST: post-switch row included in today")
        checkEqual(Adapters.localDateKey(UsageCore.timestampMs(row.startedAt), timeZone: tz), "2026-03-08", "DST: date key across switch")
    }
}

    // File fingerprint behavior (PLAN.md Phase 3 test matrix): no change,
    // append, overwrite, delete, atomic rename, new subdirectory.
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tm-fp-test-\(UUID().uuidString)")
        try! fm.createDirectory(at: root.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.jsonl")
        let b = root.appendingPathComponent("b.jsonl")
        try! Data("one\n".utf8).write(to: a)
        try! Data("two\n".utf8).write(to: b)
        let sig0 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(!sig0.isEmpty, "fingerprint non-empty for two files")

        // No change -> identical signature.
        let sig0b = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        checkEqual(sig0b, sig0, "fingerprint stable without changes")

        // Append -> signature changes (size/mtime).
        let fh = try! FileHandle(forWritingTo: a)
        fh.seekToEndOfFile()
        fh.write(Data("more\n".utf8))
        try! fh.close()
        let sig1 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(sig1 != sig0, "append changes signature")

        // Overwrite same size (mtime still changes) -> signature changes.
        try! Data("three\n".utf8).write(to: b)
        let sig2 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(sig2 != sig1, "overwrite changes signature")

        // Delete -> signature changes.
        try! fm.removeItem(at: b)
        let sig3 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(sig3 != sig2, "delete changes signature")

        // New file -> signature changes.
        let c = root.appendingPathComponent("c.jsonl")
        try! Data("four\n".utf8).write(to: c)
        let sig4 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(sig4 != sig3, "new file changes signature")

        // Atomic rename (write tmp then rename) of a NEW name -> signature
        // changes; renaming a file away and back to the same name is
        // correctly stable (same path, size and mtime).
        let tmp = root.appendingPathComponent("e.jsonl.tmp")
        try! Data("five\n".utf8).write(to: tmp)
        let e = root.appendingPathComponent("e.jsonl")
        try! fm.moveItem(at: tmp, to: e)
        let sig5 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(sig5 != sig4, "atomic rename of a new name changes signature")

        // New subdirectory with a file -> signature changes.
        try! Data("five\n".utf8).write(to: root.appendingPathComponent("sub/d.jsonl"))
        let sig6 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        check(sig6 != sig5, "new nested file changes signature")

        // Extension filter: non-jsonl files do not participate (proma).
        try! Data("noise".utf8).write(to: root.appendingPathComponent("ignore.txt"))
        let sig7 = SourceScanner.fingerprint(client: "proma", roots: [root.path]).signature
        checkEqual(sig7, sig6, "unrelated file types are ignored")

        // Missing roots produce an empty, stable fingerprint.
        let missing = SourceScanner.fingerprint(client: "proma", roots: ["/nonexistent/tm-path"])
        check(missing.isEmpty, "missing roots yield empty fingerprint")
        let missing2 = SourceScanner.fingerprint(client: "proma", roots: ["/nonexistent/tm-path"])
        checkEqual(missing2.signature, missing.signature, "empty fingerprint is stable")
    }

// MARK: - Stateful Collector tests (review-round Phase 0)
//
// These drive a real Collector instance with fakes for file scanning,
// tokscale runs, pricing lookups, settings and the clock. They assert
// observable behavior and call counts (raw reads, pricing lookups,
// tokscale spawns, executed ticks) — not just pure-function outputs.

func shanghaiDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func stateRow(client: String, session: String, model: String, input: Double, output: Double, startedAt: String) -> UsageCore.UsageRow {
    return UsageCore.UsageRow(
        client: client, sessionId: session, model: model, provider: client,
        input: input, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0,
        messageCount: 1, cost: 0, startedAt: startedAt, lastUsedAt: startedAt,
        projectId: "", projectLabel: "", performance: nil
    )
}

func periodWithTokens(_ tokens: Int, client: String = "claude") -> [String: Any] {
    var p = UsageCore.emptyPeriod()
    p["totalTokens"] = tokens
    p["clients"] = [client: tokens]
    return p
}

func fakePricing(_ inputCost: Double, _ outputCost: Double) -> TokscalePricing {
    return TokscalePricing(
        modelId: "model-a", matchedKey: "model-a", source: "test",
        pricing: TokscalePricing.Pricing(
            inputCostPerToken: inputCost, outputCostPerToken: outputCost,
            cacheReadInputTokenCost: nil, cacheCreationInputTokenCost: nil
        )
    )
}

final class FakeCollectorWorld {
    var now: Date
    var settings: [String: Any]
    var adapterFingerprints: [String: String] = [:]
    var rowsByClient: [String: [UsageCore.UsageRow]] = [:]
    var pricingByModel: [String: TokscalePricing?] = [:]
    var tokscaleFingerprint = "fp-tok-1"
    var tokscalePeriods: [String: [String: Any]]?
    var tokscaleGraph: (days: [HistoryCore.Day], activeTimeMs: Double?)?
    var pushes: [[String: Any]] = []
    var statsPushes: Int {
        pushes.filter { ($0["event"] as? String) == "stats:push" }.count
    }
    // tickKinds/tickReasons are appended on the worker queue and read by the
    // main thread; mid-tick assertions (while the worker is blocked) use the
    // locked snapshot so the test itself stays race-free under TSan.
    private let observerLock = NSLock()
    func tickKindSnapshot() -> [RefreshKind] {
        observerLock.lock(); defer { observerLock.unlock() }
        return tickKinds
    }
    var tickKinds: [RefreshKind] = []
    var tickReasons: [RefreshReason] = []
    var rawReads: [String: Int] = [:]
    var pricingLookups: [String: Int] = [:]
    var pricingLookupPolicies: [String: PricingPolicy] = [:]
    var tokscalePeriodSpawns = 0
    var tokscaleGraphSpawns = 0
    var tokscaleFingerprintChecks = 0
    var adapterFingerprintChecks: [String: Int] = [:]
    var customPricingSyncCalls = 0
    /// When non-nil, the first adapter read blocks until this is signalled.
    var blockFirstRead: DispatchSemaphore?

    init(now: Date, settings: [String: Any]) {
        self.now = now
        self.settings = settings
    }

    func makeCollector() -> (Collector, DispatchQueue) {
        let queue = DispatchQueue(label: "test-collector-\(UUID().uuidString)")
        let env = CollectorEnvironment(
            now: { self.now },
            settings: { self.settings },
            adapterFingerprint: { client in
                self.adapterFingerprintChecks[client, default: 0] += 1
                return SourceScanner.Fingerprint(files: [], signature: self.adapterFingerprints[client] ?? "")
            },
            adapterRows: { client in
                self.rawReads[client, default: 0] += 1
                if let gate = self.blockFirstRead {
                    self.blockFirstRead = nil
                    gate.wait()
                }
                return self.rowsByClient[client] ?? []
            },
            pricingLookup: { model, policy in
                self.pricingLookups[model, default: 0] += 1
                self.pricingLookupPolicies[model] = policy
                return self.pricingByModel[model] ?? nil
            },
            tokscaleFingerprint: { _ in
                self.tokscaleFingerprintChecks += 1
                return SourceScanner.Fingerprint(files: [], signature: self.tokscaleFingerprint)
            },
            tokscalePeriods: { _, _, _ in
                self.tokscalePeriodSpawns += 1
                return self.tokscalePeriods
            },
            tokscaleGraph: { _ in
                self.tokscaleGraphSpawns += 1
                return self.tokscaleGraph
            },
            push: { event, payload in
                self.pushes.append(["event": event, "payload": payload])
            },
            customPricingSync: { _ in
                self.customPricingSyncCalls += 1
            },
            tickObserver: { kind, reason in
                self.observerLock.lock()
                self.tickKinds.append(kind)
                self.tickReasons.append(reason)
                self.observerLock.unlock()
            }
        )
        return (Collector(environment: env, workerQueue: queue), queue)
    }

    func waitIdle(_ collector: Collector, _ queue: DispatchQueue) {
        queue.sync {}
    }

    func period(_ collector: Collector, _ name: String) -> [String: Any] {
        let periods = collector.latestStats()?["periods"] as? [String: Any] ?? [:]
        return periods[name] as? [String: Any] ?? [:]
    }
}

func stateSettings(clients: String, allTimeSince: String = "2024-01-01", collectionIntervalMs: Double = 300000) -> [String: Any] {
    return [
        "clients": clients,
        "allTimeSince": allTimeSince,
        "collectionIntervalMs": collectionIntervalMs,
        "refreshMs": 15000,
        "customModelPricing": [Any](),
        "deviceId": "test-device"
    ]
}

func runCollectorStateTests() {
    // T1: midnight crossing re-derives today from cached rows (no raw read).
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 23, 59),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T12:00:00+08:00"),
            stateRow(client: "proma", session: "s2", model: "model-a", input: 200, output: 100, startedAt: "2026-08-14T12:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 150, "T1 today before midnight")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T1 one raw read at startup")

        world.now = shanghaiDate(2026, 8, 16, 0, 1)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 0, "T1 today empty after midnight")
        checkEqual(UsageCore.intValue(world.period(collector, "month")["totalTokens"]), 450, "T1 month keeps both days")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T1 no raw re-read after midnight")
    }

    // T2: month crossing re-derives month from cached rows.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 31, 23, 59),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-31T12:00:00+08:00"),
            stateRow(client: "proma", session: "s2", model: "model-a", input: 200, output: 100, startedAt: "2026-07-15T12:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        // month = current month only: the July row is outside it.
        checkEqual(UsageCore.intValue(world.period(collector, "month")["totalTokens"]), 150, "T2 month before rollover")

        world.now = shanghaiDate(2026, 9, 1, 0, 1)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "month")["totalTokens"]), 0, "T2 month empty after rollover")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T2 no raw re-read after rollover")
    }

    // T3: allTimeSince change re-derives adapter allTime from cached rows.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma", allTimeSince: "2024-01-01")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2025-06-01T12:00:00+08:00"),
            stateRow(client: "proma", session: "s2", model: "model-a", input: 200, output: 100, startedAt: "2023-06-01T12:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 150, "T3 allTime before since change")

        world.settings["allTimeSince"] = "2023-01-01"
        collector.requestRefresh(.full, reason: .settingsChange)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 450, "T3 allTime after since change")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T3 no raw re-read for allTimeSince")
    }

    // T4: disabling a client removes it from totals/history immediately.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,hanako")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.rowsByClient["hanako"] = [
            stateRow(client: "hanako", session: "h1", model: "model-b", input: 300, output: 150, startedAt: "2026-08-15T11:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        let allTimeBefore = world.period(collector, "allTime")
        checkEqual(UsageCore.intValue((allTimeBefore["clients"] as? [String: Any])?["proma"]), 150, "T4 proma present before")
        checkEqual(UsageCore.intValue((allTimeBefore["clients"] as? [String: Any])?["hanako"]), 450, "T4 hanako present before")

        world.settings["clients"] = "hanako"
        collector.requestRefresh(.full, reason: .settingsChange)
        world.waitIdle(collector, queue)
        let allTimeAfter = world.period(collector, "allTime")
        checkEqual(UsageCore.intValue((allTimeAfter["clients"] as? [String: Any])?["proma"]), 0, "T4 proma gone after disable")
        checkEqual(UsageCore.intValue((allTimeAfter["clients"] as? [String: Any])?["hanako"]), 450, "T4 hanako stays")
        checkEqual(UsageCore.intValue(allTimeAfter["totalTokens"]), 450, "T4 totals exclude disabled client")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T4 no raw re-read for client change")
        // History no longer contains proma per-client contributions.
        let history = collector.history() ?? [:]
        let days = history["daily"] as? [[String: Any]] ?? []
        var promaInHistory = false
        for day in days {
            let perClient = day["perClient"] as? [String: Any] ?? [:]
            if perClient["proma"] != nil { promaInHistory = true }
        }
        check(!promaInHistory, "T4 proma gone from history")
    }

    // T5: startup cheap pricing miss is retried and completed by the full
    // tick, costs update without a raw re-read.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.pricingByModel["model-a"] = nil // unresolved on cache-only
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.cheap, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.0, "T5 cost 0 before pricing resolved")
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T5 one cache-only lookup")
        checkEqual(world.pricingLookupPolicies["model-a"], .cacheOnly, "T5 cheap tick uses cacheOnly policy")

        world.pricingByModel["model-a"] = fakePricing(0.001, 0.002)
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 2, "T5 full tick retries the lookup")
        checkEqual(world.pricingLookupPolicies["model-a"], .resolve, "T5 full tick uses resolve policy")
        // 100 input * 0.001 + 50 output * 0.002 = 0.1 + 0.1 = 0.2
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.2, "T5 cost resolved after full tick")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T5 no raw re-read for pricing")
    }

    // T6: scheduled full checks respect collectionIntervalMs; an unchanged
    // fingerprint check advances the cadence without spawning.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,claude", collectionIntervalMs: 300000)
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.tokscalePeriods = ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]
        world.tokscaleGraph = ([], nil)
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleFingerprintChecks, 1, "T6 full startup checks fingerprint once")
        checkEqual(world.tokscalePeriodSpawns, 1, "T6 startup scans periods once")

        world.now = world.now.addingTimeInterval(60)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleFingerprintChecks, 1, "T6 cheap tick within interval does not full-check")

        world.now = world.now.addingTimeInterval(301)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleFingerprintChecks, 2, "T6 full check runs once interval elapsed")
        checkEqual(world.tokscalePeriodSpawns, 1, "T6 unchanged fingerprint spawns nothing")

        world.now = world.now.addingTimeInterval(60)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleFingerprintChecks, 2, "T6 cadence reset: no per-15s full check")
    }

    // T9: startup runs the cheap tick first, then the full tick — the
    // first stats push must stay cheap (cheap-first startup).
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.cheap, reason: .startup)
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tickKinds.count, 2, "T9 startup executes two ticks")
        checkEqual(world.tickKinds.first, .cheap, "T9 startup cheap runs first")
        checkEqual(world.tickKinds.last, .full, "T9 startup full follows the cheap tick")
    }

    // T7: requests arriving during a long tick coalesce into exactly one
    // necessary follow-up refresh (a full), settings change not lost.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let gate = DispatchSemaphore(value: 0)
        world.blockFirstRead = gate
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .manual)
        // Give the worker a moment to enter the blocked tick.
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<10 { collector.requestRefresh(.cheap, reason: .timer) }
        for _ in 0..<3 { collector.requestRefresh(.full, reason: .manual) }
        collector.requestRefresh(.full, reason: .settingsChange)
        checkEqual(world.tickKindSnapshot().count, 1, "T7 blocked tick is the only running tick")
        gate.signal()
        world.waitIdle(collector, queue)
        checkEqual(world.tickKinds.count, 2, "T7 exactly one follow-up tick after the burst")
        checkEqual(world.tickKinds.last, .full, "T7 follow-up is a full refresh")
    }

    // T8: period success + graph failure keeps new periods and old history;
    // graph retries with backoff without re-running the periods.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,claude", collectionIntervalMs: 300)
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.tokscalePeriods = ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]
        world.tokscaleGraph = nil // graph fails on the first full scan
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePeriodSpawns, 1, "T8 first full scans periods once")
        checkEqual(world.tokscaleGraphSpawns, 1, "T8 first full attempts graph once")
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 150, "T8 periods survive graph failure")

        // Immediate manual full: within backoff, no retry.
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleGraphSpawns, 1, "T8 graph retry backs off")

        // After the backoff window: graph retries alone, periods not re-run.
        var graphDay = HistoryCore.Day(date: "2026-08-15", tokens: 10, cost: 0.5, messages: 1)
        graphDay.perClient["claude"] = (tokens: 10, cost: 0.5, messages: 1)
        world.tokscaleGraph = (days: [graphDay], activeTimeMs: 1000)
        world.now = world.now.addingTimeInterval(301)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleGraphSpawns, 2, "T8 graph retried after backoff")
        checkEqual(world.tokscalePeriodSpawns, 1, "T8 periods not re-run for a graph-only retry")
        let history = collector.history() ?? [:]
        let daily = history["daily"] as? [[String: Any]] ?? []
        check(daily.contains { ($0["date"] as? String) == "2026-08-15" && UsageCore.doubleValue($0["tokens"]) > 0 }, "T8 history gained the graph day after recovery")
    }

    // T10: a context change (new day, same fingerprint) resets per-part
    // validity. The old snapshot's success flags must not leak into the new
    // context; the failed part keeps last-known-good data but retries alone
    // after its backoff, and the successful part is not re-run.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,claude", collectionIntervalMs: 300)
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.tokscalePeriods = ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]
        world.tokscaleGraph = ([], nil)
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePeriodSpawns, 1, "T10 first full scans periods once")
        checkEqual(world.tokscaleGraphSpawns, 1, "T10 first full scans graph once")
        checkEqual(collector.tokscaleSnapshot?.periodsSuccess, true, "T10 initial period success")
        checkEqual(collector.tokscaleSnapshot?.graphSuccess, true, "T10 initial graph success")

        // Next day, same fingerprint: the period scan fails, graph succeeds.
        world.now = shanghaiDate(2026, 8, 16, 0, 5)
        world.tokscalePeriods = nil
        var graphDay = HistoryCore.Day(date: "2026-08-16", tokens: 10, cost: 0.5, messages: 1)
        graphDay.perClient["claude"] = (tokens: 10, cost: 0.5, messages: 1)
        world.tokscaleGraph = (days: [graphDay], activeTimeMs: 1000)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(collector.tokscaleSnapshot?.periodsSuccess, false, "T10 new-context period failure resets validity")
        checkEqual(collector.tokscaleSnapshot?.graphSuccess, true, "T10 new-context graph success kept")
        checkEqual(world.tokscalePeriodSpawns, 2, "T10 period attempted once for the new context")
        checkEqual(world.tokscaleGraphSpawns, 2, "T10 graph attempted once for the new context")
        // Old period data stays visible as last-known-good (adapter-only totals).
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 150, "T10 last-known-good period data still displayed")

        // Within the backoff window nothing retries.
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePeriodSpawns, 2, "T10 period failure backs off")
        checkEqual(world.tokscaleGraphSpawns, 2, "T10 successful graph not re-run")

        // After the backoff window the period retries alone and recovers.
        world.tokscalePeriods = [
            "today": periodWithTokens(500),
            "month": periodWithTokens(500),
            "allTime": periodWithTokens(500)
        ]
        world.now = world.now.addingTimeInterval(301)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePeriodSpawns, 3, "T10 failed period retried after backoff")
        checkEqual(world.tokscaleGraphSpawns, 2, "T10 successful graph still not re-run")
        checkEqual(collector.tokscaleSnapshot?.periodsSuccess, true, "T10 period validity recovered")
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 650, "T10 recovered period data merged")
    }

    // T10b: the symmetric case — fingerprint changes and the graph scan
    // fails: graph validity must reset and retry alone, period not re-run.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,claude", collectionIntervalMs: 300)
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.tokscalePeriods = ["today": UsageCore.emptyPeriod(), "month": UsageCore.emptyPeriod(), "allTime": UsageCore.emptyPeriod()]
        world.tokscaleGraph = ([], nil)
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePeriodSpawns, 1, "T10b startup scans periods once")
        checkEqual(world.tokscaleGraphSpawns, 1, "T10b startup scans graph once")

        // Fingerprint changes and the graph scan now fails.
        world.tokscaleFingerprint = "fp-tok-2"
        world.tokscaleGraph = nil
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(collector.tokscaleSnapshot?.graphSuccess, false, "T10b new-context graph failure resets validity")
        checkEqual(collector.tokscaleSnapshot?.periodsSuccess, true, "T10b period success kept for new context")
        checkEqual(world.tokscalePeriodSpawns, 2, "T10b period scanned once for the new context")
        checkEqual(world.tokscaleGraphSpawns, 2, "T10b graph attempted once for the new context")

        // Within backoff nothing retries.
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleGraphSpawns, 2, "T10b graph failure backs off")
        checkEqual(world.tokscalePeriodSpawns, 2, "T10b successful period not re-run")

        // After backoff the graph retries alone and recovers.
        var graphDay = HistoryCore.Day(date: "2026-08-15", tokens: 10, cost: 0.5, messages: 1)
        graphDay.perClient["claude"] = (tokens: 10, cost: 0.5, messages: 1)
        world.tokscaleGraph = (days: [graphDay], activeTimeMs: 1000)
        world.now = world.now.addingTimeInterval(301)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleGraphSpawns, 3, "T10b failed graph retried after backoff")
        checkEqual(world.tokscalePeriodSpawns, 2, "T10b successful period still not re-run")
        checkEqual(collector.tokscaleSnapshot?.graphSuccess, true, "T10b graph validity recovered")
    }

    // T11: disabling every client pushes one legal empty stats/history wire
    // shape (no early return), clears the raw/derived caches, and recovers
    // when clients are re-enabled.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,hanako")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.rowsByClient["hanako"] = [
            stateRow(client: "hanako", session: "h1", model: "model-b", input: 300, output: 150, startedAt: "2026-08-15T11:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 600, "T11 initial totals")
        checkEqual(collector.rawSnapshots.count, 2, "T11 raw snapshots for both clients")
        checkEqual(world.statsPushes, 1, "T11 one startup push")

        // Partial disable: proma drops out and its caches are removed.
        world.settings["clients"] = "hanako"
        collector.requestRefresh(.full, reason: .settingsChange)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 450, "T11 partial disable totals")
        checkEqual(collector.rawSnapshots.count, 1, "T11 disabled client raw cache removed")
        checkEqual(collector.derivedSnapshots.count, 1, "T11 disabled client derived cache removed")

        // Full disable: one empty push with the normal wire shape.
        world.settings["clients"] = ""
        collector.requestRefresh(.full, reason: .settingsChange)
        world.waitIdle(collector, queue)
        let stats = collector.latestStats() ?? [:]
        let periods = stats["periods"] as? [String: Any] ?? [:]
        let allTime = periods["allTime"] as? [String: Any] ?? [:]
        let today = periods["today"] as? [String: Any] ?? [:]
        checkEqual(UsageCore.intValue(allTime["totalTokens"]), 0, "T11 empty clients zero totals")
        checkEqual(UsageCore.intValue(today["totalTokens"]), 0, "T11 empty clients zero today")
        checkEqual((allTime["clients"] as? [String: Any] ?? [:]).isEmpty, true, "T11 no per-client entries")
        let device = (stats["devices"] as? [[String: Any]])?.first ?? [:]
        checkEqual((device["trackedClients"] as? [String] ?? []).isEmpty, true, "T11 trackedClients empty")
        checkEqual((device["clientStatus"] as? [String: Any] ?? [:]).isEmpty, true, "T11 clientStatus empty")
        let history = stats["history"] as? [String: Any]
        check(history != nil, "T11 empty history present")
        checkEqual((history?["daily"] as? [Any] ?? []).isEmpty, true, "T11 empty daily history")
        checkEqual(collector.rawSnapshots.isEmpty, true, "T11 all raw caches cleared")
        checkEqual(collector.derivedSnapshots.isEmpty, true, "T11 all derived caches cleared")
        checkEqual(collector.tokscaleSnapshot == nil, true, "T11 tokscale snapshot dropped")
        checkEqual(world.statsPushes, 3, "T11 empty stats pushed exactly once")

        // Re-enable: normal collection resumes.
        world.settings["clients"] = "proma"
        collector.requestRefresh(.full, reason: .settingsChange)
        world.waitIdle(collector, queue)
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 150, "T11 re-enabled client recovers")
        checkEqual(world.statsPushes, 4, "T11 recovery pushed once")
    }

    // T13: timer cheap requests arriving while a full tick is running are
    // covered by that full and dropped instead of queued behind it.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let gate = DispatchSemaphore(value: 0)
        world.blockFirstRead = gate
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .manual)
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<10 { collector.requestRefresh(.cheap, reason: .timer) }
        checkEqual(world.tickKindSnapshot().count, 1, "T13 blocked full is the only running tick")
        gate.signal()
        world.waitIdle(collector, queue)
        checkEqual(world.tickKinds.count, 1, "T13 timer cheaps during a running full are dropped")
    }

    // T13b: strong requests arriving during a running full still queue
    // exactly one necessary follow-up; the strongest kind wins.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let gate = DispatchSemaphore(value: 0)
        world.blockFirstRead = gate
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .manual)
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<5 { collector.requestRefresh(.cheap, reason: .timer) }
        collector.requestRefresh(.full, reason: .settingsChange)
        collector.requestRefresh(.full, reason: .manual)
        collector.requestRefresh(.fullForced, reason: .manual)
        checkEqual(world.tickKindSnapshot().count, 1, "T13b blocked tick is the only running tick")
        gate.signal()
        world.waitIdle(collector, queue)
        checkEqual(world.tickKinds.count, 2, "T13b exactly one follow-up tick")
        checkEqual(world.tickKinds.last, .fullForced, "T13b strongest request wins")
    }

    // T12: pricing honors the 6h TTL in a long-running app. Within the TTL
    // nothing re-resolves; past the TTL exactly one resolve runs per model
    // and tick (shared across clients), costs re-derive from cached rows;
    // an expired lookup failure keeps the last-known-good price with a
    // bounded retry floor instead of zeroing costs.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma,hanako")
        )
        world.pricingByModel["model-a"] = fakePricing(0.001, 0.002)
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.rowsByClient["hanako"] = [
            stateRow(client: "hanako", session: "h1", model: "model-a", input: 200, output: 100, startedAt: "2026-08-15T11:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T12 one lookup per tick for a model shared by clients")
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.6, "T12 initial costs")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T12 one raw read at startup")

        // Within the TTL another full adds no resolve lookup.
        world.now = world.now.addingTimeInterval(3600)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T12 cached pricing within TTL does not resolve")

        // Past 6h: the runner returns an updated price. Exactly one resolve
        // runs; costs re-derive from cached rows without a raw re-read.
        world.now = world.now.addingTimeInterval(6 * 3600 + 60)
        world.pricingByModel["model-a"] = fakePricing(0.002, 0.004)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 2, "T12 expired pricing resolved once")
        checkEqual(world.pricingLookupPolicies["model-a"], .resolve, "T12 expired resolve uses resolve policy")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T12 expiry re-derives from cached rows")
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 1.2, "T12 updated costs after expiry")

        // Expired lookup failure: last-known-good pricing survives with a
        // bounded retry floor; costs are never zeroed.
        world.pricingByModel["model-a"] = nil
        world.now = world.now.addingTimeInterval(7 * 3600)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 3, "T12 expired resolve attempted once on failure")
        // The clock has crossed midnight by now, so the allTime window is
        // the stable view: last-known-good costs must survive the failure.
        checkClose(UsageCore.doubleValue(world.period(collector, "allTime")["costUsd"]), 1.2, "T12 failed expiry keeps last-known-good costs")
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 3, "T12 expiry failure respects the retry floor")

        world.pricingByModel["model-a"] = fakePricing(0.003, 0.006)
        world.now = world.now.addingTimeInterval(301)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 4, "T12 expiry retried after the floor")
        checkClose(UsageCore.doubleValue(world.period(collector, "allTime")["costUsd"]), 1.8, "T12 recovered costs")
    }

    // T14: the custom pricing sidecar syncs only on the first tick and when
    // the setting actually changes; a change also invalidates the pricing
    // generation through the real settings-change notification path.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.pricingByModel["model-a"] = fakePricing(0.001, 0.002)
        world.settings["customModelPricing"] = [
            ["modelId": "custom-a", "inputPerM": 1.5, "outputPerM": 3.0]
        ]
        let (collector, queue) = world.makeCollector()
        collector.start()
        world.waitIdle(collector, queue)
        checkEqual(world.customPricingSyncCalls, 1, "T14 startup syncs the sidecar exactly once")
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T14 pricing resolved once at startup")

        // Ordinary ticks with the same setting never re-sync.
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        collector.requestRefresh(.full, reason: .manual)
        world.waitIdle(collector, queue)
        checkEqual(world.customPricingSyncCalls, 1, "T14 unchanged setting does not re-sync")

        // An actual change (through the real notification the settings
        // store posts) syncs exactly once more and invalidates pricing.
        world.settings["customModelPricing"] = [
            ["modelId": "custom-a", "inputPerM": 2.0, "outputPerM": 3.0]
        ]
        NotificationCenter.default.post(
            name: SettingsStore.changedNotification,
            object: nil,
            userInfo: ["keys": ["customModelPricing"]]
        )
        world.waitIdle(collector, queue)
        checkEqual(world.customPricingSyncCalls, 2, "T14 changed setting syncs exactly once more")
        checkEqual(world.pricingLookups["model-a"] ?? 0, 2, "T14 pricing generation invalidated and re-resolved")
    }

    // T15: the adapter re-read cooldown defers re-reads while a source is
    // actively appending; stats may lag by the window, and the re-read
    // happens once the window elapses.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T11:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.cheap, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T15 one raw read at startup")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 150, "T15 initial tokens")

        // Fingerprint changes, but the last read was < 30s ago: the tick
        // defers the re-read and keeps publishing the previous snapshot.
        world.adapterFingerprints["proma"] = "fp-v2"
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 200, output: 100, startedAt: "2026-08-15T11:00:00+08:00")
        ]
        world.now = world.now.addingTimeInterval(10)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T15 no re-read inside cooldown")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 150, "T15 stats still show previous snapshot")

        // Past the 30s window the next tick re-reads and picks up the data.
        world.now = world.now.addingTimeInterval(40)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.rawReads["proma"] ?? 0, 2, "T15 re-read after cooldown elapses")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 300, "T15 fresh data after re-read")
    }
}

// MARK: - DSH cache lifecycle tests (round-4 Phase 5)

func compressZstd(_ text: String) -> Data {
    let input = Array(text.utf8)
    let bound = ZSTD_compressBound(input.count)
    var dst = [UInt8](repeating: 0, count: bound)
    let written = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
        dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            ZSTD_compress(out.baseAddress, bound, src.baseAddress, src.count, Int32(1))
        }
    }
    guard written > 0 else { return Data() }
    return Data(dst.prefix(written))
}

func dshSessionLines(_ input: Int) -> String {
    return "{\"type\":\"session\",\"seq\":0,\"createdAt\":\"2026-08-15T10:00:00+08:00\"}\n"
        + "{\"type\":\"request/header\",\"seq\":1,\"time\":\"2026-08-15T10:00:05+08:00\",\"data\":{\"header\":{\"config\":{\"model\":\"deepseek-chat\"}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":2,\"time\":\"2026-08-15T10:00:10+08:00\",\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":\(input),\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
}

func runDshCacheTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-dsh-\(UUID().uuidString)")
    let s1 = dir.appendingPathComponent("session-1")
    let s2 = dir.appendingPathComponent("session-2")
    try! fm.createDirectory(at: s1, withIntermediateDirectories: true)
    try! fm.createDirectory(at: s2, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let f1 = s1.appendingPathComponent("session.jsonl.zstd")
    let f2 = s2.appendingPathComponent("session.jsonl.zstd")
    try! compressZstd(dshSessionLines(100)).write(to: f1)
    try! compressZstd(dshSessionLines(300)).write(to: f2)

    // T15a: the first parse decompresses once; the second parse hits the
    // parse cache and never decompresses again.
    let c0 = Adapters.dshDecompressCount
    let r1 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r1.events, 1, "T15 one usage event parsed")
    checkEqual(r1.rows.count, 1, "T15 one row parsed")
    checkEqual(r1.rows.first?.input ?? 0, 100, "T15 input tokens parsed")
    checkEqual(r1.rows.first?.output ?? 0, 50, "T15 output tokens parsed")
    checkEqual(Adapters.dshDecompressCount - c0, 1, "T15 first parse decompresses once")
    let r2 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r2.rows.count, 1, "T15 second parse returns cached rows")
    checkEqual(Adapters.dshDecompressCount - c0, 1, "T15 cache hit does not re-decompress")

    // T15b: the fully decompressed Data must not be retained long-term.
    checkEqual(Adapters.dshRetainedDecompressedBytes, 0, "T15 decompressed Data not retained")

    // T15c: a stamp change re-decompresses only that file and replaces its
    // entry instead of keeping a historical version.
    try! compressZstd(dshSessionLines(100) + "{\"type\":\"session\",\"seq\":9,\"createdAt\":\"2026-08-15T11:00:00+08:00\"}\n").write(to: f1)
    let r3 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r3.rows.first?.input ?? 0, 100, "T15 replaced file still parses")
    checkEqual(Adapters.dshDecompressCount - c0, 2, "T15 stamp change re-decompresses once")
    checkEqual(Adapters.dshParseCachePaths().count, 1, "T15 changed file entry replaced, not duplicated")

    // T15d: the second file joins the cache.
    _ = Adapters.cachedSessionFileRows(f2)
    checkEqual(Adapters.dshParseCachePaths().count, 2, "T15 both files cached")

    // T15f: appending a frame to a live session uses the incremental path —
    // one delta decompression feeds only the tail, and new usage rows appear
    // once their finish chunk resolves the model.
    let appendHandle = try! FileHandle(forWritingTo: f2)
    try! appendHandle.seekToEnd()
    let deltaText = "{\"type\":\"assistant/chunk\",\"seq\":99,\"time\":\"2026-08-15T10:01:00+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":500,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":100,\"time\":\"2026-08-15T10:01:05+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
    try! appendHandle.write(compressZstd(deltaText))
    try! appendHandle.close()
    let c1 = Adapters.dshDecompressCount
    let r4 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r4.rows.count, 2, "T15f appended usage row resolved incrementally")
    checkEqual(r4.rows.last?.input ?? 0, 500, "T15f appended tokens parsed")
    checkEqual(Adapters.dshDecompressCount - c1, 1, "T15f delta decompresses once")

    // T15g: a usage event whose finish chunk arrives in a LATER append stays
    // pending (no row) until the finish resolves it.
    let usageOnly = "{\"type\":\"assistant/chunk\",\"seq\":101,\"time\":\"2026-08-15T10:02:00+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":700,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let finishOnly = "{\"type\":\"assistant/chunk\",\"seq\":102,\"time\":\"2026-08-15T10:02:05+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
    let h1 = try! FileHandle(forWritingTo: f2)
    try! h1.seekToEnd()
    try! h1.write(compressZstd(usageOnly))
    try! h1.close()
    let r5 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r5.rows.count, 2, "T15g unresolved usage stays pending")
    let h2 = try! FileHandle(forWritingTo: f2)
    try! h2.seekToEnd()
    try! h2.write(compressZstd(finishOnly))
    try! h2.close()
    let r6 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r6.rows.count, 3, "T15g pending usage resolved by later finish")
    checkEqual(r6.rows.last?.input ?? 0, 700, "T15g late-resolved row carries its tokens")

    // T15i: once the file stops changing, one final full re-parse verifies
    // (emitting anything still pending with the fallback model), memoizes
    // the result, and drops the streaming state; later calls are pure
    // cache hits with no decompression.
    let c2 = Adapters.dshDecompressCount
    let r7 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r7.rows.count, 3, "T15i idle verify keeps the accumulated rows")
    checkEqual(Adapters.dshDecompressCount - c2, 1, "T15i idle verify re-parses once")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T15i verified file dropped its stream state")
    let c3 = Adapters.dshDecompressCount
    let r8 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r8.rows.count, 3, "T15i memoized after verify")
    checkEqual(Adapters.dshDecompressCount - c3, 0, "T15i verified result memoized, no re-decompress")

    // T15h: truncating a session resets the incremental state and re-parses
    // the (smaller) content from scratch.
    try! compressZstd(dshSessionLines(10)).write(to: f1)
    let r9 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r9.rows.count, 1, "T15h truncated file re-parsed")
    checkEqual(r9.rows.first?.input ?? 0, 10, "T15h truncated content parsed")

    // T15e: a deleted file's entry is pruned; disabling dsh clears all.
    try! fm.removeItem(at: s2)
    Adapters.pruneDshParseCache(activeFiles: [f1.path])
    checkEqual(Adapters.dshParseCachePaths(), Set([f1.path]), "T15 deleted file entry pruned")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T15 pruning keeps the active file's state")
    Adapters.dropClientCaches(["dsh"])
    checkEqual(Adapters.dshParseCachePaths().isEmpty, true, "T15 disabled dsh clears the parse cache")
    checkEqual(Adapters.dshIncrementalStateCount, 0, "T15 disabled dsh frees streaming states")
}

// MARK: - Managed visibility tests (review round Phase 5)

func runVisibilityTests() {
    // V1: duplicate hides/shows emit exactly one event each.
    do {
        var sent: [Bool] = []
        var v = ManagedVisibility { sent.append($0) }
        v.hide()
        v.hide()
        checkEqual(sent.count, 1, "V1 duplicate hides emit once")
        checkEqual(sent.last, false, "V1 hide emits false")
        v.show()
        v.show()
        checkEqual(sent.count, 2, "V1 duplicate shows emit once more")
        checkEqual(sent.last, true, "V1 show emits true")
        v.hide()
        checkEqual(sent.count, 3, "V1 alternating transitions all emit")
    }
    // V2: resync after page load re-sends the current state even when it
    // did not change (the pre-load push was lost).
    do {
        var sent: [Bool] = []
        var v = ManagedVisibility { sent.append($0) }
        v.show()
        checkEqual(sent.count, 1, "V2 initial show emitted")
        v.resync()
        checkEqual(sent.count, 2, "V2 resync re-sends current state")
        checkEqual(sent.last, true, "V2 resync sends visible state")
        v.resync()
        checkEqual(sent.count, 3, "V2 repeated resync also re-sends")
    }
    // V3: hide before any show (miniaturize during load), then resync.
    do {
        var sent: [Bool] = []
        var v = ManagedVisibility { sent.append($0) }
        v.hide()
        checkEqual(sent.count, 1, "V3 hide before show emits once")
        v.resync()
        checkEqual(sent.count, 2, "V3 resync sends hidden state")
        checkEqual(sent.last, false, "V3 resync sends false")
    }
    // V4: one event per transition, correct order.
    do {
        var sent: [Bool] = []
        var v = ManagedVisibility { sent.append($0) }
        v.show()
        v.hide()
        v.show()
        v.hide()
        checkEqual(sent.count, 4, "V4 one event per transition")
        checkEqual(sent, [true, false, true, false], "V4 event sequence")
    }
}

// MARK: - Idle teardown scheduler tests (round-4 Phase 6)

func runIdleTeardownTests() {
    // V5: repeated hides supersede to exactly one pending teardown; the
    // superseded scheduled fire is a no-op and the winner fires once.
    do {
        var scheduled: [(TimeInterval, () -> Void)] = []
        let scheduler = IdleTeardownScheduler { delay, fire in
            scheduled.append((delay, fire))
        }
        var fired = 0
        scheduler.schedule(delay: 600) { fired += 1 }
        scheduler.schedule(delay: 600) { fired += 1 }
        checkEqual(scheduled.count, 2, "V5 each hide schedules one work")
        check(scheduler.hasPending, "V5 one pending teardown after repeated hides")
        scheduled[0].1()
        checkEqual(fired, 0, "V5 superseded work does not fire")
        scheduled[1].1()
        checkEqual(fired, 1, "V5 current work fires once")
        check(!scheduler.hasPending, "V5 pending cleared after fire")
        scheduled[1].1()
        checkEqual(fired, 1, "V5 work never double-fires")
    }
    // V6: a show inside the delay cancels the pending teardown; the stale
    // scheduled fire is a no-op.
    do {
        var scheduled: [(TimeInterval, () -> Void)] = []
        let scheduler = IdleTeardownScheduler { delay, fire in
            scheduled.append((delay, fire))
        }
        var fired = 0
        scheduler.schedule(delay: 600) { fired += 1 }
        scheduler.cancel()
        check(!scheduler.hasPending, "V6 cancel clears the pending teardown")
        scheduled[0].1()
        checkEqual(fired, 0, "V6 cancelled teardown never fires")
    }
    // V7: a hide timeout fires the teardown exactly once, and the scheduler
    // is reusable afterwards.
    do {
        var scheduled: [(TimeInterval, () -> Void)] = []
        let scheduler = IdleTeardownScheduler { delay, fire in
            scheduled.append((delay, fire))
        }
        var fired = 0
        scheduler.schedule(delay: 600) { fired += 1 }
        scheduled[0].1()
        checkEqual(fired, 1, "V7 hide timeout fires once")
        scheduler.schedule(delay: 600) { fired += 1 }
        scheduled[1].1()
        checkEqual(fired, 2, "V7 scheduler reusable after fire")
    }
    // V8: 20 hide/show cycles never accumulate live work items, and every
    // stale scheduled fire stays a no-op.
    do {
        var scheduled: [(TimeInterval, () -> Void)] = []
        let scheduler = IdleTeardownScheduler { delay, fire in
            scheduled.append((delay, fire))
        }
        var fired = 0
        for _ in 0..<20 {
            scheduler.schedule(delay: 600) { fired += 1 }
            scheduler.cancel()
        }
        check(!scheduler.hasPending, "V8 no live items after 20 hide/show cycles")
        for (_, fire) in scheduled { fire() }
        checkEqual(fired, 0, "V8 stale fires stay no-ops")
        check(!scheduler.hasPending, "V8 still no live items")
    }
}

// MARK: - Single-instance activation buffering tests (review round Phase 6)

func runSingleInstanceTests() {
    let coordinator = SingleInstanceCoordinator.shared
    // S1: activations before the show callback is installed are buffered and
    // consumed exactly once on install (multiple requests coalesce).
    do {
        var fired = 0
        coordinator.handleRemoteActivation()
        coordinator.handleRemoteActivation()
        coordinator.handleRemoteActivation()
        checkEqual(fired, 0, "S1 buffered before callback installed")
        coordinator.installShowCallback { fired += 1 }
        checkEqual(fired, 1, "S1 pending activation consumed exactly once")
    }
    // S2: after install, each activation fires immediately.
    do {
        var fired = 0
        coordinator.installShowCallback { fired += 1 }
        coordinator.handleRemoteActivation()
        coordinator.handleRemoteActivation()
        checkEqual(fired, 2, "S2 post-install activations fire immediately")
    }
    // S3: unregister is idempotent and does not clear the callback.
    do {
        var fired = 0
        coordinator.installShowCallback { fired += 1 }
        coordinator.unregisterActivationObserver()
        coordinator.unregisterActivationObserver()
        coordinator.handleRemoteActivation()
        checkEqual(fired, 1, "S3 callback survives unregister")
    }
}

runChecks()
runCollectorStateTests()
runDshCacheTests()
runVisibilityTests()
runIdleTeardownTests()
runSingleInstanceTests()
print("fixture checks: \(checkCount) checks, \(failureCount) failures")
if failureCount > 0 { exit(1) }
