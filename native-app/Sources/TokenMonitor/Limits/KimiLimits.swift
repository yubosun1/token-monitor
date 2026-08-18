import Foundation

/// Kimi membership and Kimi Code quota collection. Mirrors the upstream
/// `src/shared/kimiLimits.js` behavior while keeping credentials local to the
/// native process.
enum KimiLimits {
    typealias JSON = [String: Any]

    static let codeUsagesURL = "https://api.kimi.com/coding/v1/usages"
    static let webUsagesURL = "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    static let membershipStatsURL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"

    private static let requestTimeout: TimeInterval = 12
    private static let membershipGrace: TimeInterval = 2
    private static let sessionMaxMinutes = 6 * 60
    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    struct Window: Equatable {
        let kind: String
        let label: String
        let usedPercent: Double
        let resetsAt: String?
        let windowMinutes: Int?
        let detail: String

        init(
            kind: String,
            label: String,
            usedPercent: Double,
            resetsAt: String? = nil,
            windowMinutes: Int? = nil,
            detail: String = ""
        ) {
            self.kind = kind
            self.label = label
            self.usedPercent = clamp(usedPercent)
            self.resetsAt = resetsAt
            self.windowMinutes = windowMinutes
            self.detail = detail
        }
    }

    private struct ParsedLimitEntry {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: String?
    }

    private enum ProbeOutcome {
        case value(JSON)
        case failed(String)
        case timedOut
    }

    // MARK: - Public entry points

    static func normalizedAPIKey(_ value: String) -> String {
        cleanSecret(value)
    }

    static func normalizedWebAccessToken(_ value: String) -> String {
        normalizeWebToken(value)
    }

    /// Kimi's browser and CLI credentials are JWTs today. Treat an explicitly
    /// expired JWT as unusable before issuing a request, while still allowing
    /// opaque credentials if the service changes its token format.
    static func isJWTExpired(_ token: String, at date: Date = Date()) -> Bool {
        guard let expiration = jwtExpiration(token) else { return false }
        return expiration.timeIntervalSince1970 <= date.timeIntervalSince1970
    }

    static func fetchLimits(apiKey rawAPIKey: String, webAccessToken rawWebToken: String, nowMs: Int64) async -> JSON {
        let apiKey = normalizedAPIKey(rawAPIKey)
        let webToken = normalizedWebAccessToken(rawWebToken)
        let updatedAt = isoDate(Date(timeIntervalSince1970: Double(nowMs) / 1000))

        guard !apiKey.isEmpty || !webToken.isEmpty else {
            return providerRecord(
                accountKey: "", source: "api", status: "notConfigured", updatedAt: updatedAt, windows: []
            )
        }

        var errors: [String] = []
        var webWindows: [Window] = []
        var codeWindows: [Window] = []

        if !webToken.isEmpty, !isJWTExpired(webToken) {
            let web = await fetchWebWindows(token: webToken)
            webWindows = web.windows
            errors.append(contentsOf: web.errors)
        } else if !webToken.isEmpty {
            errors.append("unauthorized")
        }

        let missingCodeWindow = !webWindows.contains(where: { $0.kind == "session" })
            || !webWindows.contains(where: { $0.kind == "weekly" })
        if !apiKey.isEmpty && (webToken.isEmpty || missingCodeWindow) {
            let code = await fetchCodeWindows(key: apiKey)
            switch code {
            case .value(let body):
                codeWindows = parseUsage(body)
            case .failed(let status):
                errors.append(status)
            case .timedOut:
                errors.append("unavailable")
            }
        }

        let windows = mergeWindows(webWindows, codeWindows)
        let source = webWindows.isEmpty ? "api" : "web"
        // A configured web session remains the account identity when a
        // transient web failure leaves this refresh using API fallback data.
        let accountSecret = !webToken.isEmpty ? webToken : apiKey
        return providerRecord(
            accountKey: accountSecret.isEmpty ? "" : CredentialHash.key(["kimi", accountSecret]),
            source: source,
            status: windows.isEmpty ? failureStatus(errors) : "ok",
            updatedAt: updatedAt,
            windows: windows
        )
    }

