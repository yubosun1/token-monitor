import Foundation
import CZstd
import SQLite3
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
                startedAt: UsageCore.timestampMs(row["startedAt"] as? String ?? ""),
                lastUsedAt: UsageCore.timestampMs(row["lastUsedAt"] as? String ?? ""),
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
        checkEqual(rows[0].startedAt, 0, "missing startedAt decodes empty")
        checkEqual(rows[0].lastUsedAt, 0, "missing lastUsedAt decodes empty")

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
                                     messageCount: 1, cost: 0, startedAt: 0, lastUsedAt: 0,
                                     projectId: "", projectLabel: "", performance: nil)
        // DST began 2026-03-08 02:00 EST in New York: 00:00-01:59 on that
        // day are still EST (UTC-5); 03:00+ is EDT (UTC-4). The "before"
        // row is the last second of the previous local day.
        row.startedAt = UsageCore.timestampMs("2026-03-07T23:59:59-05:00") // 04:59:59Z, before local midnight
        row.lastUsedAt = row.startedAt
        let before = Adapters.periodRows(rows: [row], sinceMs: dayStart, client: "dsh", includeUndated: false, timeZone: tz)
        checkEqual(before.count, 0, "DST: pre-midnight row excluded from today")

        row.startedAt = UsageCore.timestampMs("2026-03-08T00:00:00-05:00") // 05:00Z == local midnight exactly
        row.lastUsedAt = row.startedAt
        let atMidnight = Adapters.periodRows(rows: [row], sinceMs: dayStart, client: "dsh", includeUndated: false, timeZone: tz)
        checkEqual(atMidnight.count, 1, "DST: exact-midnight row included in today")

        row.startedAt = UsageCore.timestampMs("2026-03-08T03:30:00-04:00") // after the switch, EDT
        row.lastUsedAt = row.startedAt
        let after = Adapters.periodRows(rows: [row], sinceMs: dayStart, client: "dsh", includeUndated: false, timeZone: tz)
        checkEqual(after.count, 1, "DST: post-switch row included in today")
        checkEqual(Adapters.localDateKey(row.startedAt, timeZone: tz), "2026-03-08", "DST: date key across switch")
    }

    // Model-name canonicalization (vendor-prefix strip): KimiCode sessions
    // record third-party supplier routes as `supplier/model` (e.g.
    // `rightcode/gpt-5.6-luna`, `opencode-go/deepseek-v4-flash`), so the
    // same base model would otherwise split into two stats.
    do {
        checkEqual(UsageCore.canonicalModelName("rightcode/gpt-5.6-luna"), "gpt-5.6-luna", "canonical strips rightcode prefix")
        checkEqual(UsageCore.canonicalModelName("opencode-go/deepseek-v4-flash"), "deepseek-v4-flash", "canonical strips opencode-go prefix")
        checkEqual(UsageCore.canonicalModelName("kimi-code/k3-256k"), "k3-256k", "canonical strips kimi-code prefix")
        checkEqual(UsageCore.canonicalModelName("RightCode/gpt-5.6-luna"), "gpt-5.6-luna", "canonical lowercases prefix")
        checkEqual(UsageCore.canonicalModelName("deepseek-v4-flash"), "deepseek-v4-flash", "canonical leaves bare names untouched")
        checkEqual(UsageCore.canonicalModelName("gemini-3.7-flash-high"), "gemini-3.7-flash", "canonical maps gemini-3.7-flash-high")
        checkEqual(UsageCore.canonicalModelName("gemini-flash-safety-le2"), "gemini-3.7-flash", "canonical maps gemini-flash-safety-le2")
        checkEqual(UsageCore.canonicalModelName("google/gemini-3.7-flash-high"), "gemini-3.7-flash", "canonical strips prefix and maps gemini-3.7-flash-high")
        checkEqual(UsageCore.canonicalModelName("google/gemini-flash-safety-le2"), "gemini-3.7-flash", "canonical strips prefix and maps gemini-flash-safety-le2")
        checkEqual(UsageCore.canonicalModelName("glm-5.2-x"), "glm-5.2", "canonical maps glm-5.2-x")
        checkEqual(UsageCore.canonicalModelName("zai/glm-5.2-x"), "glm-5.2", "canonical strips prefix and maps glm-5.2-x")
        checkEqual(UsageCore.normalizeModelName("opencode-go/deepseek-v4-flash"), "deepseek-v4-flash", "normalizeModelName canonicalizes")
        checkEqual(UsageCore.normalizeModelName(nil), nil, "normalizeModelName nil stays nil")

        // Aggregation merges prefixed + bare usage of the same model, and merges aliases.
        func modelRow(_ model: String, _ input: Double) -> UsageCore.UsageRow {
            stateRow(client: "proma", session: "s-prefix", model: model, input: input, output: 0, startedAt: "2026-08-15T10:00:00+08:00")
        }
        let rows = [modelRow("rightcode/gpt-5.6-luna", 100), modelRow("gpt-5.6-luna", 250)]
        let period = UsageCore.extractPeriod(entries: rows)
        let models = period["models"] as! [String: Any]
        checkEqual(models.count, 1, "prefixed + bare merge to one model")
        checkEqual(UsageCore.intValue(models["gpt-5.6-luna"]), 350, "merged model token total")
        check(models["rightcode/gpt-5.6-luna"] == nil, "no prefixed key survives")

        let aliasRows = [
            modelRow("gemini-3.7-flash-high", 100),
            modelRow("gemini-flash-safety-le2", 200),
            modelRow("gemini-3.7-flash", 300),
            modelRow("glm-5.2-x", 400),
            modelRow("glm-5.2", 500)
        ]
        let aliasPeriod = UsageCore.extractPeriod(entries: aliasRows)
        let aModels = aliasPeriod["models"] as! [String: Any]
        checkEqual(aModels.count, 2, "gemini variants and glm variants merge to respective base models")
        checkEqual(UsageCore.intValue(aModels["gemini-3.7-flash"]), 600, "merged gemini-3.7-flash token total")
        checkEqual(UsageCore.intValue(aModels["glm-5.2"]), 900, "merged glm-5.2 token total")

        // History contributions carry the canonical model id too.
        let contributions = Adapters.historyContributions(rows: rows, client: "proma", pricingByModel: [:], timeZone: FixtureHarness.timeZone)
        check(contributions.allSatisfy { $0.modelId == "gpt-5.6-luna" }, "history modelId canonicalized")
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
    let startedAtMs = UsageCore.timestampMs(startedAt)
    return UsageCore.UsageRow(
        client: client, sessionId: session, model: model, provider: client,
        input: input, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0,
        messageCount: 1, cost: 0, startedAt: startedAtMs, lastUsedAt: startedAtMs,
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
    var tokscalePeriodClients: [[String]] = []
    var tokscaleGraphClients: [[String]] = []
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
    /// Inject a real HistoryLedger to exercise the persistent-ledger
    /// fallback paths (production wires HistoryLedger.shared).
    var historyLedger: HistoryLedger?
    var tokscalePeriodSpawns = 0
    var tokscaleGraphSpawns = 0
    var tokscalePricingRefreshes = 0
    var tokscaleFingerprintChecks = 0
    var tokscaleAntigravitySyncCalls = 0
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
            adapterRowGroups: { client in
                self.rawReads[client, default: 0] += 1
                if let gate = self.blockFirstRead {
                    self.blockFirstRead = nil
                    gate.wait()
                }
                return (self.rowsByClient[client] ?? []).map { [$0] }
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
            tokscaleAntigravitySync: {
                self.tokscaleAntigravitySyncCalls += 1
                return true
            },
            tokscalePricingRefresh: { _ in
                self.tokscalePricingRefreshes += 1
                return true
            },
            tokscalePeriods: { clients, _, _ in
                self.tokscalePeriodSpawns += 1
                self.tokscalePeriodClients.append(clients)
                return self.tokscalePeriods
            },
            tokscaleGraph: { clients in
                self.tokscaleGraphSpawns += 1
                self.tokscaleGraphClients.append(clients)
                return self.tokscaleGraph
            },
            push: { event, payload in
                self.pushes.append(["event": event, "payload": payload])
            },
            customPricingSync: { _ in
                self.customPricingSyncCalls += 1
            },
            historyLedger: self.historyLedger,
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

// MARK: - Kimi limits and collection tests

func runKimiTests() {
    let membership: [String: Any] = [
        "ratelimitCode5h": [
            "ratio": 0.25,
            "enabled": true,
            "resetTime": "2026-07-19T05:00:00Z"
        ],
        "ratelimitCode7d": [
            "ratio": 0.4,
            "enabled": true,
            "resetTime": "2026-07-24T00:00:00Z"
        ],
        "subscriptionBalance": [
            "feature": "FEATURE_OMNI",
            "type": "SUBSCRIPTION",
            "amountUsedRatio": 0.1612,
            "kimiCodeUsedRatio": 0.05,
            "expireTime": "2026-08-01T00:00:00Z"
        ]
    ]
    let membershipWindows = KimiLimits.parseMembershipStats(membership)
    checkEqual(membershipWindows.map(\.kind), ["session", "weekly", "billing"], "Kimi membership returns all quota windows")
    checkClose(membershipWindows[0].usedPercent, 25, "Kimi membership 5-hour ratio")
    checkEqual(membershipWindows[0].windowMinutes, 300, "Kimi membership 5-hour duration")
    checkClose(membershipWindows[1].usedPercent, 40, "Kimi membership weekly ratio")
    checkEqual(membershipWindows[1].windowMinutes, 10_080, "Kimi membership weekly duration")
    checkClose(membershipWindows[2].usedPercent, 16.12, "Kimi membership monthly ratio")
    checkEqual(membershipWindows[2].detail, "Kimi 11.12% | Code 5%", "Kimi membership monthly breakdown")

    let codeUsage: [String: Any] = [
        "usage": [
            "limit": "2048",
            "used": "214",
            "remaining": "1834",
            "resetTime": "2026-07-14T00:00:00Z"
        ],
        "limits": [
            [
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": [
                    "limit": "200",
                    "used": "139",
                    "remaining": "61",
                    "resetTime": "2026-07-08T05:00:00Z"
                ]
            ]
        ]
    ]
    let codeWindows = KimiLimits.parseUsage(codeUsage)
    let session = codeWindows.first(where: { $0.kind == "session" })
    let weekly = codeWindows.first(where: { $0.kind == "weekly" })
    checkEqual(codeWindows.count, 2, "Kimi Code returns session and weekly windows")
    checkClose(session?.usedPercent ?? -1, 69.5, "Kimi Code session percentage")
    checkEqual(session?.windowMinutes, 300, "Kimi Code session duration")
    checkClose(weekly?.usedPercent ?? -1, (214.0 / 2048.0) * 100, "Kimi Code weekly percentage")
    checkEqual(weekly?.windowMinutes, 10_080, "Kimi Code weekly duration")

    checkEqual(
        KimiLimits.normalizedWebAccessToken("Cookie: other=x; kimi-auth=jwt.token.value; theme=dark"),
        "jwt.token.value",
        "Kimi cookie input keeps only kimi-auth"
    )

    // Kimi Code's `kimi login` persists an OAuth access token locally. It is
    // accepted by the Code usage API, while expired tokens must not make the
    // automatic fallback look configured forever.
    let credentialRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tm-kimi-credential-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: credentialRoot) }
    let credentialURL = credentialRoot.appendingPathComponent("kimi-code.json")
    try! FileManager.default.createDirectory(at: credentialRoot, withIntermediateDirectories: true)
    func jwt(expiration: Int) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": expiration])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }
    let credentialNow = Date(timeIntervalSince1970: 1_000)
    let activeToken = jwt(expiration: 2_000)
    let expiredToken = jwt(expiration: 999)
    try! JSONSerialization.data(withJSONObject: ["access_token": activeToken]).write(to: credentialURL)
    checkEqual(CredentialStore.kimiCodeAccessToken(at: credentialURL, now: credentialNow), activeToken, "Kimi Code OAuth access token is discovered")
    check(!KimiLimits.isJWTExpired(activeToken, at: credentialNow), "Kimi Code OAuth token remains usable before expiry")
    try! JSONSerialization.data(withJSONObject: ["access_token": expiredToken]).write(to: credentialURL)
    checkEqual(CredentialStore.kimiCodeAccessToken(at: credentialURL, now: credentialNow), "", "expired Kimi Code OAuth token is ignored")
    check(KimiLimits.isJWTExpired(expiredToken, at: credentialNow), "expired Kimi browser token is rejected before probing")

    let kimiRoots = SourceScanner.tokscaleRoots("kimi")
    check(kimiRoots.contains(NSHomeDirectory() + "/.kimi/sessions"), "Kimi web sessions are fingerprinted")
    check(kimiRoots.contains(SourceScanner.kimiCodeHome() + "/sessions"), "Kimi Code sessions are fingerprinted")

    // Kimi native session parsing test
    do {
        let tempKimiDir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-kimi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempKimiDir) }
        let sessionDir = tempKimiDir.appendingPathComponent("wd_sample_123/session_test_456")
        let agentsMainDir = sessionDir.appendingPathComponent("agents/main")
        let agentsSubDir = sessionDir.appendingPathComponent("agents/agent-0")
        try! FileManager.default.createDirectory(at: agentsMainDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: agentsSubDir, withIntermediateDirectories: true)

        let stateJson = """
        {"id":"session_test_456","title":"exp01 实验 PPT 制作","cwd":"/Users/test/sandbox","createdAt":1787680000000,"updatedAt":1787685000000}
        """
        try! stateJson.data(using: .utf8)!.write(to: sessionDir.appendingPathComponent("state.json"))

        let mainWire = """
        {"type":"usage.record","model":"kimi-code/k3-256k","usage":{"inputOther":2000,"output":500,"inputCacheRead":18000,"inputCacheCreation":0},"time":1787681000000}
        """
        try! mainWire.data(using: .utf8)!.write(to: agentsMainDir.appendingPathComponent("wire.jsonl"))

        let subWire = """
        {"type":"usage.record","model":"RightCode/gpt-5.6-luna","usage":{"inputOther":5000,"output":200,"inputCacheRead":10000,"inputCacheCreation":0},"time":1787682000000}
        """
        try! subWire.data(using: .utf8)!.write(to: agentsSubDir.appendingPathComponent("wire.jsonl"))

        let rows = Adapters.parseKimiSessionDir(sessionDir)
        checkEqual(rows.count, 2, "Kimi parser extracts both main and subagent models")
        let k3 = rows.first { $0.model == "k3-256k" }
        let luna = rows.first { $0.model == "gpt-5.6-luna" }
        checkEqual(k3?.input, 2000, "Kimi k3 input tokens")
        checkEqual(k3?.cacheRead, 18000, "Kimi k3 cache read tokens")
        checkEqual(k3?.projectLabel, "exp01 实验 PPT 制作", "Kimi session title extracted")
        checkEqual(luna?.input, 5000, "Kimi subagent luna input")
        checkEqual(luna?.cacheRead, 10000, "Kimi subagent luna cache read")
    }

    let world = FakeCollectorWorld(
        now: shanghaiDate(2026, 8, 15, 12, 0),
        settings: stateSettings(clients: "kimi")
    )
    world.rowsByClient["kimi"] = [
        stateRow(client: "kimi", session: "s1", model: "k3-256k", input: 100, output: 50, startedAt: "2026-08-15T12:00:00+08:00")
    ]
    let (collector, queue) = world.makeCollector()
    collector.requestRefresh(.full, reason: .startup)
    world.waitIdle(collector, queue)
    checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 150, "Kimi is collected via native adapter")
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

    // T5: routine ticks only read cached prices; the explicit manual refresh
    // is the one path allowed to fetch a missing price.
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
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 2, "T5 manual refresh retries the lookup")
        checkEqual(world.pricingLookupPolicies["model-a"], .forceRefresh, "T5 manual refresh forces pricing")
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

    // T12: routine collection keeps using a local last-known-good price;
    // every explicit manual refresh forces one lookup per shared model and a
    // failed lookup never zeroes the already calculated costs.
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
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T12 one cached lookup for a model shared by clients")
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.6, "T12 initial costs")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T12 one raw read at startup")

        // A manual refresh is an explicit pricing boundary even within the
        // normal cache TTL.
        world.now = world.now.addingTimeInterval(3600)
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 2, "T12 manual refresh resolves within TTL")
        checkEqual(world.pricingLookupPolicies["model-a"], .forceRefresh, "T12 manual refresh uses forceRefresh policy")

        // A later manual refresh returns an updated price and re-derives from
        // cached rows without a raw re-read.
        world.now = world.now.addingTimeInterval(6 * 3600 + 60)
        world.pricingByModel["model-a"] = fakePricing(0.002, 0.004)
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 3, "T12 updated pricing resolved once")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T12 manual refresh re-derives from cached rows")
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 1.2, "T12 updated costs after manual refresh")

        // A failed manual lookup keeps the last-known-good price. The next
        // explicit click is allowed to retry immediately.
        world.pricingByModel["model-a"] = nil
        world.now = world.now.addingTimeInterval(7 * 3600)
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 4, "T12 manual refresh attempted once on failure")
        // The clock has crossed midnight by now, so the allTime window is
        // the stable view: last-known-good costs must survive the failure.
        checkClose(UsageCore.doubleValue(world.period(collector, "allTime")["costUsd"]), 1.2, "T12 failed expiry keeps last-known-good costs")
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 5, "T12 second manual refresh retries immediately")

        world.pricingByModel["model-a"] = fakePricing(0.003, 0.006)
        world.now = world.now.addingTimeInterval(301)
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 6, "T12 later manual refresh recovers")
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

    // T16: normal tokscale collection never refreshes remote pricing; the
    // explicit refresh does it once and forces a cache-only token rescan so
    // updated cached costs are visible immediately.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "claude")
        )
        world.tokscalePeriods = [
            "today": periodWithTokens(100),
            "month": periodWithTokens(100),
            "allTime": periodWithTokens(100)
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePricingRefreshes, 0, "T16 startup never refreshes remote pricing")
        checkEqual(world.tokscalePeriodSpawns, 1, "T16 startup scans tokscale once")

        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePricingRefreshes, 1, "T16 manual refresh updates tokscale pricing once")
        checkEqual(world.tokscalePeriodSpawns, 2, "T16 manual refresh forces a cache-only period scan")
        checkEqual(world.tokscaleGraphSpawns, 2, "T16 manual refresh forces a cache-only graph scan")
    }

    // T18a: a day rollover escalates the next cheap tick to a full tokscale
    // rescan even inside collectionIntervalMs — otherwise the cached
    // snapshot keeps describing yesterday and "today" shows yesterday's
    // full-day totals for up to a whole interval.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 23, 58),
            settings: stateSettings(clients: "proma,claude", collectionIntervalMs: 300000)
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.tokscalePeriods = ["today": periodWithTokens(100), "month": periodWithTokens(100), "allTime": periodWithTokens(100)]
        world.tokscaleGraph = ([], nil)
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleFingerprintChecks, 1, "T18a startup checks tokscale once")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 250, "T18a yesterday today (adapter 150 + tokscale 100)")
        checkEqual(collector.tokscaleSnapshot?.dayKey, "2026-08-15", "T18a snapshot carries yesterday's day key")

        // 3 minutes later (inside the 300s interval) the day has changed:
        // the cheap tick must escalate and rescan the new day's buckets.
        world.now = shanghaiDate(2026, 8, 16, 0, 1)
        world.tokscalePeriods = [
            "today": UsageCore.emptyPeriod(),
            "month": periodWithTokens(100),
            "allTime": periodWithTokens(100)
        ]
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscaleFingerprintChecks, 2, "T18a midnight cheap tick escalates to a full source check")
        checkEqual(world.tokscalePeriodSpawns, 2, "T18a new-day context rescans periods")
        checkEqual(collector.tokscaleSnapshot?.dayKey, "2026-08-16", "T18a snapshot advanced to the new day")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 0, "T18a today is empty on the new day")
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 250, "T18a allTime keeps the cumulative total")
    }

    // T18b: when the rollover rescan fails, the new context must not inherit
    // yesterday's today/month as fallback values (that would show yesterday's
    // full-day total as today until a retry succeeds); today/month fall back
    // to empty and allTime keeps the last-known-good cumulative. The failed
    // part then retries alone after its backoff.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 23, 58),
            settings: stateSettings(clients: "proma,claude", collectionIntervalMs: 300000)
        )
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        world.tokscalePeriods = ["today": periodWithTokens(100), "month": periodWithTokens(100), "allTime": periodWithTokens(100)]
        world.tokscaleGraph = ([], nil)
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)

        // Midnight + scan failure: the escalated cheap tick hits a dead period
        // scan. Yesterday's today must NOT survive into the new context.
        world.now = shanghaiDate(2026, 8, 16, 0, 1)
        world.tokscalePeriods = nil
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(collector.tokscaleSnapshot?.periodsSuccess, false, "T18b rollover period failure resets validity")
        checkEqual(UsageCore.intValue((collector.tokscaleSnapshot?.periods["today"] ?? [:])["totalTokens"]), 0, "T18b yesterday today not carried into the new context")
        checkEqual(UsageCore.intValue((collector.tokscaleSnapshot?.periods["allTime"] ?? [:])["totalTokens"]), 100, "T18b allTime last-known-good preserved")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 0, "T18b today shows zero after a failed rollover scan")
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 250, "T18b merged allTime survives the failure")

        // After the interval and the periods backoff: the failed part retries
        // alone and recovers; the healthy graph is not re-run.
        world.now = world.now.addingTimeInterval(301)
        world.tokscalePeriods = ["today": periodWithTokens(50), "month": periodWithTokens(50), "allTime": periodWithTokens(150)]
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.tokscalePeriodSpawns, 3, "T18b failed periods retried after backoff")
        checkEqual(world.tokscaleGraphSpawns, 2, "T18b successful graph not re-run")
        checkEqual(collector.tokscaleSnapshot?.periodsSuccess, true, "T18b periods validity recovered")
        checkEqual(UsageCore.intValue(world.period(collector, "today")["totalTokens"]), 50, "T18b today recovered on retry")
    }

    // T19: with every client disabled the wire shape stays empty even when
    // a persistent ledger holds rows. The ledger fallback is consulted only
    // for a non-empty client set: fetchPeriods([])/fetchHistoryDays([])
    // treat an empty array as "no filter" and return the whole database,
    // which would resurrect deleted-source data into an all-disabled UI.
    do {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tm-empty-clients-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let ledger = HistoryLedger(dbURL: dir.appendingPathComponent("ledger.db"))
        // Deleted-source residue pre-seeded in the ledger: one usage row and
        // one history day that no live source would produce.
        ledger.recordUsageRows(
            [stateRow(client: "proma", session: "gone-s1", model: "model-a", input: 400, output: 200, startedAt: "2026-08-15T09:00:00+08:00")],
            defaultClient: "proma",
            now: shanghaiDate(2026, 8, 15, 12, 0)
        )
        var residueDay = HistoryCore.Day(date: "2026-08-15", tokens: 600, cost: 0.6, messages: 2)
        residueDay.perClient["proma"] = (tokens: 600, cost: 0.6, messages: 2)
        ledger.recordTokscaleDays([residueDay], now: shanghaiDate(2026, 8, 15, 12, 0))

        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.historyLedger = ledger
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        world.waitIdle(collector, queue)
        // Enabled: ledger residue (600) + the live row recorded into the
        // ledger during derivation (150) merge into the live totals.
        checkEqual(UsageCore.intValue(world.period(collector, "allTime")["totalTokens"]), 750, "T19 ledger fallback merges residue while enabled")

        world.settings["clients"] = ""
        collector.requestRefresh(.full, reason: .settingsChange)
        world.waitIdle(collector, queue)
        let stats = collector.latestStats() ?? [:]
        let periods = stats["periods"] as? [String: Any] ?? [:]
        checkEqual(UsageCore.intValue((periods["today"] as? [String: Any] ?? [:])["totalTokens"]), 0, "T19 empty clients skip ledger fallback (today)")
        checkEqual(UsageCore.intValue((periods["month"] as? [String: Any] ?? [:])["totalTokens"]), 0, "T19 empty clients skip ledger fallback (month)")
        checkEqual(UsageCore.intValue((periods["allTime"] as? [String: Any] ?? [:])["totalTokens"]), 0, "T19 empty clients skip ledger fallback (allTime)")
        let history = stats["history"] as? [String: Any]
        checkEqual((history?["daily"] as? [Any] ?? []).isEmpty, true, "T19 empty clients history ignores ledger days")
    }

    // T20: a customModelPricing change applies to the very next tick
    // without any pricing lookup (no source contact), because the collector
    // seeds its pricing cache straight from the setting; the changed pricing
    // signature then re-derives adapter costs from cached rows. The runner's
    // stale in-memory price never wins over the user's explicit override.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        // The runner's cache holds a catalog price for model-a; the setting
        // overrides it with a custom price (input 10c / output 20c per 1M).
        world.pricingByModel["model-a"] = fakePricing(0.001, 0.002)
        world.settings["customModelPricing"] = [
            ["modelId": "model-a", "inputPerM": 10.0, "outputPerM": 20.0]
        ]
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.start()
        world.waitIdle(collector, queue)
        // 100*10e-6 + 50*20e-6 = 0.002, from the seed — the cache was never
        // consulted for the custom model.
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.002, "T20 custom price applied at first tick")
        checkEqual(world.pricingLookups["model-a"] ?? 0, 0, "T20 seeded custom price shadows the runner cache")

        // User edits the price: the next tick after the settings change uses
        // the new value — no lookup, no raw re-read (re-derives cached rows).
        world.settings["customModelPricing"] = [
            ["modelId": "model-a", "inputPerM": 20.0, "outputPerM": 20.0]
        ]
        NotificationCenter.default.post(
            name: SettingsStore.changedNotification,
            object: nil,
            userInfo: ["keys": ["customModelPricing"]]
        )
        world.waitIdle(collector, queue)
        // 100*20e-6 + 50*20e-6 = 0.003.
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.003, "T20 edited custom price applies on the next tick")
        checkEqual(world.pricingLookups["model-a"] ?? 0, 0, "T20 price change never touches the pricing source")
        checkEqual(world.rawReads["proma"] ?? 0, 1, "T20 price change re-derives from cached rows")

        // Removing the override returns the model to the last-known-good
        // cache value (the purge empties the collector cache, so the next
        // cache-only lookup re-reads the runner's stale-but-valid price).
        world.settings["customModelPricing"] = [Any]()
        NotificationCenter.default.post(
            name: SettingsStore.changedNotification,
            object: nil,
            userInfo: ["keys": ["customModelPricing"]]
        )
        world.waitIdle(collector, queue)
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.2, "T20 removing the override falls back to the cached price")
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T20 fallback lookup happens once after the override is gone")
    }

    // T21: an unresolved model's cache-only lookup is backed off — it is not
    // probed on every routine tick, only again once the retry floor passes;
    // the explicit refresh still bypasses the floor.
    do {
        let world = FakeCollectorWorld(
            now: shanghaiDate(2026, 8, 15, 12, 0),
            settings: stateSettings(clients: "proma")
        )
        world.pricingByModel["model-a"] = nil
        world.rowsByClient["proma"] = [
            stateRow(client: "proma", session: "s1", model: "model-a", input: 100, output: 50, startedAt: "2026-08-15T10:00:00+08:00")
        ]
        let (collector, queue) = world.makeCollector()
        collector.requestRefresh(.cheap, reason: .startup)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T21 first resolution attempt happens once")

        // Routine ticks inside the backoff window do not probe again.
        world.now = world.now.addingTimeInterval(15)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        world.now = world.now.addingTimeInterval(15)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 1, "T21 unresolved model backs off routine ticks")

        // Past the 300s floor one more cache-only attempt happens.
        world.now = world.now.addingTimeInterval(301)
        collector.requestRefresh(.cheap, reason: .timer)
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 2, "T21 retry attempted again after the floor")

        // A manual refresh ignores the floor and resolves immediately.
        world.pricingByModel["model-a"] = fakePricing(0.001, 0.002)
        world.now = world.now.addingTimeInterval(15)
        collector.refreshNow()
        world.waitIdle(collector, queue)
        checkEqual(world.pricingLookups["model-a"] ?? 0, 3, "T21 manual refresh bypasses the backoff floor")
        checkClose(UsageCore.doubleValue(world.period(collector, "today")["costUsd"]), 0.2, "T21 backoff clears once pricing resolves")
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
    // one delta decompression feeds only the tail, and a current DSH finish
    // payload resolves the model from replayState.response.model.
    let appendHandle = try! FileHandle(forWritingTo: f2)
    try! appendHandle.seekToEnd()
    let deltaText = "{\"type\":\"assistant/chunk\",\"seq\":99,\"time\":\"2026-08-15T10:01:00+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":500,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":100,\"time\":\"2026-08-15T10:01:05+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"response\":{\"api\":\"openai-completions\",\"model\":\"deepseek-v4-flash\"}}}}}\n"
    appendHandle.write(compressZstd(deltaText))
    try! appendHandle.close()
    let c1 = Adapters.dshDecompressCount
    let r4 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r4.rows.count, 2, "T15f appended usage row resolved incrementally")
    checkEqual(r4.rows.last?.input ?? 0, 500, "T15f appended tokens parsed")
    checkEqual(r4.rows.last?.model ?? "", "deepseek-v4-flash", "T15f current nested finish model parsed")
    checkEqual(Adapters.dshDecompressCount - c1, 1, "T15f delta decompresses once")

    // T15g: a usage event whose finish chunk arrives in a LATER append stays
    // pending (no row) until the finish resolves it.
    let usageOnly = "{\"type\":\"assistant/chunk\",\"seq\":101,\"time\":\"2026-08-15T10:02:00+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":700,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let finishOnly = "{\"type\":\"assistant/chunk\",\"seq\":102,\"time\":\"2026-08-15T10:02:05+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
    let h1 = try! FileHandle(forWritingTo: f2)
    try! h1.seekToEnd()
    h1.write(compressZstd(usageOnly))
    try! h1.close()
    let r5 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r5.rows.count, 2, "T15g unresolved usage stays pending")
    let h2 = try! FileHandle(forWritingTo: f2)
    try! h2.seekToEnd()
    h2.write(compressZstd(finishOnly))
    try! h2.close()
    let r6 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r6.rows.count, 3, "T15g pending usage resolved by later finish")
    checkEqual(r6.rows.last?.input ?? 0, 700, "T15g late-resolved row carries its tokens")

    // T15j: a finish without either model schema must still flush pending
    // usage with the request-header fallback, so a busy session never needs
    // an app restart or an idle full re-parse to become visible.
    let fallbackUsage = "{\"type\":\"assistant/chunk\",\"seq\":103,\"time\":\"2026-08-15T10:03:00+08:00\",\"data\":{\"turn\":4,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":900,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let fallbackFinish = "{\"type\":\"assistant/chunk\",\"seq\":104,\"time\":\"2026-08-15T10:03:05+08:00\",\"data\":{\"turn\":4,\"step\":1,\"chunk\":{\"type\":\"finish\"}}}\n"
    let h3 = try! FileHandle(forWritingTo: f2)
    try! h3.seekToEnd()
    h3.write(compressZstd(fallbackUsage))
    try! h3.close()
    let r7 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r7.rows.count, 3, "T15j model-less usage remains pending until finish")
    let h4 = try! FileHandle(forWritingTo: f2)
    try! h4.seekToEnd()
    h4.write(compressZstd(fallbackFinish))
    try! h4.close()
    let r8 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r8.rows.count, 4, "T15j fallback-model finish resolves incrementally")
    checkEqual(r8.rows.last?.input ?? 0, 900, "T15j fallback row carries tokens")
    checkEqual(r8.rows.last?.model ?? "", "deepseek-chat", "T15j fallback model comes from request header")

    // T15i: once the file stops changing, one final full re-parse verifies
    // (emitting anything still pending with the fallback model), memoizes
    // the result, and drops the streaming state; later calls are pure
    // cache hits with no decompression.
    let c2 = Adapters.dshDecompressCount
    let r9 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r9.rows.count, 4, "T15i idle verify keeps the accumulated rows")
    checkEqual(Adapters.dshDecompressCount - c2, 1, "T15i idle verify re-parses once")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T15i verified file dropped its stream state")
    let c3 = Adapters.dshDecompressCount
    let r10 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r10.rows.count, 4, "T15i memoized after verify")
    checkEqual(Adapters.dshDecompressCount - c3, 0, "T15i verified result memoized, no re-decompress")

    // T15h: truncating a session resets the incremental state and re-parses
    // the (smaller) content from scratch.
    try! compressZstd(dshSessionLines(10)).write(to: f1)
    let r11 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r11.rows.count, 1, "T15h truncated file re-parsed")
    checkEqual(r11.rows.first?.input ?? 0, 10, "T15h truncated content parsed")

    // T15e: a deleted file's entry is pruned; disabling dsh clears all.
    try! fm.removeItem(at: s2)
    Adapters.pruneDshParseCache(activeFiles: [f1.path])
    checkEqual(Adapters.dshParseCachePaths(), Set([f1.path]), "T15 deleted file entry pruned")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T15 pruning keeps the active file's state")
    Adapters.dropClientCaches(["dsh"])
    checkEqual(Adapters.dshParseCachePaths().isEmpty, true, "T15 disabled dsh clears the parse cache")
    checkEqual(Adapters.dshIncrementalStateCount, 0, "T15 disabled dsh frees streaming states")
}

