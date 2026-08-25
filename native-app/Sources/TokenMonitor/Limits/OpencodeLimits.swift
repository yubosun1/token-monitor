import Foundation
import CryptoKit

/// OpenCode (opencode.ai) limit collection using official API key authentication.
///
/// The wire shape produced here is the array returned by `normalizeLimitProvider`
/// (input object already assembled), so callers can hand it straight to the hub
/// ingest path. Only Foundation + CryptoKit are used; the async surface is kept to
/// plain Swift 5 `URLSession`-based await calls.
enum OpencodeLimits {
    typealias JSON = [String: Any]

    struct Profile {
        let name: String
        let apiKey: String
        let enabled: Bool

        init(name: String, apiKey: String = "", enabled: Bool = true) {
            self.name = name
            self.apiKey = apiKey
            self.enabled = enabled
        }

        init(name: String, cookie: String, apiKey: String = "", enabled: Bool = true) {
            self.name = name
            self.apiKey = apiKey.isEmpty ? cookie : apiKey
            self.enabled = enabled
        }
    }

    // MARK: - Public API

    /// Returns the opencode provider wire dictionaries (same shape as
    /// `normalizeLimitProvider` output). Directly queries OpenCode's official
    /// API with configured API key(s) or auto-detected ambient credentials.
    static func fetchProviders(
        profiles: [Profile],
        nowMs: Int64,
        opencodeLocalLimitsEnabled: Bool
    ) async -> [JSON] {
        let now = Int64(truncatingIfNeeded: nowMs)
        let updatedAt = nowIso(now)
        let env = ProcessInfo.processInfo.environment

        let ambientKey = readGoApiKey(env)

        var accounts: [(name: String, apiKey: String, ambient: Bool)] = []
        for p in profiles where p.enabled && !p.apiKey.isEmpty {
            accounts.append((p.name, p.apiKey, false))
        }
        let envKey = cleanSecret(env["TOKEN_MONITOR_OPENCODE_API_KEY"] ?? env["OPENCODE_API_KEY"] ?? "")
        if !envKey.isEmpty && !accounts.contains(where: { $0.apiKey == envKey }) {
            accounts.append(("default (env)", envKey, false))
        }

        let ambientEnabled = parseAmbientEnv(env["TOKEN_MONITOR_OPENCODE_AMBIENT"], default: true)
        let ambientClaimed = accounts.contains { $0.apiKey == ambientKey }
        if !ambientKey.isEmpty && accounts.isEmpty && !ambientClaimed && ambientEnabled {
            accounts.append((opencodeAmbientAccountName, ambientKey, true))
        }

        let multiAccountMode = accounts.count > 1

        // ── Single account mode ─────────────────────────────────────────────
        if !multiAccountMode {
            let goLocal = opencodeLocalLimitsEnabled
                ? collectGo(env: env, nowMs: now)
                : (status: "notConfigured", windows: [] as [Window], identity: "")
            let primary = accounts.first
            let primaryApiKey = primary?.apiKey ?? ""
            var goApi: (status: String, windows: [Window], identity: String, entitled: Bool)? = nil

            if !primaryApiKey.isEmpty {
                do {
                    goApi = try await withTimeout(15) {
                        await collectGoApi(env: env, apiKey: primaryApiKey, nowMs: now)
                    }
                } catch {
                    goApi = nil
                }
            }

            var windows: [Window] = []
            var status = "notConfigured"
            var source = "local"
            var accountLabel = primary?.name.isEmpty == false ? primary!.name : "Go"
            var accountKey = ""

            if let api = goApi, api.status == "ok", !api.windows.isEmpty {
                windows.append(contentsOf: api.windows.map { $0.withSource("web") })
                status = "ok"
                source = "api"
                accountLabel = primary?.name.isEmpty == false ? primary!.name : "Go"
                accountKey = hashKey("opencode", api.identity.isEmpty ? "go-api" : api.identity)
            } else if goLocal.status == "ok" && goApi?.entitled != false {
                windows.append(contentsOf: goLocal.windows.map { $0.withSource("local") })
                status = "ok"
                accountLabel = "Go"
                accountKey = hashKey("opencode", goLocal.identity.isEmpty ? "go" : goLocal.identity)
            } else if goLocal.status == "unavailable" && goApi?.entitled != false {
                status = "unavailable"
            } else if let api = goApi, opencodeRemoteFailStatuses.contains(api.status) {
                status = api.status
                source = "api"
            }

            if accountKey.isEmpty, let api = goApi, !api.identity.isEmpty {
                accountKey = hashKey("opencode", api.identity)
            }

            return [normalizeLimitProvider(ProviderInput(
                provider: "opencode",
                accountKey: accountKey,
                webAccountKey: "",
                accountKeyAliases: [],
                accountLabel: accountLabel,
                accountName: primary?.name ?? "",
                status: status,
                source: source,
                sourceDetail: "managed",
                updatedAt: updatedAt,
                windows: windows,
                balanceUsd: nil
            ))].compactMap { $0 }
        }

        // ── Multi-account mode ──────────────────────────────────────────────
        var providers: [JSON] = []
        let results: [(index: Int, provider: JSON?)] = await withTaskGroup(
            of: (index: Int, provider: JSON?).self
        ) { group in
            for (idx, acc) in accounts.enumerated() {
                group.addTask {
                    let provider = await fetchSingleOpenCodeProfile(
                        name: acc.name, apiKey: acc.apiKey, nowMs: now, updatedAt: updatedAt
                    )
                    return (idx, provider)
                }
            }
            var collected: [(index: Int, provider: JSON?)] = []
            for await r in group { collected.append(r) }
            return collected.sorted { a, b in a.index < b.index }
        }
        for r in results { if let p = r.provider { providers.append(p) } }

        if providers.isEmpty {
            providers.append(normalizeLimitProvider(ProviderInput(
                provider: "opencode", accountKey: "", accountLabel: "",
                status: "notConfigured", source: "local", updatedAt: updatedAt, windows: []
            ))!)
        }
        return providers
    }