    /// Parses Kimi Code's `/usages` payload and compatible proxy variants.
    static func parseUsage(_ rawBody: Any) -> [Window] {
        let body = unwrapData(rawBody)
        var windows: [Window] = []
        var seenKinds = Set<String>()

        // FEATURE_CODING's top-level detail is the weekly figure the Kimi
        // console presents. It must win over an optional 7-day limit entry.
        if let usage = body["usage"] as? JSON,
           let usedPercent = usedPercent(from: usage) {
            let rawName = pickString(usage, keys: ["name", "label", "title"])
            let kind = classifyUsageName(rawName)
            let reset = pickRaw(usage, keys: ["reset_at", "resetAt", "resetTime", "reset_time"])
            windows.append(Window(
                kind: kind,
                label: safeLabel(rawName, fallback: kindLabel(kind)),
                usedPercent: usedPercent,
                resetsAt: isoTimestamp(reset),
                windowMinutes: kind == "weekly" ? weeklyWindowMinutes : nil
            ))
            seenKinds.insert(kind)
        }

        let entries = limitEntries(body)
        let classified: [(entry: ParsedLimitEntry, kind: String)]
        if entries.count == 2 {
            classified = classifyPair(entries)
        } else {
            classified = entries.map { ($0, classifyWindow(minutes: $0.windowMinutes)) }
        }

        for item in classified where !seenKinds.contains(item.kind) {
            seenKinds.insert(item.kind)
            windows.append(Window(
                kind: item.kind,
                label: kindLabel(item.kind),
                usedPercent: item.entry.usedPercent,
                resetsAt: item.entry.resetsAt,
                windowMinutes: item.entry.windowMinutes
            ))
        }
        return windows
    }

    /// Parses Kimi web GetUsages response for the FEATURE_CODING scope.
    static func parseWebUsage(_ rawBody: Any) -> [Window] {
        let body = unwrapData(rawBody)
        let usages = body["usages"] as? [Any] ?? []
        guard let coding = usages.compactMap({ $0 as? JSON }).first(where: {
            String(describing: $0["scope"] ?? "") == "FEATURE_CODING"
        }) else { return [] }
        return parseUsage(["usage": coding["detail"] ?? [:], "limits": coding["limits"] ?? []])
    }