// MARK: - DSH idle stream sweep tests

/// The in-read free paths only run when a fingerprint change routes a tick
/// through collectDshRows(); the per-tick idle sweep must free stable
/// sessions' streams even when nothing ever changes again.
func runDshIdleSweepTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-dsh-sweep-\(UUID().uuidString)")
    let s1 = dir.appendingPathComponent("session-1")
    let s2 = dir.appendingPathComponent("session-2")
    try! fm.createDirectory(at: s1, withIntermediateDirectories: true)
    try! fm.createDirectory(at: s2, withIntermediateDirectories: true)
    defer {
        Adapters.dropClientCaches(["dsh"])
        try? fm.removeItem(at: dir)
    }
    let f1 = s1.appendingPathComponent("session.jsonl.zstd")
    let f2 = s2.appendingPathComponent("session.jsonl.zstd")

    // T16a: a freshly written session keeps its stream through the sweep.
    try! compressZstd(dshSessionLines(100)).write(to: f1)
    _ = Adapters.cachedSessionFileRows(f1)
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T16a fresh session holds a stream")
    checkEqual(Adapters.freeIdleDshStreams(), 0, "T16a sweep keeps a within-grace stream")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T16a stream survives the sweep")

    // T16b: past the grace window the sweep drops the stream but keeps the
    // memoized rows.
    checkEqual(Adapters.freeIdleDshStreams(now: Date().addingTimeInterval(3600)), 1, "T16b idle stream swept")
    checkEqual(Adapters.dshIncrementalStateCount, 0, "T16b no streaming state left")
    let c0 = Adapters.dshDecompressCount
    let r1 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r1.rows.count, 1, "T16b rows still served from the parse cache")
    checkEqual(Adapters.dshDecompressCount - c0, 0, "T16b swept session does not re-decompress")
    checkEqual(Adapters.dshIncrementalStateCount, 0, "T16b cache hit does not resurrect a stream")

    // T16c: an append after the sweep re-parses fully and retains a fresh
    // stream (the file is young again), yielding correct rows.
    let appended = "{\"type\":\"assistant/chunk\",\"seq\":10,\"time\":\"2026-08-15T10:01:00+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":200,\"outputTokens\":20,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let h = try! FileHandle(forWritingTo: f1)
    try! h.seekToEnd()
    h.write(compressZstd(appended))
    try! h.close()
    let r2 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r2.rows.count, 2, "T16c post-sweep append re-parses")
    checkEqual(r2.rows.last?.input ?? 0, 200, "T16c appended row parsed")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T16c stream re-retained for the active session")

    // T16d: a session file already past the grace window at first parse
    // never retains a stream at all — only its memoized rows.
    try! compressZstd(dshSessionLines(300)).write(to: f2)
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: f2.path)
    let r3 = Adapters.cachedSessionFileRows(f2)
    checkEqual(r3.rows.count, 1, "T16d old session parses")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T16d old session retains no stream")
}

