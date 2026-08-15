import Foundation
import CryptoKit

/// OpenCode (opencode.ai) limit collection, ported from `src/shared/opencodeWeb.js`,
/// `src/shared/opencodeLimits.js`, and the opencode sections of
/// `src/shared/limitCollector.js` / `src/shared/limits.js`.
///
/// The wire shape produced here is the array returned by `normalizeLimitProvider`
/// (input object already assembled), so callers can hand it straight to the hub
/// ingest path. Only Foundation + CryptoKit are used; the async surface is kept to
/// plain Swift 5 `URLSession`-based await calls.
enum OpencodeLimits {
    typealias JSON = [String: Any]

    struct Profile {
        let name: String
        let cookie: String
        let apiKey: String
        let enabled: Bool

        init(name: String, cookie: String, apiKey: String = "", enabled: Bool = true) {
            self.name = name
            self.cookie = cookie
            self.apiKey = apiKey
            self.enabled = enabled
        }
    }

    // MARK: - Public API

    /// Returns the opencode provider wire dictionaries (same shape as
    /// `normalizeLimitProvider` output). Local mode (0 or 1 cookie) returns a single
    /// provider; multi-account (2+ enabled cookies) returns one per profile,
    /// matching `fetchOpenCodeLimits` / `fetchSingleOpenCodeProfile`.
    static func fetchProviders(
        profiles: [Profile],
        nowMs: Int64,
        opencodeLocalLimitsEnabled: Bool
    ) async -> [JSON] {
        let now = Int64(truncatingIfNeeded: nowMs)
        let updatedAt = nowIso(now)
        let env = ProcessInfo.processInfo.environment

        // An account is a name, and credentials belong to a name. A profile may
        // hold a cookie (Go quota plus Zen balance) and/or a stored API key (Go
        // quota); sharing a name is the user's assertion that they are one
        // account, which licenses reading quota from one credential while
        // identity and balance come from the other.
        //
        // The key OpenCode keeps in auth.json needs no setup. It is re-read
        // every tick (never stored), and tracked as its own account until a
        // saved profile claims it (same key stored verbatim), which keeps the
        // zero-config path alive.
        let ambientKey = readGoApiKey(env)

        // Credential sources: enabled profiles > env var (appended if not present) > ambient.
        var cookies: [(name: String, cookie: String, apiKey: String, ambient: Bool)] = []
        for p in profiles where p.enabled && (!p.cookie.isEmpty || !p.apiKey.isEmpty) {
            cookies.append((p.name, p.cookie, p.apiKey, false))
        }
        let envCookie = env["TOKEN_MONITOR_OPENCODE_COOKIE"] ?? ""
        if !envCookie.isEmpty && !cookies.contains(where: { $0.cookie == envCookie }) {
            cookies.append(("default (env)", envCookie, "", false))
        }

        // Switched off for a machine signed in to an account the user does not
        // want reported (`TOKEN_MONITOR_OPENCODE_AMBIENT=0`). Only the unclaimed
        // row is suppressed: once a saved account holds the same key, the
        // account's own toggle owns it.
        let ambientEnabled = parseAmbientEnv(env["TOKEN_MONITOR_OPENCODE_AMBIENT"], default: true)
        let ambientClaimed = cookies.contains { $0.apiKey == ambientKey }
        if !ambientKey.isEmpty && !ambientClaimed && ambientEnabled {
            cookies.append((opencodeAmbientAccountName, "", ambientKey, true))
        }

        let multiAccountMode = cookies.count > 1

        // ── Single account: merged behavior ─────────────────────────────────
        if !multiAccountMode {
            let goLocal = opencodeLocalLimitsEnabled
                ? collectGo(env: env, nowMs: now)
                : (status: "notConfigured", windows: [] as [Window], identity: "")
            let primary = cookies.first
            let cookie = primary?.cookie ?? ""
            // Only this entry's own key, never the ambient one as a stand-in.
            // The ambient key is its own entry above; reaching for it here
            // would pair it with a cookie whose account nothing can prove it
            // shares, publishing one account's quota under the other's identity.
            let primaryApiKey = primary?.apiKey ?? ""
            var goApi: (status: String, windows: [Window], identity: String, entitled: Bool)?
            var goWeb: (status: String, windows: [Window], workspaceId: String)? = nil
            var zen: (status: String, windows: [Window], balanceUsd: Double?, workspaceId: String)? = nil
            if !cookie.isEmpty || !primaryApiKey.isEmpty {
                async let api = collectGoApi(env: env, apiKey: primaryApiKey.isEmpty ? nil : primaryApiKey, nowMs: now)
                async let gw = cookie.isEmpty ? nil : fetchGoWeb(cookie: cookie, nowMs: now)
                async let zn = cookie.isEmpty ? nil : fetchZen(cookie: cookie, nowMs: now)
                goApi = await api
                goWeb = await gw
                zen = await zn
            }

            let identity = openCodeWebIdentity(goWeb: goWeb, zen: zen, cookie: cookie.isEmpty ? nil : cookie)
            let webAccountKey = identity.accountKey

            var windows: [Window] = []
            var status = "notConfigured"
            var source = "local"
            var accountLabel = ""
            var accountKey = ""
            var balanceUsd: Double? = nil

            // Go quota resolves api → web → local. The official API needs no
            // user setup and is anchored on the real subscription month, so it
            // outranks the cookie scrape; the local estimate stays last because
            // it sees only this device's rows. API windows are tagged `web`,
            // not `api`: windows[].source is a two-value wire enum ('web' |
            // 'local') that hubs rank on, and the finer provenance rides on the
            // provider-level source.
            if let api = goApi, api.status == "ok", !api.windows.isEmpty {
                windows.append(contentsOf: api.windows.map { $0.withSource("web") })
                status = "ok"; source = "api"; accountLabel = "Go"
                accountKey = hashKey("opencode", api.identity.isEmpty ? "go-api" : api.identity)
            } else if let go = goWeb, go.status == "ok", !go.windows.isEmpty {
                windows.append(contentsOf: go.windows.map { $0.withSource("web") })
                status = "ok"; source = "web"; accountLabel = "Go"
                accountKey = hashKey("opencode", "go:\(go.workspaceId)")
            } else if goLocal.status == "ok" && goApi?.entitled != false {
                // `entitled === false` is the server saying this account has no
                // Go plan; only an absent or failed API answer leaves room for
                // the local estimate.
                windows.append(contentsOf: goLocal.windows.map { $0.withSource("local") })
                status = "ok"; accountLabel = "Go"
                accountKey = hashKey("opencode", goLocal.identity.isEmpty ? "go" : goLocal.identity)
            } else if goLocal.status == "unavailable" && goApi?.entitled != false {
                status = "unavailable"
            }

            if let zn = zen, identity.includeZen {
                windows.append(contentsOf: supplementalZenWindows(takenWindows: windows, zen: zn).map { $0.withSource("web") })
                status = "ok"
                // 'api' already implies every quota window is server truth, so
                // it keeps that stronger claim instead of being flattened to
                // 'web' by a Zen window.
                if source != "api" && !windows.contains(where: { $0.source == "local" }) { source = "web" }
                if let b = zn.balanceUsd, b.isFinite { balanceUsd = b }
                if accountLabel.isEmpty { accountLabel = "Zen" }
                if accountKey.isEmpty { accountKey = hashKey("opencode", "zen:\(zn.workspaceId)") }
            } else if status != "ok" {
                // Only reached when nothing produced windows. A stale API key
                // would otherwise read as "not configured" and leave the user
                // nothing to fix. `notConfigured` from the API means "no Go
                // subscription", a fallback condition rather than a failure.
                let surfaced: (status: String, source: String)?
                if let api = goApi, opencodeRemoteFailStatuses.contains(api.status) {
                    surfaced = (api.status, "api")
                } else if let go = goWeb, opencodeRemoteFailStatuses.contains(go.status) {
                    surfaced = (go.status, "web")
                } else if let zn = zen, opencodeRemoteFailStatuses.contains(zn.status) {
                    surfaced = (zn.status, "web")
                } else {
                    surfaced = nil
                }
                if let s = surfaced { status = s.status; source = s.source }
            }

            // A failed API probe still names its account: the key identifies
            // it, so a 401 or rate limit must not leave an empty accountKey.
            if accountKey.isEmpty, let api = goApi, !api.identity.isEmpty {
                accountKey = hashKey("opencode", api.identity)
            }
            if !webAccountKey.isEmpty { accountKey = webAccountKey }
            // Publish the key's own identity as an alias whenever one was used,
            // so a device holding only the key groups with the cookie account.
            let apiAlias: String
            if let api = goApi, !api.identity.isEmpty, hashKey("opencode", api.identity) != accountKey {
                apiAlias = hashKey("opencode", api.identity)
            } else {
                apiAlias = ""
            }

            return [normalizeLimitProvider(ProviderInput(
                provider: "opencode",
                accountKey: accountKey,
                webAccountKey: webAccountKey,
                accountKeyAliases: identity.aliases + (apiAlias.isEmpty ? [] : [apiAlias]),
                accountLabel: accountLabel,
                accountName: primary?.name ?? "",
                status: status,
                source: source,
                sourceDetail: "managed",
                updatedAt: updatedAt,
                windows: windows,
                balanceUsd: balanceUsd
            ))].compactMap { $0 }
        }

        // ── Multi-account: per-profile providers (parallel) ─────────────────
        var providers: [JSON] = []
        let results: [(name: String, cookie: String, provider: JSON?)] = await withTaskGroup(
            of: (name: String, cookie: String, provider: JSON?).self
        ) { group in
            for c in cookies {
                group.addTask {
                    let provider = await fetchSingleOpenCodeProfile(
                        name: c.name, cookie: c.cookie, apiKey: c.apiKey, nowMs: now, updatedAt: updatedAt
                    )
                    return (c.name, c.cookie, provider)
                }
            }
            var collected: [(String, String, JSON?)] = []
            for await r in group { collected.append(r) }
            // Preserve original cookie order for deterministic output.
            return collected.sorted { a, b in
                cookies.firstIndex(where: { $0.cookie == a.1 })!
                    < cookies.firstIndex(where: { $0.cookie == b.1 })!
            }
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

    // MARK: - Window model (pre-normalization, mirrors opencodeWeb.js outputs)

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

    // MARK: - Identity (openCodeWebIdentity)

    private static func openCodeWebIdentity(
        goWeb: (status: String, windows: [Window], workspaceId: String)?,
        zen: (status: String, windows: [Window], balanceUsd: Double?, workspaceId: String)?,
        cookie: String?
    ) -> (accountKey: String, aliases: [String], includeZen: Bool) {
        let goWorkspaceId = goWeb?.status == "ok" ? goWeb!.workspaceId : ""
        let zenWorkspaceId = zen?.status == "ok" ? zen!.workspaceId : ""
        let workspaceConflict = !goWorkspaceId.isEmpty && !zenWorkspaceId.isEmpty && goWorkspaceId != zenWorkspaceId
        let includeZen = zen?.status == "ok" && !workspaceConflict
        let hasSuccessfulWebProbe = goWeb?.status == "ok" || includeZen
        let workspaceId = !goWorkspaceId.isEmpty ? goWorkspaceId : (includeZen ? zenWorkspaceId : "")

        if hasSuccessfulWebProbe && !workspaceId.isEmpty {
            return (
                accountKey: hashKey("opencode", "workspace:\(workspaceId)"),
                aliases: [
                    hashKey("opencode", "go:\(workspaceId)"),
                    hashKey("opencode", "zen:\(workspaceId)")
                ],
                includeZen: includeZen
            )
        }
        if let cookie, !cookie.isEmpty, hasSuccessfulWebProbe {
            let cookieHash = sha256HexPrefix(cookie, 12)
            return (accountKey: hashKey("opencode", "cookie:\(cookieHash)"), aliases: [], includeZen: includeZen)
        }
        return (accountKey: "", aliases: [], includeZen: includeZen)
    }

    private static func supplementalZenWindows(
        takenWindows: [Window],
        zen: (status: String, windows: [Window], balanceUsd: Double?, workspaceId: String)?
    ) -> [Window] {
        let takenKeys = Set(takenWindows.map { openCodeWindowKey($0) }.filter { !$0.isEmpty })
        return (zen?.windows ?? []).filter { w in
            let key = openCodeWindowKey(w)
            return key.isEmpty || !takenKeys.contains(key)
        }
    }

    private static func openCodeWindowKey(_ window: Window) -> String {
        let kind = normalizeWindowKind(window.kind) ?? ""
        if kind.isEmpty { return "" }
        let metric = normalizeValue(window.metric, from: VALID_LIMIT_WINDOW_METRICS) ?? ""
        let label = normalizeWindowLabel(window.label ?? "")
        return [kind, metric, label].joined(separator: ":")
    }

    // MARK: - Single-profile fetch (fetchSingleOpenCodeProfile)

    private static func fetchSingleOpenCodeProfile(
        name: String, cookie: String, apiKey: String, nowMs: Int64, updatedAt: String
    ) async -> JSON? {
        // Race the probes against a 15s deadline (Promise.race in JS).
        let env = ProcessInfo.processInfo.environment
        let resolved: (goWeb: (status: String, windows: [Window], workspaceId: String)?,
                       zen: (status: String, windows: [Window], balanceUsd: Double?, workspaceId: String)?,
                       goApi: (status: String, windows: [Window], identity: String, entitled: Bool)?)?
        do {
            resolved = try await withThrowingTaskGroup(
                of: Optional<(goWeb: (status: String, windows: [Window], workspaceId: String)?,
                               zen: (status: String, windows: [Window], balanceUsd: Double?, workspaceId: String)?,
                               goApi: (status: String, windows: [Window], identity: String, entitled: Bool)?)>.self
            ) { group in
                group.addTask {
                    async let go = cookie.isEmpty ? nil : fetchGoWeb(cookie: cookie, nowMs: nowMs)
                    async let zn = cookie.isEmpty ? nil : fetchZen(cookie: cookie, nowMs: nowMs)
                    async let api = apiKey.isEmpty ? nil : collectGoApi(env: env, apiKey: apiKey, nowMs: nowMs)
                    let (g, z, a) = await (go, zn, api)
                    return (goWeb: g, zen: z, goApi: a)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw FetchError.timeout
                }
                guard let first = try await group.next() else { throw FetchError.timeout }
                group.cancelAll()
                return first
            }
        } catch {
            resolved = nil
        }

        if let resolved {
            let goWeb = resolved.goWeb
            let zen = resolved.zen
            let goApi = resolved.goApi
            var windows: [Window] = []
            var status = "notConfigured"
            var planLabel = ""
            var balanceUsd: Double? = nil
            var source = "web"

            // Go quota resolves api → web within the profile: the official API
            // needs no user setup and is the only source anchored on the real
            // subscription month.
            if let api = goApi, api.status == "ok", !api.windows.isEmpty {
                windows.append(contentsOf: api.windows.map { $0.withSource("web") })
                status = "ok"
                planLabel = "Go"
                source = "api"
            } else if let go = goWeb, go.status == "ok", !go.windows.isEmpty {
                windows.append(contentsOf: go.windows.map { $0.withSource("web") })
                status = "ok"
                planLabel = "Go"
            }

            let identity = openCodeWebIdentity(goWeb: goWeb, zen: zen, cookie: cookie.isEmpty ? nil : cookie)
            if let zn = zen, identity.includeZen {
                windows.append(contentsOf: supplementalZenWindows(takenWindows: windows, zen: zn).map { $0.withSource("web") })
                status = "ok"
                if planLabel.isEmpty { planLabel = "Zen" }
                if let b = zn.balanceUsd, b.isFinite { balanceUsd = b }
            }

            if status != "ok" {
                // `notConfigured` from the API means "no Go subscription", a
                // fallback condition rather than a failure; it is ranked last so
                // it cannot hide an expired cookie's `unauthorized`. Provenance
                // travels with the status: how many accounts are configured
                // cannot change which credential failed.
                let failure: (status: String, source: String)?
                if let api = goApi, opencodeRemoteFailStatuses.contains(api.status) {
                    failure = (api.status, "api")
                } else if let gw = goWeb {
                    failure = (gw.status, "web")
                } else if let zn = zen {
                    failure = (zn.status, "web")
                } else if let api = goApi {
                    failure = (api.status, "api")
                } else {
                    failure = ("unauthorized", apiKey.isEmpty || !cookie.isEmpty ? "web" : "api")
                }
                if let f = failure { status = f.status; source = f.source }
            }

            // The key's own identity, published whenever this account holds one:
            // the same key on another device with no cookie identifies itself by
            // the key alone, so the two devices group into one account.
            let keyIdentity = apiKey.isEmpty ? "" : hashKey("opencode", goApiIdentity(apiKey))

            // Stable accountKey: workspaceId (preferred), then the key, then the
            // cookie hash — never the user-editable profile name. The key ranks
            // above the cookie hash because it is the same string on every
            // device, while a cookie is per-browser-session.
            var accountKey = identity.accountKey
            if accountKey.isEmpty { accountKey = keyIdentity }
            if accountKey.isEmpty && !cookie.isEmpty {
                accountKey = hashKey("opencode", "cookie:\(sha256HexPrefix(cookie, 12))")
            }
            let boundKeyAlias = accountKey == keyIdentity ? "" : keyIdentity

            return normalizeLimitProvider(ProviderInput(
                provider: "opencode",
                accountKey: accountKey,
                // Only a cookie yields a workspace identity. The Hub picks the
                // canonical identity from webAccountKeys it collects, so
                // publishing the key's hash here would let an API-only device's
                // identity win over a real workspace id.
                webAccountKey: identity.accountKey,
                accountKeyAliases: identity.aliases + (boundKeyAlias.isEmpty ? [] : [boundKeyAlias]),
                accountLabel: name,
                planLabel: planLabel,
                accountName: name,
                status: status,
                source: source,
                sourceDetail: "managed",
                updatedAt: updatedAt,
                windows: windows,
                balanceUsd: balanceUsd
            ))
        }

        // Timeout / network-error path. Same identity ranking as the success
        // path, so a timeout does not hand the account a different accountKey.
        let keyIdentity = apiKey.isEmpty ? "" : hashKey("opencode", goApiIdentity(apiKey))
        var accountKey = keyIdentity
        if accountKey.isEmpty && !cookie.isEmpty {
            accountKey = hashKey("opencode", "cookie:\(sha256HexPrefix(cookie, 12))")
        }
        return normalizeLimitProvider(ProviderInput(
            provider: "opencode",
            accountKey: accountKey,
            // No webAccountKey: this row probed nothing, so it has no workspace
            // identity to offer.
            accountLabel: name,
            planLabel: "",
            accountName: name,
            status: "unavailable",
            source: apiKey.isEmpty || !cookie.isEmpty ? "web" : "api",
            sourceDetail: "managed",
            updatedAt: updatedAt,
            windows: [],
            balanceUsd: nil
        ))
    }

    // MARK: - opencodeWeb.js ports

    private static let baseURL = "https://opencode.ai"
    private static let serverURL = "https://opencode.ai/_server"
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"

    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static let pctKeys = ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "used_percent", "utilization", "utilizationPercent", "utilization_percent", "usage"]
    private static let resetSecKeys = ["resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec", "resetsInSec", "resetsInSeconds", "resetIn", "resetSec"]
    private static let resetAtKeys = ["resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset", "renewAt", "renew_at"]
    private static let balanceKeys = ["balanceUSD", "balanceUsd", "currentBalance", "zenBalance", "currentBalanceUSD"]

    private static let goWindowMinutes: [String: Int] = ["session": 300, "weekly": 10080, "monthly": 43200]

    private static func sanitizeCookieHeader(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if let r = text.range(of: "^cookie\\s*:\\s*", options: .regularExpression) { text.removeSubrange(r) }
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cleaned = parts.joined(separator: "; ")
        if !cleaned.isEmpty && !cleaned.contains("=") { return "auth=\(cleaned)" }
        return cleaned
    }

    private static func serverRequestUrl(_ serverId: String, args: [String]?, method: String) -> String {
        if method.uppercased() != "GET" { return serverURL }
        var comps = URLComponents(string: serverURL)!
        var items = [URLQueryItem(name: "id", value: serverId)]
        if let args, !args.isEmpty {
            if let data = try? JSONSerialization.data(withJSONObject: args),
               let s = String(data: data, encoding: .utf8) {
                items.append(URLQueryItem(name: "args", value: s))
            }
        }
        comps.queryItems = items
        return comps.url!.absoluteString
    }

    private static func buildHeaders(_ serverId: String, cookieHeader: String, referer: String) -> [String: String] {
        return [
            "Cookie": cookieHeader,
            "X-Server-Id": serverId,
            "X-Server-Instance": "server-fn:\(UUID().uuidString.lowercased())",
            "User-Agent": browserUserAgent,
            "Origin": baseURL,
            "Referer": referer.isEmpty ? baseURL : referer,
            "Accept": "text/javascript, application/json;q=0.9, */*;q=0.8"
        ]
    }

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

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func clampPct(_ v: Double) -> Double { max(0, min(100, v)) }

    /// Ports opencodeWeb.js `toMs`: returns milliseconds. Numbers >1e12 are already
    /// ms; >1e9 are seconds; strings are parsed as dates (milliseconds since epoch).
    private static func toMs(_ value: Any) -> Double? {
        if let n = asNum(value) {
            if n > 1e12 { return n }
            if n > 1e9 { return n * 1000 }
            return nil
        }
        if let s = value as? String {
            let f = ISO8601DateFormatter.parsingAny
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
            return nil
        }
        return nil
    }

    private static func pick(_ obj: JSON, _ keys: [String]) -> Any? {
        for k in keys {
            if let v = obj[k], !(v is NSNull) { return v }
        }
        return nil
    }

    private static func parseWorkspaceIds(_ text: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        let re = try! NSRegularExpression(pattern: "id\\s*[:=]\\s*\"(wrk_[^\"]+)\"")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for m in re.matches(in: text, range: range) {
            if let r = Range(m.range(at: 1), in: text) {
                let id = String(text[r])
                if !seen.contains(id) { seen.insert(id); ids.append(id) }
            }
        }
        if ids.isEmpty {
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                walkWorkspaceIds(obj, &seen, &ids)
            }
        }
        return ids
    }

