import Foundation
import CryptoKit

/// Port of fetchDeepSeekLimits (limitCollector.js) + recordConsumption
/// (deepseekBalanceHistory.js). Reads the stored API key, polls
/// https://api.deepseek.com/user/balance, records paid-balance drops into a
/// local daily-spend history, and emits the credits-window provider shape.
enum DeepseekBalance {
    typealias JSON = [String: Any]

    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    static let retentionMs: Int64 = 40 * 24 * 60 * 60 * 1000
    static let storeVersion = 2

    private static var storePath: String {
        return CredentialStore.shared.fileURL.deletingLastPathComponent()
            .appendingPathComponent("deepseek-balance-v2.json").path
    }

    private static var legacyStorePath: String {
        return CredentialStore.shared.fileURL.deletingLastPathComponent()
            .appendingPathComponent("deepseek-balance.json").path
    }

    // MARK: - Fetch

    static func fetchLimits(nowMs: Int64) -> JSON {
        let now = nowMs > 0 ? nowMs : Int64(Date().timeIntervalSince1970 * 1000)
        let updatedAt = isoFromMs(now)
        let key = CredentialStore.shared.deepseekApiKey()
        guard !key.isEmpty else {
            return notConfigured(updatedAt: updatedAt)
        }
        do {
            let rows = try fetchBalanceRows(apiKey: key)
            let row = try selectFundedRow(rows)
            let accountKey = hashKey("deepseek", key)
            let spend = recordConsumption(accountKey: accountKey, currency: row.currency, paid: row.paid, now: now)
            return [
                "provider": "deepseek",
                "accountKey": accountKey,
                "accountLabel": "Pay-as-you-go",
                "source": "api",
                "status": "ok",
                "updatedAt": updatedAt,
                "windows": [[
                    "kind": "billing",
                    "metric": "credits",
                    "label": "Balance",
                    "remaining": row.amount,
                    "currency": row.currency,
                    "used": NSNull(), "limit": NSNull(),
                    "usedPercent": NSNull(), "remainingPercent": NSNull()
                ]],
                "balance": [
                    "amount": row.amount,
                    "currency": row.currency,
                    // 当前可用余额 = total_balance（含赠金）；总充值余额 =
                    // topped_up_balance。渲染层用这两个数分别展示。
                    "toppedUpBalance": row.paid,
                    "todaySpend": spend.todaySpend,
                    "yesterdaySpend": spend.yesterdaySpend,
                    "weekSpend": spend.weekSpend,
                    "month30Spend": spend.month30Spend,
                    "monthSpend": spend.monthSpend,
                    "allTimeSpend": spend.allTimeSpend,
                    "trackingSince": spend.trackingSince,
                    "monthSinceTracking": spend.monthSinceTracking
                ]
            ]
        } catch {
            let status = providerStatusFromError(error)
            return ["provider": "deepseek", "source": "api", "status": status, "updatedAt": updatedAt, "windows": [Any]()]
        }
    }

    private static func notConfigured(updatedAt: String) -> JSON {
        return ["provider": "deepseek", "source": "api", "status": "notConfigured", "updatedAt": updatedAt, "windows": [Any]()]
    }

    private static func providerStatusFromError(_ error: Error) -> String {
        if let status = (error as NSError).userInfo["status"] as? String,
           ["disabled", "notConfigured", "unauthorized", "rateLimited", "sourceRateLimited", "unavailable", "error"].contains(status) {
            return status
        }
        return "unavailable"
    }