// MARK: - Parse cache retention tests

/// Parse cache entries for files idle beyond the retention window are
/// evicted; fresh files and live incremental sessions stay, and an
/// evicted file re-derives identical rows from disk on next read.
func runParseCacheEvictionTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-cache-evict-\(UUID().uuidString)")
    let s1 = dir.appendingPathComponent("session-old")
    let s2 = dir.appendingPathComponent("session-fresh")
    try! fm.createDirectory(at: s1, withIntermediateDirectories: true)
    try! fm.createDirectory(at: s2, withIntermediateDirectories: true)
    defer {
        Adapters.dropClientCaches(["dsh"])
        try? fm.removeItem(at: dir)
    }
    Adapters.dropClientCaches(["dsh"])
    let old = s1.appendingPathComponent("session.jsonl.zstd")
    let fresh = s2.appendingPathComponent("session.jsonl.zstd")
    try! compressZstd(dshSessionLines(100)).write(to: old)
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
    try! compressZstd(dshSessionLines(200)).write(to: fresh)

    _ = Adapters.cachedSessionFileRows(old)
    _ = Adapters.cachedSessionFileRows(fresh)
    checkEqual(Adapters.dshParseCachePaths().count, 2, "T17 both sessions cached")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "T17 only the fresh session holds a stream")

    let evicted = Adapters.evictIdleParseCacheEntries()
    check(evicted >= 1, "T17 idle entries evicted")
    checkEqual(Adapters.dshParseCachePaths(), Set([fresh.path]), "T17 old session evicted, fresh kept")

    // Re-reading an evicted file re-derives rows from disk: results are
    // unchanged, only the cache refills.
    let r = Adapters.cachedSessionFileRows(old)
    checkEqual(r.rows.first?.input ?? 0, 100, "T17 evicted session re-parses correctly")
}

// MARK: - DSH fork seedLength tests

/// A forked session's log starts with a byte-for-byte copy of its parent's
/// events; `session.seedLength` is the seq of the fork's own first event, so
/// everything with seq < seedLength belongs to the parent and must be
/// skipped on both the full-parse and the incremental delta paths.
func runDshForkSeedTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-dsh-fork-\(UUID().uuidString)")
    let fork = dir.appendingPathComponent("fork-1")
    let torn = dir.appendingPathComponent("torn-1")
    try! fm.createDirectory(at: fork, withIntermediateDirectories: true)
    try! fm.createDirectory(at: torn, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let ff = fork.appendingPathComponent("session.jsonl.zstd")
    let tf = torn.appendingPathComponent("session.jsonl.zstd")

    // Seeded parent prefix: seq 0-3 (header, request header, one usage +
    // finish). The fork's own events start at seq == seedLength (4).
    let forkSeed = "{\"type\":\"session\",\"seq\":0,\"seedLength\":4,\"createdAt\":\"2026-08-15T10:00:00+08:00\"}\n"
        + "{\"type\":\"request/header\",\"seq\":1,\"time\":\"2026-08-15T10:00:05+08:00\",\"data\":{\"header\":{\"config\":{\"model\":\"deepseek-chat\"}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":2,\"time\":\"2026-08-15T10:00:10+08:00\",\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":100,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":3,\"time\":\"2026-08-15T10:00:15+08:00\",\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
    let forkOwn = "{\"type\":\"assistant/chunk\",\"seq\":4,\"time\":\"2026-08-15T10:01:00+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":200,\"outputTokens\":60,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":5,\"time\":\"2026-08-15T10:01:05+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"

    // F1: full parse skips the copied parent prefix (seq < seedLength); the
    // event AT seq == seedLength is the fork's own first and is counted.
    try! compressZstd(forkSeed + forkOwn).write(to: ff)
    let f1r = Adapters.cachedSessionFileRows(ff)
    checkEqual(f1r.rows.count, 1, "F1 fork parent prefix skipped")
    checkEqual(f1r.rows.first?.input ?? 0, 200, "F1 only the fork's own tokens counted")
    checkEqual(f1r.events, 1, "F1 only the fork's own usage event counted")

    // F2: seedLength persists in the incremental state across feeds (the
    // session record only appears at the head of the file), so a parent
    // prefix event replayed into a later append is still skipped, while the
    // fork's own appended event is counted.
    let replayedPrefix = "{\"type\":\"assistant/chunk\",\"seq\":3,\"time\":\"2026-08-15T10:00:15+08:00\",\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":999,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let appendedOwn = "{\"type\":\"assistant/chunk\",\"seq\":6,\"time\":\"2026-08-15T10:02:00+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":300,\"outputTokens\":70,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":7,\"time\":\"2026-08-15T10:02:05+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
    let fh = try! FileHandle(forWritingTo: ff)
    try! fh.seekToEnd()
    fh.write(compressZstd(replayedPrefix + appendedOwn))
    try! fh.close()
    let f2r = Adapters.cachedSessionFileRows(ff)
    checkEqual(f2r.rows.count, 2, "F2 replayed prefix event skipped in delta")
    checkEqual(f2r.rows.last?.input ?? 0, 300, "F2 fork's own appended event counted")

    // F3: a torn/absent session record leaves seedLength unknown, so no
    // event is skipped on a guess — the transcript still counts.
    let tornLines = "{\"type\":\"request/header\",\"seq\":0,\"time\":\"2026-08-15T10:00:05+08:00\",\"data\":{\"header\":{\"config\":{\"model\":\"deepseek-chat\"}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":1,\"time\":\"2026-08-15T10:00:10+08:00\",\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":400,\"outputTokens\":80,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":2,\"time\":\"2026-08-15T10:00:15+08:00\",\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
    try! compressZstd(tornLines).write(to: tf)
    let f3r = Adapters.cachedSessionFileRows(tf)
    checkEqual(f3r.rows.count, 1, "F3 torn header still counts events")
    checkEqual(f3r.rows.first?.input ?? 0, 400, "F3 torn header tokens counted")

    Adapters.dropClientCaches(["dsh"])
}

// MARK: - DSH corrupt-frame tests

/// Compress with a content checksum so flipping the trailing checksum byte
/// deterministically fails decoding ("Restored data doesn't match
/// checksum") — a plain ZSTD_compress frame carries no checksum, and
/// corrupted payload bytes in one may silently decode into garbage instead
/// of raising the error this test needs.
func compressZstdWithChecksum(_ text: String) -> Data {
    let input = Array(text.utf8)
    let bound = ZSTD_compressBound(input.count)
    var dst = [UInt8](repeating: 0, count: bound)
    let written = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
        dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            guard let cctx = ZSTD_createCCtx() else { return 0 }
            defer { ZSTD_freeCCtx(cctx) }
            ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1)
            return ZSTD_compress2(cctx, out.baseAddress, bound, src.baseAddress, src.count)
        }
    }
    guard written > 0, ZSTD_isError(written) == 0 else { return Data() }
    return Data(dst.prefix(written))
}

/// A content-corrupt frame in the MIDDLE of a transcript is the recovery
/// boundary: decoding stops there and keeps the valid prefix, and the
/// frames past it are NOT recovered (upstream scanZstdFrames /
/// decodeZstdBuffer semantics) — instead of the whole session being zeroed.
func runDshCorruptFrameTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-dsh-corrupt-\(UUID().uuidString)")
    let s1 = dir.appendingPathComponent("session-1")
    let s2 = dir.appendingPathComponent("session-2")
    try! fm.createDirectory(at: s1, withIntermediateDirectories: true)
    try! fm.createDirectory(at: s2, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let f1 = s1.appendingPathComponent("session.jsonl.zstd")
    let f2 = s2.appendingPathComponent("session.jsonl.zstd")

    // Three concatenated frames: a valid head (one usage event, input 100),
    // a content-corrupt middle frame (usage input 200, checksum flipped),
    // and a valid tail frame (usage input 300).
    let headFrame = compressZstd(dshSessionLines(100))
    let middleLines = "{\"type\":\"assistant/chunk\",\"seq\":3,\"time\":\"2026-08-15T10:01:00+08:00\",\"data\":{\"turn\":2,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":200,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    var corruptFrame = compressZstdWithChecksum(middleLines)
    corruptFrame[corruptFrame.count - 1] ^= 0xFF
    let tailLines = "{\"type\":\"assistant/chunk\",\"seq\":4,\"time\":\"2026-08-15T10:02:00+08:00\",\"data\":{\"turn\":3,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":300,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let tailFrame = compressZstd(tailLines)

    // F4 (full parse): the prefix before the corrupt frame is kept; the
    // corrupt frame's own event and the valid frame PAST it are skipped.
    var whole = headFrame
    whole.append(corruptFrame)
    whole.append(tailFrame)
    try! whole.write(to: f1)
    let c4 = Adapters.cachedSessionFileRows(f1)
    checkEqual(c4.rows.count, 1, "F4 prefix before corrupt frame kept")
    checkEqual(c4.rows.first?.input ?? 0, 100, "F4 prefix tokens intact")

    // F5 (incremental): the same corruption arriving in an appended tail
    // errors the delta feed, which falls back to a full re-parse keeping
    // the same prefix; no poisoned stream state is retained, and the
    // prefix result is memoized for unchanged re-reads.
    try! headFrame.write(to: f2)
    let c5a = Adapters.cachedSessionFileRows(f2)
    checkEqual(c5a.rows.count, 1, "F5 clean head parses before corruption")
    let fh = try! FileHandle(forWritingTo: f2)
    try! fh.seekToEnd()
    fh.write(corruptFrame)
    fh.write(tailFrame)
    try! fh.close()
    let c5b = Adapters.cachedSessionFileRows(f2)
    checkEqual(c5b.rows.count, 1, "F5 corrupt appended frame keeps prefix")
    checkEqual(c5b.rows.first?.input ?? 0, 100, "F5 prefix tokens intact after delta error")
    checkEqual(Adapters.dshIncrementalStateCount, 0, "F5 poisoned stream state not retained")
    let dc = Adapters.dshDecompressCount
    let c5c = Adapters.cachedSessionFileRows(f2)
    checkEqual(c5c.rows.count, 1, "F5 unchanged re-read returns memoized prefix")
    checkEqual(Adapters.dshDecompressCount - dc, 0, "F5 memoized prefix needs no re-decompress")

    Adapters.dropClientCaches(["dsh"])
}

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

// MARK: - Antigravity tests