    // MARK: - Single profile fetch

    private static func fetchSingleOpenCodeProfile(
        name: String, apiKey: String, nowMs: Int64, updatedAt: String
    ) async -> JSON? {
        let env = ProcessInfo.processInfo.environment
        let goApi: (status: String, windows: [Window], identity: String, entitled: Bool)?
        do {
            goApi = try await withTimeout(15) {
                await collectGoApi(env: env, apiKey: apiKey, nowMs: nowMs)
            }
        } catch {
            goApi = nil
        }

        let keyIdentity = apiKey.isEmpty ? "" : hashKey("opencode", goApiIdentity(apiKey))
        if let api = goApi {
            var windows: [Window] = []
            var status = api.status
            var planLabel = ""
            let source = "api"

            if api.status == "ok", !api.windows.isEmpty {
                windows.append(contentsOf: api.windows.map { $0.withSource("web") })
                status = "ok"
                planLabel = "Go"
            }

            return normalizeLimitProvider(ProviderInput(
                provider: "opencode",
                accountKey: keyIdentity,
                webAccountKey: "",
                accountKeyAliases: [],
                accountLabel: name,
                planLabel: planLabel,
                accountName: name,
                status: status,
                source: source,
                sourceDetail: "managed",
                updatedAt: updatedAt,
                windows: windows,
                balanceUsd: nil
            ))
        }

        return normalizeLimitProvider(ProviderInput(
            provider: "opencode",
            accountKey: keyIdentity,
            accountLabel: name,
            planLabel: "",
            accountName: name,
            status: "unavailable",
            source: "api",
            sourceDetail: "managed",
            updatedAt: updatedAt,
            windows: [],
            balanceUsd: nil
        ))
    }

    // MARK: - Window model

    struct Window {
        var kind: String
        var usedPercent: Double?
        var used: Double?
        var limit: Double?
        var resetsAt: Date?
        var windowMinutes: Int
        var metric: String? = nil
        var source: String? = nil
        var label: String? = nil

        func withSource(_ value: String) -> Window {
            var w = self
            w.source = value
            return w
        }
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func clampPct(_ v: Double) -> Double { max(0, min(100, v)) }

    private static func asNum(_ value: Any) -> Double? {
        if let n = value as? Double { return n.isFinite ? n : nil }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            if let n = Double(t), n.isFinite { return n }
        }
        return nil
    }

    private enum FetchError: Error { case timeout }

