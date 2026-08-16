import Foundation

/// Wire-exact port of the period/session shapes from src/shared/usage.js.
/// The renderer consumes these dictionaries, so keys must match the
/// Electron wire contract exactly.
enum UsageCore {
    typealias JSON = [String: Any]

    // MARK: - Period

    static func emptyPeriod() -> JSON {
        return [
            "totalTokens": 0,
            "costUsd": 0.0,
            "cacheReadTokens": 0,
            "cacheWriteTokens": 0,
            "outputTokens": 0,
            "timedTokens": 0,
            "timedOutputTokens": 0,
            "timedDurationMs": 0,
            "clients": JSON(),
            "clientCosts": JSON(),
            "clientCacheReads": JSON(),
            "clientCacheWrites": JSON(),
            "clientOutputs": JSON(),
            "models": JSON(),
            "modelCosts": JSON(),
            "modelCacheReads": JSON(),
            "modelCacheWrites": JSON(),
            "modelOutputs": JSON(),
            "clientModels": JSON(),
            "clientModelCosts": JSON(),
            "projects": JSON(),
            "sessions": JSON()
        ]
    }

    static func emptySession(client: String, id: String) -> JSON {
        return [
            "client": client,
            "sessionId": id,
            "totalTokens": 0,
            "costUsd": 0.0,
            "messageCount": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "cacheReadTokens": 0,
            "cacheWriteTokens": 0,
            "reasoningTokens": 0,
            "startedAt": "",
            "lastUsedAt": "",
            "projectId": "",
            "projectLabel": "",
            "models": JSON(),
            "modelCosts": JSON(),
            "providers": JSON()
        ]
    }