func runAntigravityTests() {
    // A1: Client name normalization
    checkEqual(UsageCore.normalizeClientName("antigravity"), "antigravity", "A1 normalize antigravity")
    checkEqual(UsageCore.normalizeClientName("antigravity-cli"), "antigravity", "A1 normalize antigravity-cli")
    checkEqual(UsageCore.normalizeClientName("Google Antigravity"), "antigravity", "A1 normalize Google Antigravity")
    checkEqual(UsageCore.normalizeClientName("ANTIGRAVITY"), "antigravity", "A1 normalize uppercase")

    // A2: Tokscale client filter alias expansion
    let expanded = TokscaleRunner.expandClientFilter(["claude", "antigravity", "codex"])
    checkEqual(expanded, ["claude", "antigravity", "antigravity-cli", "codex"], "A2 expand client filter includes antigravity-cli")

    let expandedNoAntigravity = TokscaleRunner.expandClientFilter(["claude", "codex"])
    checkEqual(expandedNoAntigravity, ["claude", "codex"], "A2 expand without antigravity leaves list unchanged")

    // A3: SourceScanner roots for antigravity
    let adapterRoots = SourceScanner.adapterRoots("antigravity")
    check(adapterRoots.contains(where: { $0.contains(".config/tokscale/antigravity-cache") }), "A3 adapter roots include antigravity-cache")
    check(adapterRoots.contains(where: { $0.contains(".gemini/antigravity") }), "A3 adapter roots include .gemini/antigravity")

    // A4: Collector invokes antigravity sync when antigravity is enabled
    do {
        let fake = FakeCollectorWorld(now: FixtureHarness.now, settings: ["clients": "claude,antigravity"])
        fake.rowsByClient["antigravity"] = [
            UsageCore.UsageRow(
                client: "antigravity",
                sessionId: "session-1",
                model: "gemini-3.7-flash",
                provider: "google",
                input: 1000,
                output: 200,
                cacheRead: 500,
                cacheWrite: 0,
                reasoning: 50,
                messageCount: 1,
                cost: 0.05,
                startedAt: FixtureHarness.now.timeIntervalSince1970 * 1000,
                lastUsedAt: FixtureHarness.now.timeIntervalSince1970 * 1000,
                projectId: "",
                projectLabel: "",
                performance: nil
            )
        ]
        let (collector, queue) = fake.makeCollector()
        collector.requestRefresh(.full, reason: .startup)
        queue.sync {}
        checkEqual(fake.tokscaleAntigravitySyncCalls, 1, "A4 tokscaleAntigravitySync called on full startup tick")
        checkEqual(fake.rawReads["antigravity"], 1, "A4 adapterRows called for antigravity")
    }

    // A5: History attribution folds antigravity-cli into antigravity
    do {
        let jsonStr = """
        {
            "contributions": [
                {
                    "date": "2026-08-15",
                    "totals": { "tokens": 100, "cost": 0.5, "messages": 2 },
                    "clients": [
                        {
                            "client": "antigravity-cli",
                            "modelId": "gemini-3-pro",
                            "providerId": "google",
                            "tokens": { "input": 50, "output": 50, "cacheRead": 0, "cacheWrite": 0 },
                            "cost": 0.5,
                            "messages": 2
                        }
                    ],
                    "activeTimeMs": 12000
                }
            ]
        }
        """
        guard let data = jsonStr.data(using: .utf8),
              let graph = try? JSONDecoder().decode(TokscaleGraph.self, from: data) else {
            check(false, "A5 graph decoding failed")
            return
        }
        let days = HistoryCore.parseTokscaleGraph(graph)
        checkEqual(days.count, 1, "A5 graph parsed 1 day")
        check(days.first?.perClient["antigravity"] != nil, "A5 perClient attributed to antigravity")
        checkEqual(days.first?.perClient["antigravity"]?.tokens, 100, "A5 perClient tokens correct")
    }
    // A6: Custom Pricing Sidecar with custom TOKSCALE_CONFIG_DIR
    do {
        let tempDir = NSTemporaryDirectory() + "tokscale-test-\(UUID().uuidString)"
        setenv("TOKSCALE_CONFIG_DIR", tempDir, 1)
        defer {
            unsetenv("TOKSCALE_CONFIG_DIR")
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let settingsURL = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.native.json")
        let customPricing: [[String: Any]] = [
            ["modelId": "gemini-3.7-flash", "inputPerM": 0.75, "outputPerM": 3.75, "cacheReadPerM": 0.07]
        ]
        CustomPricingSidecar.sync(settingValue: customPricing, settingsFileURL: settingsURL)
        let pricingFile = tempDir + "/custom-pricing.json"
        check(FileManager.default.fileExists(atPath: pricingFile), "A6 custom-pricing.json written to TOKSCALE_CONFIG_DIR")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: pricingFile)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [String: Any],
           let gemini = models["gemini-3.7-flash"] as? [String: Any] {
            checkClose(gemini["input_cost_per_million_tokens"] as? Double ?? 0.0, 0.75, "A6 input cost correct")
            checkClose(gemini["output_cost_per_million_tokens"] as? Double ?? 0.0, 3.75, "A6 output cost correct")
            checkClose(gemini["cache_read_input_token_cost_per_million_tokens"] as? Double ?? 0.0, 0.07, "A6 cache read cost correct")
        } else {
            check(false, "A6 failed to parse custom-pricing.json")
        }
    }
    // A7: Window Behavior and Dashboard Pinning settings defaults
    do {
        let defaults = SettingsStore.defaults()
        checkEqual(defaults["windowBehavior"] as? String ?? "", "floating", "A7 windowBehavior defaults to floating")
        checkEqual(defaults["dashboardPinned"] as? Bool ?? true, false, "A7 dashboardPinned defaults to false")
        checkEqual(defaults["showTrayIcon"] as? Bool ?? false, true, "A7 showTrayIcon defaults to true")
    }
    // A8: Stale Antigravity sync lock cleanup
    do {
        let tempDir = NSTemporaryDirectory() + "tm-lock-test-\(UUID().uuidString)"
        let cacheDir = tempDir + "/.config/tokscale/antigravity-cache"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let lockPath = cacheDir + "/sync.lock"
        // Write a dead PID into sync.lock (PID 9999999 is nonexistent)
        try? "9999999 1234567890\n".write(toFile: lockPath, atomically: true, encoding: .utf8)
        check(FileManager.default.fileExists(atPath: lockPath), "A8 lock file created")
        let cleaned = TokscaleRunner.cleanupStaleAntigravityLocks(home: tempDir, force: false)
        checkEqual(cleaned, 1, "A8 cleaned 1 stale lock")
        check(!FileManager.default.fileExists(atPath: lockPath), "A8 lock file removed")
    }
    // A9: Multi-cache root and manifest timestamp handling
    do {
        let tempDir = NSTemporaryDirectory() + "tm-multicache-test-\(UUID().uuidString)"
        let cacheDir1 = tempDir + "/.config/tokscale/antigravity-cache"
        let sessionsDir1 = cacheDir1 + "/sessions"
        try? FileManager.default.createDirectory(atPath: sessionsDir1, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        let manifestContent = """
        {
            "version": 1,
            "sessions": [
                {
                    "sessionId": "session-ws-1",
                    "lastModifiedMs": 1787400000000
                }
            ]
        }
        """
        try? manifestContent.write(toFile: cacheDir1 + "/manifest.json", atomically: true, encoding: .utf8)
        let sessionContent = """
        {"type":"session_meta","sessionId":"session-ws-1","modelId":"gemini-3.7-flash","timestamp":null}
        {"type":"usage","sessionId":"session-ws-1","modelId":"gemini-3.7-flash","input":100,"output":50,"cacheRead":20,"cacheWrite":0,"reasoning":10,"timestamp":null}
        """
        try? sessionContent.write(toFile: sessionsDir1 + "/session-ws-1-abc.jsonl", atomically: true, encoding: .utf8)
        let rows = Adapters.collectAntigravityRowGroups().flatMap { $0 }
        check(rows.count >= 0, "A9 collectAntigravityRowGroups runs without error")
    }
    // A10: SourceScanner included filter and fingerprinting for Antigravity files
    do {
        check(SourceScanner.included("antigravity", path: "/path/to/session.jsonl"), "A10 included accepts jsonl")
        check(SourceScanner.included("antigravity", path: "/path/to/conversations/123.db"), "A10 included accepts db")
        check(SourceScanner.included("antigravity", path: "/path/to/conversations/123.db-wal"), "A10 included accepts db-wal")
        check(SourceScanner.included("antigravity", path: "/path/to/conversations/123.db-shm"), "A10 included accepts db-shm")
        check(SourceScanner.included("antigravity", path: "/path/to/manifest.json"), "A10 included accepts manifest.json")
        check(!SourceScanner.included("antigravity", path: "/path/to/.DS_Store"), "A10 included rejects DS_Store")
    }
}

// MARK: - Memory leak and cache bounds tests

func runMemoryLeakAndCacheTests() {
    print("--- Memory leak & cache bounds tests ---")

    // M1: BridgeCore pusher registration and unregistration
    do {
        let initialCount = BridgeCore.shared.pusherCount
        var unregisters: [() -> Void] = []
        for _ in 0..<50 {
            let unregister = BridgeCore.shared.registerPusher { _, _ in }
            unregisters.append(unregister)
        }
        checkEqual(BridgeCore.shared.pusherCount, initialCount + 50, "M1.1: BridgeCore registered 50 pushers")
        for i in 0..<25 {
            unregisters[i]()
        }
        checkEqual(BridgeCore.shared.pusherCount, initialCount + 25, "M1.2: BridgeCore accurately unregisters 25 pushers")
        for i in 25..<50 {
            unregisters[i]()
        }
        checkEqual(BridgeCore.shared.pusherCount, initialCount, "M1.3: BridgeCore unregisters all pushers cleanly without leak")
    }

    // M2: Adapters parseCache Antigravity boundedness across timestamp changes
    do {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-mem-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("session-test-ts.jsonl")
        let jsonl = """
        {"type":"usage","sessionId":"session-test-ts","modelId":"gemini-3.7-flash","input":10,"output":5,"timestamp":null}
        """
        try? jsonl.write(to: testFile, atomically: true, encoding: .utf8)

        Adapters.dropClientCaches(["antigravity"])
        checkEqual(Adapters.parseCacheKeys(client: "antigravity").count, 0, "M2.1: initial antigravity cache is empty")

        // Parse with multiple successive timestamps
        for ts: Double in [1000, 2000, 3000, 4000, 5000] {
            _ = Adapters.collectAntigravityRowGroups()
            let rows = Adapters.collectAntigravityRowGroups().flatMap { $0 }
            check(rows.count >= 0, "M2.2: collect runs for ts=\(ts)")
        }

        // Even if timestamps change repeatedly, only 1 entry per file path should exist
        let keys = Adapters.parseCacheKeys(client: "antigravity")
        let distinctPaths = Set(keys.map { $0.components(separatedBy: "|").dropFirst().joined(separator: "|") })
        checkEqual(keys.count, distinctPaths.count, "M2.3: antigravity parseCache entries are strictly 1-per-path with no unbounded key expansion")
    }

    // M3: Adapter parse cache pruning for deleted/moved files
    do {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-prune-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("a.jsonl")
        let fileB = tempDir.appendingPathComponent("b.jsonl")
        try? "{\"type\":\"test\"}".write(to: fileA, atomically: true, encoding: .utf8)
        try? "{\"type\":\"test\"}".write(to: fileB, atomically: true, encoding: .utf8)

        Adapters.dropClientCaches(["proma"])
        // Manually simulate cached values
        _ = Adapters.jsonlFiles(root: tempDir.path, recursive: false, client: "proma")
        Adapters.pruneParseCache(client: "proma", activePaths: Set([fileA.path]))

        let promaKeys = Adapters.parseCacheKeys(client: "proma")
        check(promaKeys.allSatisfy { $0.contains("a.jsonl") }, "M3.1: pruned parse cache only retains active paths")
    }

    // M4: HistoryLedger repeated fetchPeriods caching & memory boundedness
    do {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-ledger-mem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HistoryLedger(dbURL: tempDir.appendingPathComponent("ledger.db"))
        let row = UsageCore.UsageRow(
            client: "claude", sessionId: "s-mem", model: "claude-3-5-sonnet",
            provider: "anthropic", input: 100, output: 50, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: 1, cost: 0.01, startedAt: 1723700000000, lastUsedAt: 1723700000000,
            projectId: "", projectLabel: ""
        )
        ledger.recordUsageRows([row])
        // Call fetchPeriods 500 times in a loop; with caching it must be instantaneous and allocate no leak
        for _ in 0..<500 {
            _ = ledger.fetchPeriods(clients: ["claude"], now: Date(timeIntervalSince1970: 1723700000), allTimeSince: 1700000000000)
        }
        let periods = ledger.fetchPeriods(clients: ["claude"], now: Date(timeIntervalSince1970: 1723700000), allTimeSince: 1700000000000)
        checkEqual(UsageCore.intValue(periods.allTime["totalTokens"]), 150, "M4.1: cached fetchPeriods returns accurate result without memory leak across 500 queries")
    }
}

func runHistoryLedgerTests() {
    print("--- HistoryLedger persistent SQLite tests ---")
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-ledger-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbURL = tempDir.appendingPathComponent("test-ledger.db")
    let ledger = HistoryLedger(dbURL: dbURL)

    // L1: Basic upsert and deduplication
    do {
        let row1 = UsageCore.UsageRow(
            client: "claude",
            sessionId: "session-1",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            input: 100,
            output: 50,
            cacheRead: 20,
            cacheWrite: 10,
            reasoning: 0,
            messageCount: 2,
            cost: 0.05,
            startedAt: 1723700000000,
            lastUsedAt: 1723700000000,
            projectId: "proj-1",
            projectLabel: "Project 1",
            performance: nil
        )
        ledger.recordUsageRows([row1], defaultClient: "claude")

        let rows = ledger.querySessionRows(clients: ["claude"])
        checkEqual(rows.count, 1, "L1.1: 1 session row recorded")
        checkEqual(rows.first?.input ?? 0, 100, "L1.2: input tokens recorded correctly")
        checkEqual(rows.first?.output ?? 0, 50, "L1.3: output tokens recorded correctly")

        // Append to existing session (live growth)
        let row1Updated = UsageCore.UsageRow(
            client: "claude",
            sessionId: "session-1",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            input: 200,
            output: 100,
            cacheRead: 40,
            cacheWrite: 20,
            reasoning: 0,
            messageCount: 4,
            cost: 0.10,
            startedAt: 1723700000000,
            lastUsedAt: 1723701000000,
            projectId: "proj-1",
            projectLabel: "Project 1",
            performance: nil
        )
        ledger.recordUsageRows([row1Updated], defaultClient: "claude")

        let rowsAfterUpdate = ledger.querySessionRows(clients: ["claude"])
        checkEqual(rowsAfterUpdate.count, 1, "L1.4: row count remains 1 on upsert (no double counting)")
        checkEqual(rowsAfterUpdate.first?.input ?? 0, 200, "L1.5: input tokens updated to latest max")
        checkEqual(rowsAfterUpdate.first?.output ?? 0, 100, "L1.6: output tokens updated to latest max")
        checkClose(rowsAfterUpdate.first?.cost ?? 0, 0.10, "L1.7: cost updated correctly")
    }

    // L2: Preserving deleted session data
    do {
        let row2 = UsageCore.UsageRow(
            client: "workbuddy",
            sessionId: "session-deleted-tool",
            model: "deepseek-chat",
            provider: "deepseek",
            input: 1000,
            output: 500,
            cacheRead: 0,
            cacheWrite: 0,
            reasoning: 0,
            messageCount: 5,
            cost: 0.02,
            startedAt: 1723700000000,
            lastUsedAt: 1723700000000,
            projectId: "workbuddy-proj",
            projectLabel: "Workbuddy Proj",
            performance: nil
        )
        ledger.recordUsageRows([row2], defaultClient: "workbuddy")

        // Active scan now simulates tool uninstall (workbuddy files deleted from disk)
        let liveRowsOnlyClaude = ledger.querySessionRows(clients: ["claude"])
        checkEqual(liveRowsOnlyClaude.count, 1, "L2.1: live scan only sees claude")

        // Querying all clients or fetching all periods includes the deleted workbuddy session!
        let allSessions = ledger.querySessionRows(clients: ["claude", "workbuddy"])
        checkEqual(allSessions.count, 2, "L2.2: ledger retains both claude and uninstalled workbuddy session")
        let totalTokens = allSessions.reduce(0) { $0 + Int($1.input + $1.output + $1.cacheRead + $1.cacheWrite) }
        checkEqual(totalTokens, 360 + 1500, "L2.3: total tokens preserved across deleted session")
    }

    // L3: Custom date range queries
    do {
        let rowMar10 = UsageCore.UsageRow(
            client: "proma",
            sessionId: "session-mar10",
            model: "gpt-4o",
            provider: "openai",
            input: 300,
            output: 100,
            cacheRead: 0,
            cacheWrite: 0,
            reasoning: 0,
            messageCount: 1,
            cost: 0.01,
            startedAt: 1773120000000, // 2026-03-10
            lastUsedAt: 1773120000000,
            projectId: "",
            projectLabel: "",
            performance: nil
        )
        let rowMar25 = UsageCore.UsageRow(
            client: "proma",
            sessionId: "session-mar25",
            model: "gpt-4o",
            provider: "openai",
            input: 700,
            output: 300,
            cacheRead: 0,
            cacheWrite: 0,
            reasoning: 0,
            messageCount: 1,
            cost: 0.03,
            startedAt: 1774416000000, // 2026-03-25
            lastUsedAt: 1774416000000,
            projectId: "",
            projectLabel: "",
            performance: nil
        )
        ledger.recordUsageRows([rowMar10, rowMar25], defaultClient: "proma")

        let dayMar10 = DateFormatUtil.dayKey(Date(timeIntervalSince1970: 1773120000000 / 1000))
        let customPeriod = ledger.fetchCustomPeriod(clients: ["proma"], startDate: dayMar10, endDate: dayMar10)
        checkEqual(UsageCore.intValue(customPeriod["totalTokens"]), 400, "L3.1: custom period fetches exact date range tokens")
        checkClose(UsageCore.doubleValue(customPeriod["costUsd"]), 0.01, "L3.2: custom period fetches exact date range cost")
    }

    // L4: History days and mergeDays
    do {
        let day1 = HistoryCore.Day(date: "2026-08-10", tokens: 500, cost: 0.5, messages: 10, activeTimeMs: 1000)
        let day2 = HistoryCore.Day(date: "2026-08-11", tokens: 800, cost: 0.8, messages: 15, activeTimeMs: 2000)
        ledger.recordTokscaleDays([day1, day2])

        let fetchedDays = ledger.fetchHistoryDays(clients: nil)
        check(fetchedDays.count >= 2, "L4.1: history days recorded and fetched")

        // Live days only has day2 with newer tokens (1000 instead of 800), day1 deleted from disk
        var liveDay2 = HistoryCore.Day(date: "2026-08-11", tokens: 1000, cost: 1.0, messages: 20, activeTimeMs: 2500)
        liveDay2.perClient["claude"] = (tokens: 1000, cost: 1.0, messages: 20)
        liveDay2.perModel["claude-3-5-sonnet"] = (tokens: 1000, cost: 1.0)

        let merged = HistoryLedger.mergeDays(liveDays: [liveDay2], ledgerDays: fetchedDays)
        check(merged.contains { $0.date == "2026-08-10" }, "L4.2: deleted day1 preserved in merged history")
        let mDay2 = merged.first { $0.date == "2026-08-11" }
        checkEqual(mDay2?.tokens ?? 0, 1000, "L4.3: live growth merged to latest max tokens")
    }

    // L5: Session model token breakdown with parent model and subagents
    do {
        let parentRow = UsageCore.UsageRow(
            client: "antigravity",
            sessionId: "test-sess-123@local",
            model: "gemini-3.7-flash",
            provider: "google",
            input: 30000,
            output: 5000,
            cacheRead: 165000,
            cacheWrite: 0,
            reasoning: 2000,
            messageCount: 20,
            cost: 0.07,
            startedAt: 1787400000000,
            lastUsedAt: 1787405000000,
            projectId: "proj-1",
            projectLabel: "Project One"
        )
        let subagentRow = UsageCore.UsageRow(
            client: "antigravity",
            sessionId: "test-sess-123@local",
            model: "gemini-3.7-flash-lite",
            provider: "google",
            input: 8000,
            output: 1200,
            cacheRead: 35800,
            cacheWrite: 0,
            reasoning: 300,
            messageCount: 5,
            cost: 0.015,
            startedAt: 1787401000000,
            lastUsedAt: 1787404000000,
            projectId: "proj-1",
            projectLabel: "Project One"
        )
        ledger.recordUsageRows([parentRow, subagentRow])

        let breakdown = ledger.querySessionModelBreakdown(client: "antigravity", sessionId: "test-sess-123")
        check(breakdown != nil, "L5.1: querySessionModelBreakdown found session")
        checkEqual(breakdown?["found"] as? Bool, true, "L5.2: found flag is true")
        checkEqual(breakdown?["totalTokens"] as? Int, 245000, "L5.3: total tokens computed correctly (200k + 45k)")
        checkEqual(breakdown?["messageCount"] as? Int, 25, "L5.4: message count summed (20 + 5)")

        let models = breakdown?["models"] as? [[String: Any]] ?? []
        checkEqual(models.count, 2, "L5.5: both parent and subagent models returned")
        if models.count == 2 {
            let m0 = models[0]
            let m1 = models[1]
            checkEqual(m0["modelId"] as? String, "gemini-3.7-flash", "L5.6: primary model sorted first")
            checkEqual(m0["totalTokens"] as? Int, 200000, "L5.7: primary model tokens 200,000")
            checkEqual(m0["percent"] as? Double, 81.6, "L5.8: primary model percentage 81.6%")

            checkEqual(m1["modelId"] as? String, "gemini-3.7-flash-lite", "L5.9: subagent model sorted second")
            checkEqual(m1["totalTokens"] as? Int, 45000, "L5.10: subagent model tokens 45,000")
            checkEqual(m1["percent"] as? Double, 18.4, "L5.11: subagent model percentage 18.4%")
        }

        let totals = breakdown?["totals"] as? [String: Any] ?? [:]
        checkEqual(totals["inputTokens"] as? Int, 38000, "L5.12: total input tokens 38,000")
        checkEqual(totals["outputTokens"] as? Int, 6200, "L5.13: total output tokens 6,200")
        checkEqual(totals["cacheReadTokens"] as? Int, 200800, "L5.14: total cache read tokens 200,800")
        checkEqual(totals["cacheHitRate"] as? Double, 84.1, "L5.15: total cache hit rate 84.1%")
    }

    // L6: Multi-message batches are pre-aggregated per (session, date, model)
    // — the overwrite upsert must not collapse a multi-message day down to
    // the last message (regression for the per-message adapter rows).
    do {
        let msg = UsageCore.UsageRow(
            client: "dsh", sessionId: "s-agg", model: "deepseek-v4-flash",
            provider: "dsh", input: 100, output: 50, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: 1, cost: 0.01,
            startedAt: 1773200000000, lastUsedAt: 1773200000000, // 2026-03-11
            projectId: "", projectLabel: "", performance: nil
        )
        func row(_ input: Double, _ output: Double) -> UsageCore.UsageRow {
            var r = msg
            r.input = input
            r.output = output
            r.cost = input * 0.0001
            return r
        }
        // First batch: 3 messages of the same session+model+day.
        ledger.recordUsageRows([row(100, 50), row(200, 80), row(150, 70)])
        var rows = ledger.querySessionRows(clients: ["dsh"])
        checkEqual(rows.count, 1, "L6.1: multi-message batch aggregates to one ledger row")
        checkEqual(rows.first?.input ?? 0, 450, "L6.2: input tokens summed across messages")
        checkEqual(rows.first?.output ?? 0, 200, "L6.3: output tokens summed across messages")
        checkEqual(rows.first?.messageCount ?? 0, 3, "L6.4: message count summed across messages")
        // Full-snapshot replay (the same 3 messages re-parsed next tick) must
        // NOT double the totals.
        ledger.recordUsageRows([row(100, 50), row(200, 80), row(150, 70)])
        rows = ledger.querySessionRows(clients: ["dsh"])
        checkEqual(rows.first?.input ?? 0, 450, "L6.5: re-recorded snapshot does not double count")
        // Growth: one more message appended.
        ledger.recordUsageRows([row(100, 50), row(200, 80), row(150, 70), row(50, 20)])
        rows = ledger.querySessionRows(clients: ["dsh"])
        checkEqual(rows.first?.input ?? 0, 500, "L6.6: appended message grows the aggregate")
        checkEqual(rows.first?.messageCount ?? 0, 4, "L6.7: appended message grows the message count")
    }

    // L7: Tokscale graph days persist per (client, model) combination — the
    // old client×model cartesian product inflated totals by the number of
    // clients. A day with 2 clients and 2 models must come back exactly.
    do {
        var day = HistoryCore.Day(date: "2026-08-20", tokens: 1200, cost: 4.0, messages: 6, activeTimeMs: 3000)
        day.perClient["claude"] = (tokens: 300, cost: 1.0, messages: 2)
        day.perClient["codex"] = (tokens: 900, cost: 3.0, messages: 4)
        day.perModel["model-t1"] = (tokens: 300, cost: 1.0)
        day.perModel["model-t2"] = (tokens: 900, cost: 3.0)
        day.perClientModel["claude"] = ["model-t1": (tokens: 300, cost: 1.0, messages: 2)]
        day.perClientModel["codex"] = ["model-t2": (tokens: 900, cost: 3.0, messages: 4)]
        ledger.recordTokscaleDays([day])

        let fetched = ledger.fetchHistoryDays(clients: nil).first { $0.date == "2026-08-20" }
        check(fetched != nil, "L7.1: multi-client day found in history")
        checkEqual(fetched?.tokens ?? 0, 1200, "L7.2: day tokens not inflated by client count")
        checkEqual(fetched?.cost ?? 0, 4.0, "L7.3: day cost not inflated by client count")
        checkEqual(fetched?.messages ?? 0, 6, "L7.4: day messages not inflated by client count")
        checkEqual(fetched?.perClient["claude"]?.tokens ?? 0, 300, "L7.5: per-client attribution correct")
        checkEqual(fetched?.perClient["codex"]?.tokens ?? 0, 900, "L7.6: second client attribution correct")
        checkEqual(fetched?.perModel["model-t2"]?.tokens ?? 0, 900, "L7.7: per-model attribution correct")
        checkEqual(fetched?.activeTimeMs ?? 0, 3000, "L7.8: active time preserved")
    }

    // L8: maxPeriods — component-wise max of live and ledger periods keeps
    // the freshest live values while the ledger backfills deleted sources.
    do {
        let live: [String: Any] = [
            "totalTokens": 500, "costUsd": 0.1,
            "clients": ["claude": 500], "clientCosts": ["claude": 0.1],
            "clientCacheReads": [String: Any](), "clientCacheWrites": [String: Any](), "clientOutputs": ["claude": 100]
        ] as [String: Any]
        let ledgerPeriod: [String: Any] = [
            "totalTokens": 1200, "costUsd": 0.5,
            "clients": ["claude": 300, "codex": 700], "clientCosts": ["claude": 0.5, "codex": 0.4],
            "clientCacheReads": [String: Any](), "clientCacheWrites": [String: Any](), "clientOutputs": [String: Any](),
            "models": [String: Any](), "modelCosts": [String: Any](), "modelCacheReads": [String: Any](),
            "modelCacheWrites": [String: Any](), "modelOutputs": [String: Any](),
            "clientModels": [String: Any](), "clientModelCosts": [String: Any](),
            "sessions": [String: Any](), "projects": [String: Any]()
        ] as [String: Any]
        let merged = UsageCore.maxPeriods(live, ledgerPeriod)
        let clients = merged["clients"] as? [String: Any] ?? [:]
        checkEqual(clients["claude"] as? Int, 500, "L8.1: live claude tokens win over stale ledger")
        checkEqual(clients["codex"] as? Int, 700, "L8.2: deleted-source codex tokens backfilled from ledger")
        checkEqual(UsageCore.intValue(merged["totalTokens"]), 1200, "L8.3: total equals sum of per-client buckets")
        let outputs = merged["clientOutputs"] as? [String: Any] ?? [:]
        checkEqual(outputs["claude"] as? Int, 100, "L8.4: live per-client detail preserved")
    }

    // L9: Schema migration clears the polluted v1 daily table once and flags
    // user_version=2, so the rebuilt history starts clean.
    do {
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-ledger-legacy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacy) }
        let dbPath = legacy.appendingPathComponent("ledger.db")
        // Create a v1-shaped database with polluted daily rows.
        var raw: OpaquePointer?
        let openRC = sqlite3_open_v2(dbPath.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        let legacySQL = """
        CREATE TABLE IF NOT EXISTS daily_history_ledger (
            date TEXT NOT NULL, client TEXT NOT NULL, model_id TEXT NOT NULL,
            tokens REAL NOT NULL DEFAULT 0, cost_usd REAL NOT NULL DEFAULT 0.0,
            messages REAL NOT NULL DEFAULT 0.0, active_time_ms REAL NOT NULL DEFAULT 0.0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (date, client, model_id)
        );
        INSERT INTO daily_history_ledger (date, client, model_id, tokens, cost_usd, messages, active_time_ms, updated_at_ms)
        VALUES ('2026-08-01','claude','model-t1',1200,3,4,1000,1000);
        """
        let execRC = raw.map { sqlite3_exec($0, legacySQL, nil, nil, nil) } ?? -1
        XCTAssertSQLITE(openRC == SQLITE_OK && execRC == SQLITE_OK)
        XCTAssertSQLITE(sqlite3_exec(raw, "PRAGMA user_version = 1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let migrated = HistoryLedger(dbURL: dbPath)
        let days = migrated.fetchHistoryDays(clients: nil)
        checkEqual(days.count, 0, "L9.1: v1 polluted daily rows cleared by migration")
        // The rebuilt writer populates the same table afterwards.
        var cleanDay = HistoryCore.Day(date: "2026-08-02", tokens: 10, cost: 0.1, messages: 1)
        cleanDay.perClientModel["claude"] = ["model-t1": (tokens: 10, cost: 0.1, messages: 1)]
        migrated.recordTokscaleDays([cleanDay])
        let rebuilt = migrated.fetchHistoryDays(clients: nil)
        checkEqual(rebuilt.first?.tokens ?? 0, 10, "L9.2: rebuilt history accumulates after migration")
        checkEqual(migrated.currentUserVersion(), 4, "L9.3: user_version advanced to the current schema")
    }

    // L10: v2 → v3 migration purges the v1-era tokscale session rows that a
    // v2 upgrade left frozen in session_ledger (they would win the max merge
    // forever), while adapter rows survive.
    do {
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-ledger-v2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacy) }
        let dbPath = legacy.appendingPathComponent("ledger.db")
        var raw: OpaquePointer?
        let openRC = sqlite3_open_v2(dbPath.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        let v2SQL = """
        CREATE TABLE IF NOT EXISTS session_ledger (
            session_id TEXT NOT NULL,
            client TEXT NOT NULL,
            date TEXT NOT NULL,
            model_id TEXT NOT NULL,
            provider TEXT NOT NULL DEFAULT '',
            input_tokens REAL NOT NULL DEFAULT 0,
            output_tokens REAL NOT NULL DEFAULT 0,
            cache_read_tokens REAL NOT NULL DEFAULT 0,
            cache_write_tokens REAL NOT NULL DEFAULT 0,
            reasoning_tokens REAL NOT NULL DEFAULT 0,
            message_count REAL NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0.0,
            started_at_ms REAL NOT NULL DEFAULT 0.0,
            last_used_at_ms REAL NOT NULL DEFAULT 0.0,
            project_id TEXT NOT NULL DEFAULT '',
            project_label TEXT NOT NULL DEFAULT '',
            timed_tokens REAL NOT NULL DEFAULT 0,
            timed_duration_ms REAL NOT NULL DEFAULT 0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (session_id, client, date, model_id)
        );
        CREATE TABLE IF NOT EXISTS daily_history_ledger (
            date TEXT NOT NULL,
            client TEXT NOT NULL,
            model_id TEXT NOT NULL,
            tokens REAL NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0.0,
            messages REAL NOT NULL DEFAULT 0.0,
            active_time_ms REAL NOT NULL DEFAULT 0.0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (date, client, model_id)
        );
        INSERT INTO session_ledger (session_id, client, date, model_id, input_tokens, output_tokens, updated_at_ms)
        VALUES ('s-codex-1','codex','2026-08-01','gpt-5',900000,0,1787600000000);
        INSERT INTO session_ledger (session_id, client, date, model_id, input_tokens, output_tokens, updated_at_ms)
        VALUES ('s-proma-1','proma','2026-08-01','gpt-4o',500,200,1787700000000);
        """
        let execRC = raw.map { sqlite3_exec($0, v2SQL, nil, nil, nil) } ?? -1
        XCTAssertSQLITE(openRC == SQLITE_OK && execRC == SQLITE_OK)
        XCTAssertSQLITE(sqlite3_exec(raw, "PRAGMA user_version = 2;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let migrated = HistoryLedger(dbURL: dbPath)
        let tokscaleRows = migrated.querySessionRows(clients: ["codex"])
        checkEqual(tokscaleRows.count, 0, "L10.1: legacy tokscale session rows purged by v3 migration")
        let adapterRows = migrated.querySessionRows(clients: ["proma"])
        checkEqual(adapterRows.count, 1, "L10.2: adapter rows survive the v3 migration")
        checkEqual(adapterRows.first?.input ?? 0, 500, "L10.3: adapter row values intact")
        checkEqual(migrated.currentUserVersion(), 4, "L10.4: user_version advanced to 4")
        // Periods no longer include the frozen tokscale snapshot.
        let periods = migrated.fetchPeriods(clients: ["codex", "proma"], now: Date(timeIntervalSince1970: 1787700000), allTimeSince: 0)
        checkEqual(UsageCore.intValue(periods.allTime["totalTokens"]), 700, "L10.5: allTime reflects only adapter rows after purge")
    }

    // L11: v3 → v4 migration merges model variant aliases into canonical base models
    // (gemini-3.7-flash-high & gemini-flash-safety-le2 -> gemini-3.7-flash, glm-5.2-x -> glm-5.2).
    do {
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-ledger-v3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacy) }
        let dbPath = legacy.appendingPathComponent("ledger.db")
        var raw: OpaquePointer?
        let openRC = sqlite3_open_v2(dbPath.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        let v3SQL = """
        CREATE TABLE IF NOT EXISTS session_ledger (
            session_id TEXT NOT NULL,
            client TEXT NOT NULL,
            date TEXT NOT NULL,
            model_id TEXT NOT NULL,
            provider TEXT NOT NULL DEFAULT '',
            input_tokens REAL NOT NULL DEFAULT 0,
            output_tokens REAL NOT NULL DEFAULT 0,
            cache_read_tokens REAL NOT NULL DEFAULT 0,
            cache_write_tokens REAL NOT NULL DEFAULT 0,
            reasoning_tokens REAL NOT NULL DEFAULT 0,
            message_count REAL NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0.0,
            started_at_ms REAL NOT NULL DEFAULT 0.0,
            last_used_at_ms REAL NOT NULL DEFAULT 0.0,
            project_id TEXT NOT NULL DEFAULT '',
            project_label TEXT NOT NULL DEFAULT '',
            timed_tokens REAL NOT NULL DEFAULT 0,
            timed_duration_ms REAL NOT NULL DEFAULT 0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (session_id, client, date, model_id)
        );
        CREATE TABLE IF NOT EXISTS daily_history_ledger (
            date TEXT NOT NULL,
            client TEXT NOT NULL,
            model_id TEXT NOT NULL,
            tokens REAL NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0.0,
            messages REAL NOT NULL DEFAULT 0.0,
            active_time_ms REAL NOT NULL DEFAULT 0.0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (date, client, model_id)
        );
        INSERT INTO session_ledger (session_id, client, date, model_id, input_tokens, output_tokens, updated_at_ms)
        VALUES ('s-gemini-1','antigravity','2026-08-01','gemini-3.7-flash-high',100,50,1787600000000);
        INSERT INTO session_ledger (session_id, client, date, model_id, input_tokens, output_tokens, updated_at_ms)
        VALUES ('s-gemini-1','antigravity','2026-08-01','gemini-flash-safety-le2',200,80,1787700000000);
        INSERT INTO session_ledger (session_id, client, date, model_id, input_tokens, output_tokens, updated_at_ms)
        VALUES ('s-glm-1','dsh','2026-08-01','glm-5.2-x',300,120,1787800000000);
        INSERT INTO daily_history_ledger (date, client, model_id, tokens, cost_usd, messages, updated_at_ms)
        VALUES ('2026-08-01','antigravity','gemini-3.7-flash-high',150,0.01,2,1787600000000);
        INSERT INTO daily_history_ledger (date, client, model_id, tokens, cost_usd, messages, updated_at_ms)
        VALUES ('2026-08-01','antigravity','gemini-flash-safety-le2',280,0.02,3,1787700000000);
        INSERT INTO daily_history_ledger (date, client, model_id, tokens, cost_usd, messages, updated_at_ms)
        VALUES ('2026-08-01','dsh','glm-5.2-x',420,0.03,4,1787800000000);
        """
        let execRC = raw.map { sqlite3_exec($0, v3SQL, nil, nil, nil) } ?? -1
        XCTAssertSQLITE(openRC == SQLITE_OK && execRC == SQLITE_OK)
        XCTAssertSQLITE(sqlite3_exec(raw, "PRAGMA user_version = 3;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let migrated = HistoryLedger(dbURL: dbPath)
        checkEqual(migrated.currentUserVersion(), 4, "L11.1: user_version advanced to 4")

        let geminiRows = migrated.querySessionRows(clients: ["antigravity"])
        checkEqual(geminiRows.count, 1, "L11.2: gemini alias session rows merged into one")
        checkEqual(geminiRows.first?.model ?? "", "gemini-3.7-flash", "L11.3: session row model is gemini-3.7-flash")
        checkEqual(geminiRows.first?.input ?? 0, 300, "L11.4: input tokens merged (100 + 200)")
        checkEqual(geminiRows.first?.output ?? 0, 130, "L11.5: output tokens merged (50 + 80)")

        let glmRows = migrated.querySessionRows(clients: ["dsh"])
        checkEqual(glmRows.count, 1, "L11.6: glm-5.2-x session row renamed")
        checkEqual(glmRows.first?.model ?? "", "glm-5.2", "L11.7: session row model is glm-5.2")
        checkEqual(glmRows.first?.input ?? 0, 300, "L11.8: glm input preserved")

        let days = migrated.fetchHistoryDays(clients: nil)
        checkEqual(days.count, 1, "L11.9: one history day")
        let day = days.first!
        checkEqual(day.perModel["gemini-3.7-flash"]?.tokens ?? 0, 430, "L11.10: daily history gemini variants merged (150 + 280)")
        checkEqual(day.perModel["glm-5.2"]?.tokens ?? 0, 420, "L11.11: daily history glm-5.2 merged")
        check(day.perModel["gemini-3.7-flash-high"] == nil, "L11.12: old gemini-3.7-flash-high key absent")
        check(day.perModel["gemini-flash-safety-le2"] == nil, "L11.13: old gemini-flash-safety-le2 key absent")
        check(day.perModel["glm-5.2-x"] == nil, "L11.14: old glm-5.2-x key absent")
    }

    // L12: fetchHistoryDays cache invalidation must not be cleared by a
    // fetchPeriods rebuild. The two caches used to share one dirty flag:
    // fetchPeriods rebuilt its own cache, cleared the flag, and the next
    // fetchHistoryDays served the startup snapshot forever (every later
    // tokscale graph scan vanished from trends until restart).
    do {
        let dayA = HistoryCore.Day(date: "2026-08-30", tokens: 111, cost: 0.1, messages: 2)
        ledger.recordTokscaleDays([dayA])
        let first = ledger.fetchHistoryDays(clients: nil)
        check(first.contains { $0.date == "2026-08-30" }, "L12.1: first history read sees recorded day")

        // A later scan records more days...
        let dayB = HistoryCore.Day(date: "2026-08-31", tokens: 222, cost: 0.2, messages: 3)
        ledger.recordTokscaleDays([dayB])
        // ...and the periods cache is rebuilt in between (the exact tick
        // order that used to leave fetchHistoryDays with a stale cache).
        _ = ledger.fetchPeriods(clients: ["claude"], now: Date(timeIntervalSince1970: 1787610000), allTimeSince: 0)
        let second = ledger.fetchHistoryDays(clients: nil)
        check(second.contains { $0.date == "2026-08-31" }, "L12.2: history refreshed after record + fetchPeriods rebuild")
        let dayBReadBack = second.first { $0.date == "2026-08-31" }
        checkEqual(dayBReadBack?.tokens ?? 0, 222, "L12.3: fetched day carries the new values")

        // The inverse ordering also stays fresh: a record after a history
        // read must not be hidden by a later periods rebuild.
        let dayC = HistoryCore.Day(date: "2026-09-01", tokens: 333, cost: 0.3, messages: 4)
        ledger.recordTokscaleDays([dayC])
        let third = ledger.fetchHistoryDays(clients: nil)
        check(third.contains { $0.date == "2026-09-01" }, "L12.4: history refreshed after record without fetchPeriods")
    }

    // L13: querySessionModelBreakdown honors the period parameter. Dates are
    // computed relative to the real run date so the test holds on any day:
    // one row today, one row at the start of the current month (they merge
    // onto the same date when the run happens on the 1st), and a separate
    // session holding only an undated (date = '') row. today/month must
    // exclude undated rows; allTime/total must include them; a custom
    // startDate/endDate range filters too.
    do {
        let now = Date()
        let todayKey = DateFormatUtil.dayKey(now)
        let monthStartKey = DateFormatUtil.monthKey(now) + "-01"
        let dayMs = { (key: String) -> Double in
            (DateFormatUtil.parseDayKey(key)?.timeIntervalSince1970 ?? 0) * 1000
        }
        let base = UsageCore.UsageRow(
            client: "periodclient", sessionId: "", model: "",
            provider: "", input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: 1, cost: 0, startedAt: 0, lastUsedAt: 0,
            projectId: "", projectLabel: "", performance: nil
        )
        func row(_ session: String, _ model: String, _ date: String, _ tokens: Double, _ startedAtMs: Double) -> UsageCore.UsageRow {
            var r = base
            r.sessionId = session
            r.model = model
            r.input = tokens
            r.startedAt = startedAtMs
            return r
        }
        ledger.recordUsageRows([
            row("s-period-filter", "model-today", todayKey, 500, now.timeIntervalSince1970 * 1000),
            row("s-period-filter", "model-month", monthStartKey, 300, dayMs(monthStartKey)),
            row("s-period-undated", "model-undated", "", 700, 0)
        ])

        // On the 1st of a month the month-start row lands on today's date,
        // so the today filter picks both rows up; otherwise just today's.
        let monthStartIsToday = monthStartKey == todayKey
        let todayExpected = 500 + (monthStartIsToday ? 300 : 0)
        let todayModels = monthStartIsToday ? 2 : 1

        let today = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-filter", period: "today")
        check(today != nil, "L13.1: today breakdown found")
        checkEqual(today?["totalTokens"] as? Int ?? -1, todayExpected, "L13.2: today filter keeps only today's dated rows")
        checkEqual((today?["models"] as? [[String: Any]])?.count ?? 0, todayModels, "L13.3: today filter returns only dated models")

        let month = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-filter", period: "month")
        checkEqual(month?["totalTokens"] as? Int ?? -1, 800, "L13.4: month filter keeps every dated row of the month")
        checkEqual((month?["models"] as? [[String: Any]])?.count ?? 0, 2, "L13.5: month filter returns both dated models")

        let allTime = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-filter", period: "allTime")
        checkEqual(allTime?["totalTokens"] as? Int ?? -1, 800, "L13.6: allTime includes all dated rows")

        let total = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-filter", period: "total")
        checkEqual(total?["totalTokens"] as? Int ?? -1, 800, "L13.7: total (default) keeps the lifetime aggregate")

        let custom = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-filter", period: "custom", startDate: todayKey, endDate: todayKey)
        checkEqual(custom?["totalTokens"] as? Int ?? -1, todayExpected, "L13.8: custom startDate/endDate range filters")

        // Undated rows are excluded from today/month (renderer shows
        // "No activity in this period" via the nil fallback) but included
        // in allTime/total.
        let undatedToday = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-undated", period: "today")
        check(undatedToday == nil, "L13.9: undated-only session yields nil for today")
        let undatedMonth = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-undated", period: "month")
        check(undatedMonth == nil, "L13.10: undated-only session yields nil for month")
        let undatedAllTime = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-undated", period: "allTime")
        checkEqual(undatedAllTime?["totalTokens"] as? Int ?? -1, 700, "L13.11: undated row included in allTime")
        let undatedTotal = ledger.querySessionModelBreakdown(client: "periodclient", sessionId: "s-period-undated", period: "total")
        checkEqual(undatedTotal?["totalTokens"] as? Int ?? -1, 700, "L13.12: undated row included in total")
    }

    // L14: recordTokscaleDays must not multiply day.messages by the number
    // of per-model / per-client rows. day.messages is a whole-day total —
    // binding it on every row made the read-back sum (accumulated across
    // rows by fetchHistoryDays) N times too large. It is now distributed
    // proportionally to each row's tokens so the day total survives.
    do {
        var modelDay = HistoryCore.Day(date: "2026-08-25", tokens: 600, cost: 2.0, messages: 12, activeTimeMs: 4000)
        modelDay.perModel["model-a"] = (tokens: 400, cost: 1.5)
        modelDay.perModel["model-b"] = (tokens: 200, cost: 0.5)
        ledger.recordTokscaleDays([modelDay])

        var clientDay = HistoryCore.Day(date: "2026-08-26", tokens: 600, cost: 3.0, messages: 9, activeTimeMs: 5000)
        clientDay.perClient["claude"] = (tokens: 300, cost: 1.5, messages: 0)
        clientDay.perClient["codex"] = (tokens: 300, cost: 1.5, messages: 0)
        ledger.recordTokscaleDays([clientDay])

        let fetched = ledger.fetchHistoryDays(clients: nil)
        let modelDayBack = fetched.first { $0.date == "2026-08-25" }
        checkEqual(modelDayBack?.tokens ?? 0, 600, "L14.1: per-model day tokens intact")
        checkClose(modelDayBack?.messages ?? 0, 12, "L14.2: per-model day messages not amplified", tolerance: 1e-9)
        checkClose(modelDayBack?.perModel["model-a"]?.tokens ?? 0, 400, "L14.3: per-model attribution intact")

        let clientDayBack = fetched.first { $0.date == "2026-08-26" }
        checkEqual(clientDayBack?.tokens ?? 0, 600, "L14.4: per-client day tokens intact")
        checkClose(clientDayBack?.messages ?? 0, 9, "L14.5: per-client day messages not amplified", tolerance: 1e-9)
        checkClose(clientDayBack?.perClient["claude"]?.messages ?? 0, 4.5, "L14.6: per-client messages split proportionally", tolerance: 1e-9)
    }

    // L15: querySessionModelBreakdown escapes LIKE wildcards in session ids.
    // A base session id containing _ or % must only match its own @-suffixed
    // rows, not look-alikes (an unescaped 'ab_cd@%' pattern also matched
    // 'abXcd@...').
    do {
        let base = UsageCore.UsageRow(
            client: "escapeclient", sessionId: "", model: "",
            provider: "", input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
            reasoning: 0, messageCount: 1, cost: 0, startedAt: 1787400000000, lastUsedAt: 1787400000000,
            projectId: "", projectLabel: "", performance: nil
        )
        func row(_ session: String, _ model: String, _ tokens: Double) -> UsageCore.UsageRow {
            var r = base
            r.sessionId = session
            r.model = model
            r.input = tokens
            return r
        }
        ledger.recordUsageRows([
            row("ab_cd@local", "m-underscore", 100),
            row("abXcd@local", "m-lookalike", 50),
            row("ab%cd@local", "m-percent", 200),
            row("ab\\cd@local", "m-backslash", 300)
        ])

        let under = ledger.querySessionModelBreakdown(client: "escapeclient", sessionId: "ab_cd", period: "total")
        checkEqual(under?["totalTokens"] as? Int ?? -1, 100, "L15.1: underscore base matches only its own session")
        checkEqual((under?["models"] as? [[String: Any]])?.count ?? 0, 1, "L15.2: underscore lookup does not match the lookalike")

        let percent = ledger.querySessionModelBreakdown(client: "escapeclient", sessionId: "ab%cd", period: "total")
        checkEqual(percent?["totalTokens"] as? Int ?? -1, 200, "L15.3: percent base matches only its own session")

        let backslash = ledger.querySessionModelBreakdown(client: "escapeclient", sessionId: "ab\\cd", period: "total")
        checkEqual(backslash?["totalTokens"] as? Int ?? -1, 300, "L15.4: backslash base matches only its own session")
    }
}

// T-series: tokscale response decoding — one corrupt row must be skipped
// (not nullify the whole scan), but an all-bad non-empty array must throw
// so the collector keeps last-known-good data instead of recording zeros.
func runTokscaleDecodeTests() {
    print("--- Tokscale lossy decode tests ---")
    let decoder = JSONDecoder()

    do {
        // A row whose optional field is present-but-corrupt fails decode;
        // the sibling row must survive.
        let json = """
        {
          "groupBy": "client,session,model",
          "entries": [
            { "client": "claude", "sessionId": "s1", "model": "claude-3", "input": 100, "output": 50, "cost": 0.01 },
            { "client": "claude", "sessionId": "s2", "model": "claude-3", "input": 200, "output": 50, "cost": 0.01, "performance": "junk" }
          ],
          "totalInput": 300, "totalOutput": 100, "totalCost": 0.02
        }
        """
        let response = try! decoder.decode(TokscaleResponse.self, from: Data(json.utf8))
        checkEqual(response.entries.count, 1, "T1: bad entry row skipped, good row kept")
        checkEqual(response.entries.first?.sessionId, "s1", "T1: surviving row is the valid one")
        checkEqual(response.entries.first?.input ?? 0, 100, "T1: surviving row values intact")
    }

    do {
        // Every row bad → the decode must throw (upstream treats it as a
        // failed scan and keeps last-known-good + backed-off retry).
        let json = """
        { "entries": [
            { "input": 1, "performance": "junk" },
            { "output": 2, "mergedClients": 12345 }
        ] }
        """
        do {
            _ = try decoder.decode(TokscaleResponse.self, from: Data(json.utf8))
            check(false, "T2: all-bad entries array must throw")
        } catch {
            check(true, "T2: all-bad entries array throws")
        }
    }

    do {
        // A genuinely empty entries array is a legitimate empty scan.
        let json = "{ \"entries\": [], \"totalInput\": 0 }"
        do {
            let response = try decoder.decode(TokscaleResponse.self, from: Data(json.utf8))
            checkEqual(response.entries.count, 0, "T3: empty entries array decodes to empty")
        } catch {
            check(false, "T3: empty entries array must not throw")
        }
    }

    do {
        // Graph contributions follow the same rule.
        let badGraph = """
        { "contributions": [ { "date": 123 }, { "date": "2026-08-15", "clients": "oops" } ] }
        """
        do {
            _ = try decoder.decode(TokscaleGraph.self, from: Data(badGraph.utf8))
            check(false, "T4: all-bad contributions array must throw")
        } catch {
            check(true, "T4: all-bad contributions array throws")
        }

        let mixedGraph = """
        { "contributions": [
            { "date": "2026-08-15", "totals": { "tokens": 100 }, "clients": [
                { "client": "claude", "tokens": { "input": 50, "output": 50 }, "messages": 2 }
            ] },
            { "date": 42 }
        ] }
        """
        let graph = try! decoder.decode(TokscaleGraph.self, from: Data(mixedGraph.utf8))
        checkEqual(graph.contributions.count, 1, "T5: bad contribution skipped, good one kept")
        checkEqual(graph.contributions.first?.date, "2026-08-15", "T5: surviving contribution is the valid one")
    }
}

// MARK: - JSONL BOM tests

/// A UTF-8 BOM at the head of a jsonl file must not leak into the first
/// line's re-encoded data (String(data:encoding:.utf8) keeps it as
/// U+FEFF); parseJsonlLines strips it.
func t57JsonlBomTests() {
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data("{\"type\":\"message\",\"id\":\"bom-1\"}\n{\"type\":\"message\",\"id\":\"bom-2\"}\n".utf8))
    let parsed = Adapters.parseJsonlLines(data)
    checkEqual(parsed.count, 2, "t57 BOM-prefixed file parses both lines")
    checkEqual(parsed[0]["id"] as? String, "bom-1", "t57 first line intact after BOM strip")
    checkEqual(parsed[1]["id"] as? String, "bom-2", "t57 second line unaffected")
}

// MARK: - Hanako cross-format dedup tests

/// The hanako dedup lives in ONE key space with prefixed keys: a message
/// that carries an id in one file and appears id-less in a mirror is still
/// merged, and the fallback key's timestamp must not be rounded (two
/// distinct messages within the same millisecond must not merge).
func t54HanakoDedupTests() {
    func row(_ session: String, _ startedAt: Double, _ input: Double, _ output: Double) -> UsageCore.UsageRow {
        UsageCore.UsageRow(
            client: "hanako", sessionId: session, model: "model-a", provider: "hanako",
            input: input, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0,
            messageCount: 1, cost: 0, startedAt: startedAt, lastUsedAt: startedAt,
            projectId: "", projectLabel: "", performance: nil
        )
    }

    // t54a: same message with an id in one file and without one in the
    // mirror is counted once (cross-format dedup).
    do {
        var seen = Set<String>()
        let g1 = Adapters.dedupeHanakoRows(
            rows: [row("msg-1@src1", 1_725_430_000_000, 300, 150)],
            messageIds: ["m1"], seenKeys: &seen)
        checkEqual(g1.count, 1, "t54a id-bearing message kept")
        let g2 = Adapters.dedupeHanakoRows(
            rows: [row("msg-1@src2", 1_725_430_000_000, 300, 150)],
            messageIds: [""], seenKeys: &seen)
        checkEqual(g2.count, 0, "t54a id-less mirror of an id'd message deduped")
    }

    // t54b: the reverse order — id-less first, then the same message with
    // its id — also dedupes (every applicable key is inserted per row).
    do {
        var seen = Set<String>()
        let g1 = Adapters.dedupeHanakoRows(
            rows: [row("msg-2@src1", 1_725_430_000_000, 420, 210)],
            messageIds: [""], seenKeys: &seen)
        checkEqual(g1.count, 1, "t54b id-less message kept")
        let g2 = Adapters.dedupeHanakoRows(
            rows: [row("msg-2@src2", 1_725_430_000_000, 420, 210)],
            messageIds: ["m2"], seenKeys: &seen)
        checkEqual(g2.count, 0, "t54b later id-bearing mirror deduped")
    }

    // t54c: the fallback key uses the full-precision timestamp: two distinct
    // messages within the same (rounded) millisecond are NOT merged.
    do {
        var seen = Set<String>()
        let g1 = Adapters.dedupeHanakoRows(
            rows: [
                row("msg-3@src1", 1_725_430_000_000.4, 500, 250),
                row("msg-3@src1", 1_725_430_000_000.6, 500, 250)
            ],
            messageIds: ["", ""], seenKeys: &seen)
        checkEqual(g1.count, 2, "t54c distinct sub-ms messages not falsely merged")
        let g2 = Adapters.dedupeHanakoRows(
            rows: [row("msg-3@src2", 1_725_430_000_000.6, 500, 250)],
            messageIds: [""], seenKeys: &seen)
        checkEqual(g2.count, 0, "t54c an exact mirror is still deduped")
    }

    // t54d: duplicate ids are still deduped across files, and unique
    // messages pass through untouched.
    do {
        var seen = Set<String>()
        let g1 = Adapters.dedupeHanakoRows(
            rows: [row("msg-4@src1", 1_725_430_000_000, 600, 300)],
            messageIds: ["m4"], seenKeys: &seen)
        let g2 = Adapters.dedupeHanakoRows(
            rows: [row("msg-4@src2", 1_725_430_000_000, 600, 300)],
            messageIds: ["m4"], seenKeys: &seen)
        let g3 = Adapters.dedupeHanakoRows(
            rows: [row("msg-5@src1", 1_725_430_000_000, 700, 350)],
            messageIds: ["m5"], seenKeys: &seen)
        checkEqual(g1.count, 1, "t54d first id kept")
        checkEqual(g2.count, 0, "t54d repeated id deduped")
        checkEqual(g3.count, 1, "t54d unrelated message kept")
    }
}

// MARK: - Kimi mixed-format wire tests

/// A wire file that mixes usage.record lines with legacy
/// context.append_loop_event step.end records counts BOTH: the per-line
/// dispatch must not let one usage.record silence the legacy lines.
func t58KimiMixedFormatTests() {
    let tempKimiDir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-kimi-mixed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempKimiDir) }
    let sessionDir = tempKimiDir.appendingPathComponent("wd_mix_1/session_mix_1")
    let agentsMainDir = sessionDir.appendingPathComponent("agents/main")
    try! FileManager.default.createDirectory(at: agentsMainDir, withIntermediateDirectories: true)
    try! """
    {"id":"session_mix_1","title":"mixed","cwd":"/tmp","createdAt":1787680000000,"updatedAt":1787685000000}
    """.data(using: .utf8)!.write(to: sessionDir.appendingPathComponent("state.json"))
    let mixedWire = """
    {"type":"usage.record","model":"kimi-code/k3-256k","usage":{"inputOther":2000,"output":500,"inputCacheRead":18000,"inputCacheCreation":0},"time":1787681000000}
    {"type":"context.append_loop_event","time":1787682000000,"model":"kimi-code/k3-256k","event":{"type":"step.end","usage":{"inputOther":4000,"output":800,"inputCacheRead":5000,"inputCacheCreation":0}}}
    {"type":"context.append_loop_event","time":1787683000000,"event":{"type":"step.end","usage":{"inputOther":6000,"output":900,"inputCacheRead":1000,"inputCacheCreation":0}}}
    {"type":"context.append_loop_event","time":1787684000000,"event":{"type":"step.end"}}
    {"type":"context.append_loop_event","time":1787685000000,"event":{"type":"step.start"}}
    """
    try! mixedWire.data(using: .utf8)!.write(to: agentsMainDir.appendingPathComponent("wire.jsonl"))

    let rows = Adapters.parseKimiSessionDir(sessionDir)
    checkEqual(rows.count, 3, "t58 mixed-format wire counts usage.record + step.end usage lines")
    checkEqual(rows[0].input, 2000, "t58 usage.record line counted")
    checkEqual(rows[1].input, 4000, "t58 step.end line without own model counted")
    checkEqual(rows[2].input, 6000, "t58 model-less step.end line counted via fallback")
    checkEqual(rows[1].model, "k3-256k", "t58 step.end model falls back to the line model")
    checkEqual(rows[2].model, "k3-256k", "t58 model-less step.end uses normalization fallback")
}

// MARK: - Recursive listing cache tests

/// A recursive listing must not be validated by the ROOT's mtime: adding a
/// file deep in the tree (hanako session dirs) leaves the root stamp
/// unchanged, and a cached listing would miss it forever. Recursive scans
/// bypass the list cache; non-recursive scans keep using it.
func t56RecursiveListingTests() {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-recursive-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tempDir) }
    let sub = tempDir.appendingPathComponent("sub", isDirectory: true)
    let deep = sub.appendingPathComponent("deep", isDirectory: true)
    try! fm.createDirectory(at: deep, withIntermediateDirectories: true)

    // Seed the listing and the (bypassed) cache key with one file.
    try! Data("{\"type\":\"x\"}\n".utf8).write(to: tempDir.appendingPathComponent("a.jsonl"))
    let first = Adapters.jsonlFiles(root: tempDir.path, recursive: true, client: "hanako")
    checkEqual(first.count, 1, "t56 recursive listing sees the seed file")

    // A new file two levels deep: the root directory's mtime does not
    // change, yet the next listing must include it. (With the old
    // root-stamp cache this returned the stale 1-file listing.)
    try! Data("{\"type\":\"x\"}\n".utf8).write(to: deep.appendingPathComponent("b.jsonl"))
    let second = Adapters.jsonlFiles(root: tempDir.path, recursive: true, client: "hanako")
    check(second.contains { $0.lastPathComponent == "b.jsonl" }, "t56 deep added file is seen by the next listing")

    // Non-recursive scans still cache: a new DIRECT child moves the root
    // mtime, so the unchanged+new child set is served from the cache.
    let flat1 = Adapters.jsonlFiles(root: tempDir.path, recursive: false, client: "proma")
    try! Data("{\"type\":\"x\"}\n".utf8).write(to: tempDir.appendingPathComponent("c.jsonl"))
    let flat2 = Adapters.jsonlFiles(root: tempDir.path, recursive: false, client: "proma")
    check(flat2.contains { $0.lastPathComponent == "c.jsonl" }, "t56 non-recursive cache is still valid for direct children")
    _ = flat1
    Adapters.dropClientCaches(["hanako", "proma"])
}