    private static func withTimeout<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw FetchError.timeout
            }
            guard let first = try await group.next() else { throw FetchError.timeout }
            group.cancelAll()
            return first
        }
    }

    // MARK: - opencodeGoApi.js ports (official Go usage API)

    private static let goUsageURL = "https://opencode.ai/zen/go/v1/usage"
    private static let goAuthProviderID = "opencode-go"
    private static let opencodeAmbientAccountName = "Auto-detected"
    private static let opencodeRemoteFailStatuses: Set<String> = ["unauthorized", "sourceRateLimited", "unavailable"]

    /// [payload key, window kind, windowMinutes]. Mirrors opencodeWeb's
    /// GO_WINDOW_MINUTES so a window keeps the same shape whichever source
    /// produced it. 300 stays an assumption (server-configured, not in payload).
    private static let goWindowMap: [(payloadKey: String, kind: String, windowMinutes: Int)] = [
        ("rolling", "session", 300),
        ("weekly", "weekly", 10080),
        ("monthly", "monthly", 43200)
    ]

    private static func cleanSecret(_ value: String) -> String {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private static func parseAmbientEnv(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return defaultValue }
        if v == "1" || v == "true" || v == "yes" || v == "on" { return true }
        if v == "0" || v == "false" || v == "no" || v == "off" { return false }
        return defaultValue
    }

    private static func goAuthPath(_ env: [String: String]) -> String {
        return (resolveDataDir(env) as NSString).appendingPathComponent("auth.json")
    }

    /// The variable is tried first and, when it parses, replaces the file rather
    /// than merging with it; unparsable content falls through to the file. The
    /// file is schema-checked (`type === 'api'`, `key` is a String); the
    /// variable is not — upstream's own asymmetry.
    private static func isGoApiCredential(_ entry: Any?) -> Bool {
        guard let dict = entry as? JSON,
              (dict["type"] as? String) == "api",
              let key = dict["key"] as? String,
              !key.isEmpty else { return false }
        return true
    }

    /// Returns "" when no key is available — the caller treats that as notConfigured.
    private static func readGoApiKey(_ env: [String: String]) -> String {
        let explicit = cleanSecret(env["TOKEN_MONITOR_OPENCODE_API_KEY"] ?? "")
        if !explicit.isEmpty { return explicit }

        let inline = env["OPENCODE_AUTH_CONTENT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !inline.isEmpty {
            if let data = inline.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? JSON {
                return cleanSecret((parsed[goAuthProviderID] as? JSON)?["key"] as? String ?? "")
            }
            // fall through to the file, as upstream does
        }

        guard let raw = try? String(contentsOfFile: goAuthPath(env), encoding: .utf8),
              let data = raw.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return "" }
        let entry = parsed[goAuthProviderID]
        guard isGoApiCredential(entry) else { return "" }
        return cleanSecret((entry as? JSON)?["key"] as? String ?? "")
    }

    /// The endpoint returns no workspace id, so the key itself is the identity.
    private static func goApiIdentity(_ apiKey: String) -> String {
        return "go-api:\(sha256Hex(apiKey))"
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func goWindowPercent(_ entry: Any?) -> Double? {
        guard let dict = entry as? JSON else { return nil }
        if let raw = asNum(dict["percent"] ?? NSNull()) {
            return max(0, min(100, raw))
        }
        // Upstream already reports 100 alongside `rate-limited`; the fallback
        // only covers a payload that drops the number but keeps the status.
        return String(describing: dict["status"] ?? "") == "rate-limited" ? 100 : nil
    }

    private static func goResetsAt(_ entry: Any?) -> Date? {
        guard let dict = entry as? JSON else { return nil }
        let raw = String(describing: dict["resetsAt"] ?? "")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: raw) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Parses the official usage payload into windows. Every Go account has
    /// session and weekly; a payload missing either is an upstream shape change,
    /// so report nothing rather than a half-populated card.
    private static func parseGoUsagePayload(_ payload: JSON, nowMs: Int64) -> [Window] {
        guard let usage = payload["usage"] as? JSON else { return [] }
        var windows: [Window] = []
        for (payloadKey, kind, windowMinutes) in goWindowMap {
            guard let entry = usage[payloadKey], let usedPercent = goWindowPercent(entry) else { continue }
            windows.append(Window(
                kind: kind,
                usedPercent: usedPercent,
                used: nil,
                limit: nil,
                resetsAt: goResetsAt(entry),
                windowMinutes: windowMinutes
            ))
        }
        let kinds = Set(windows.map { $0.kind })
        guard kinds.contains("session") && kinds.contains("weekly") else { return [] }
        return windows
    }

    private static func fetchGoApi(apiKey: String, nowMs: Int64) async -> (status: String, windows: [Window], entitled: Bool) {
        let key = cleanSecret(apiKey)
        guard !key.isEmpty else { return ("notConfigured", [], true) }

        var request = URLRequest(url: URL(string: goUsageURL)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let status: Int
        let payload: JSON?
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            payload = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        } catch {
            return ("unavailable", [], true)
        }

        // 403 + EntitlementError = the key is valid but the account has no Go
        // subscription: not a failure, so it falls through to the cookie
        // quietly. `entitled: false` marks it as the server's authoritative
        // answer so the local estimate cannot take over from cancelled-subscription rows.
        if status == 403 {
            if (payload?["error"] as? JSON)?["type"] as? String == "EntitlementError" {
                return ("notConfigured", [], false)
            }
            return ("unavailable", [], true)
        }
        if status == 401 { return ("unauthorized", [], true) }
        if status == 429 { return ("sourceRateLimited", [], true) }
        guard status == 200, let payload else { return ("unavailable", [], true) }
        let windows = parseGoUsagePayload(payload, nowMs: nowMs)
        if windows.isEmpty { return ("unavailable", [], true) }
        return ("ok", windows, true)
    }

    /// Composed entry point: resolve the key and probe. An explicit `apiKey` of
    /// "" suppresses the ambient lookup entirely ("this account has no API
    /// credential of its own").
    private static func collectGoApi(
        env: [String: String], apiKey: String?, nowMs: Int64
    ) async -> (status: String, windows: [Window], identity: String, entitled: Bool) {
        let key = cleanSecret(apiKey ?? readGoApiKey(env))
        guard !key.isEmpty else { return ("notConfigured", [], "", true) }
        let result = await fetchGoApi(apiKey: key, nowMs: nowMs)
        // Identity comes from the key, not the probe result, so an account keeps
        // one identity across a failed refresh.
        return (result.status, result.windows, goApiIdentity(key), result.entitled)
    }

    // MARK: - opencodeLimits.js ports (collectGo)

    private static let sessionMs: Int64 = 5 * 60 * 60 * 1000
    private static let weekMs: Int64 = 7 * 24 * 60 * 60 * 1000
    private static let defaultGoLimits: [String: Double] = ["session": 12, "weekly": 30, "monthly": 60]

    private static func goLimits(_ env: [String: String]) -> [String: Double] {
        let raw = (env["TOKEN_MONITOR_OPENCODE_GO_LIMITS"] ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return defaultGoLimits }
        let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3, parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! > 0 }) {
            return ["session": parts[0]!, "weekly": parts[1]!, "monthly": parts[2]!]
        }
        return defaultGoLimits
    }

    private static func weekStartMs(_ nowMs: Int64) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let day = cal.component(.weekday, from: d) // 1=Sun..7=Sat
        let sinceMonday = day == 1 ? 6 : day - 2
        let startOfDay = cal.startOfDay(for: d)
        return Int64(startOfDay.timeIntervalSince1970 * 1000) - Int64(sinceMonday) * 86_400_000
    }

    private static func monthBoundsMs(_ nowMs: Int64, anchorMs: Int64?) -> (startMs: Int64, endMs: Int64) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        if anchorMs == nil {
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps)!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
        }
        let a = Date(timeIntervalSince1970: Double(anchorMs!) / 1000)
        let ac = cal.dateComponents([.day, .hour, .minute, .second], from: a)
        func anchored(_ year: Int, _ month: Int) -> Int64 {
            var c = DateComponents()
            c.timeZone = TimeZone(identifier: "UTC")
            c.year = year; c.month = month; c.day = ac.day
            c.hour = ac.hour; c.minute = ac.minute; c.second = ac.second
            // Nanoseconds dropped (JS uses milliseconds); acceptable precision loss.
            var lastDayCal = Calendar(identifier: .gregorian)
            lastDayCal.timeZone = TimeZone(identifier: "UTC")!
            var next = DateComponents()
            next.timeZone = TimeZone(identifier: "UTC"); next.year = year; next.month = month + 1; next.day = 0
            let lastDayDate = lastDayCal.date(from: next)!
            let lastDay = lastDayCal.component(.day, from: lastDayDate)
            c.day = min(ac.day ?? 1, lastDay)
            return Int64(cal.date(from: c)!.timeIntervalSince1970 * 1000)
        }
        var year = cal.component(.year, from: now)
        var month = cal.component(.month, from: now)
        var startMs = anchored(year, month)
        if startMs > nowMs {
            month -= 1
            if month < 1 { month = 12; year -= 1 }
            startMs = anchored(year, month)
        }
        var ey = year
        var em = month + 1
        if em > 12 { em = 1; ey += 1 }
        return (startMs, anchored(ey, em))
    }

    private static func sumCost(_ rows: [(createdMs: Int64, cost: Double)], _ startMs: Int64, _ endMs: Int64) -> Double {
        var total = 0.0
        for r in rows where r.createdMs >= startMs && r.createdMs < endMs {
            total += r.cost
        }
        return total
    }

    private static func resolveDataDir(_ env: [String: String]) -> String {
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        let home = env["HOME"] ?? env["USERPROFILE"] ?? NSHomeDirectory()
        var p = (home as NSString).appendingPathComponent(".local")
        p = (p as NSString).appendingPathComponent("share")
        p = (p as NSString).appendingPathComponent("opencode")
        return p
    }

    private static func isOpenCodeDbFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".db") else { return false }
        let stem = String(name.dropLast(3))
        if stem == "opencode" { return true }
        guard stem.hasPrefix("opencode-") else { return false }
        let channel = String(stem.dropFirst("opencode-".count))
        if channel.isEmpty { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return channel.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func discoverDbPaths(_ env: [String: String]) -> [String] {
        let fm = FileManager.default
        let override = (env["OPENCODE_DB"] ?? "").trimmingCharacters(in: .whitespaces)
        if !override.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: override, isDirectory: &isDir) && !isDir.boolValue { return [override] }
        }
        let dataDir = resolveDataDir(env)
        guard let entries = try? fm.contentsOfDirectory(atPath: dataDir) else { return [] }
        return entries.filter(isOpenCodeDbFilename).sorted().map { (dataDir as NSString).appendingPathComponent($0) }
    }

    private static let goRowsSql = """
    SELECT CAST(COALESCE(json_extract(data,'$.time.created'), time_created) AS INTEGER) AS createdMs,
           CAST(json_extract(data,'$.cost') AS REAL) AS cost
    FROM message
    WHERE json_valid(data)
      AND json_extract(data,'$.providerID') = 'opencode-go'
      AND json_extract(data,'$.role') = 'assistant'
      AND json_type(data,'$.cost') IN ('integer','real')
    """

    /// Reads opencode-go rows from a SQLite DB without sqlite3 C linkage by shelling
    /// out to the `sqlite3` CLI (always present on macOS). Throws on any read error,
    /// mirroring the JS "skip unreadable db" behavior (which the caller try/catches).
    private static func readGoRows(_ dbPath: String) throws -> [(createdMs: Int64, cost: Double)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let sql = "PRAGMA busy_timeout = 250; \(goRowsSql);"
        proc.arguments = [dbPath, sql]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw FetchError.timeout }
        guard let text = String(data: data, encoding: .utf8) else { throw FetchError.timeout }
        var rows: [(Int64, Double)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|")
            guard parts.count >= 2,
                  let created = Int64(parts[0]),
                  let cost = Double(parts[1]) else { continue }
            if created > 0 && cost >= 0 && cost.isFinite { rows.append((created, cost)) }
        }
        return rows
    }

    private static func buildWindows(rows: [(createdMs: Int64, cost: Double)], nowMs: Int64, limits: [String: Double]) -> [Window] {
        var earliest: Int64? = nil
        for r in rows where earliest == nil || r.createdMs < earliest! { earliest = r.createdMs }

        let sessionStart = nowMs - sessionMs
        let weekStart = weekStartMs(nowMs)
        let mb = monthBoundsMs(nowMs, anchorMs: earliest)

        let sessionRows = rows.filter { $0.createdMs >= sessionStart && $0.createdMs < nowMs }
        var sessionOldest = nowMs
        for r in sessionRows where r.createdMs < sessionOldest { sessionOldest = r.createdMs }

        let monthlyWindowMinutes = Int((Double(mb.endMs - mb.startMs) / 60_000).rounded())

        func mk(_ kind: String, _ used: Double, _ limit: Double, _ resetMs: Int64, _ windowMinutes: Int) -> Window {
            let usedRound = round1(used)
            let usedPercent = limit > 0 ? round1(clampPct((used / limit) * 100)) : nil
            return Window(
                kind: kind,
                usedPercent: usedPercent,
                used: usedRound,
                limit: limit,
                resetsAt: Date(timeIntervalSince1970: Double(resetMs) / 1000),
                windowMinutes: windowMinutes
            )
        }

        return [
            mk("session", sumCost(rows, sessionStart, nowMs), limits["session"]!, sessionOldest + sessionMs, 300),
            mk("weekly", sumCost(rows, weekStart, weekStart + weekMs), limits["weekly"]!, weekStart + weekMs, 10080),
            mk("monthly", sumCost(rows, mb.startMs, mb.endMs), limits["monthly"]!, mb.endMs, monthlyWindowMinutes)
        ]
    }

    private static func collectGo(env: [String: String], nowMs: Int64) -> (status: String, windows: [Window], identity: String) {
        let paths = discoverDbPaths(env)
        let notConfigured: (status: String, windows: [Window], identity: String) = ("notConfigured", [], "")
        if paths.isEmpty { return notConfigured }

        var rows: [(createdMs: Int64, cost: Double)] = []
        var read = false
        for dbPath in paths {
            do {
                rows.append(contentsOf: try readGoRows(dbPath))
                read = true
            } catch {
                // skip unreadable db (mirrors JS try/catch continue)
            }
        }
        if !read { return ("unavailable", [], "") }
        if rows.isEmpty { return notConfigured }
        return ("ok", buildWindows(rows: rows, nowMs: nowMs, limits: goLimits(env)), "opencode-go:\(paths[0])")
    }

    // MARK: - limits.js normalization ports

    private static let validProviders: Set<String> = [
        "claude", "codex", "opencode", "cursor", "antigravity", "kimi", "grok",
        "copilot", "mimo", "zai", "zaiteam", "kiro", "deepseek", "openrouter",
        "minimax", "volcengine", "qoder", "ollama", "thirdparty"
    ]
    private static let validStatuses: Set<String> = ["ok", "disabled", "notConfigured", "unauthorized", "rateLimited", "sourceRateLimited", "unavailable", "error"]
    private static let validSources: Set<String> = ["oauth", "cli", "web", "rpc", "local", "api"]
    private static let VALID_LIMIT_WINDOW_SOURCES: Set<String> = ["web", "local"]
    private static let VALID_LIMIT_WINDOW_METRICS: Set<String> = ["credits", "spend"]
    private static let validSourceDetails: Set<String> = ["app", "cli", "ide", "managed", "unknown"]
    private static let windowOrder = ["session", "weekly", "billing"]
    private static let maxAccountLabelInputLength = 256
    private static let maxAccountNameInputLength = 512
    private static let maxOpencodeAccountKeyAliases = 8

    private static func normalizeProviderId(_ value: Any?) -> String? {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return validProviders.contains(raw) ? raw : nil
    }

    private static func normalizeStatus(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces)
        return validStatuses.contains(raw) ? raw : "error"
    }

    private static func normalizeSource(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return validSources.contains(raw) ? raw : ""
    }

    private static func normalizeSourceDetail(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return validSourceDetails.contains(raw) ? raw : ""
    }

    private static func containsSensitiveAccountText(_ value: String) -> Bool {
        let normalized = value.precomposedStringWithCompatibilityMapping
        return normalized.contains("@") || normalized.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func normalizeAccountLabel(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw.count > maxAccountLabelInputLength || containsSensitiveAccountText(raw) { return "" }
        var clean = stripUnicode(raw, letters: true, marks: true, numbers: true, extra: " +._-")
        clean = collapseWhitespace(clean)
        return !clean.isEmpty && clean.count <= 32 ? clean : ""
    }

    private static func normalizeAccountName(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw.count > maxAccountNameInputLength || containsSensitiveAccountText(raw) { return "" }
        var clean = stripUnicode(raw, letters: true, marks: true, numbers: true, extra: " ._-")
        clean = collapseWhitespace(clean)
        return !clean.isEmpty && clean.count <= 64 ? clean : ""
    }

    private static func normalizeAccountEmail(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if raw.isEmpty || raw.count > 254 || !raw.contains("@") { return "" }
        // /^[^\s@]+@[^\s@]+\.[^\s@]+$/
        let atParts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard atParts.count == 2 else { return "" }
        let domain = atParts[1]
        guard domain.contains(".") else { return "" }
        let invalid = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))
        return raw.unicodeScalars.allSatisfy { !invalid.contains($0) } ? raw : ""
    }

    private static func normalizeWindowKind(_ value: Any?) -> String? {
        let raw = String(describing: value ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .filter { !"_ -".contains($0) }
        if raw == "session" { return "session" }
        if raw == "weekly" { return "weekly" }
        if raw == "billing" || raw == "billingcycle" || raw == "monthly" { return "billing" }
        return nil
    }

    private static func normalizeWindowLabel(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw.count > 32 { return "" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 +._/-")
        var clean = String(raw.unicodeScalars.filter { allowed.contains($0) })
        clean = collapseWhitespace(clean)
        return clean.count <= 32 ? clean : ""
    }

    private static func normalizeWindowDetail(_ value: Any?) -> String {
        var raw = String(describing: value ?? "")
            .map { $0.unicodeScalars.first!.value >= 0x20 && $0.unicodeScalars.first!.value != 0x7f ? String($0) : " " }
            .joined()
        raw = collapseWhitespace(raw)
        return String(raw.prefix(96))
    }

    private static func normalizeWindowCurrency(_ value: Any?) -> String? {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let clipped = String(raw.prefix(8))
        return clipped.isEmpty ? nil : clipped
    }

    private static func normalizeIsoTimestamp(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return nil }
        if let s = value as? String, s.isEmpty { return nil }
        var date: Date?
        if let n = value as? Double, n.isFinite {
            date = Date(timeIntervalSince1970: n < 20_000_000_000 ? n : n / 1000)
        } else if let n = value as? Int {
            let d = Double(n)
            date = Date(timeIntervalSince1970: d < 20_000_000_000 ? d : d / 1000)
        } else if let n = value as? NSNumber {
            let d = n.doubleValue
            date = Date(timeIntervalSince1970: d < 20_000_000_000 ? d : d / 1000)
        } else {
            date = ISO8601DateFormatter.parsingAny.date(from: String(describing: value!))
        }
        guard let date else { return nil }
        return ISO8601DateFormatter.machineUTCMs.string(from: date)
    }

    private static func asNumber(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            let cleaned = t.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            if let n = Double(cleaned), n.isFinite { return n }
        }
        return nil
    }

    private static func numberOrNull(_ value: Any?) -> Double? {
        asNumber(value)
    }

    private static func percentFromWindow(_ input: JSON, used: Double?, limit: Double?) -> Double? {
        let explicit = numberOrNull(input["usedPercent"] ?? input["used_percent"] ?? input["utilization"] ?? input["percent"])
        if let e = explicit { return clamp(e, 0, 100) }
        if let u = used, let l = limit, l > 0 { return clamp((u / l) * 100, 0, 100) }
        return nil
    }

    private static func clamp(_ v: Double, _ min: Double, _ max: Double) -> Double {
        Swift.max(min, Swift.min(max, v))
    }

    private static func normalizeLimitWindow(_ input: Any?) -> JSON? {
        guard let dict = input as? JSON, !dict.isEmpty else { return nil }
        let kind = normalizeWindowKind(dict["kind"] ?? dict["type"] ?? dict["name"] ?? dict["window"] ?? dict["windowKind"])
        guard let kind else { return nil }
        let metricValue = String(describing: dict["metric"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let metric = VALID_LIMIT_WINDOW_METRICS.contains(metricValue) ? metricValue : nil
        let sourceValue = String(describing: dict["source"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let source = VALID_LIMIT_WINDOW_SOURCES.contains(sourceValue) ? sourceValue : nil
        let used = numberOrNull(dict["used"])
        let limit = numberOrNull(dict["limit"])
        let remaining = numberOrNull(dict["remaining"])
        let usedPercent = percentFromWindow(dict, used: used, limit: limit)

        var out: JSON = [:]
        out["kind"] = kind
        if let metric { out["metric"] = metric }
        if let source { out["source"] = source }
        out["label"] = normalizeWindowLabel(dict["label"] ?? dict["displayLabel"] ?? dict["title"] ?? "")
        out["used"] = used as Any? ?? NSNull()
        out["limit"] = limit as Any? ?? NSNull()
        out["remaining"] = remaining as Any? ?? NSNull()
        out["usedPercent"] = usedPercent as Any? ?? NSNull()
        out["remainingPercent"] = usedPercent.map { round3(100 - $0) } as Any? ?? NSNull()
        let resetAt = normalizeIsoTimestamp(dict["resetsAt"] ?? dict["resets_at"] ?? dict["resetAt"] ?? dict["reset_at"])
        out["resetsAt"] = resetAt as Any? ?? NSNull()
        out["windowMinutes"] = numberOrNull(dict["windowMinutes"] ?? dict["window_minutes"] ?? dict["windowDurationMins"]) as Any? ?? NSNull()
        out["resetDescription"] = dict["resetDescription"] as? String ?? ""
        out["detail"] = normalizeWindowDetail(dict["detail"] ?? dict["detailText"] ?? dict["detail_text"] ?? "")
        out["currency"] = normalizeWindowCurrency(dict["currency"] ?? "") as Any? ?? NSNull()
        let showMeter = (dict["showMeter"] == nil || (dict["showMeter"] as? Bool) != false)
            && (dict["meter"] == nil || (dict["meter"] as? Bool) != false)
        out["showMeter"] = showMeter
        return out
    }

    private static func normalizeOpenCodeAccountKeyAliases(_ values: Any?, accountKey: String) -> [String] {
        guard let arr = values as? [Any] else { return [] }
        let canonical = accountKey.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        var result: [String] = []
        for v in arr {
            let s = String(describing: v).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty && s != canonical && s.count <= 128 && !seen.contains(s) {
                seen.insert(s)
                result.append(s)
            }
        }
        result.sort()
        return Array(result.prefix(maxOpencodeAccountKeyAliases))
    }

    private static func normalizeWorkspaceKind(_ value: Any?) -> String {
        return String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "personal" ? "personal" : ""
    }

    private static func normalizeRegion(_ value: Any?) -> String {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if raw.isEmpty { return "" }
        if raw == "cn" || raw == "en" || raw == "global" { return raw }
        return raw.count <= 16 ? raw : ""
    }

    private struct ProviderInput {
        var provider: String
        var accountKey: String
        var webAccountKey: String = ""
        var accountKeyAliases: [String] = []
        var accountLabel: String = ""
        var planLabel: String = ""
        var accountName: String = ""
        var accountEmail: String = ""
        var workspaceKind: String = ""
        var status: String
        var source: String
        var sourceDetail: String = ""
        var updatedAt: String
        var windows: [Window]
        var balanceUsd: Double? = nil
    }

    private static func normalizeLimitProvider(_ input: ProviderInput) -> JSON? {
        guard let provider = normalizeProviderId(input.provider) else { return nil }
        let accountKey = input.accountKey
        let accountKeyAliases = provider == "opencode"
            ? normalizeOpenCodeAccountKeyAliases(input.accountKeyAliases, accountKey: accountKey)
            : []
        let accountLabel = normalizeAccountLabel(input.accountLabel)

        var windows = input.windows
            .map { windowToInput($0) }
            .compactMap { normalizeLimitWindow($0) }
        windows.sort { a, b in
            let ka = windowOrder.firstIndex(of: (a["kind"] as? String) ?? "") ?? Int.max
            let kb = windowOrder.firstIndex(of: (b["kind"] as? String) ?? "") ?? Int.max
            return ka < kb
        }

        var out: JSON = [:]
        out["provider"] = provider
        out["accountKey"] = accountKey
        if provider == "opencode" && !input.webAccountKey.isEmpty {
            out["webAccountKey"] = input.webAccountKey
        }
        if !accountKeyAliases.isEmpty { out["accountKeyAliases"] = accountKeyAliases }
        out["accountLabel"] = accountLabel
        out["planLabel"] = normalizeAccountLabel(input.planLabel)
        out["accountName"] = normalizeAccountName(input.accountName)
        out["accountEmail"] = normalizeAccountEmail(input.accountEmail)
        out["workspaceKind"] = normalizeWorkspaceKind(input.workspaceKind)
        out["status"] = normalizeStatus(input.status)
        out["source"] = normalizeSource(input.source)
        out["sourceDetail"] = normalizeSourceDetail(input.sourceDetail)
        out["updatedAt"] = normalizeIsoTimestamp(input.updatedAt) ?? ""
        out["windows"] = windows
        out["balanceUsd"] = (input.balanceUsd as Any?) ?? NSNull()
        out["balance"] = NSNull()
        out["resetCredits"] = NSNull()
        out["region"] = normalizeRegion("")
        return out
    }

    /// Converts the internal `Window` model into the raw JSON input shape
    /// `normalizeLimitWindow` expects (mirroring what opencodeWeb.js emits).
    private static func windowToInput(_ w: Window) -> JSON {
        var dict: JSON = [:]
        dict["kind"] = w.kind
        if let metric = w.metric { dict["metric"] = metric }
        if let source = w.source { dict["source"] = source }
        if let label = w.label { dict["label"] = label }
        if let used = w.used { dict["used"] = used }
        if let limit = w.limit { dict["limit"] = limit }
        if let usedPercent = w.usedPercent { dict["usedPercent"] = usedPercent }
        dict["resetsAt"] = w.resetsAt.map { ISO8601DateFormatter.machineUTCMs.string(from: $0) } as Any? ?? NSNull()
        dict["windowMinutes"] = w.windowMinutes
        return dict
    }

    // MARK: - Shared low-level helpers

    private static func hashKey(_ parts: String...) -> String {
        CredentialHash.key(parts)
    }

    private static func sha256HexPrefix(_ value: String, _ length: Int) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    private static func nowIso(_ nowMs: Int64) -> String {
        return ISO8601DateFormatter.machineUTCMs.string(from: Date(timeIntervalSince1970: Double(nowMs) / 1000))
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Ports the JS `\p{L}\p{M}\p{N}` + literal-class filter. The three flags toggle
    /// letters/marks/numbers; `extra` is a literal character set appended verbatim.
    private static func stripUnicode(_ s: String, letters: Bool, marks: Bool, numbers: Bool, extra: String) -> String {
        let extraSet = CharacterSet(charactersIn: extra)
        var result = ""
        for scalar in s.unicodeScalars {
            let isLetter = CharacterSet.letters.contains(scalar)
            let isMark = CharacterSet.nonBaseCharacters.contains(scalar)
            let isNumber = CharacterSet.decimalDigits.contains(scalar)
            let keep = (letters && isLetter) || (marks && isMark) || (numbers && isNumber) || extraSet.contains(scalar)
            if keep { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    /// Normalizes a metric/source value against a small allowlist.
    private static func normalizeValue(_ value: Any?, from allowlist: Set<String>) -> String? {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return allowlist.contains(raw) ? raw : nil
    }
}

// MARK: - Date/ISO8601 helpers

private extension ISO8601DateFormatter {
    /// Parses a broad range of ISO-8601 inputs (with and without milliseconds/offset).
    static let parsingAny: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Emits exactly `yyyy-MM-dd'T'HH:mm:ss.SSSZ` with milliseconds, matching
    /// JavaScript's `Date.prototype.toISOString()`.
    static let machineUTCMs: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()
}