    /// Parses membership ratios, including the monthly pool shared by Kimi and
    /// Kimi Code. Ratios are 0-1 fractions, not already-scaled percentages.
    static func parseMembershipStats(_ rawBody: Any) -> [Window] {
        let body = unwrapData(rawBody)
        var windows: [Window] = []

        if let session = membershipRateWindow(
            body,
            keys: ["ratelimitCode5h", "ratelimit_code_5h", "ratelimit5h", "ratelimit_5h"],
            kind: "session",
            label: "5-hour",
            windowMinutes: sessionWindowMinutes
        ) {
            windows.append(session)
        }
        if let weekly = membershipRateWindow(
            body,
            keys: ["ratelimitCode7d", "ratelimit_code_7d", "ratelimit7d", "ratelimit_7d"],
            kind: "weekly",
            label: "Weekly",
            windowMinutes: weeklyWindowMinutes
        ) {
            windows.append(weekly)
        }

        guard let balance = objectAt(body, keys: ["subscriptionBalance", "subscription_balance"]) else {
            return windows
        }
        let feature = String(describing: balance["feature"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let type = String(describing: balance["type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (feature.isEmpty || feature == "FEATURE_OMNI"),
              (type.isEmpty || type == "SUBSCRIPTION"),
              let rawUsedPercent = ratioPercent(pickRaw(balance, keys: ["amountUsedRatio", "amount_used_ratio"])) else {
            return windows
        }

        let rawCodePercent = ratioPercent(pickRaw(balance, keys: ["kimiCodeUsedRatio", "kimi_code_used_ratio"]))
        let detail: String
        if let rawCodePercent {
            let safeCodePercent = min(rawUsedPercent, rawCodePercent)
            detail = "Kimi \(formatPercent(max(0, rawUsedPercent - safeCodePercent)))% | Code \(formatPercent(safeCodePercent))%"
        } else {
            detail = ""
        }
        windows.append(Window(
            kind: "billing",
            label: "Monthly",
            usedPercent: rawUsedPercent,
            resetsAt: isoTimestamp(pickRaw(balance, keys: ["expireTime", "expire_time"])),
            detail: detail
        ))
        return windows
    }

    // MARK: - Fetching

    private static func fetchWebWindows(token: String) async -> (windows: [Window], errors: [String]) {
        let headers = webHeaders(token)
        let membershipRequest: URLRequest = {
            var value = request(url: membershipStatsURL, method: "POST", headers: headers, body: Data("{}".utf8))
            value.timeoutInterval = membershipGrace
            return value
        }()
        let usageRequest = request(
            url: webUsagesURL,
            method: "POST",
            headers: headers,
            body: try? JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        )

        async let membership = fetchMembershipWithinGrace(membershipRequest)
        async let usage = fetchOutcome(usageRequest)
        let membershipOutcome = await membership
        let usageOutcome = await usage

        let membershipWindows: [Window]
        let usageWindows: [Window]
        var errors: [String] = []
        switch membershipOutcome {
        case .value(let body): membershipWindows = parseMembershipStats(body)
        case .failed(let status): membershipWindows = []; errors.append(status)
        case .timedOut: membershipWindows = []
        }
        switch usageOutcome {
        case .value(let body): usageWindows = parseWebUsage(body)
        case .failed(let status): usageWindows = []; errors.append(status)
        case .timedOut: usageWindows = []; errors.append("unavailable")
        }

        // Usage is authoritative for 5-hour/weekly quota. Membership only
        // enriches it with the monthly shared pool and missing windows.
        return (mergeWindows(usageWindows, membershipWindows), errors)
    }

    private static func fetchCodeWindows(key: String) async -> ProbeOutcome {
        let request = request(
            url: codeUsagesURL,
            method: "GET",
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        )
        return await fetchOutcome(request)
    }

    private static func fetchMembershipWithinGrace(_ request: URLRequest) async -> ProbeOutcome {
        await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask { await fetchOutcome(request) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(membershipGrace * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    private static func fetchOutcome(_ request: URLRequest) async -> ProbeOutcome {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                return .failed(statusForHTTP(statusCode))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else {
                return .failed("unavailable")
            }
            return .value(json)
        } catch is CancellationError {
            return .timedOut
        } catch {
            return .failed("unavailable")
        }
    }

    private static func request(url: String, method: String, headers: [String: String], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func webHeaders(_ token: String) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Cookie": "kimi-auth=\(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Origin": "https://www.kimi.com",
            "Referer": "https://www.kimi.com/code/console",
            "connect-protocol-version": "1",
            "x-language": "en-US",
            "x-msh-platform": "web",
            "User-Agent": browserUserAgent,
            "r-timezone": TimeZone.current.identifier
        ]
        for (name, value) in jwtSessionHeaders(token) { headers[name] = value }
        return headers
    }

    private static func jwtSessionHeaders(_ token: String) -> [String: String] {
        guard let payload = jwtPayload(token) else { return [:] }
        var headers: [String: String] = [:]
        if let value = payload["device_id"], !String(describing: value).isEmpty { headers["x-msh-device-id"] = String(describing: value) }
        if let value = payload["ssid"], !String(describing: value).isEmpty { headers["x-msh-session-id"] = String(describing: value) }
        if let value = payload["sub"], !String(describing: value).isEmpty { headers["x-traffic-id"] = String(describing: value) }
        return headers
    }

    private static func jwtExpiration(_ token: String) -> Date? {
        guard let expiration = number(jwtPayload(token)?["exp"]), expiration.isFinite else { return nil }
        return Date(timeIntervalSince1970: expiration)
    }

    private static func jwtPayload(_ token: String) -> JSON? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }

    // MARK: - Response parsing

    private static func unwrapData(_ rawBody: Any) -> JSON {
        guard let body = rawBody as? JSON else { return [:] }
        return body["data"] as? JSON ?? body
    }

    private static func limitEntries(_ body: JSON) -> [ParsedLimitEntry] {
        let keys = ["limits", "limitInfos", "limit_infos", "rateLimits", "rate_limits", "windows"]
        let rawEntries = firstArray(body, keys: keys)
        return rawEntries.compactMap { raw in
            guard let entry = raw as? JSON else { return nil }
            let detail = firstObject(entry, keys: ["detail", "usage", "quota"])
            guard let usedPercent = usedPercent(from: detail) else { return nil }
            let window = firstObject(entry, keys: ["window", "period", "rateLimit", "rate_limit", "timeWindow", "time_window"])
            let duration = pickNumber(window, keys: ["duration", "windowDuration", "window_duration", "size", "value", "length"])
            let unit = pickString(window, keys: ["timeUnit", "time_unit", "unit", "windowUnit", "window_unit"])
            let reset = pickRaw(detail, keys: ["resetTime", "reset_time", "resetAt", "reset_at"])
                ?? pickRaw(window, keys: ["resetTime", "reset_time", "resetAt", "reset_at"])
            return ParsedLimitEntry(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes(duration: duration, unit: unit),
                resetsAt: isoTimestamp(reset)
            )
        }
    }

    private static func classifyPair(_ entries: [ParsedLimitEntry]) -> [(entry: ParsedLimitEntry, kind: String)] {
        let first = entries[0]
        let second = entries[1]
        if let firstMinutes = first.windowMinutes,
           let secondMinutes = second.windowMinutes,
           classifyWindow(minutes: firstMinutes) != classifyWindow(minutes: secondMinutes) {
            return [(first, classifyWindow(minutes: firstMinutes)), (second, classifyWindow(minutes: secondMinutes))]
        }
        let sessionFirst: Bool
        if let firstMinutes = first.windowMinutes, let secondMinutes = second.windowMinutes {
            sessionFirst = firstMinutes <= secondMinutes
        } else {
            sessionFirst = first.windowMinutes != nil || second.windowMinutes == nil
        }
        return sessionFirst ? [(first, "session"), (second, "weekly")] : [(second, "session"), (first, "weekly")]
    }

    private static func membershipRateWindow(
        _ body: JSON,
        keys: [String],
        kind: String,
        label: String,
        windowMinutes: Int
    ) -> Window? {
        guard let source = objectAt(body, keys: keys), (source["enabled"] as? Bool) != false,
              let rawPercent = ratioPercent(pickRaw(source, keys: ["ratio", "usedRatio", "used_ratio"])) else {
            return nil
        }
        return Window(
            kind: kind,
            label: label,
            usedPercent: rawPercent,
            resetsAt: isoTimestamp(pickRaw(source, keys: ["resetTime", "reset_time", "resetAt", "reset_at"])),
            windowMinutes: windowMinutes
        )
    }

    private static func usedPercent(from detail: JSON) -> Double? {
        let used = pickNumber(detail, keys: ["used", "usedValue", "used_value", "usedAmount", "used_amount", "currentValue", "current_value", "consumed", "consumedValue", "consumed_value"])
        let limit = pickNumber(detail, keys: ["limit", "limitValue", "limit_value", "total", "totalValue", "total_value", "quota", "quotaValue", "quota_value", "max", "maxValue", "max_value"])
        if let used, let limit, limit > 0 { return clamp((used / limit) * 100) }
        let remaining = pickNumber(detail, keys: ["remaining", "remainingValue", "remaining_value"])
        if let limit, let remaining, limit > 0 { return clamp(((limit - remaining) / limit) * 100) }
        if let percent = pickNumber(detail, keys: ["percent", "percentage", "usedPercent", "used_percent", "usagePercentage", "usage_percentage"]) {
            return clamp(percent)
        }
        return nil
    }

    private static func firstArray(_ body: JSON, keys: [String]) -> [Any] {
        for key in keys {
            if let value = body[key] as? [Any] { return value }
        }
        return []
    }

    private static func firstObject(_ body: JSON, keys: [String]) -> JSON {
        for key in keys {
            if let value = body[key] as? JSON { return value }
        }
        return body
    }

    private static func objectAt(_ body: JSON, keys: [String]) -> JSON? {
        for key in keys {
            if let value = body[key] as? JSON { return value }
        }
        return nil
    }

    private static func pickRaw(_ body: JSON, keys: [String]) -> Any? {
        for key in keys {
            guard let value = body[key], !(value is NSNull) else { continue }
            if let string = value as? String, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return value
        }
        return nil
    }

    private static func pickNumber(_ body: JSON, keys: [String]) -> Double? {
        for key in keys {
            if let number = number(body[key]) { return number }
        }
        return nil
    }

    private static func pickString(_ body: JSON, keys: [String]) -> String {
        for key in keys {
            if let value = body[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(number is Bool) {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let result = Double(trimmed), result.isFinite { return result }
        }
        return nil
    }

    private static func windowMinutes(duration: Double?, unit: String) -> Int? {
        guard let duration, duration > 0 else { return nil }
        let uppercase = unit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let minutes: Double
        if uppercase.contains("MIN") { minutes = duration }
        else if uppercase.contains("HOUR") { minutes = duration * 60 }
        else if uppercase.contains("DAY") { minutes = duration * 24 * 60 }
        else if uppercase.contains("WEEK") { minutes = duration * 7 * 24 * 60 }
        else if uppercase.contains("MONTH") { minutes = duration * 30 * 24 * 60 }
        else { return nil }
        guard minutes.isFinite, minutes <= Double(Int.max) else { return nil }
        return Int(minutes.rounded())
    }

    private static func classifyWindow(minutes: Int?) -> String {
        guard let minutes, minutes <= sessionMaxMinutes else { return "weekly" }
        return "session"
    }

    private static func classifyUsageName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("hour") || lower.contains("5h")
            || lower.contains("\u{5C0F}\u{65F6}") || lower.contains("\u{6642}\u{9593}") || lower.contains("\u{C2DC}\u{AC04}") {
            return "session"
        }
        return "weekly"
    }

    private static func kindLabel(_ kind: String) -> String {
        kind == "session" ? "5-hour" : "Weekly"
    }

    private static func ratioPercent(_ value: Any?) -> Double? {
        guard let ratio = number(value), ratio >= 0 else { return nil }
        return ratio * 100
    }

    // MARK: - Wire conversion and helpers

    private static func providerRecord(accountKey: String, source: String, status: String, updatedAt: String, windows: [Window]) -> JSON {
        return [
            "provider": "kimi",
            "accountKey": accountKey,
            "accountLabel": "",
            "planLabel": "",
            "accountName": "",
            "accountEmail": "",
            "workspaceKind": "",
            "status": status,
            "source": source,
            "sourceDetail": "managed",
            "updatedAt": updatedAt,
            "windows": windows.map(windowRecord),
            "balanceUsd": NSNull(),
            "balance": NSNull(),
            "resetCredits": NSNull(),
            "region": ""
        ]
    }

    private static func windowRecord(_ window: Window) -> JSON {
        var record: JSON = [
            "kind": window.kind,
            "label": window.label,
            "usedPercent": clamp(window.usedPercent),
            "remainingPercent": clamp(100 - window.usedPercent),
            "showMeter": true,
            "detail": window.detail
        ]
        if let resetsAt = window.resetsAt { record["resetsAt"] = resetsAt }
        if let windowMinutes = window.windowMinutes { record["windowMinutes"] = windowMinutes }
        return record
    }

    private static func mergeWindows(_ groups: [Window]...) -> [Window] {
        var byKind: [String: Window] = [:]
        for group in groups {
            for window in group where byKind[window.kind] == nil {
                byKind[window.kind] = window
            }
        }
        return ["session", "weekly", "billing"].compactMap { byKind[$0] }
    }

    private static func failureStatus(_ errors: [String]) -> String {
        if errors.contains("unauthorized") { return "unauthorized" }
        if errors.contains("sourceRateLimited") { return "sourceRateLimited" }
        return "unavailable"
    }

    private static func statusForHTTP(_ status: Int) -> String {
        if status == 401 || status == 403 { return "unauthorized" }
        if status == 429 { return "sourceRateLimited" }
        return "unavailable"
    }

    private static func cleanSecret(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func normalizeWebToken(_ value: String) -> String {
        var value = cleanSecret(value)
        guard !value.isEmpty else { return "" }
        value = value.replacingOccurrences(of: "^authorization\\s*:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "^bearer\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "(?:^|[;\\s])kimi-auth=([^;\\s'\\\"]+)", options: [.regularExpression, .caseInsensitive]) {
            let matched = String(value[range])
            if let equals = matched.firstIndex(of: "=") {
                return String(matched[matched.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let lower = value.lowercased()
        if lower.hasPrefix("cookie:") || lower.hasPrefix("curl ") || value.contains(";") { return "" }
        return value
    }

    private static func isoTimestamp(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let seconds = number(value) {
            let normalized = seconds < 20_000_000_000 ? seconds : seconds / 1000
            return normalized.isFinite ? isoDate(Date(timeIntervalSince1970: normalized)) : nil
        }
        guard let text = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
            return isoDate(date)
        }
        return nil
    }

    private static func isoDate(_ date: Date) -> String {
        DateFormatUtil.iso8601.string(from: date)
    }

    private static func safeLabel(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 +._/-")
        let filtered = String(value.unicodeScalars.filter { allowed.contains($0) })
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filtered.isEmpty, filtered.count <= 32 else { return fallback }
        return filtered
    }

    private static func formatPercent(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.contains(".") && text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private static func clamp(_ value: Double) -> Double {
        max(0, min(100, value))
    }
}
