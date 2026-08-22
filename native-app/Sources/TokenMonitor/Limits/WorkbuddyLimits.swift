import Foundation

/// WorkBuddy (Tencent CodeBuddy) local desktop app credits monitoring.
/// Reads local session from ~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/auth.json
/// and queries copilot.tencent.com billing APIs for Personal or Enterprise accounts.
enum WorkbuddyLimits {
    typealias JSON = [String: Any]

    static let defaultEndpoint = "https://copilot.tencent.com"
    static let personalPath = "/v2/billing/meter/get-user-resource"
    static let enterprisePath = "/v2/billing/meter/get-enterprise-user-usage"
    static let productCode = "p_tcaca"
    static let authFileNames = ["workbuddy-desktop.info", "auth.json"]
    static let logoutMarkerSuffixes = [".logged-out", ".logout"]
    static let maxAuthFileSize = 1024 * 1024 // 1 MB
    static let sessionExpirySkewMs: Int64 = 30 * 1000 // 30s
    static let userResourceUrl = "https://copilot.tencent.com/v2/billing/meter/get-user-resource"
    static let enterpriseUsageUrl = "https://copilot.tencent.com/v2/billing/meter/get-enterprise-user-usage"

    struct LocalSession {
        let accessToken: String
        let userId: String
        let enterpriseId: String
        let departmentFullName: String
        let domain: String
        let accountType: String
        let expiresAt: Int64?
        let expired: Bool
    }

