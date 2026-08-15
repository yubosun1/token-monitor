import Foundation
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

runChecks()
print("fixture checks: \(checkCount) checks, \(failureCount) failures")
if failureCount > 0 { exit(1) }