    private static func walkWorkspaceIds(_ value: Any, _ seen: inout Set<String>, _ ids: inout [String]) {
        if let s = value as? String, s.hasPrefix("wrk_"), !seen.contains(s) {
            seen.insert(s); ids.append(s)
            return
        }
        if let arr = value as? [Any] {
            for v in arr { walkWorkspaceIds(v, &seen, &ids) }
        } else if let dict = value as? JSON {
            for (_, v) in dict { walkWorkspaceIds(v, &seen, &ids) }
        }
    }

    private static func parseWindowObj(_ obj: Any?, kind: String, windowMinutes: Int, nowMs: Int64) -> Window? {
        guard let dict = obj as? JSON, !dict.isEmpty else { return nil }
        var pct: Double? = nil
        for k in pctKeys {
            if let v = dict[k], let n = asNum(v) { pct = n; break }
        }
        if pct == nil {
            let used = asNum(pick(dict, ["used", "consumed"]) ?? NSNull())
            let limit = asNum(pick(dict, ["limit", "total", "quota", "max", "cap"]) ?? NSNull())
            if let u = used, let l = limit, l > 0 { pct = (u / l) * 100 }
        }
        guard var pctValue = pct else { return nil }
        if pctValue <= 1 && pctValue >= 0 { pctValue *= 100 }
        pctValue = round1(clampPct(pctValue))
        var resetSec: Double? = nil
        for k in resetSecKeys {
            if let v = dict[k], let n = asNum(v) { resetSec = n; break }
        }
        if resetSec == nil {
            if let v = pick(dict, resetAtKeys), let ms = toMs(v) {
                resetSec = max(0, ((ms - Double(nowMs)) / 1000).rounded())
            }
        }
        let sec = max(0, resetSec ?? 0)
        return Window(
            kind: kind,
            usedPercent: pctValue,
            used: nil,
            limit: nil,
            resetsAt: Date(timeIntervalSince1970: Double(nowMs) / 1000 + sec),
            windowMinutes: windowMinutes
        )
    }