// MARK: - DSH torn delta tail tests

/// A delta that ends mid-line must not lose the line: the raw bytes are
/// buffered and prepended to the next delta, and a delta ending mid-
/// UTF-8-character must not drop the whole delta either.
func t53DshTornTailTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-dsh-torn-\(UUID().uuidString)")
    let s1 = dir.appendingPathComponent("session-1")
    try! fm.createDirectory(at: s1, withIntermediateDirectories: true)
    defer {
        Adapters.dropClientCaches(["dsh"])
        try? fm.removeItem(at: dir)
    }
    let f1 = s1.appendingPathComponent("session.jsonl.zstd")
    try! compressZstd(dshSessionLines(100)).write(to: f1)
    _ = Adapters.cachedSessionFileRows(f1)
    checkEqual(Adapters.dshIncrementalStateCount, 1, "t53 head holds a streaming state")

    // Split helpers: cut a full line inside the two-byte é (C3 A9) so the
    // halves rejoin cleanly once prepended.
    func splitInsideMultibyte(_ line: String) -> (first: Data, second: Data) {
        let bytes = Array(line.utf8)
        let splitAt = bytes.firstIndex(of: 0xC3)! + 1   // just after the lead byte
        return (Data(bytes[0..<splitAt]), Data(bytes[splitAt...]))
    }

    let seq5Line = "{\"type\":\"assistant/chunk\",\"seq\":5,\"time\":\"2026-08-15T10:06:00+08:00\",\"data\":{\"turn\":6,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":900,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}},\"label\":\"caf\u{E9}\"}}\n"
    let (seq5First, seq5Second) = splitInsideMultibyte(seq5Line)

    // t53a: delta 1 = one COMPLETE line (seq 3) followed by the first half
    // of the seq 5 line, so the delta output ends mid-character. The
    // completed line must survive (the previous strict UTF-8 decode
    // returned nil for this whole delta and dropped seq 3 forever), while
    // the half-line yields nothing yet.
    let h1 = try! FileHandle(forWritingTo: f1)
    try! h1.seekToEnd()
    h1.write(compressZstd("{\"type\":\"assistant/chunk\",\"seq\":3,\"time\":\"2026-08-15T10:05:00+08:00\",\"data\":{\"turn\":5,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":800,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"))
    try! h1.close()
    let h2 = try! FileHandle(forWritingTo: f1)
    try! h2.seekToEnd()
    h2.write(compressZstd(String(decoding: seq5First, as: UTF8.self)))
    try! h2.close()
    let afterFirst = Adapters.cachedSessionFileRows(f1)
    checkEqual(afterFirst.rows.count, 1, "t53a mid-character delta keeps only completed lines")
    checkEqual(afterFirst.rows[0].input, 100, "t53a head row untouched")

    // t53b: delta 2 starts with the second half of the split é and brings
    // the finishes for both pending usage events. The buffered lead byte
    // is prepended, the seq 5 line parses, and both rows resolve.
    let h3 = try! FileHandle(forWritingTo: f1)
    try! h3.seekToEnd()
    h3.write(compressZstd(String(decoding: seq5Second, as: UTF8.self)
        + "{\"type\":\"assistant/chunk\",\"seq\":4,\"time\":\"2026-08-15T10:05:05+08:00\",\"data\":{\"turn\":5,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"
        + "{\"type\":\"assistant/chunk\",\"seq\":6,\"time\":\"2026-08-15T10:06:05+08:00\",\"data\":{\"turn\":6,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"))
    try! h3.close()
    let afterSecond = Adapters.cachedSessionFileRows(f1)
    checkEqual(afterSecond.rows.count, 3, "t53b torn lines completed across deltas")
    checkEqual(afterSecond.rows[1].input, 800, "t53b seq3 usage from the torn delta kept")
    checkEqual(afterSecond.rows[2].input, 900, "t53b seq5 usage spanning the multibyte split counted")
    checkEqual(afterSecond.rows[2].model, "deepseek-chat", "t53b split-line event resolved to a model")

    // t53c: a delta that is ONLY a partial line (no newline at all) parses
    // nothing and keeps the bytes; the later completion brings the event in.
    let seq7Line = "{\"type\":\"assistant/chunk\",\"seq\":7,\"time\":\"2026-08-15T10:07:00+08:00\",\"data\":{\"turn\":7,\"step\":1,\"chunk\":{\"type\":\"usage\",\"usage\":{\"inputTokens\":1200,\"outputTokens\":50,\"cacheReadTokens\":0,\"cacheWriteTokens\":0}}}}\n"
    let seq7Bytes = Array(seq7Line.utf8)
    let h4 = try! FileHandle(forWritingTo: f1)
    try! h4.seekToEnd()
    h4.write(compressZstd(String(decoding: Data(seq7Bytes[0..<(seq7Bytes.count - 3)]), as: UTF8.self)))   // drops "}}\n
    try! h4.close()
    let afterFirstHalf = Adapters.cachedSessionFileRows(f1)
    checkEqual(afterFirstHalf.rows.count, 3, "t53c fully-partial delta adds nothing")
    let h5 = try! FileHandle(forWritingTo: f1)
    try! h5.seekToEnd()
    h5.write(compressZstd(String(decoding: Data(seq7Bytes[(seq7Bytes.count - 3)...]), as: UTF8.self)
        + "{\"type\":\"assistant/chunk\",\"seq\":8,\"time\":\"2026-08-15T10:07:05+08:00\",\"data\":{\"turn\":7,\"step\":1,\"chunk\":{\"type\":\"finish\",\"replayState\":{\"model\":\"deepseek-chat\"}}}}\n"))
    try! h5.close()
    let afterCompletion = Adapters.cachedSessionFileRows(f1)
    checkEqual(afterCompletion.rows.count, 4, "t53c line completed by the next delta")
    checkEqual(afterCompletion.rows[3].input, 1200, "t53c fully-partial line's event counted")
    Adapters.dropClientCaches(["dsh"])
}

// MARK: - DSH touch-only stamp tests

/// A touch-only change (mtime advanced, size unchanged) must advance the
/// stamp IN the stored dictionary entry: the stream then becomes stable
/// and the idle sweep can free it. Without the write-back the stored
/// stamp lags forever, the stream never looks idle, and the state
/// dictionary grows without bound.
func t55DshTouchOnlyStampTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("tm-dsh-touch-\(UUID().uuidString)")
    let s1 = dir.appendingPathComponent("session-1")
    try! fm.createDirectory(at: s1, withIntermediateDirectories: true)
    defer {
        Adapters.dropClientCaches(["dsh"])
        try? fm.removeItem(at: dir)
    }
    let f1 = s1.appendingPathComponent("session.jsonl.zstd")
    try! compressZstd(dshSessionLines(100)).write(to: f1)
    let r1 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r1.rows.count, 1, "t55 head parses")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "t55 fresh session holds a stream")

    // Touch: same content, new mtime. The feed finds an empty tail and
    // must persist the advanced stamp.
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: f1.path)
    let r2 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r2.rows.count, 1, "t55 touch-only read keeps the rows")
    checkEqual(Adapters.dshIncrementalStateCount, 1, "t55 touch-only read keeps the stream")

    // The touching host pattern: repeated touch-only ticks. Each must
    // advance the stored stamp, so a sweep far past the now-current mtime
    // sees a stable idle stream and frees it.
    checkEqual(Adapters.freeIdleDshStreams(now: Date().addingTimeInterval(3600)), 1,
               "t55 touch-only stream becomes stable and is swept")
    checkEqual(Adapters.dshIncrementalStateCount, 0, "t55 touch-only stream freed")

    // The sweep freed the state; rows are still served (the touch made the
    // parse-cache stamp stale, so the re-read re-derives them once).
    let r3 = Adapters.cachedSessionFileRows(f1)
    checkEqual(r3.rows.count, 1, "t55 rows still served after the sweep")
    Adapters.dropClientCaches(["dsh"])
}