    static func authDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth")
    }

    static func readLocalSession(nowMs: Int64) -> LocalSession? {
        let authDir = authDirectory()
        let fileManager = FileManager.default

        for authFileName in authFileNames {
            let authFile = authDir.appendingPathComponent(authFileName)
            let hasLogoutMarker = logoutMarkerSuffixes.contains { suffix in
                fileManager.fileExists(atPath: authFile.path + suffix)
            }
            if hasLogoutMarker {
                continue
            }
            guard fileManager.fileExists(atPath: authFile.path) else {
                continue
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: authFile.path),
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.intValue <= maxAuthFileSize else {
                continue
            }
            guard let data = try? Data(contentsOf: authFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let auth = json["auth"] as? [String: Any] ?? [:]
            let account = json["account"] as? [String: Any] ?? [:]

            let accessToken = (auth["accessToken"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let userId = String(describing: account["uid"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !accessToken.isEmpty && !userId.isEmpty else {
                continue
            }

            let enterpriseId = String(describing: account["enterpriseId"] ?? "").trimmingCharacters(in: .whitespaces)
            let departmentFullName = String(describing: account["departmentFullName"] ?? "").trimmingCharacters(in: .whitespaces)
            let domain = String(describing: auth["domain"] ?? "").trimmingCharacters(in: .whitespaces)
            let accountType = String(describing: account["accountType"] ?? account["type"] ?? "personal").trimmingCharacters(in: .whitespaces)

            let expiresAt: Int64?
            if let expNum = auth["expiresAt"] as? NSNumber {
                expiresAt = expNum.int64Value
            } else if let expStr = auth["expiresAt"] as? String, let parsed = Int64(expStr.trimmingCharacters(in: .whitespaces)) {
                expiresAt = parsed
            } else {
                expiresAt = nil
            }

            let expired = (expiresAt != nil) && (expiresAt! <= nowMs + sessionExpirySkewMs)

            return LocalSession(
                accessToken: accessToken,
                userId: userId,
                enterpriseId: enterpriseId,
                departmentFullName: departmentFullName,
                domain: domain,
                accountType: accountType,
                expiresAt: expiresAt,
                expired: expired
            )
        }
        return nil
    }

    static func fetchLimits(nowMs: Int64) async -> JSON {
        let now = nowMs > 0 ? nowMs : Int64(Date().timeIntervalSince1970 * 1000)
        let updatedAt = isoFromMs(now)

        guard let session = readLocalSession(nowMs: now) else {
            return notConfigured(updatedAt: updatedAt)
        }

        if session.expired {
            return unauthorized(updatedAt: updatedAt)
        }

        let isEnterprise = !session.enterpriseId.isEmpty
        let accountKey = isEnterprise
            ? CredentialHash.key(["workbuddy", "enterprise:\(session.enterpriseId):\(session.userId)"])
            : CredentialHash.key(["workbuddy", "user:\(session.userId)"])

        let endpoint = defaultEndpoint + (isEnterprise ? enterprisePath : personalPath)
        guard let url = URL(string: endpoint) else {
            return unavailable(accountKey: accountKey, updatedAt: updatedAt)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.userId, forHTTPHeaderField: "X-User-Id")

        if isEnterprise {
            request.setValue(session.enterpriseId, forHTTPHeaderField: "X-Enterprise-Id")
            request.setValue(session.enterpriseId, forHTTPHeaderField: "X-Tenant-Id")
        }
        if !session.domain.isEmpty {
            request.setValue(session.domain, forHTTPHeaderField: "X-Domain")
        }
        if !session.departmentFullName.isEmpty {
            request.setValue(session.departmentFullName, forHTTPHeaderField: "X-Department-Info")
        }

        if isEnterprise {
            request.httpBody = Data("{}".utf8)
        } else {
            let bodyDict: [String: Any] = [
                "PageNumber": 1,
                "PageSize": 100,
                "ProductCode": productCode,
                "Status": [0],
                "OnlyValidPeriod": true
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return unavailable(accountKey: accountKey, updatedAt: updatedAt)
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return unauthorized(accountKey: accountKey, updatedAt: updatedAt)
            }
            if httpResponse.statusCode == 429 {
                return statusProvider("sourceRateLimited", accountKey: accountKey, updatedAt: updatedAt)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                return unavailable(accountKey: accountKey, updatedAt: updatedAt)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return unavailable(accountKey: accountKey, updatedAt: updatedAt)
            }

            if let code = json["code"] as? Int, code != 0 && code != 200 {
                if code == 401 || code == 403 {
                    return unauthorized(accountKey: accountKey, updatedAt: updatedAt)
                }
                if code == 429 {
                    return statusProvider("sourceRateLimited", accountKey: accountKey, updatedAt: updatedAt)
                }
                return statusProvider("error", accountKey: accountKey, updatedAt: updatedAt)
            }

            if isEnterprise {
                return parseEnterpriseUsage(json: json, session: session, accountKey: accountKey, updatedAt: updatedAt)
            } else {
                return parsePersonalUsage(json: json, session: session, accountKey: accountKey, updatedAt: updatedAt)
            }
        } catch {
            return unavailable(accountKey: accountKey, updatedAt: updatedAt)
        }
    }

    private static func parseEnterpriseUsage(json: [String: Any], session: LocalSession, accountKey: String, updatedAt: String) -> JSON {
        let usage = unwrapEnterpriseUsage(json)
        guard let rawLimit = numberOrNull(usage?["limitNum"] ?? usage?["limit_num"]) else {
            return statusProvider("error", accountKey: accountKey, updatedAt: updatedAt)
        }
        guard let rawUsed = numberOrNull(usage?["credit"] ?? usage?["used"] ?? usage?["usedNum"] ?? usage?["used_num"]) else {
            return statusProvider("error", accountKey: accountKey, updatedAt: updatedAt)
        }

        let used = max(0, rawUsed)
        let resetsAt = toIso(usage?["cycleResetTime"] ?? usage?["cycle_reset_time"])

        if rawLimit < 0 {
            // Unlimited Credits
            let window: JSON = [
                "kind": "billing",
                "label": "Credits",
                "metric": "credits",
                "currency": "CREDITS",
                "used": used,
                "limit": NSNull(),
                "remaining": NSNull(),
                "usedPercent": NSNull(),
                "remainingPercent": NSNull(),
                "detail": "unlimited",
                "resetsAt": resetsAt ?? NSNull(),
                "showMeter": false
            ]
            return [
                "provider": "workbuddy",
                "accountKey": accountKey,
                "accountLabel": "Enterprise",
                "source": "local",
                "sourceDetail": "app",
                "status": "ok",
                "updatedAt": updatedAt,
                "windows": [window]
            ]
        }

        let limit = max(0, rawLimit)
        let remaining = max(0, limit - used)
        let usedPercent: Any = limit > 0 ? (used / limit) * 100.0 : NSNull()
        let remainingPercent: Any = limit > 0 ? max(0, 100.0 - ((used / limit) * 100.0)) : NSNull()

        let window: JSON = [
            "kind": "billing",
            "label": "Credits",
            "metric": "credits",
            "currency": "CREDITS",
            "used": used,
            "limit": limit,
            "remaining": remaining,
            "usedPercent": usedPercent,
            "remainingPercent": remainingPercent,
            "resetsAt": resetsAt ?? NSNull(),
            "showMeter": limit > 0
        ]

        return [
            "provider": "workbuddy",
            "accountKey": accountKey,
            "accountLabel": "Enterprise",
            "source": "local",
            "sourceDetail": "app",
            "status": "ok",
            "updatedAt": updatedAt,
            "windows": [window],
            "balance": [
                "amount": remaining,
                "currency": "CREDITS"
            ]
        ]
    }

    private static func parsePersonalUsage(json: [String: Any], session: LocalSession, accountKey: String, updatedAt: String) -> JSON {
        guard let accounts = pickAccountsArray(json) else {
            return statusProvider("error", accountKey: accountKey, updatedAt: updatedAt)
        }

        var limit: Double = 0
        var remaining: Double = 0
        var used: Double = 0
        var validResources = 0

        for item in accounts {
            guard let resource = item as? [String: Any] else { continue }
            let status = numberOrNull(resource["Status"] ?? resource["status"])
            // Status 0 is active. Status 3 is exhausted/expired.
            if let s = status, s != 0 {
                continue
            }

            guard let total = numberOrNull(resource["CycleCapacitySizePrecise"] ?? resource["cycleCapacitySizePrecise"]),
                  let left = numberOrNull(resource["CycleCapacityRemainPrecise"] ?? resource["cycleCapacityRemainPrecise"]),
                  total >= 0, left >= 0 else {
                continue
            }

            let safeTotal = total
            let safeRemaining = min(safeTotal, left)
            let reportedUsed = numberOrNull(resource["CycleCapacityUsedPrecise"] ?? resource["cycleCapacityUsedPrecise"])
            let safeUsed = reportedUsed == nil ? max(0, safeTotal - safeRemaining) : min(safeTotal, max(0, reportedUsed!))

            limit += safeTotal
            remaining += safeRemaining
            used += safeUsed
            validResources += 1
        }

        if validResources == 0 {
            return [
                "provider": "workbuddy",
                "accountKey": accountKey,
                "accountLabel": "Personal",
                "source": "local",
                "sourceDetail": "app",
                "status": "ok",
                "updatedAt": updatedAt,
                "windows": [Any](),
                "balance": [
                    "amount": 0.0,
                    "currency": "CREDITS"
                ]
            ]
        }

        let usedPercent: Any = limit > 0 ? (used / limit) * 100.0 : NSNull()
        let remainingPercent: Any = limit > 0 ? max(0, 100.0 - ((used / limit) * 100.0)) : NSNull()

        let window: JSON = [
            "kind": "billing",
            "label": "Credits",
            "metric": "credits",
            "currency": "CREDITS",
            "used": used,
            "limit": limit,
            "remaining": remaining,
            "usedPercent": usedPercent,
            "remainingPercent": remainingPercent,
            "resetsAt": NSNull(),
            "showMeter": limit > 0
        ]

        return [
            "provider": "workbuddy",
            "accountKey": accountKey,
            "accountLabel": "Personal",
            "source": "local",
            "sourceDetail": "app",
            "status": "ok",
            "updatedAt": updatedAt,
            "windows": [window],
            "balance": [
                "amount": remaining,
                "currency": "CREDITS"
            ]
        ]
    }

    private static func unwrapEnterpriseUsage(_ body: [String: Any]) -> [String: Any]? {
        if let data = body["data"] as? [String: Any] {
            if let subData = data["data"] as? [String: Any] { return subData }
            return data
        }
        if let data = body["Data"] as? [String: Any] { return data }
        return body
    }

    private static func pickAccountsArray(_ body: [String: Any]) -> [Any]? {
        let paths: [[String]] = [
            ["data", "Response", "Data", "Accounts"],
            ["data", "data", "Response", "Data", "Accounts"],
            ["Response", "Data", "Accounts"],
            ["data", "Accounts"],
            ["Accounts"],
            ["data", "response", "data", "accounts"],
            ["response", "data", "accounts"]
        ]
        for path in paths {
            var current: Any? = body
            for key in path {
                if let dict = current as? [String: Any] {
                    current = dict[key]
                } else {
                    current = nil
                    break
                }
            }
            if let array = current as? [Any] {
                return array
            }
        }
        return nil
    }

    private static func numberOrNull(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let num = value as? NSNumber { return num.doubleValue }
        if let str = value as? String, let d = Double(str.trimmingCharacters(in: .whitespaces)) { return d }
        return nil
    }

    private static func toIso(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let num = value as? NSNumber {
            let date = Date(timeIntervalSince1970: num.doubleValue / 1000.0)
            return ISO8601DateFormatter().string(from: date)
        }
        if let str = value as? String {
            if let ms = Double(str.trimmingCharacters(in: .whitespaces)) {
                let date = Date(timeIntervalSince1970: ms / 1000.0)
                return ISO8601DateFormatter().string(from: date)
            }
        }
        return nil
    }

    private static func notConfigured(updatedAt: String) -> JSON {
        return [
            "provider": "workbuddy",
            "source": "local",
            "sourceDetail": "app",
            "status": "notConfigured",
            "updatedAt": updatedAt,
            "windows": [Any]()
        ]
    }

    private static func unauthorized(accountKey: String? = nil, updatedAt: String) -> JSON {
        var dict: JSON = [
            "provider": "workbuddy",
            "source": "local",
            "sourceDetail": "app",
            "status": "unauthorized",
            "updatedAt": updatedAt,
            "windows": [Any]()
        ]
        if let accountKey { dict["accountKey"] = accountKey }
        return dict
    }

    private static func unavailable(accountKey: String? = nil, updatedAt: String) -> JSON {
        var dict: JSON = [
            "provider": "workbuddy",
            "source": "local",
            "sourceDetail": "app",
            "status": "unavailable",
            "updatedAt": updatedAt,
            "windows": [Any]()
        ]
        if let accountKey { dict["accountKey"] = accountKey }
        return dict
    }

    private static func statusProvider(_ status: String, accountKey: String? = nil, updatedAt: String) -> JSON {
        var dict: JSON = [
            "provider": "workbuddy",
            "source": "local",
            "sourceDetail": "app",
            "status": status,
            "updatedAt": updatedAt,
            "windows": [Any]()
        ]
        if let accountKey { dict["accountKey"] = accountKey }
        return dict
    }

    private static func isoFromMs(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        return ISO8601DateFormatter().string(from: date)
    }
}