    private static func findByKeyword(_ obj: Any?, _ keyword: String, depth: Int = 0) -> JSON? {
        guard depth <= 4 else { return nil }
        if let dict = obj as? JSON {
            for (k, v) in dict where k.lowercased().contains(keyword) {
                if let nested = v as? JSON { return nested }
            }
            for (_, v) in dict {
                if let nested = v as? JSON, let found = findByKeyword(nested, keyword, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func findBalance(_ obj: Any?, depth: Int = 0) -> Double? {
        guard depth <= 4 else { return nil }
        if let dict = obj as? JSON {
            for k in balanceKeys {
                if let v = dict[k], let n = asNum(v) { return n }
            }
            for (_, v) in dict {
                if let nested = v as? JSON, let n = findBalance(nested, depth: depth + 1) { return n }
            }
        }
        return nil
    }

    private static func extractWindowByRegex(_ text: String, windowKey: String, kind: String, windowMinutes: Int, nowMs: Int64) -> Window? {
        let pctRe = try! NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: windowKey))[^}]*?usagePercent\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)")
        let pctRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let pm = pctRe.firstMatch(in: text, range: pctRange),
              let gr = Range(pm.range(at: 1), in: text),
              let pv = Double(text[gr]) else { return nil }
        let resetRe = try! NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: windowKey))[^}]*?resetInSec\\s*:\\s*([0-9]+)")
        var resetSec = 0.0
        if let rm = resetRe.firstMatch(in: text, range: pctRange),
           let rr = Range(rm.range(at: 1), in: text),
           let rv = Double(text[rr]) {
            resetSec = max(0, rv)
        }
        return Window(
            kind: kind,
            usedPercent: round1(clampPct(pv)),
            used: nil,
            limit: nil,
            resetsAt: Date(timeIntervalSince1970: Double(nowMs) / 1000 + resetSec),
            windowMinutes: windowMinutes
        )
    }

    private static func parseSubscription(_ text: String, nowMs: Int64) -> (windows: [Window], balanceUsd: Double?) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "null" {
            return ([], nil)
        }
        var windows: [Window] = []
        var balanceUsd: Double? = nil

        var rootObj: Any? = nil
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? JSON {
            rootObj = obj
        }

        if let root = rootObj as? JSON {
            if let w1 = parseWindowObj(findByKeyword(root, "rolling"), kind: "session", windowMinutes: 300, nowMs: nowMs) { windows.append(w1) }
            let weeklyObj = findByKeyword(root, "weekly") ?? findByKeyword(root, "week")
            if let w2 = parseWindowObj(weeklyObj, kind: "weekly", windowMinutes: 10080, nowMs: nowMs) { windows.append(w2) }
            balanceUsd = findBalance(root)
        }

        if windows.isEmpty {
            if let r1 = extractWindowByRegex(text, windowKey: "rollingUsage", kind: "session", windowMinutes: 300, nowMs: nowMs) { windows.append(r1) }
            if let r2 = extractWindowByRegex(text, windowKey: "weeklyUsage", kind: "weekly", windowMinutes: 10080, nowMs: nowMs) { windows.append(r2) }
        }

        if balanceUsd == nil {
            let bm = try! NSRegularExpression(pattern: "(?:balanceUSD|currentBalance|zenBalance|balanceUsd)[^0-9-]{0,20}([0-9]+(?:\\.[0-9]+)?)", options: .caseInsensitive)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let m = bm.firstMatch(in: text, range: range),
               let r = Range(m.range(at: 1), in: text),
               let bv = Double(text[r]) {
                balanceUsd = bv
            }
        }
        return (windows, balanceUsd)
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("login") || l.contains("sign in") || l.contains("auth/authorize")
            || l.contains("not associated with an account") || l.contains("actor of type \"public\"")
    }

    private static func normalizeWorkspaceId(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let re = try! NSRegularExpression(pattern: "wrk_[A-Za-z0-9]+")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - fetchServerText / resolveWorkspaceId / fetchZen / fetchGoWeb

    private enum FetchError: Error { case timeout }

    private static func fetchServerText(
        serverId: String, args: [String]?, method: String, cookieHeader: String, referer: String
    ) async throws -> (status: Int, text: String) {
        let url = serverRequestUrl(serverId, args: args, method: method)
        var headers = buildHeaders(serverId, cookieHeader: cookieHeader, referer: referer)
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if method.uppercased() != "GET", let args {
            headers["Content-Type"] = "application/json"
            request.httpBody = try JSONSerialization.data(withJSONObject: args)
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        return (status, text)
    }

    private static func resolveWorkspaceId(cookie: String) async throws -> (status: String, workspaceId: String) {
        let cookieHeader = sanitizeCookieHeader(cookie)
        if cookieHeader.isEmpty {
            return ("notConfigured", "")
        }
        var wsText = try await fetchServerText(
            serverId: workspacesServerID, args: nil, method: "GET", cookieHeader: cookieHeader, referer: baseURL
        )
        if wsText.status == 401 || wsText.status == 403 || looksSignedOut(wsText.text) {
            return ("unauthorized", "")
        }
        var ids = parseWorkspaceIds(wsText.text)
        if ids.isEmpty {
            wsText = try await fetchServerText(
                serverId: workspacesServerID, args: [], method: "POST", cookieHeader: cookieHeader, referer: baseURL
            )
            if looksSignedOut(wsText.text) { return ("unauthorized", "") }
            ids = parseWorkspaceIds(wsText.text)
        }
        if ids.isEmpty { return ("unavailable", "") }
        return ("ok", ids[0])
    }

    private static func fetchZen(cookie: String, nowMs: Int64) async -> (status: String, windows: [Window], balanceUsd: Double?, workspaceId: String) {
        let fail = { (status: String) in
            (status: status, windows: [] as [Window], balanceUsd: nil as Double?, workspaceId: "" as String)
        }
        let sanitized = sanitizeCookieHeader(cookie)
        if sanitized.isEmpty { return fail("notConfigured") }

        do {
            let ws = try await resolveWorkspaceId(cookie: cookie)
            if ws.status != "ok" { return fail(ws.status) }
            let workspaceId = ws.workspaceId
            let referer = "\(baseURL)/workspace/\(workspaceId)/billing"

            func badSubStatus(_ r: (status: Int, text: String)) -> String? {
                if r.status == 429 { return "sourceRateLimited" }
                if r.status == 401 || r.status == 403 || looksSignedOut(r.text) { return "unauthorized" }
                return nil
            }
            func isExplicitNull(_ t: String) -> Bool {
                t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "null"
            }

            var subText = try await fetchServerText(
                serverId: subscriptionServerID, args: [workspaceId], method: "GET", cookieHeader: sanitized, referer: referer
            )
            if let bad = badSubStatus(subText) { return fail(bad) }
            var parsed = parseSubscription(subText.text, nowMs: nowMs)
            if parsed.windows.isEmpty && parsed.balanceUsd == nil && !isExplicitNull(subText.text) {
                subText = try await fetchServerText(
                    serverId: subscriptionServerID, args: [workspaceId], method: "POST", cookieHeader: sanitized, referer: referer
                )
                if let bad = badSubStatus(subText) { return fail(bad) }
                parsed = parseSubscription(subText.text, nowMs: nowMs)
            }
            return (status: "ok", windows: parsed.windows, balanceUsd: parsed.balanceUsd, workspaceId: workspaceId)
        } catch {
            return fail("unavailable")
        }
    }

    private static func fetchGoPageText(workspaceId: String, cookieHeader: String) async throws -> (status: Int, text: String) {
        let url = "\(baseURL)/workspace/\(workspaceId)/go"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        return (status, text)
    }

    private static func extractGoWindow(_ text: String, key: String, kind: String, nowMs: Int64) -> Window? {
        let pctRe = try! NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: key))[^}]*?usagePercent\\s*[:=]\\s*([0-9]+(?:\\.[0-9]+)?)")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let pm = pctRe.firstMatch(in: text, range: range),
              let gr = Range(pm.range(at: 1), in: text),
              let pv = Double(text[gr]) else { return nil }
        let resetRe = try! NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: key))[^}]*?resetInSec\\s*[:=]\\s*([0-9]+)")
        var resetSec = 0.0
        if let rm = resetRe.firstMatch(in: text, range: range),
           let rr = Range(rm.range(at: 1), in: text),
           let rv = Double(text[rr]) {
            resetSec = max(0, rv)
        }
        return Window(
            kind: kind,
            usedPercent: round1(clampPct(pv)),
            used: nil,
            limit: nil,
            resetsAt: Date(timeIntervalSince1970: Double(nowMs) / 1000 + resetSec),
            windowMinutes: goWindowMinutes[kind] ?? 0
        )
    }

    private static func parseGoUsageJson(_ text: String, nowMs: Int64) -> [Window] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSON, !root.isEmpty else { return [] }
        let rolling = parseWindowObj(findByKeyword(root, "rolling"), kind: "session", windowMinutes: goWindowMinutes["session"]!, nowMs: nowMs)
        let weeklyObj = findByKeyword(root, "weekly") ?? findByKeyword(root, "week")
        let weekly = parseWindowObj(weeklyObj, kind: "weekly", windowMinutes: goWindowMinutes["weekly"]!, nowMs: nowMs)
        let monthlyObj = findByKeyword(root, "monthly") ?? findByKeyword(root, "month")
        let monthly = parseWindowObj(monthlyObj, kind: "monthly", windowMinutes: goWindowMinutes["monthly"]!, nowMs: nowMs)
        guard let rolling, let weekly else { return [] }
        var windows = [rolling, weekly]
        if let monthly { windows.append(monthly) }
        return windows
    }

    private static func parseGoUsage(_ text: String, nowMs: Int64) -> [Window] {
        let fromJson = parseGoUsageJson(text, nowMs: nowMs)
        if !fromJson.isEmpty { return fromJson }
        guard let rolling = extractGoWindow(text, key: "rollingUsage", kind: "session", nowMs: nowMs),
              let weekly = extractGoWindow(text, key: "weeklyUsage", kind: "weekly", nowMs: nowMs) else { return [] }
        var windows = [rolling, weekly]
        if let monthly = extractGoWindow(text, key: "monthlyUsage", kind: "monthly", nowMs: nowMs) { windows.append(monthly) }
        return windows
    }

    private static func fetchGoWeb(cookie: String, nowMs: Int64) async -> (status: String, windows: [Window], workspaceId: String) {
        let fail = { (status: String, workspaceId: String) in
            (status: status, windows: [] as [Window], workspaceId: workspaceId as String)
        }
        let sanitized = sanitizeCookieHeader(cookie)
        if sanitized.isEmpty { return fail("notConfigured", "") }
        do {
            let ws = try await resolveWorkspaceId(cookie: cookie)
            if ws.status != "ok" { return fail(ws.status, "") }
            let workspaceId = ws.workspaceId
            let page = try await fetchGoPageText(workspaceId: workspaceId, cookieHeader: sanitized)
            if page.status == 429 { return fail("sourceRateLimited", workspaceId) }
            if page.status == 401 || page.status == 403 || looksSignedOut(page.text) {
                return fail("unauthorized", workspaceId)
            }
            if page.status != 200 { return fail("unavailable", workspaceId) }
            let windows = parseGoUsage(page.text, nowMs: nowMs)
            if windows.isEmpty { return fail("unavailable", workspaceId) }
            return (status: "ok", windows: windows, workspaceId: workspaceId)
        } catch {
            return fail("unavailable", "")
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
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
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