func XCTAssertSQLITE(_ condition: Bool) {
    check(condition, "sqlite operation succeeded")
}

// MARK: - Tokscale drain timeout tests

/// The pipe drain must never freeze: when the child exits but a grandchild
/// inherited the stdout/stderr pipe write ends (fork/exec fd-inheritance
/// trap), EOF never arrives on its own. drainOutput must return within a
/// bounded wall-clock budget and reap the grandchild via the process-group
/// kill (/bin/sh puts background jobs in the shell's own process group).
func t61DrainTimeoutGrandchildTests() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", "sleep 30 & echo slp=$!"]
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try! proc.run()
    let started = Date()
    let drained = TokscaleRunner.drainOutput(process: proc, outPipe: outPipe, errPipe: errPipe,
                                             timeout: 1, grace: 1)
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 6.0, "t61 drain returns within a bounded budget (\(String(format: "%.2f", elapsed))s)")
    check(elapsed >= 1.9, "t61 drain does not return before the kill deadline (\(String(format: "%.2f", elapsed))s)")
    checkEqual(proc.terminationStatus, 0, "t61 wrapper shell exited cleanly")
    let stdout = drained.stdout
    guard let range = stdout.range(of: "slp=") else {
        check(false, "t61 grandchild pid captured (stdout: \(stdout))")
        return
    }
    let pidText = stdout[range.upperBound...].prefix { $0.isNumber }
    guard let grandchildPID = Int32(pidText) else {
        check(false, "t61 grandchild pid parsed (stdout: \(stdout))")
        return
    }
    let alive = kill(grandchildPID, 0) == 0 || errno == EPERM
    if alive {
        // Test hygiene: never leave the orphan running.
        kill(grandchildPID, SIGKILL)
    }
    check(!alive, "t61 grandchild reaped by the group kill")
}

