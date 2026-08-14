import Foundation

/// Local subscriptions list (port of the normalization in
/// src/shared/subscriptionDisplay.js). Local mode owns the list outright —
/// there is no hub, so writes apply straight to settings.
enum Subscriptions {
    typealias JSON = [String: Any]

    static let intervals = Set(["month", "year"])
    static let kinds = Set(["subscription", "topup"])

    // MARK: - Helpers

    static func finiteNumber(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String, s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    static func cleanText(_ value: Any?) -> String {
        return String(describing: value ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func isDateString(_ value: Any?) -> Bool {
        let text = cleanText(value)
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        guard let date = parseDate(text) else { return false }
        return date.2 >= 1 && date.2 <= daysInMonth(year: date.0, month: date.1)
    }

    static func parseDate(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        guard month >= 1, month <= 12 else { return 0 }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 0 // day 0 of next month = last day of this month
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else { return 0 }
        let day = Calendar(identifier: .gregorian).component(.day, from: date)
        return day
    }

    static func normalizeInterval(_ value: Any?) -> String {
        let interval = cleanText(value).lowercased()
        return intervals.contains(interval) ? interval : "month"
    }

    static func normalizeIntervalCount(_ value: Any?) -> Int {
        guard let count = finiteNumber(value) else { return 1 }
        return max(1, min(24, Int(count.rounded())))
    }

    static func normalizeAmountMinor(_ value: Any?) -> Int {
        guard let amount = finiteNumber(value) else { return 0 }
        return max(0, Int(amount.rounded()))
    }

    static func normalizeDateField(_ value: Any?) -> String? {
        return isDateString(value) ? cleanText(value) : nil
    }

    // MARK: - Subscription records

    static func normalizeSubscription(_ input: Any?) -> JSON? {
        guard let input = input as? JSON else { return nil }
        let provider = cleanText(input["provider"]).lowercased()
        let kindRaw = cleanText(input["kind"]).lowercased()
        let kind = kinds.contains(kindRaw) ? kindRaw : "subscription"
        let startDate = normalizeDateField(input["startDate"])
        let topUps = normalizeTopUps(input["topUps"])
        guard !provider.isEmpty else { return nil }
        // Each kind has its own anchor; a record without one derives nothing.
        if kind == "topup" {
            if topUps.isEmpty { return nil }
        } else {
            if startDate == nil { return nil }
        }

        let id = cleanText(input["id"]).isEmpty
            ? "sub_\(Int64(Date().timeIntervalSince1970 * 1000))_\(String(format: "%04x", arc4random_uniform(0xFFFF)))"
            : cleanText(input["id"])
        let bindingRaw = input["binding"] as? JSON ?? JSON()
        let currencyRaw = input["currency"] as? String ?? "USD"

        return [
            "id": id,
            "provider": provider,
            "kind": kind,
            "binding": [
                "profileName": cleanText(bindingRaw["profileName"]),
                "accountKey": cleanText(bindingRaw["accountKey"]),
                "accountEmail": cleanText(bindingRaw["accountEmail"]).lowercased()
            ],
            "planName": cleanText(input["planName"]),
            "amountMinor": normalizeAmountMinor(input["amountMinor"]),
            "currency": currencyRaw.uppercased(),
            "interval": normalizeInterval(input["interval"]),
            "intervalCount": normalizeIntervalCount(input["intervalCount"]),
            "startDate": startDate ?? "",
            "topUps": topUps,
            "autoRenew": input["autoRenew"] as? Bool ?? true,
            "nextRenewalOverride": normalizeDateField(input["nextRenewalOverride"]) ?? "",
            "endDate": normalizeDateField(input["endDate"]) ?? "",
            "note": cleanText(input["note"]),
            "updatedAt": cleanText(input["updatedAt"]).isEmpty
                ? ISO8601DateFormatter().string(from: Date())
                : cleanText(input["updatedAt"])
        ]
    }

    private static func normalizeTopUps(_ value: Any?) -> [JSON] {
        guard let list = value as? [JSON] else { return [] }
        var out: [JSON] = []
        var seen = Set<String>()
        for entry in list {
            guard let date = normalizeDateField(entry["date"]) else { continue }
            let id = cleanText(entry["id"]).isEmpty ? "topup_\(date)_\(out.count)" : cleanText(entry["id"])
            if seen.contains(id) { continue }
            seen.insert(id)
            out.append([
                "id": id,
                "date": date,
                "amountMinor": normalizeAmountMinor(entry["amountMinor"])
            ])
        }
        return out
    }

    static func normalizeSubscriptions(_ input: Any?) -> [JSON] {
        guard let list = input as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [JSON] = []
        for entry in list {
            guard let subscription = normalizeSubscription(entry), !seen.contains(cleanText(subscription["id"])) else { continue }
            seen.insert(cleanText(subscription["id"]))
            out.append(subscription)
        }
        return out
    }
}