    private static func fetchBalanceRows(apiKey: String) throws -> [[String: Any]] {
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        var data: Data?
        var response: URLResponse?
        var fetchError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { d, r, e in
            data = d; response = r; fetchError = e
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let fetchError {
            throw fetchError
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            // 429 surfaces as rateLimited (not a generic failure) so the UI
            // can distinguish throttling from a real outage.
            if status == 429 { throw statusError("rateLimited") }
            throw statusError(status == 401 || status == 403 ? "unauthorized" : "unavailable")
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["balance_infos"] as? [[String: Any]] else {
            throw statusError("unavailable")
        }
        return rows
    }

    private static func statusError(_ status: String) -> NSError {
        return NSError(domain: "TokenMonitor.deepseek", code: 1, userInfo: ["status": status])
    }

    /// Port of selectFundedRow: prefer the funded row with the largest amount
    /// (USD tiebreak), fall back to the first row.
    private static func selectFundedRow(_ rows: [[String: Any]]) throws -> (currency: String, amount: Double, paid: Double) {
        var parsed: [(currency: String, amount: Double, paid: Double)] = []
        for row in rows {
            guard let amount = number(row["total_balance"]),
                  let paid = number(row["topped_up_balance"]),
                  let currency = (row["currency"] as? String)?.trimmingCharacters(in: .whitespaces).uppercased(),
                  !currency.isEmpty else { continue }
            parsed.append((currency, amount, paid))
        }
        guard !parsed.isEmpty else { throw statusError("unavailable") }
        let funded = parsed.filter { $0.amount > 0 }.sorted { a, b in
            if a.amount != b.amount { return a.amount > b.amount }
            if a.currency == "USD" { return true }
            if b.currency == "USD" { return false }
            return false
        }
        if let first = funded.first { return first }
        return parsed.first { $0.currency == "USD" } ?? parsed[0]
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    /// JSON numbers arrive as NSNumber; read them as Int64 without
    /// `as?` chaining pitfalls.
    private static func int64FromJson(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let d = Double(s) { return Int64(d) }
        return 0
    }

    // MARK: - Consumption history (port of deepseekBalanceHistory.js)

    struct Spend {
        let todaySpend: Double
        let yesterdaySpend: Double
        /// 近7天（含今天）
        let weekSpend: Double
        /// 近30天（含今天）
        let month30Spend: Double
        /// 本月（自然月）
        let monthSpend: Double
        let allTimeSpend: Double
        let trackingSince: String
        let monthSinceTracking: Bool
    }

    private static func recordConsumption(accountKey: String, currency: String, paid: Double, now: Int64) -> Spend {
        let store = readJson(storePath) ?? (readJson(legacyStorePath) ?? JSON())
        var entry = normalizedCompactEntry(store[accountKey], currency: currency, now: now)

        var changed = false
        if entry["lastPaid"] is NSNull {
            entry["lastPaid"] = paid
            changed = true
        } else if let lastPaid = number(entry["lastPaid"]), lastPaid != paid {
            let drop = max(0, lastPaid - paid)
            addDailySpend(&entry, timestamp: now, amount: drop)
            // Parentheses matter: `??` binds looser than `+`, so the unparenthesized
            // form `number(...) ?? 0 + drop` parsed as `?? (0 + drop)` and the drop
            // was silently dropped whenever an entry already existed — the port of
            // `round2(Number(entry.allTimeSpend || 0) + drop)` in the JS original.
            entry["allTimeSpend"] = round2((number(entry["allTimeSpend"]) ?? 0) + drop)
            entry["lastPaid"] = paid
            changed = true
        }

        var daily = entry["dailySpend"] as? JSON ?? JSON()
        let pruned = pruneDailySpend(daily, now: now)
        if !jsonEqual(pruned, daily) { changed = true }
        entry["dailySpend"] = pruned
        daily = pruned

        if changed {
            var document = store
            document[accountKey] = entry
            writeJson(document, to: storePath)
        }
        return computeConsumption(entry, daily: daily, now: now)
    }

    private static func normalizedCompactEntry(_ raw: Any?, currency: String, now: Int64) -> JSON {
        let entry = raw as? JSON ?? JSON()
        let version = entry["version"] as? Int ?? 0
        let entryCurrency = entry["currency"] as? String ?? ""
        guard version == storeVersion, entryCurrency == currency else {
            return [
                "version": storeVersion,
                "currency": currency,
                "trackingSince": now,
                "lastPaid": NSNull(),
                "allTimeSpend": 0.0,
                "dailySpend": JSON()
            ]
        }
        let rawTrackingSince = int64FromJson(entry["trackingSince"])
        let trackingSince = rawTrackingSince > 0 ? rawTrackingSince : now
        let lastPaid: Any = entry["lastPaid"] ?? NSNull()
        var daily: JSON = [:]
        for (key, value) in (entry["dailySpend"] as? JSON ?? JSON()).sorted(by: { $0.key < $1.key }) {
            guard localDayStartFromKey(key) != nil, let amount = number(value), amount > 0 else { continue }
            daily[key] = round2(amount)
        }
        var allTime = number(entry["allTimeSpend"]) ?? 0
        if allTime < 0 {
            allTime = daily.values.reduce(0.0) { $0 + (number($1) ?? 0) }
        }
        return [
            "version": storeVersion,
            "currency": currency,
            "trackingSince": trackingSince,
            "lastPaid": lastPaid,
            "allTimeSpend": round2(allTime),
            "dailySpend": daily
        ]
    }

    private static func addDailySpend(_ entry: inout JSON, timestamp: Int64, amount: Double) {
        guard amount > 0 else { return }
        let key = localDayKey(timestamp)
        var daily = entry["dailySpend"] as? JSON ?? JSON()
        // Same precedence trap as allTimeSpend above: without the parentheses the
        // second drop of a day was discarded (port of `Number(daily[key] || 0) + amount`).
        daily[key] = round2((number(daily[key]) ?? 0) + amount)
        entry["dailySpend"] = daily
    }

    private static func pruneDailySpend(_ daily: JSON, now: Int64) -> JSON {
        let cutoff = startOfLocalDay(now - retentionMs)
        var pruned: JSON = [:]
        for (key, amount) in daily.sorted(by: { $0.key < $1.key }) {
            guard let start = localDayStartFromKey(key), start >= cutoff else { continue }
            pruned[key] = amount
        }
        return pruned
    }

    private static func computeConsumption(_ entry: JSON, daily: JSON, now: Int64) -> Spend {
        let todayKey = localDayKey(now)
        let yesterdayKey = localDayKey(startOfLocalDay(now) - 24 * 60 * 60 * 1000)
        let weekStartKey = localDayKey(startOfLocalDay(now) - 6 * 24 * 60 * 60 * 1000)
        let month30StartKey = localDayKey(startOfLocalDay(now) - 29 * 24 * 60 * 60 * 1000)
        let monthKey = String(localDayKey(now).prefix(7))
        var weekSpend = 0.0
        var month30Spend = 0.0
        var monthSpend = 0.0
        for (key, value) in daily {
            // Day keys are zero-padded local dates ("yyyy-MM-dd"), so string
            // comparison is chronological.
            if key >= weekStartKey && key <= todayKey { weekSpend += number(value) ?? 0 }
            if key >= month30StartKey && key <= todayKey { month30Spend += number(value) ?? 0 }
            if key.hasPrefix(monthKey) { monthSpend += number(value) ?? 0 }
        }
        let trackingSince = int64FromJson(entry["trackingSince"])
        return Spend(
            todaySpend: round2(number(daily[todayKey]) ?? 0),
            yesterdaySpend: round2(number(daily[yesterdayKey]) ?? 0),
            weekSpend: round2(weekSpend),
            month30Spend: round2(month30Spend),
            monthSpend: round2(monthSpend),
            allTimeSpend: round2(number(entry["allTimeSpend"]) ?? 0),
            trackingSince: isoFromMs(trackingSince),
            monthSinceTracking: trackingSince > startOfLocalMonth(now)
        )
    }

    // MARK: - Date helpers

    private static func round2(_ value: Double) -> Double {
        return (value * 100).rounded() / 100
    }

    private static func startOfLocalDay(_ ms: Int64) -> Int64 {
        return Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(ms) / 1000)).timeIntervalSince1970 * 1000)
    }

    private static func startOfLocalMonth(_ ms: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let start = Calendar.current.date(from: comps) ?? date
        return Int64(start.timeIntervalSince1970 * 1000)
    }

    private static func localDayKey(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static func localDayStartFromKey(_ key: String) -> Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: key),
              formatter.string(from: date) == key else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func isoFromMs(_ ms: Int64) -> String {
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: - JSON io

    private static func readJson(_ path: String) -> JSON? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? JSON) ?? nil
    }

    private static func writeJson(_ document: JSON, to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func jsonEqual(_ a: JSON, _ b: JSON) -> Bool {
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return da == db
    }

    static func hashKey(_ parts: String...) -> String {
        CredentialHash.key(parts)
    }
}