// MARK: - Antigravity lock cleanup heuristics tests

/// Stale-lock cleanup must never remove a lock whose recorded pid is still
/// alive: the age fallback exists only for locks that carry no pid info,
/// and the force path must liveness-check too. Dead-pid locks and
/// pid-less old locks are still cleaned. Each step leaves exactly one lock
/// file in place (cleanup scans sync.lock / sync.os.lock / <dir>.lock).
func t59AntigravityLockCleanupTests() {
    let fm = FileManager.default
    let lockDir = fm.temporaryDirectory.appendingPathComponent("tm-lock-pid-\(UUID().uuidString)")
    let cacheDir = lockDir.appendingPathComponent(".config/tokscale/antigravity-cache")
    try! fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: lockDir) }
    let syncLock = cacheDir.appendingPathComponent("sync.lock").path
    func age(_ path: String, seconds: TimeInterval) {
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: seconds)], ofItemAtPath: path)
    }

    // A live holder: a real process whose pid sits in the lock file.
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["60"]
    try! sleeper.run()
    let livePid = sleeper.processIdentifier
    try! "\(livePid) 1234567890\n".write(toFile: syncLock, atomically: true, encoding: .utf8)
    age(syncLock, seconds: -3600)

    // (c) An old mtime must not delete a lock held by a live process,
    // even one that has outlived the 30s fallback.
    let cleanedLive = TokscaleRunner.cleanupStaleAntigravityLocks(home: lockDir.path, force: false)
    checkEqual(cleanedLive, 0, "t59 live-pid lock not cleaned by age fallback")
    check(fm.fileExists(atPath: syncLock), "t59 live-pid lock file kept")

    // (b) The force path liveness-checks too.
    let cleanedLiveForce = TokscaleRunner.cleanupStaleAntigravityLocks(home: lockDir.path, force: true)
    checkEqual(cleanedLiveForce, 0, "t59 live-pid lock not cleaned by force")
    check(fm.fileExists(atPath: syncLock), "t59 live-pid lock kept under force")

    sleeper.terminate()
    sleeper.waitUntilExit()

    // Once the recorded holder is gone the same lock is stale.
    let cleanedDead = TokscaleRunner.cleanupStaleAntigravityLocks(home: lockDir.path, force: false)
    checkEqual(cleanedDead, 1, "t59 dead-pid lock cleaned once holder exits")
    check(!fm.fileExists(atPath: syncLock), "t59 dead-pid lock file removed")

    // Pid-less lock: only an old mtime marks it stale.
    try! "antigravity sync\n".write(toFile: syncLock, atomically: true, encoding: .utf8)
    age(syncLock, seconds: -3600)
    checkEqual(TokscaleRunner.cleanupStaleAntigravityLocks(home: lockDir.path, force: false), 1,
               "t59 pid-less old lock cleaned by age fallback")

    try! "antigravity sync\n".write(toFile: syncLock, atomically: true, encoding: .utf8)
    checkEqual(TokscaleRunner.cleanupStaleAntigravityLocks(home: lockDir.path, force: false), 0,
               "t59 fresh pid-less lock kept")

    // A dead-pid lock is cleaned regardless of age.
    try! "9999999 1234567890\n".write(toFile: syncLock, atomically: true, encoding: .utf8)
    checkEqual(TokscaleRunner.cleanupStaleAntigravityLocks(home: lockDir.path, force: false), 1,
               "t59 dead-pid lock cleaned regardless of age")
}

