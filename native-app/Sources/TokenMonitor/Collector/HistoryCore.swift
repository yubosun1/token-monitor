import Foundation

/// Port of src/shared/history.js: tokscale `graph` contributions (plus the
/// local adapters' own per-day contributions) → {daily, monthly, summary}
/// consumed by the dashboard trends view and the home history module.
enum HistoryCore {
    typealias JSON = [String: Any]

    struct Day {
        var date: String
        var tokens: Double = 0
        var cost: Double = 0
        var messages: Double = 0
        var activeTimeMs: Double = 0
        var perClient: [String: (tokens: Double, cost: Double, messages: Double)] = [:]
        var perModel: [String: (tokens: Double, cost: Double)] = [:]
    }

    static func parseTokscaleGraph(_ graph: TokscaleGraph) -> [Day] {
        var days: [Day] = []
        for row in graph.contributions {
            let date = String(row.date.prefix(10))
            guard !date.isEmpty else { continue }
            var day = Day(date: date)
            day.activeTimeMs = row.activeTimeMs ?? 0
            for client in row.clients ?? [] {
                let clientId = UsageCore.normalizeClientName(client.client) ?? client.client ?? "unknown"
                let model = UsageCore.canonicalModelName(client.modelId ?? "unknown")
                let breakdown = client.tokens ?? TokscaleGraph.Breakdown(input: nil, output: nil, cacheRead: nil, cacheWrite: nil, reasoning: nil)
                let tokens = (breakdown.input ?? 0) + (breakdown.output ?? 0)
                    + (breakdown.cacheRead ?? 0) + (breakdown.cacheWrite ?? 0)
                let cost = client.cost ?? 0
                let messages = client.messages ?? 0
                day.tokens += tokens
                day.cost += cost
                day.messages += messages
                var pc = day.perClient[clientId] ?? (0, 0, 0)
                pc.tokens += tokens; pc.cost += cost; pc.messages += messages
                day.perClient[clientId] = pc
                var pm = day.perModel[model] ?? (0, 0)
                pm.tokens += tokens; pm.cost += cost
                day.perModel[model] = pm
            }
            days.append(day)
        }
        return days
    }

    static func mergeAdapterContributions(_ contributions: [Adapters.HistoryContribution], into days: inout [Day]) {
        // Build a date->index map once so each contribution is an O(1)
        // lookup instead of a linear firstIndex scan (was O(n^2) total).
        var indexByDate: [String: Int] = [:]
        for (i, day) in days.enumerated() {
            indexByDate[day.date] = i
        }
        for c in contributions {
            let i: Int
            if let existing = indexByDate[c.date] {
                i = existing
            } else {
                days.append(Day(date: c.date))
                i = days.count - 1
                indexByDate[c.date] = i
            }
            let tokens = Double(c.input + c.output + c.cacheRead + c.cacheWrite)
            days[i].tokens += tokens
            days[i].cost += c.cost
            days[i].messages += Double(c.messages)
            var pc = days[i].perClient[c.client] ?? (0, 0, 0)
            pc.tokens += tokens; pc.cost += c.cost; pc.messages += Double(c.messages)
            days[i].perClient[c.client] = pc
            var pm = days[i].perModel[c.modelId] ?? (0, 0)
            pm.tokens += tokens; pm.cost += c.cost
            days[i].perModel[c.modelId] = pm
        }
    }

    /// Local "today" key for the daily window. Day keys are local-day
    /// scoped everywhere else (adapter contributions, tokscale graph with
    /// its pinned bucket timezone, the renderer's heatmap cells), so the
    /// fallback must be local too: ISO8601DateFormatter formats in UTC,
    /// which cut the current local day out of the daily window between
    /// local midnight and 08:00 (UTC+8) — the dashboard's activity view
    /// showed today as 0 during that window.
    static func localTodayKey() -> String {
        DateFormatUtil.localTodayKey()
    }

