import Foundation
import CryptoKit
import CZstd

/// Local JSONL adapters — ports of src/shared/promaUsage.js and
/// src/shared/hanakoUsage.js, plus the new DeepSeek Harness collector.
/// Each adapter produces UsageCore.UsageRow values so every source shares
/// one aggregation path, and per-day history contributions for the trends
/// views.
enum Adapters {
    typealias JSON = [String: Any]

    struct HistoryContribution {
        let date: String
        let client: String
        let modelId: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let reasoning: Int
        let cost: Double
        let messages: Int
    }

    // MARK: - Shared helpers (ported from promaUsage.js)

    static func sourceNamespace(_ root: String) -> String {
        let digest = SHA256.hash(data: Data(root.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func jsonlFiles(root: String, recursive: Bool) -> [URL] {
        let url = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: recursive ? [] : [.skipsSubdirectoryDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.pathExtension == "jsonl" { files.append(file) }
        }
        return files
    }

    static func parseJsonlLines(_ data: Data) -> [JSON] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var objects: [JSON] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? JSON {
                objects.append(obj)
            }
        }
        return objects
    }

    /// estimatedRowCost port: null (→ no cost) when a used component's rate
    /// is missing, never a silent undercount.
    static func estimatedRowCost(row: UsageCore.UsageRow, pricingByModel: [String: TokscalePricing]) -> Double? {
        let key = (row.model ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard let pricing = pricingByModel[key]?.pricing else { return nil }
        let components: [(Double, Double?)] = [
            (row.input, pricing.inputCostPerToken),
            (row.output, pricing.outputCostPerToken),
            (row.cacheRead, pricing.cacheReadInputTokenCost),
            (row.cacheWrite, pricing.cacheCreationInputTokenCost)
        ]
        var cost = 0.0
        for (tokens, unitCost) in components {
            guard tokens > 0 else { continue }
            guard let unitCost, unitCost.isFinite, unitCost >= 0 else { return nil }
            cost += tokens * unitCost
        }
        return cost
    }

    static func localDateKey(_ timestampMs: Double) -> String {
        guard timestampMs > 0 else { return "" }
        let date = Date(timeIntervalSince1970: timestampMs / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func localDayStart(_ date: Date) -> Double {
        Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000
    }

    static func localMonthStart(_ date: Date) -> Double {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let start = Calendar.current.date(from: comps) ?? date
        return start.timeIntervalSince1970 * 1000
    }

    /// Resolve pricing for every distinct model (tokscale lookups are cached
    /// for 6h inside the runner; custom pricing flows through tokscale too).
    static func pricingMap(forRows rows: [UsageCore.UsageRow]) -> [String: TokscalePricing] {
        var map: [String: TokscalePricing] = [:]
        for row in rows {
            guard let model = row.model else { continue }
            let key = model.trimmingCharacters(in: .whitespaces).lowercased()
            if map[key] == nil, let pricing = TokscaleRunner.shared.pricing(for: model) {
                map[key] = pricing
            }
        }
        return map
    }

    /// Build tokscale-entry-shaped rows per (session, model), mirroring
    /// buildTokscaleJson + extractUsageFromTokscale's input.
    static func periodRows(rows: [UsageCore.UsageRow], sinceMs: Double, client: String, includeUndated: Bool) -> [UsageCore.UsageRow] {
        var filtered = rows.filter { row in
            let createdAt = UsageCore.timestampMs(row.startedAt.isEmpty ? row.lastUsedAt : row.startedAt)
            // startedAt is the row's createdAt for adapters; see adapter row builders.
            if createdAt <= 0 { return includeUndated }
            return createdAt >= sinceMs
        }
        // Aggregate by session+model, summing token components; the adapters
        // emit one row per message, matching the JS buildTokscaleJson grouping.
        var grouped: [String: UsageCore.UsageRow] = [:]
        for row in filtered {
            let key = "\(row.sessionId ?? "unknown")\u{0}\(row.model ?? "")"
            if var existing = grouped[key] {
                existing.input += row.input
                existing.output += row.output
                existing.cacheRead += row.cacheRead
                existing.cacheWrite += row.cacheWrite
                existing.reasoning += row.reasoning
                existing.messageCount += row.messageCount > 0 ? row.messageCount : 1
                existing.cost += row.cost
                if !row.startedAt.isEmpty && (existing.startedAt.isEmpty || row.startedAt < existing.startedAt) {
                    existing.startedAt = row.startedAt
                }
                if row.lastUsedAt > existing.lastUsedAt { existing.lastUsedAt = row.lastUsedAt }
                grouped[key] = existing
            } else {
                var copy = row
                copy.messageCount = row.messageCount > 0 ? row.messageCount : 1
                grouped[key] = copy
            }
        }
        filtered = Array(grouped.values)
        return filtered
    }

    static func historyContributions(rows: [UsageCore.UsageRow], client: String, pricingByModel: [String: TokscalePricing]) -> [HistoryContribution] {
        var out: [HistoryContribution] = []
        for row in rows {
            // Row createdAt lives in startedAt for adapters.
            let date = localDateKey(UsageCore.timestampMs(row.startedAt))
            guard !date.isEmpty else { continue }
            let modelId = (row.model ?? "unknown").trimmingCharacters(in: .whitespaces).lowercased()
            let cost = estimatedRowCost(row: row, pricingByModel: pricingByModel)
            out.append(HistoryContribution(
                date: date,
                client: client,
                modelId: modelId.isEmpty ? "unknown" : modelId,
                input: max(0, Int(row.input.rounded())),
                output: max(0, Int(row.output.rounded())),
                cacheRead: max(0, Int(row.cacheRead.rounded())),
                cacheWrite: max(0, Int(row.cacheWrite.rounded())),
                reasoning: max(0, Int(row.reasoning.rounded())),
                cost: cost ?? 0,
                messages: 1
            ))
        }
        return out
    }

    // MARK: - Proma (~/.proma/agent-sessions/*.jsonl)

    static let promaRoot = NSHomeDirectory() + "/.proma/agent-sessions"

    static func collectPromaRows() -> [UsageCore.UsageRow] {
        let sourceId = sourceNamespace(promaRoot)
        var rows: [UsageCore.UsageRow] = []
        for file in jsonlFiles(root: promaRoot, recursive: false) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let sessionId = "\(file.deletingPathExtension().lastPathComponent)@\(sourceId)"
            // Group by message id (chunk dedupe), fall back to row uuid.
            var groups: [String: [JSON]] = [:]
            for obj in parseJsonlLines(data) {
                guard (obj["type"] as? String) == "assistant" else { continue }
                guard let msg = obj["message"] as? JSON, (msg["usage"] as? JSON) != nil else { continue }
                let msgId = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? "row-\(obj["_createdAt"] ?? "")"
                groups[msgId, default: []].append(obj)
            }
            for (_, chunks) in groups {
                guard let row = promaRow(from: chunks, sessionId: sessionId) else { continue }
                rows.append(row)
            }
        }
        return rows
    }

    private static func promaRow(from chunks: [JSON], sessionId: String) -> UsageCore.UsageRow? {
        // Collapse: keep the chunk with the largest token total; createdAt is
        // the max across the group (ported from collectSessionRows).
        var best: UsageCore.UsageRow?
        var bestTotal = -1.0
        var latestCreatedAt = 0.0
        for obj in chunks {
            guard let msg = obj["message"] as? JSON, let u = msg["usage"] as? JSON else { continue }
            let input = UsageCore.doubleValue(u["input_tokens"] ?? u["inputTokens"])
            let output = UsageCore.doubleValue(u["output_tokens"] ?? u["outputTokens"])
            let cacheRead = UsageCore.doubleValue(u["cache_read_input_tokens"] ?? u["cacheReadInputTokens"])
            let cacheWrite = UsageCore.doubleValue(u["cache_creation_input_tokens"] ?? u["cacheCreationInputTokens"])
            let total = input + output + cacheRead + cacheWrite
            let createdAt = UsageCore.timestampMs(obj["_createdAt"] ?? obj["createdAt"] ?? obj["created_at"] ?? obj["timestamp"])
            if createdAt > latestCreatedAt { latestCreatedAt = createdAt }
            if total > bestTotal {
                bestTotal = total
                best = UsageCore.UsageRow(
                    client: "proma",
                    sessionId: sessionId,
                    model: (msg["model"] as? String) ?? (obj["_channelModelId"] as? String) ?? "unknown",
                    provider: "proma",
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    messageCount: 1,
                    cost: 0,
                    startedAt: UsageCore.isoFromMs(createdAt),
                    lastUsedAt: UsageCore.isoFromMs(createdAt),
                    projectId: "",
                    projectLabel: "",
                    performance: nil
                )
            }
        }
        guard var row = best else { return nil }
        row.startedAt = UsageCore.isoFromMs(latestCreatedAt)
        row.lastUsedAt = UsageCore.isoFromMs(latestCreatedAt)
        return row
    }

    // MARK: - Hanako (~/.hanako/agents/hanako/{sessions,activity}/**/*.jsonl)

    static let hanakoRoots = [
        NSHomeDirectory() + "/.hanako/agents/hanako/sessions",
        NSHomeDirectory() + "/.hanako/agents/hanako/activity"
    ]

    static func collectHanakoRows() -> [UsageCore.UsageRow] {
        var rows: [UsageCore.UsageRow] = []
        var seenMessageIds = Set<String>()
        for root in hanakoRoots {
            let sourceId = sourceNamespace(root)
            for file in jsonlFiles(root: root, recursive: true) {
                guard let data = try? Data(contentsOf: file) else { continue }
                let sessionId = "\(file.deletingPathExtension().lastPathComponent)@\(sourceId)"
                for obj in parseJsonlLines(data) {
                    guard let msg = obj["message"] as? JSON, let u = msg["usage"] as? JSON else { continue }
                    let messageId = (obj["id"] as? String) ?? ((msg["id"] as? String).map { String($0) })
                    if let messageId, !messageId.isEmpty {
                        if seenMessageIds.contains(messageId) { continue }
                        seenMessageIds.insert(messageId)
                    }
                    let input = UsageCore.doubleValue(u["input"] ?? u["input_tokens"])
                    let output = UsageCore.doubleValue(u["output"] ?? u["output_tokens"])
                    let cacheRead = UsageCore.doubleValue(u["cacheRead"] ?? u["cache_read_input_tokens"])
                    let cacheWrite = UsageCore.doubleValue(u["cacheWrite"] ?? u["cache_creation_input_tokens"])
                    let createdAt = UsageCore.timestampMs(obj["timestamp"] ?? msg["timestamp"] ?? obj["_createdAt"])
                    rows.append(UsageCore.UsageRow(
                        client: "hanako",
                        sessionId: sessionId,
                        model: (msg["model"] as? String) ?? (obj["modelId"] as? String) ?? "unknown",
                        provider: "hanako",
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        reasoning: 0,
                        messageCount: 1,
                        cost: 0,
                        startedAt: UsageCore.isoFromMs(createdAt),
                        lastUsedAt: UsageCore.isoFromMs(createdAt),
                        projectId: "",
                        projectLabel: "",
                        performance: nil
                    ))
                }
            }
        }
        return rows
    }

    // MARK: - DeepSeek Harness (~/.dsh/sessions/<project>/session-*/session.jsonl.zstd)

    static let dshRoot = NSHomeDirectory() + "/.dsh/sessions"

    static func dshSessionFiles() -> [URL] {
        let root = URL(fileURLWithPath: dshRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.lastPathComponent == "session.jsonl.zstd" { files.append(file) }
        }
        return files
    }

    /// In-memory zstd decompression through the vendored static libzstd.
    /// DSH appends to session files, so frames are streaming (content size
    /// unknown) — use the streaming API rather than single-shot decompress.
    static func decompressZstd(_ url: URL) -> Data? {
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        guard let compressed = try? Data(contentsOf: url) else {
            if diag { NSLog("[dsh] read failed: %@", url.path) }
            return nil
        }
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        let initResult = ZSTD_initDStream(stream)
        guard ZSTD_isError(initResult) == 0 else { return nil }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        return compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            var keepGoing = true
            while keepGoing {
                let produced = chunk.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Int in
                    var out = ZSTD_outBuffer(dst: outRaw.baseAddress, size: outRaw.count, pos: 0)
                    let ret = ZSTD_decompressStream(stream, &out, &input)
                    if ZSTD_isError(ret) != 0 {
                        if diag {
                            NSLog("[dsh] stream error for %@: %@", url.lastPathComponent,
                                  String(cString: ZSTD_getErrorName(Int(ret))))
                        }
                        return -1
                    }
                    return out.pos
                }
                guard produced >= 0 else { return nil }
                if produced > 0 {
                    output.append(contentsOf: chunk[0..<produced])
                }
                keepGoing = (input.pos < input.size) || produced > 0
            }
            return output
        }
    }

    static func collectDshRows() -> [UsageCore.UsageRow] {
        var rows: [UsageCore.UsageRow] = []
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        let files = dshSessionFiles()
        var totalEvents = 0
        for file in files {
            guard let data = decompressZstd(file) else {
                if diag { NSLog("[dsh] decompress failed: %@", file.path) }
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let sessionDir = file.deletingLastPathComponent()
            let sessionId = sessionDir.lastPathComponent // session-<uuid>

            // Pass 1: attribute models per (turn, step) from finish chunks,
            // plus the session-level fallback model from request/header.
            var stepModels: [String: String] = [:]
            var fallbackModel = "unknown"
            var headerCreatedAt = 0.0
            var lastTime = 0.0
            var usageEvents: [JSON] = []
            var seenSeq = Set<Int>()

            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? JSON else { continue }
                let seq = obj["seq"] as? Int ?? 0
                if seenSeq.contains(seq) { continue }
                seenSeq.insert(seq)
                let time = UsageCore.timestampMs(obj["time"])
                if time > lastTime { lastTime = time }
                let type = obj["type"] as? String ?? ""
                let data = obj["data"] as? JSON ?? JSON()

                if type == "session" {
                    if let createdAt = obj["createdAt"] { headerCreatedAt = UsageCore.timestampMs(createdAt) }
                    continue
                }
                if type == "request/header" || type == "request/context" {
                    let header = data["header"] as? JSON ?? data
                    let config = header["config"] as? JSON ?? header
                    if let model = config["model"] as? String { fallbackModel = model }
                    continue
                }
                if type == "assistant/chunk" {
                    let chunk = data["chunk"] as? JSON ?? JSON()
                    let chunkType = chunk["type"] as? String ?? ""
                    let turn = data["turn"] as? Int ?? 0
                    let step = data["step"] as? Int ?? 0
                    if chunkType == "usage", let usage = chunk["usage"] as? JSON {
                        let event: JSON = ["usage": usage, "turn": turn, "step": step]
                        usageEvents.append(event)
                    } else if chunkType == "finish" {
                        if let model = (chunk["replayState"] as? JSON)?["model"] as? String {
                            stepModels["\(turn):\(step)"] = model
                        }
                    }
                }
            }

            // Pass 2: usage events with model attribution.
            for event in usageEvents {
                guard let usage = event["usage"] as? JSON else { continue }
                totalEvents += 1
                let turn = event["turn"] as? Int ?? 0
                let step = event["step"] as? Int ?? 0
                let model = stepModels["\(turn):\(step)"] ?? fallbackModel
                let input = UsageCore.doubleValue(usage["inputTokens"])
                let output = UsageCore.doubleValue(usage["outputTokens"])
                let cacheRead = UsageCore.doubleValue(usage["cacheReadTokens"])
                let cacheWrite = UsageCore.doubleValue(usage["cacheWriteTokens"])
                let createdAt = headerCreatedAt > 0 ? headerCreatedAt : lastTime
                rows.append(UsageCore.UsageRow(
                    client: "dsh",
                    sessionId: sessionId,
                    model: model,
                    provider: "dsh",
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    messageCount: 1,
                    cost: 0,
                    startedAt: UsageCore.isoFromMs(createdAt),
                    lastUsedAt: UsageCore.isoFromMs(lastTime),
                    projectId: "",
                    projectLabel: "",
                    performance: nil
                ))
            }
        }
        if diag {
            NSLog("[dsh] files=%d usageEvents=%d rows=%d", files.count, totalEvents, rows.count)
        }
        return rows
    }
}