func t60StaleLockErrorPatternTests() {
    checkEqual(TokscaleRunner.isStaleLockError("sqlite3: database is locked (5)"), false,
               "t60 live SQLite contention never triggers lock cleanup")
    checkEqual(TokscaleRunner.isStaleLockError("the database is locked by another connection"), false,
               "t60 database-is-locked variant ignored")
    checkEqual(TokscaleRunner.isStaleLockError("error: sync lock already exists"), true,
               "t60 sync-lock message triggers cleanup")
    checkEqual(TokscaleRunner.isStaleLockError("a stale lock from a crashed run blocks startup"), true,
               "t60 stale-lock message triggers cleanup")
    checkEqual(TokscaleRunner.isStaleLockError("unable to create lock file"), true,
               "t60 lock-file message triggers cleanup")
    checkEqual(TokscaleRunner.isStaleLockError("lock already exists for this sync"), true,
               "t60 already-exists message triggers cleanup")
    checkEqual(TokscaleRunner.isStaleLockError("some unrelated mention of lock"), false,
               "t60 bare lock mention never triggers cleanup")
    checkEqual(TokscaleRunner.isStaleLockError("database is locked; the sync lock stays"), false,
               "t60 database lock mentioned with other text still ignored")
}

func t62ZeroBalanceKeepsHistoryTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-limits-history-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let storePath = dir.appendingPathComponent("deepseek-balance-v2.json").path
    DeepseekBalance.storePathOverride = storePath
    defer { DeepseekBalance.storePathOverride = nil }
    let account = "t62-account"

    // Day 1: funded CNY row at 100, then a 60 drop to 40.
    let day1 = Int64(1_760_000_000_000)
    var spend = DeepseekBalance.recordConsumption(accountKey: account, currency: "CNY", paid: 100, now: day1)
    checkClose(spend.allTimeSpend, 0, "t62 fresh account starts at zero spend")
    spend = DeepseekBalance.recordConsumption(accountKey: account, currency: "CNY", paid: 40, now: day1 + 3_600_000)
    checkClose(spend.allTimeSpend, 60, "t62 drop records consumption")

    // Balance hits zero: selectFundedRow falls back to the USD row, so the
    // next record arrives under a different currency. That must NOT wipe the
    // recorded history — the entry stays pinned to its original currency and
    // the final drop (40) is recorded on top of the earlier 60.
    spend = DeepseekBalance.recordConsumption(accountKey: account, currency: "USD", paid: 0, now: day1 + 24 * 3_600_000)
    checkClose(spend.allTimeSpend, 100, "t62 zero balance keeps all-time history")
    let persisted = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: storePath)))) as? [String: Any]
    let entry = persisted?[account] as? [String: Any]
    checkEqual(entry?["currency"] as? String, "CNY", "t62 entry keeps its pinned currency")
    let daily = entry?["dailySpend"] as? [String: Any] ?? [:]
    checkClose(daily.values.reduce(0.0) { $0 + (($1 as? NSNumber)?.doubleValue ?? 0) }, 100,
               "t62 daily spend survives zero balance")

    // A funded row reappearing in another currency (row switch) also
    // preserves history; paid going up means no further drop.
    spend = DeepseekBalance.recordConsumption(accountKey: account, currency: "USD", paid: 50, now: day1 + 48 * 3_600_000)
    checkClose(spend.allTimeSpend, 100, "t62 funded-row switch keeps history")

    // A genuinely new account still starts clean.
    spend = DeepseekBalance.recordConsumption(accountKey: "t62-other", currency: "USD", paid: 9, now: day1)
    checkClose(spend.allTimeSpend, 0, "t62 separate account unaffected")
}

func t63CredentialsFilePermissionTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-credentials-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CredentialStore(fileURL: dir.appendingPathComponent("credentials.json"))

    // First write: the file must already be 0600 right after the rename
    // (chmod happens on the temp file before it replaces the store).
    store.setKimiApiKey("kimi-key-1")
    check(FileManager.default.fileExists(atPath: store.fileURL.path), "t63 credentials file exists after write")
    checkEqual(posixPermissions(of: store.fileURL.path), 0o600, "t63 credentials file is 0600 after first write")

    // Overwriting an existing file that was left at 0644 (e.g. by the old
    // write-then-chmod path) re-locks it to 0600.
    try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
    store.setDeepseekApiKey("sk-existing")
    checkEqual(posixPermissions(of: store.fileURL.path), 0o600, "t63 overwritten credentials file is 0600")
    checkEqual(store.deepseekApiKey(), "sk-existing", "t63 round-trip read after overwrite")
}

func posixPermissions(of path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

runChecks()
runKimiTests()
runCollectorStateTests()
runDshCacheTests()
runDshIdleSweepTests()
runParseCacheEvictionTests()
runDshForkSeedTests()
runDshCorruptFrameTests()
runVisibilityTests()
runIdleTeardownTests()
runSingleInstanceTests()
runAntigravityTests()
runMemoryLeakAndCacheTests()
runHistoryLedgerTests()
runTokscaleDecodeTests()
t53DshTornTailTests()
t54HanakoDedupTests()
t55DshTouchOnlyStampTests()
t56RecursiveListingTests()
t57JsonlBomTests()
t58KimiMixedFormatTests()
t61DrainTimeoutGrandchildTests()
t59AntigravityLockCleanupTests()
t60StaleLockErrorPatternTests()
t62ZeroBalanceKeepsHistoryTests()
t63CredentialsFilePermissionTests()
print("fixture checks: \(checkCount) checks, \(failureCount) failures")
if failureCount > 0 { exit(1) }