    static func normalizeHistory(days input: [Day], todayKey: String? = nil, capDays: Int = 370, totalActiveTimeMsOverride: Double? = nil) -> JSON {
        let full = input.sorted { $0.date < $1.date }
        let today = String((todayKey ?? localTodayKey()).prefix(10))

        let count = max(0, capDays)
        let startKey = dayKeyAddDays(today, delta: -(count - 1))
        let dailyDays = count == 0 ? [] : full.filter { day in
            let key = String(day.date.prefix(10))
            return key >= startKey && key <= today
        }

        var maxTokens = 0.0
        var maxCost = 0.0
        for day in dailyDays {
            maxTokens = max(maxTokens, day.tokens)
            maxCost = max(maxCost, day.cost)
        }

        let daily: [JSON] = dailyDays.map { day in
            let tokenIntensity = intensityBucket(day.tokens, max: maxTokens)
            let costIntensity = intensityBucket(day.cost, max: maxCost)
            return [
                "date": day.date,
                "tokens": day.tokens,
                "cost": day.cost,
                "messages": day.messages,
                "activeTimeMs": day.activeTimeMs,
                "tokenIntensity": tokenIntensity,
                "costIntensity": costIntensity,
                "intensity": costIntensity,
                "perClient": day.perClient.mapValues { ["tokens": $0.tokens, "cost": $0.cost, "messages": $0.messages] },
                "perModel": day.perModel.mapValues { ["tokens": $0.tokens, "cost": $0.cost] }
            ]
        }

        // Monthly rollup (full set, like the JS tier).
        var byMonth: [String: JSON] = [:]
        for day in full {
            let month = String(day.date.prefix(7))
            guard month.count == 7 else { continue }
            var m = byMonth[month] ?? [
                "month": month, "tokens": 0.0, "cost": 0.0, "activeTimeMs": 0.0,
                "perClient": JSON(), "perModel": JSON()
            ]
            m["tokens"] = (m["tokens"] as? Double ?? 0) + day.tokens
            m["cost"] = (m["cost"] as? Double ?? 0) + day.cost
            m["activeTimeMs"] = (m["activeTimeMs"] as? Double ?? 0) + day.activeTimeMs
            var perClient = m["perClient"] as? JSON ?? JSON()
            for (client, v) in day.perClient {
                var entry = perClient[client] as? JSON ?? ["tokens": 0.0, "cost": 0.0, "messages": 0.0]
                entry["tokens"] = (entry["tokens"] as? Double ?? 0) + v.tokens
                entry["cost"] = (entry["cost"] as? Double ?? 0) + v.cost
                entry["messages"] = (entry["messages"] as? Double ?? 0) + v.messages
                perClient[client] = entry
            }
            var perModel = m["perModel"] as? JSON ?? JSON()
            for (model, v) in day.perModel {
                var entry = perModel[model] as? JSON ?? ["tokens": 0.0, "cost": 0.0]
                entry["tokens"] = (entry["tokens"] as? Double ?? 0) + v.tokens
                entry["cost"] = (entry["cost"] as? Double ?? 0) + v.cost
                perModel[model] = entry
            }
            m["perClient"] = perClient
            m["perModel"] = perModel
            byMonth[month] = m
        }
        let monthly = byMonth.values.sorted { ($0["month"] as? String ?? "") < ($1["month"] as? String ?? "") }

        let totalTokens = full.reduce(0.0) { $0 + $1.tokens }
        let totalCost = full.reduce(0.0) { $0 + $1.cost }
        let messages = full.reduce(0.0) { $0 + $1.messages }
        let activeDays = full.reduce(0.0) { $0 + ($1.tokens > 0 ? 1 : 0) }
        let peakDayTokens = full.reduce(0.0) { max($0, $1.tokens) }
        let activeTimeMs = totalActiveTimeMsOverride ?? full.reduce(0.0) { $0 + $1.activeTimeMs }
        let streaks = computeStreaks(full, todayKey: today)

        let summary: JSON = [
            "totalTokens": totalTokens,
            "totalCost": totalCost,
            "activeDays": activeDays,
            "currentStreak": streaks.current,
            "longestStreak": streaks.longest,
            "peakDayTokens": peakDayTokens,
            "favoriteModel": favoriteModel(full),
            "messages": messages,
            "activeTimeMs": activeTimeMs
        ]

        return ["daily": daily, "monthly": monthly, "summary": summary]
    }

    private static func intensityBucket(_ value: Double, max: Double) -> Int {
        guard max > 0 else { return 0 }
        let ratio = value / max
        if ratio >= 0.75 { return 4 }
        if ratio >= 0.5 { return 3 }
        if ratio >= 0.25 { return 2 }
        if ratio > 0 { return 1 }
        return 0
    }

    private static func computeStreaks(_ days: [Day], todayKey: String) -> (current: Int, longest: Int) {
        let active = Set(days.filter { $0.tokens > 0 }.map { String($0.date.prefix(10)) })
        var current = 0
        var cursor = todayKey
        while active.contains(cursor) {
            current += 1
            cursor = dayKeyAddDays(cursor, delta: -1)
        }
        let sorted = active.sorted()
        var longest = 0
        var run = 0
        var prev: String?
        for key in sorted {
            run = (prev != nil && key == dayKeyAddDays(prev!, delta: 1)) ? run + 1 : 1
            longest = max(longest, run)
            prev = key
        }
        return (current, longest)
    }

    private static func favoriteModel(_ days: [Day]) -> String {
        var totals: [String: Double] = [:]
        for day in days {
            for (model, v) in day.perModel {
                totals[model] = (totals[model] ?? 0) + v.tokens
            }
        }
        var best = ""
        var bestTokens = -1.0
        for (model, tokens) in totals where tokens > bestTokens {
            best = model
            bestTokens = tokens
        }
        return best
    }

    static func dayKeyAddDays(_ key: String, delta: Int) -> String {
        DateFormatUtil.dayKeyByAdding(key, delta: delta)
    }
}