    static func normalizeClientName(_ value: Any?) -> String? {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if raw.isEmpty { return nil }
        for id in ["claude", "codex", "opencode", "workbuddy", "proma", "hanako", "dsh", "hermes", "gemini", "cursor"] {
            if raw.contains(id) { return id }
        }
        let cleaned = raw.replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func normalizeModelName(_ value: Any?) -> String? {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return raw.isEmpty ? nil : raw
    }

    static func normalizeProviderName(_ value: Any?) -> String? {
        let raw = String(describing: value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let cleaned = raw.replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func intValue(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let n = value as? Int { return n }
        if let n = value as? Double, n.isFinite { return max(0, Int(n.rounded())) }
        if let s = value as? String, let n = Double(s), n.isFinite { return max(0, Int(n.rounded())) }
        return 0
    }

    static func doubleValue(_ value: Any?) -> Double {
        guard let value else { return 0 }
        if let n = value as? Double { return n.isFinite ? n : 0 }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String, let n = Double(s) { return n.isFinite ? n : 0 }
        return 0
    }

    /// Shared ISO8601 formatters: creating an ISO8601DateFormatter is
    /// expensive (~0.2-0.5ms), and timestampMs/isoFromMs run once per row
    /// per period during every derive — per-call instances made a dsh
    /// re-derive take seconds. Instances are immutable; a lock guards the
    /// (negligibly contended) shared use.
    private static let iso8601Lock = NSLock()
    private static let iso8601Parser = ISO8601DateFormatter()
    private static let iso8601Writer = ISO8601DateFormatter()

    /// Row timestamps repeat across ticks (the same rows are re-derived on
    /// every append), so memoize string → ms parses; the cache turns a warm
    /// derive's per-row parsing into dict lookups. Bounded to keep junk
    /// strings (e.g. malformed lines) from growing it unboundedly.
    private static let timestampCacheLock = NSLock()
    private static var timestampCache: [String: Double] = [:]
    private static let timestampCacheLimit = 50_000

    static func timestampMs(_ value: Any?) -> Double {
        guard let value else { return 0 }
        if let n = value as? Double, n.isFinite { return n > 0 && n < 1e12 ? n * 1000 : n }
        if let n = value as? Int { return Double(n) > 0 && Double(n) < 1e12 ? Double(n) * 1000 : Double(n) }
        if let s = value as? String, !s.isEmpty {
            if let n = Double(s), n.isFinite { return n > 0 && n < 1e12 ? n * 1000 : n }
            timestampCacheLock.lock()
            let cached = timestampCache[s]
            timestampCacheLock.unlock()
            if let cached { return cached }
            iso8601Lock.lock()
            // Fast static formatters first (they cover every canonical shape
            // we emit), then the ISO8601 parser for exotic variants.
            let parsed = RFC3339DateParser.parse(s) ?? iso8601Parser.date(from: s)
            iso8601Lock.unlock()
            let ms = parsed.map { $0.timeIntervalSince1970 * 1000 } ?? 0
            timestampCacheLock.lock()
            if timestampCache.count < timestampCacheLimit { timestampCache[s] = ms }
            timestampCacheLock.unlock()
            return ms
        }
        return 0
    }

    private enum RFC3339DateParser {
        static let withFractional: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
            return f
        }()
        static let plain: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            return f
        }()
        static func parse(_ s: String) -> Date? {
            return withFractional.date(from: s) ?? plain.date(from: s)
        }
    }

    static func isoFromMs(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        iso8601Lock.lock()
        let out = iso8601Writer.string(from: Date(timeIntervalSince1970: ms / 1000))
        iso8601Lock.unlock()
        return out
    }

    // MARK: - Row → period

    struct UsageRow {
        var client: String?
        var sessionId: String?
        var model: String?
        var provider: String?
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
        var reasoning: Double
        var messageCount: Double
        var cost: Double
        var startedAt: String
        var lastUsedAt: String
        var projectId: String
        var projectLabel: String
        var performance: TokscalePerformance?
    }

    static func rowFromTokscaleEntry(_ entry: TokscaleEntry) -> UsageRow {
        return UsageRow(
            client: entry.client,
            sessionId: entry.sessionId,
            model: entry.model,
            provider: entry.provider,
            input: entry.input,
            output: entry.output,
            cacheRead: entry.cacheRead,
            cacheWrite: entry.cacheWrite,
            reasoning: entry.reasoning ?? 0,
            messageCount: entry.messageCount ?? 0,
            cost: entry.cost,
            startedAt: entry.startedAt ?? "",
            lastUsedAt: entry.lastUsedAt ?? "",
            projectId: entry.projectId ?? "",
            projectLabel: entry.projectLabel ?? "",
            performance: entry.performance
        )
    }

    // MARK: - Typed aggregation structs

    /// Strongly-typed intermediate aggregation struct. The collector hot
    /// path previously operated on [String: Any] JSON dictionaries — every
    /// row required 13 sub-dictionary unboxes (as? JSON) plus intValue/
    /// doubleValue type-probing on each field. This struct eliminates all
    /// Any-boxing during aggregation; toJSON() is the only place values
    /// cross into the JSON wire shape.
    struct TypedSession {
        var client: String
        var sessionId: String
        var totalTokens: Int = 0
        var costUsd: Double = 0
        var messageCount: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
        var reasoningTokens: Int = 0
        var startedAtMs: Double = 0
        var lastUsedAtMs: Double = 0
        var projectId: String = ""
        var projectLabel: String = ""
        var models: [String: Int] = [:]
        var modelCosts: [String: Double] = [:]
        var providers: [String: Int] = [:]

        init(client: String, sessionId: String) {
            self.client = client
            self.sessionId = sessionId
        }

        init(from json: JSON) {
            client = json["client"] as? String ?? ""
            sessionId = json["sessionId"] as? String ?? ""
            totalTokens = intValue(json["totalTokens"])
            costUsd = doubleValue(json["costUsd"])
            messageCount = intValue(json["messageCount"])
            inputTokens = intValue(json["inputTokens"])
            outputTokens = intValue(json["outputTokens"])
            cacheReadTokens = intValue(json["cacheReadTokens"])
            cacheWriteTokens = intValue(json["cacheWriteTokens"])
            reasoningTokens = intValue(json["reasoningTokens"])
            startedAtMs = timestampMs(json["startedAt"])
            lastUsedAtMs = timestampMs(json["lastUsedAt"])
            projectId = json["projectId"] as? String ?? ""
            projectLabel = json["projectLabel"] as? String ?? ""
            if let m = json["models"] as? JSON { models = m.mapValues { intValue($0) } }
            if let mc = json["modelCosts"] as? JSON { modelCosts = mc.mapValues { doubleValue($0) } }
            if let p = json["providers"] as? JSON { providers = p.mapValues { intValue($0) } }
        }

        mutating func merge(row: UsageRow, model: String?, tokens: Int, cost: Double, cacheRead: Int, cacheWrite: Int, output: Int) {
            totalTokens += tokens
            costUsd += cost
            messageCount += max(0, Int(row.messageCount.rounded()))
            inputTokens += max(0, Int(row.input.rounded()))
            outputTokens += output
            cacheReadTokens += cacheRead
            cacheWriteTokens += cacheWrite
            reasoningTokens += max(0, Int(row.reasoning.rounded()))
            let rowStartedMs = timestampMs(row.startedAt)
            if rowStartedMs > 0 && (startedAtMs == 0 || rowStartedMs < startedAtMs) {
                startedAtMs = rowStartedMs
            }
            let rowLastMs = timestampMs(row.lastUsedAt)
            if rowLastMs > lastUsedAtMs {
                lastUsedAtMs = rowLastMs
            }
            if projectId.isEmpty && !row.projectId.isEmpty {
                projectId = row.projectId
                projectLabel = row.projectLabel
            }
            if let model, tokens > 0 {
                models[model, default: 0] += tokens
            }
            if let model, cost > 0 {
                modelCosts[model, default: 0] += cost
            }
            if let provider = normalizeProviderName(row.provider ?? ""), tokens > 0 {
                providers[provider, default: 0] += tokens
            }
        }

        mutating func mergeTyped(_ other: TypedSession) {
            totalTokens += other.totalTokens
            costUsd += other.costUsd
            messageCount += other.messageCount
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cacheReadTokens += other.cacheReadTokens
            cacheWriteTokens += other.cacheWriteTokens
            reasoningTokens += other.reasoningTokens
            if other.startedAtMs > 0 && (startedAtMs == 0 || other.startedAtMs < startedAtMs) {
                startedAtMs = other.startedAtMs
            }
            if other.lastUsedAtMs > lastUsedAtMs {
                lastUsedAtMs = other.lastUsedAtMs
            }
            if projectId.isEmpty && !other.projectId.isEmpty {
                projectId = other.projectId
                projectLabel = other.projectLabel
            }
            for (k, v) in other.models { models[k, default: 0] += v }
            for (k, v) in other.modelCosts { modelCosts[k, default: 0] += v }
            for (k, v) in other.providers { providers[k, default: 0] += v }
        }

        func toJSON() -> JSON {
            return [
                "client": client,
                "sessionId": sessionId,
                "totalTokens": totalTokens,
                "costUsd": costUsd,
                "messageCount": messageCount,
                "inputTokens": inputTokens,
                "outputTokens": outputTokens,
                "cacheReadTokens": cacheReadTokens,
                "cacheWriteTokens": cacheWriteTokens,
                "reasoningTokens": reasoningTokens,
                "startedAt": startedAtMs > 0 ? isoFromMs(startedAtMs) : "",
                "lastUsedAt": lastUsedAtMs > 0 ? isoFromMs(lastUsedAtMs) : "",
                "projectId": projectId,
                "projectLabel": projectLabel,
                "models": models,
                "modelCosts": modelCosts,
                "providers": providers
            ]
        }
    }

    struct TypedPeriod {
        var totalTokens: Int = 0
        var costUsd: Double = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
        var outputTokens: Int = 0
        var timedTokens: Int = 0
        var timedOutputTokens: Int = 0
        var timedDurationMs: Int = 0
        var clients: [String: Int] = [:]
        var clientCosts: [String: Double] = [:]
        var clientCacheReads: [String: Int] = [:]
        var clientCacheWrites: [String: Int] = [:]
        var clientOutputs: [String: Int] = [:]
        var models: [String: Int] = [:]
        var modelCosts: [String: Double] = [:]
        var modelCacheReads: [String: Int] = [:]
        var modelCacheWrites: [String: Int] = [:]
        var modelOutputs: [String: Int] = [:]
        var clientModels: [String: [String: Int]] = [:]
        var clientModelCosts: [String: [String: Double]] = [:]
        var sessions: [String: TypedSession] = [:]

        init() {}

        init(from json: JSON) {
            totalTokens = intValue(json["totalTokens"])
            costUsd = doubleValue(json["costUsd"])
            cacheReadTokens = intValue(json["cacheReadTokens"])
            cacheWriteTokens = intValue(json["cacheWriteTokens"])
            outputTokens = intValue(json["outputTokens"])
            timedTokens = intValue(json["timedTokens"])
            timedOutputTokens = intValue(json["timedOutputTokens"])
            timedDurationMs = intValue(json["timedDurationMs"])
            if let v = json["clients"] as? JSON { clients = v.mapValues { intValue($0) } }
            if let v = json["clientCosts"] as? JSON { clientCosts = v.mapValues { doubleValue($0) } }
            if let v = json["clientCacheReads"] as? JSON { clientCacheReads = v.mapValues { intValue($0) } }
            if let v = json["clientCacheWrites"] as? JSON { clientCacheWrites = v.mapValues { intValue($0) } }
            if let v = json["clientOutputs"] as? JSON { clientOutputs = v.mapValues { intValue($0) } }
            if let v = json["models"] as? JSON { models = v.mapValues { intValue($0) } }
            if let v = json["modelCosts"] as? JSON { modelCosts = v.mapValues { doubleValue($0) } }
            if let v = json["modelCacheReads"] as? JSON { modelCacheReads = v.mapValues { intValue($0) } }
            if let v = json["modelCacheWrites"] as? JSON { modelCacheWrites = v.mapValues { intValue($0) } }
            if let v = json["modelOutputs"] as? JSON { modelOutputs = v.mapValues { intValue($0) } }
            if let v = json["clientModels"] as? JSON {
                clientModels = v.mapValues { sub in (sub as? JSON ?? [:]).mapValues { intValue($0) } }
            }
            if let v = json["clientModelCosts"] as? JSON {
                clientModelCosts = v.mapValues { sub in (sub as? JSON ?? [:]).mapValues { doubleValue($0) } }
            }
            if let v = json["sessions"] as? JSON {
                for (key, val) in v {
                    if let sJSON = val as? JSON {
                        sessions[key] = TypedSession(from: sJSON)
                    }
                }
            }
        }

        mutating func addRow(_ row: UsageRow) {
            let client = normalizeClientName(row.client ?? "")
            let tokens = row.input + row.output + row.cacheRead + row.cacheWrite
            let cost = row.cost
            let cacheRead = max(0, Int(row.cacheRead.rounded()))
            let cacheWrite = max(0, Int(row.cacheWrite.rounded()))
            let output = max(0, Int(row.output.rounded()))
            let timedTokens = max(0, Int((row.performance?.timedTokens ?? 0).rounded()))
            let timedDurationMs = max(0, Int((row.performance?.totalDurationMs ?? 0).rounded()))
            let timedOutputTokens = timedDurationMs > 0 ? output : 0
            var model = normalizeModelName(row.model ?? "")
            if client == "cursor" && model == "auto" { model = "cursor-auto" }

            let tokenCount = max(0, Int(tokens.rounded()))
            totalTokens += tokenCount
            costUsd += cost
            cacheReadTokens += cacheRead
            cacheWriteTokens += cacheWrite
            outputTokens += output
            self.timedTokens += timedTokens
            self.timedOutputTokens += timedOutputTokens
            self.timedDurationMs += timedDurationMs

            if let client, tokenCount > 0 {
                clients[client, default: 0] += tokenCount
                if cacheRead > 0 { clientCacheReads[client, default: 0] += cacheRead }
                if cacheWrite > 0 { clientCacheWrites[client, default: 0] += cacheWrite }
                if output > 0 { clientOutputs[client, default: 0] += output }
            }
            if let client, cost > 0 { clientCosts[client, default: 0] += cost }
            if let model, tokenCount > 0 {
                models[model, default: 0] += tokenCount
                if cacheRead > 0 { modelCacheReads[model, default: 0] += cacheRead }
                if cacheWrite > 0 { modelCacheWrites[model, default: 0] += cacheWrite }
                if output > 0 { modelOutputs[model, default: 0] += output }
            }
            if let model, cost > 0 { modelCosts[model, default: 0] += cost }
            if let client, let model, tokenCount > 0 {
                clientModels[client, default: [:]][model, default: 0] += tokenCount
            }
            if let client, let model, cost > 0 {
                clientModelCosts[client, default: [:]][model, default: 0] += cost
            }

            if let client, let id = row.sessionId, !id.isEmpty {
                let key = "\(client):\(id)"
                var session = sessions[key] ?? TypedSession(client: client, sessionId: id)
                session.merge(row: row, model: model, tokens: tokenCount, cost: cost, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
                sessions[key] = session
            }
        }

        mutating func merge(_ other: TypedPeriod) {
            totalTokens += other.totalTokens
            costUsd += other.costUsd
            cacheReadTokens += other.cacheReadTokens
            cacheWriteTokens += other.cacheWriteTokens
            outputTokens += other.outputTokens
            timedTokens += other.timedTokens
            timedOutputTokens += other.timedOutputTokens
            timedDurationMs += other.timedDurationMs
            for (k, v) in other.clients { clients[k, default: 0] += v }
            for (k, v) in other.clientCosts { clientCosts[k, default: 0] += v }
            for (k, v) in other.clientCacheReads { clientCacheReads[k, default: 0] += v }
            for (k, v) in other.clientCacheWrites { clientCacheWrites[k, default: 0] += v }
            for (k, v) in other.clientOutputs { clientOutputs[k, default: 0] += v }
            for (k, v) in other.models { models[k, default: 0] += v }
            for (k, v) in other.modelCosts { modelCosts[k, default: 0] += v }
            for (k, v) in other.modelCacheReads { modelCacheReads[k, default: 0] += v }
            for (k, v) in other.modelCacheWrites { modelCacheWrites[k, default: 0] += v }
            for (k, v) in other.modelOutputs { modelOutputs[k, default: 0] += v }
            for (client, sub) in other.clientModels {
                for (model, v) in sub {
                    clientModels[client, default: [:]][model, default: 0] += v
                }
            }
            for (client, sub) in other.clientModelCosts {
                for (model, v) in sub {
                    clientModelCosts[client, default: [:]][model, default: 0] += v
                }
            }
            for (key, s) in other.sessions {
                if var existing = sessions[key] {
                    existing.mergeTyped(s)
                    sessions[key] = existing
                } else {
                    sessions[key] = s
                }
            }
        }

        func toJSON() -> JSON {
            var sessionsJSON: JSON = [:]
            for (key, s) in sessions {
                sessionsJSON[key] = s.toJSON()
            }
            return [
                "totalTokens": totalTokens,
                "costUsd": costUsd,
                "cacheReadTokens": cacheReadTokens,
                "cacheWriteTokens": cacheWriteTokens,
                "outputTokens": outputTokens,
                "timedTokens": timedTokens,
                "timedOutputTokens": timedOutputTokens,
                "timedDurationMs": timedDurationMs,
                "clients": clients,
                "clientCosts": clientCosts,
                "clientCacheReads": clientCacheReads,
                "clientCacheWrites": clientCacheWrites,
                "clientOutputs": clientOutputs,
                "models": models,
                "modelCosts": modelCosts,
                "modelCacheReads": modelCacheReads,
                "modelCacheWrites": modelCacheWrites,
                "modelOutputs": modelOutputs,
                "clientModels": clientModels,
                "clientModelCosts": clientModelCosts,
                "projects": JSON(),
                "sessions": sessionsJSON
            ]
        }
    }

    /// Port of addUsageRowToPeriod: row-level token totals, per-client and
    /// per-model rollups, and the session bucket.
    static func addUsageRowToPeriod(_ period: inout JSON, row: UsageRow) {
        let client = normalizeClientName(row.client ?? "")
        let tokens = row.input + row.output + row.cacheRead + row.cacheWrite
        let cost = row.cost
        let cacheRead = max(0, Int(row.cacheRead.rounded()))
        let cacheWrite = max(0, Int(row.cacheWrite.rounded()))
        let output = max(0, Int(row.output.rounded()))
        let timedTokens = max(0, Int((row.performance?.timedTokens ?? 0).rounded()))
        let timedDurationMs = max(0, Int((row.performance?.totalDurationMs ?? 0).rounded()))
        let timedOutputTokens = timedDurationMs > 0 ? output : 0
        var model = normalizeModelName(row.model ?? "")
        if client == "cursor" && model == "auto" { model = "cursor-auto" }

        period["totalTokens"] = intValue(period["totalTokens"]) + max(0, Int(tokens.rounded()))
        period["costUsd"] = doubleValue(period["costUsd"]) + cost
        period["cacheReadTokens"] = intValue(period["cacheReadTokens"]) + cacheRead
        period["cacheWriteTokens"] = intValue(period["cacheWriteTokens"]) + cacheWrite
        period["outputTokens"] = intValue(period["outputTokens"]) + output
        period["timedTokens"] = intValue(period["timedTokens"]) + timedTokens
        period["timedOutputTokens"] = intValue(period["timedOutputTokens"]) + timedOutputTokens
        period["timedDurationMs"] = intValue(period["timedDurationMs"]) + timedDurationMs

        var clients = period["clients"] as? JSON ?? JSON()
        var clientCosts = period["clientCosts"] as? JSON ?? JSON()
        var clientCacheReads = period["clientCacheReads"] as? JSON ?? JSON()
        var clientCacheWrites = period["clientCacheWrites"] as? JSON ?? JSON()
        var clientOutputs = period["clientOutputs"] as? JSON ?? JSON()
        var models = period["models"] as? JSON ?? JSON()
        var modelCosts = period["modelCosts"] as? JSON ?? JSON()
        var modelCacheReads = period["modelCacheReads"] as? JSON ?? JSON()
        var modelCacheWrites = period["modelCacheWrites"] as? JSON ?? JSON()
        var modelOutputs = period["modelOutputs"] as? JSON ?? JSON()
        var clientModels = period["clientModels"] as? JSON ?? JSON()
        var clientModelCosts = period["clientModelCosts"] as? JSON ?? JSON()
        var sessions = period["sessions"] as? JSON ?? JSON()

        let tokenCount = max(0, Int(tokens.rounded()))
        if let client, tokenCount > 0 {
            clients[client] = intValue(clients[client]) + tokenCount
            if cacheRead > 0 { clientCacheReads[client] = intValue(clientCacheReads[client]) + cacheRead }
            if cacheWrite > 0 { clientCacheWrites[client] = intValue(clientCacheWrites[client]) + cacheWrite }
            if output > 0 { clientOutputs[client] = intValue(clientOutputs[client]) + output }
        }
        if let client, cost > 0 { clientCosts[client] = doubleValue(clientCosts[client]) + cost }
        if let model, tokenCount > 0 {
            models[model] = intValue(models[model]) + tokenCount
            if cacheRead > 0 { modelCacheReads[model] = intValue(modelCacheReads[model]) + cacheRead }
            if cacheWrite > 0 { modelCacheWrites[model] = intValue(modelCacheWrites[model]) + cacheWrite }
            if output > 0 { modelOutputs[model] = intValue(modelOutputs[model]) + output }
        }
        if let model, cost > 0 { modelCosts[model] = doubleValue(modelCosts[model]) + cost }
        if let client, let model, tokenCount > 0 {
            var byModel = clientModels[client] as? JSON ?? JSON()
            byModel[model] = intValue(byModel[model]) + tokenCount
            clientModels[client] = byModel
        }
        if let client, let model, cost > 0 {
            var byModel = clientModelCosts[client] as? JSON ?? JSON()
            byModel[model] = doubleValue(byModel[model]) + cost
            clientModelCosts[client] = byModel
        }

        if let session = sessionFromRow(row) {
            addSession(&sessions, session: session)
        }

        period["clients"] = clients
        period["clientCosts"] = clientCosts
        period["clientCacheReads"] = clientCacheReads
        period["clientCacheWrites"] = clientCacheWrites
        period["clientOutputs"] = clientOutputs
        period["models"] = models
        period["modelCosts"] = modelCosts
        period["modelCacheReads"] = modelCacheReads
        period["modelCacheWrites"] = modelCacheWrites
        period["modelOutputs"] = modelOutputs
        period["clientModels"] = clientModels
        period["clientModelCosts"] = clientModelCosts
        period["sessions"] = sessions
    }

    /// Port of sessionFromRow + addSession/mergeSession.
    static func sessionFromRow(_ row: UsageRow) -> JSON? {
        guard let client = normalizeClientName(row.client ?? ""), let id = row.sessionId, !id.isEmpty else { return nil }
        var session = emptySession(client: client, id: id)
        session["totalTokens"] = max(0, Int((row.input + row.output + row.cacheRead + row.cacheWrite).rounded()))
        session["costUsd"] = row.cost
        session["messageCount"] = max(0, Int(row.messageCount.rounded()))
        session["inputTokens"] = max(0, Int(row.input.rounded()))
        session["outputTokens"] = max(0, Int(row.output.rounded()))
        session["cacheReadTokens"] = max(0, Int(row.cacheRead.rounded()))
        session["cacheWriteTokens"] = max(0, Int(row.cacheWrite.rounded()))
        session["reasoningTokens"] = max(0, Int(row.reasoning.rounded()))
        session["startedAt"] = row.startedAt
        session["lastUsedAt"] = row.lastUsedAt
        session["projectId"] = row.projectId
        session["projectLabel"] = row.projectLabel
        if let model = normalizeModelName(row.model ?? ""), intValue(session["totalTokens"]) > 0 {
            var models = session["models"] as? JSON ?? JSON()
            models[model] = intValue(models[model]) + intValue(session["totalTokens"])
            session["models"] = models
        }
        if let model = normalizeModelName(row.model ?? ""), row.cost > 0 {
            var costs = session["modelCosts"] as? JSON ?? JSON()
            costs[model] = doubleValue(costs[model]) + row.cost
            session["modelCosts"] = costs
        }
        if let provider = normalizeProviderName(row.provider ?? ""), intValue(session["totalTokens"]) > 0 {
            var providers = session["providers"] as? JSON ?? JSON()
            providers[provider] = intValue(providers[provider]) + intValue(session["totalTokens"])
            session["providers"] = providers
        }
        return session
    }

    static func addSession(_ sessions: inout JSON, session: JSON) {
        guard let client = session["client"] as? String, let id = session["sessionId"] as? String else { return }
        let key = "\(client):\(id)"
        if sessions[key] == nil { sessions[key] = emptySession(client: client, id: id) }
        guard var target = sessions[key] as? JSON else { return }
        mergeSession(&target, source: session)
        sessions[key] = target
    }

    private static func mergeSession(_ target: inout JSON, source: JSON) {
        target["totalTokens"] = intValue(target["totalTokens"]) + intValue(source["totalTokens"])
        target["costUsd"] = doubleValue(target["costUsd"]) + doubleValue(source["costUsd"])
        target["messageCount"] = intValue(target["messageCount"]) + intValue(source["messageCount"])
        target["inputTokens"] = intValue(target["inputTokens"]) + intValue(source["inputTokens"])
        target["outputTokens"] = intValue(target["outputTokens"]) + intValue(source["outputTokens"])
        target["cacheReadTokens"] = intValue(target["cacheReadTokens"]) + intValue(source["cacheReadTokens"])
        target["cacheWriteTokens"] = intValue(target["cacheWriteTokens"]) + intValue(source["cacheWriteTokens"])
        target["reasoningTokens"] = intValue(target["reasoningTokens"]) + intValue(source["reasoningTokens"])
        let sourceStarted = timestampMs(source["startedAt"])
        let targetStarted = timestampMs(target["startedAt"])
        if sourceStarted > 0 && (targetStarted == 0 || sourceStarted < targetStarted) {
            target["startedAt"] = isoFromMs(sourceStarted)
        }
        let sourceLast = timestampMs(source["lastUsedAt"])
        let targetLast = timestampMs(target["lastUsedAt"])
        if sourceLast > targetLast {
            target["lastUsedAt"] = isoFromMs(sourceLast)
        }
        let sourceProject = source["projectId"] as? String ?? ""
        if (target["projectId"] as? String ?? "").isEmpty && !sourceProject.isEmpty {
            target["projectId"] = sourceProject
            target["projectLabel"] = source["projectLabel"] ?? ""
        }
        for (model, value) in (source["models"] as? JSON ?? JSON()) {
            var models = target["models"] as? JSON ?? JSON()
            models[model] = intValue(models[model]) + intValue(value)
            target["models"] = models
        }
        for (model, value) in (source["modelCosts"] as? JSON ?? JSON()) {
            var costs = target["modelCosts"] as? JSON ?? JSON()
            costs[model] = doubleValue(costs[model]) + doubleValue(value)
            target["modelCosts"] = costs
        }
        for (provider, value) in (source["providers"] as? JSON ?? JSON()) {
            var providers = target["providers"] as? JSON ?? JSON()
            providers[provider] = intValue(providers[provider]) + intValue(value)
            target["providers"] = providers
        }
    }

    /// Port of extractUsageFromTokscale: rows → period.
    /// Uses TypedPeriod internally to avoid per-row Any-boxing; the final
    /// toJSON() is the only place values enter the JSON wire shape.
    static func extractPeriod(entries: [UsageRow]) -> JSON {
        var typed = TypedPeriod()
        for row in entries {
            typed.addRow(row)
        }
        return typed.toJSON()
    }

    /// Port of addPeriodInto.
    static func addPeriodInto(_ target: inout JSON, _ source: JSON) {
        target["totalTokens"] = intValue(target["totalTokens"]) + intValue(source["totalTokens"])
        target["costUsd"] = doubleValue(target["costUsd"]) + doubleValue(source["costUsd"])
        target["cacheReadTokens"] = intValue(target["cacheReadTokens"]) + intValue(source["cacheReadTokens"])
        target["cacheWriteTokens"] = intValue(target["cacheWriteTokens"]) + intValue(source["cacheWriteTokens"])
        target["outputTokens"] = intValue(target["outputTokens"]) + intValue(source["outputTokens"])
        target["timedTokens"] = intValue(target["timedTokens"]) + intValue(source["timedTokens"])
        target["timedOutputTokens"] = intValue(target["timedOutputTokens"]) + intValue(source["timedOutputTokens"])
        target["timedDurationMs"] = intValue(target["timedDurationMs"]) + intValue(source["timedDurationMs"])

        var clients = target["clients"] as? JSON ?? JSON()
        let srcClients = source["clients"] as? JSON ?? JSON()
        let srcClientCacheReads = source["clientCacheReads"] as? JSON ?? JSON()
        let srcClientCacheWrites = source["clientCacheWrites"] as? JSON ?? JSON()
        let srcClientOutputs = source["clientOutputs"] as? JSON ?? JSON()
        for (client, tokens) in srcClients {
            clients[client] = intValue(clients[client]) + intValue(tokens)
        }
        var clientCacheReads = target["clientCacheReads"] as? JSON ?? JSON()
        for (client, value) in srcClientCacheReads {
            clientCacheReads[client] = intValue(clientCacheReads[client]) + intValue(value)
        }
        var clientCacheWrites = target["clientCacheWrites"] as? JSON ?? JSON()
        for (client, value) in srcClientCacheWrites {
            clientCacheWrites[client] = intValue(clientCacheWrites[client]) + intValue(value)
        }
        var clientOutputs = target["clientOutputs"] as? JSON ?? JSON()
        for (client, value) in srcClientOutputs {
            clientOutputs[client] = intValue(clientOutputs[client]) + intValue(value)
        }
        var clientCosts = target["clientCosts"] as? JSON ?? JSON()
        for (client, value) in (source["clientCosts"] as? JSON ?? JSON()) {
            clientCosts[client] = doubleValue(clientCosts[client]) + doubleValue(value)
        }
        var models = target["models"] as? JSON ?? JSON()
        let srcModels = source["models"] as? JSON ?? JSON()
        for (model, tokens) in srcModels {
            models[model] = intValue(models[model]) + intValue(tokens)
        }
        var modelCacheReads = target["modelCacheReads"] as? JSON ?? JSON()
        for (model, value) in (source["modelCacheReads"] as? JSON ?? JSON()) {
            modelCacheReads[model] = intValue(modelCacheReads[model]) + intValue(value)
        }
        var modelCacheWrites = target["modelCacheWrites"] as? JSON ?? JSON()
        for (model, value) in (source["modelCacheWrites"] as? JSON ?? JSON()) {
            modelCacheWrites[model] = intValue(modelCacheWrites[model]) + intValue(value)
        }
        var modelOutputs = target["modelOutputs"] as? JSON ?? JSON()
        for (model, value) in (source["modelOutputs"] as? JSON ?? JSON()) {
            modelOutputs[model] = intValue(modelOutputs[model]) + intValue(value)
        }
        var modelCosts = target["modelCosts"] as? JSON ?? JSON()
        for (model, value) in (source["modelCosts"] as? JSON ?? JSON()) {
            modelCosts[model] = doubleValue(modelCosts[model]) + doubleValue(value)
        }
        var clientModels = target["clientModels"] as? JSON ?? JSON()
        for (client, modelsObj) in (source["clientModels"] as? JSON ?? JSON()) {
            var byModel = clientModels[client] as? JSON ?? JSON()
            for (model, tokens) in (modelsObj as? JSON ?? JSON()) {
                byModel[model] = intValue(byModel[model]) + intValue(tokens)
            }
            clientModels[client] = byModel
        }
        var clientModelCosts = target["clientModelCosts"] as? JSON ?? JSON()
        for (client, modelsObj) in (source["clientModelCosts"] as? JSON ?? JSON()) {
            var byModel = clientModelCosts[client] as? JSON ?? JSON()
            for (model, cost) in (modelsObj as? JSON ?? JSON()) {
                byModel[model] = doubleValue(byModel[model]) + doubleValue(cost)
            }
            clientModelCosts[client] = byModel
        }
        var sessions = target["sessions"] as? JSON ?? JSON()
        for (_, session) in (source["sessions"] as? JSON ?? JSON()) {
            guard let session = session as? JSON else { continue }
            addSession(&sessions, session: session)
        }

        target["clients"] = clients
        target["clientCosts"] = clientCosts
        target["clientCacheReads"] = clientCacheReads
        target["clientCacheWrites"] = clientCacheWrites
        target["clientOutputs"] = clientOutputs
        target["models"] = models
        target["modelCosts"] = modelCosts
        target["modelCacheReads"] = modelCacheReads
        target["modelCacheWrites"] = modelCacheWrites
        target["modelOutputs"] = modelOutputs
        target["clientModels"] = clientModels
        target["clientModelCosts"] = clientModelCosts
        target["sessions"] = sessions
    }

    static func mergePeriods(_ periods: [JSON]) -> JSON {
        var typed = TypedPeriod()
        for period in periods {
            typed.merge(TypedPeriod(from: period))
        }
        return typed.toJSON()
    }
}
