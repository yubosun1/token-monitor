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

    static func timestampMs(_ value: Any?) -> Double {
        guard let value else { return 0 }
        if let n = value as? Double, n.isFinite { return n > 0 && n < 1e12 ? n * 1000 : n }
        if let n = value as? Int { return Double(n) > 0 && Double(n) < 1e12 ? Double(n) * 1000 : Double(n) }
        if let s = value as? String, !s.isEmpty {
            if let n = Double(s), n.isFinite { return n > 0 && n < 1e12 ? n * 1000 : n }
            let parsed = ISO8601DateFormatter().date(from: s) ?? RFC3339DateParser.parse(s)
            if let parsed { return parsed.timeIntervalSince1970 * 1000 }
            return 0
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
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
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
    static func extractPeriod(entries: [UsageRow]) -> JSON {
        var period = emptyPeriod()
        for row in entries {
            addUsageRowToPeriod(&period, row: row)
        }
        return period
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
        var target = emptyPeriod()
        for period in periods {
            addPeriodInto(&target, period)
        }
        return target
    }
}
