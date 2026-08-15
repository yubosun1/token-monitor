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
        let activeTimeMs: Double
    }

    // MARK: - Shared helpers (ported from promaUsage.js)

    static func sourceNamespace(_ root: String) -> String {
        let digest = SHA256.hash(data: Data(root.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Directory listings and per-file parse results are memoized by
    /// (path, mtime, size): unchanged adapter files cost ~nothing per tick.
    /// A directory listing is keyed on the root's own mtime, which updates
    /// when entries are added/removed directly under it (new session files
    /// land at the root of each adapter's tree).
    private static let fileCacheLock = NSLock()
    private static var fileListCache: [String: (stamp: (Date, Int), urls: [URL])] = [:]
    private static var parseCache: [String: (stamp: (Date, Int), value: Any)] = [:]
    private static var decompressCache: [String: (stamp: (Date, Int), data: Data)] = [:]

    private static func fileStamp(_ url: URL) -> (mtime: Date, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return (mtime, size)
    }

    /// Drop memoized parse and file-list entries for adapter clients that
    /// are no longer enabled (round-4 Phase 2.2). Only touches the in-memory
    /// caches — it never reads user data — so a disabled client's rows cannot
    /// stay reachable forever.
    static func dropClientCaches(_ disabled: Set<String>) {
        guard !disabled.isEmpty else { return }
        fileCacheLock.lock()
        parseCache = parseCache.filter { key, _ in
            !disabled.contains { client in key.hasPrefix(client + "|") }
        }
        fileListCache = fileListCache.filter { key, _ in
            !disabled.contains { client in key.hasPrefix("list|" + client + "|") }
        }
        fileCacheLock.unlock()
    }

    private static func cachedValue<T>(_ key: String, stamp: (Date, Int), compute: () -> T) -> T {
        fileCacheLock.lock()
        if let cached = parseCache[key], cached.stamp.0 == stamp.0, cached.stamp.1 == stamp.1,
           let value = cached.value as? T {
            fileCacheLock.unlock()
            return value
        }
        fileCacheLock.unlock()
        let value = compute()
        fileCacheLock.lock()
        parseCache[key] = (stamp, value)
        fileCacheLock.unlock()
        return value
    }

    static func jsonlFiles(root: String, recursive: Bool, client: String) -> [URL] {
        let url = URL(fileURLWithPath: root)
        // Key MUST include the actual root + recursive flag + client: the
        // stamp check below is only valid within one (root, recursive) pair,
        // a literal key made every adapter's directory listing miss on every
        // tick, and the client segment lets a disabled client's listing be
        // pruned (round-4 Phase 2.2).
        let key = "list|\(client)|\(root)|\(recursive)"
        if let stamp = fileStamp(url) {
            fileCacheLock.lock()
            if let cached = fileListCache[key], cached.stamp.0 == stamp.0, cached.stamp.1 == stamp.1 {
                fileCacheLock.unlock()
                return cached.urls
            }
            fileCacheLock.unlock()
            let urls = enumerateJsonlFiles(url: url, recursive: recursive)
            fileCacheLock.lock()
            fileListCache[key] = (stamp, urls)
            fileCacheLock.unlock()
            return urls
        }
        return enumerateJsonlFiles(url: url, recursive: recursive)
    }

    private static func enumerateJsonlFiles(url: URL, recursive: Bool) -> [URL] {
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

    /// Local date key for a timestamp. The timeZone parameter exists for the
    /// fixture tests (PLAN.md Phase 0 boundary coverage); the app always uses
    /// the current time zone.
    static func localDateKey(_ timestampMs: Double, timeZone: TimeZone = .current) -> String {
        guard timestampMs > 0 else { return "" }
        let date = Date(timeIntervalSince1970: timestampMs / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func localDayStart(_ date: Date, timeZone: TimeZone = .current) -> Double {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date).timeIntervalSince1970 * 1000
    }

    static func localMonthStart(_ date: Date, timeZone: TimeZone = .current) -> Double {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: comps) ?? date
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
    static func periodRows(rows: [UsageCore.UsageRow], sinceMs: Double, client: String, includeUndated: Bool, timeZone: TimeZone = .current) -> [UsageCore.UsageRow] {
        var filtered = rows.filter { row in
            let createdAt = UsageCore.timestampMs(row.startedAt.isEmpty ? row.lastUsedAt : row.startedAt)
            // startedAt is the row's createdAt for adapters; see adapter row builders.
            if createdAt <= 0 { return includeUndated }
            return createdAt >= sinceMs
        }
        // Aggregate by session+model, summing token components; the adapters
        // emit one row per message, matching the JS buildTokscaleJson grouping.
        // Iterate grouped.values in sorted-key order: Swift Dictionary.values
        // order is randomized per process, and the floating-point cost/token
        // sums in extractPeriod are order-sensitive at the last ulp, so the
        // grouped rows must be ordered deterministically.
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
        filtered = grouped.keys.sorted().compactMap { grouped[$0] }
        return filtered
    }

    static func historyContributions(rows: [UsageCore.UsageRow], client: String, pricingByModel: [String: TokscalePricing], timeZone: TimeZone = .current) -> [HistoryContribution] {
        var out: [HistoryContribution] = []
        for row in rows {
            // Row createdAt lives in startedAt for adapters.
            let date = localDateKey(UsageCore.timestampMs(row.startedAt), timeZone: timeZone)
            guard !date.isEmpty else { continue }
            let modelId = (row.model ?? "unknown").trimmingCharacters(in: .whitespaces).lowercased()
            let cost = estimatedRowCost(row: row, pricingByModel: pricingByModel)
            // Estimated session active time: wall-clock span of the row, clamped
            // to non-negative and capped at 8h so long-lived sessions don't
            // inflate a single day's active time.
            let started = UsageCore.timestampMs(row.startedAt)
            let ended = UsageCore.timestampMs(row.lastUsedAt)
            let activeTimeMs = max(0, min(ended - started, 8 * 60 * 60 * 1000))
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
                messages: 1,
                activeTimeMs: activeTimeMs
            ))
        }
        return out
    }

    /// Deterministic ordering for collected rows: Dictionary-backed parse
    /// caches return rows in randomized per-process order, and floating-point
    /// aggregation is order-sensitive at the last ulp. Sort by (client,
    /// session, model, startedAt) so period and history sums are stable
    /// across processes and refreshes.
    static func sortRows(_ rows: [UsageCore.UsageRow]) -> [UsageCore.UsageRow] {
        return rows.sorted {
            let a = ($0.client ?? "", $0.sessionId ?? "", $0.model ?? "", $0.startedAt, $0.lastUsedAt)
            let b = ($1.client ?? "", $1.sessionId ?? "", $1.model ?? "", $1.startedAt, $1.lastUsedAt)
            return a < b
        }
    }

    // MARK: - Proma (~/.proma/agent-sessions/*.jsonl)

    static let promaRoot = NSHomeDirectory() + "/.proma/agent-sessions"

    static func collectPromaRows() -> [UsageCore.UsageRow] {
        let sourceId = sourceNamespace(promaRoot)
        var rows: [UsageCore.UsageRow] = []
        for file in jsonlFiles(root: promaRoot, recursive: false, client: "proma") {
            rows.append(contentsOf: promaFileRows(file, sourceId: sourceId))
        }
        return sortRows(rows)
    }

    /// Parse one proma session file, memoized by (path, mtime, size).
    private static func promaFileRows(_ file: URL, sourceId: String) -> [UsageCore.UsageRow] {
        if let stamp = fileStamp(file) {
            return cachedValue("proma|\(file.path)", stamp: stamp) {
                parsePromaFile(file, sourceId: sourceId)
            }
        }
        return parsePromaFile(file, sourceId: sourceId)
    }

    private static func parsePromaFile(_ file: URL, sourceId: String) -> [UsageCore.UsageRow] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let sessionId = "\(file.deletingPathExtension().lastPathComponent)@\(sourceId)"
        // Group by message id (chunk dedupe), fall back to row uuid.
        var groups: [String: [JSON]] = [:]
        for obj in parseJsonlLines(data) {
            guard (obj["type"] as? String) == "assistant" else { continue }
            guard let msg = obj["message"] as? JSON, (msg["usage"] as? JSON) != nil else { continue }
            let msgId = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? "row-\(obj["_createdAt"] ?? "")"
            groups[msgId, default: []].append(obj)
        }
        var rows: [UsageCore.UsageRow] = []
        for (_, chunks) in groups {
            guard let row = promaRow(from: chunks, sessionId: sessionId) else { continue }
            rows.append(row)
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

    private struct HanakoFileResult {
        var rows: [UsageCore.UsageRow] = []
        var messageIds: [String] = []
    }

    static func collectHanakoRows() -> [UsageCore.UsageRow] {
        var rows: [UsageCore.UsageRow] = []
        var seenMessageIds = Set<String>()
        for root in hanakoRoots {
            let sourceId = sourceNamespace(root)
            for file in jsonlFiles(root: root, recursive: true, client: "hanako") {
                let parsed = hanakoFileRows(file, sourceId: sourceId)
                // Cross-file (and cross-root) message dedupe over cached rows.
                for i in 0..<parsed.rows.count {
                    let messageId = i < parsed.messageIds.count ? parsed.messageIds[i] : ""
                    if !messageId.isEmpty {
                        if seenMessageIds.contains(messageId) { continue }
                        seenMessageIds.insert(messageId)
                    }
                    rows.append(parsed.rows[i])
                }
            }
        }
        return sortRows(rows)
    }

    /// Parse one hanako session/activity file, memoized by (path, mtime, size).
    private static func hanakoFileRows(_ file: URL, sourceId: String) -> HanakoFileResult {
        if let stamp = fileStamp(file) {
            return cachedValue("hanako|\(file.path)", stamp: stamp) {
                parseHanakoFile(file, sourceId: sourceId)
            }
        }
        return parseHanakoFile(file, sourceId: sourceId)
    }

    private static func parseHanakoFile(_ file: URL, sourceId: String) -> HanakoFileResult {
        var result = HanakoFileResult()
        guard let data = try? Data(contentsOf: file) else { return result }
        let sessionId = "\(file.deletingPathExtension().lastPathComponent)@\(sourceId)"
        var seenInFile = Set<String>()
        for obj in parseJsonlLines(data) {
            guard let msg = obj["message"] as? JSON, let u = msg["usage"] as? JSON else { continue }
            let messageId = (obj["id"] as? String) ?? ((msg["id"] as? String).map { String($0) })
            if let messageId, !messageId.isEmpty {
                if seenInFile.contains(messageId) { continue }
                seenInFile.insert(messageId)
            }
            let input = UsageCore.doubleValue(u["input"] ?? u["input_tokens"])
            let output = UsageCore.doubleValue(u["output"] ?? u["output_tokens"])
            let cacheRead = UsageCore.doubleValue(u["cacheRead"] ?? u["cache_read_input_tokens"])
            let cacheWrite = UsageCore.doubleValue(u["cacheWrite"] ?? u["cache_creation_input_tokens"])
            let createdAt = UsageCore.timestampMs(obj["timestamp"] ?? msg["timestamp"] ?? obj["_createdAt"])
            result.rows.append(UsageCore.UsageRow(
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
            result.messageIds.append(messageId ?? "")
        }
        return result
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
    /// Results are memoized by (path, mtime, size) so unchanged sessions are
    /// never re-decompressed; the cache sheds its largest entry if it would
    /// exceed 128MB.
    static func decompressZstd(_ url: URL) -> Data? {
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        if let stamp = fileStamp(url) {
            fileCacheLock.lock()
            if let cached = decompressCache[url.path], cached.stamp.0 == stamp.0, cached.stamp.1 == stamp.1 {
                fileCacheLock.unlock()
                return cached.data
            }
            fileCacheLock.unlock()
            let data = decompressZstdUncached(url, diag: diag)
            if let data {
                fileCacheLock.lock()
                decompressCache[url.path] = (stamp, data)
                let total = decompressCache.values.reduce(0) { $0 + $1.data.count }
                if total > 128 * 1024 * 1024,
                   let largest = decompressCache.max(by: { $0.value.data.count < $1.value.data.count }) {
                    decompressCache.removeValue(forKey: largest.key)
                }
                fileCacheLock.unlock()
            }
            return data
        }
        return decompressZstdUncached(url, diag: diag)
    }

    private static func decompressZstdUncached(_ url: URL, diag: Bool) -> Data? {
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
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        let files = dshSessionFiles()
        var rows: [UsageCore.UsageRow] = []
        var totalEvents = 0
        for file in files {
            let parsed = dshFileRows(file)
            totalEvents += parsed.events
            rows.append(contentsOf: parsed.rows)
        }
        if diag {
            NSLog("[dsh] files=%d usageEvents=%d rows=%d", files.count, totalEvents, rows.count)
        }
        return sortRows(rows)
    }

    private struct DshFileResult {
        var rows: [UsageCore.UsageRow] = []
        var events = 0
    }

    /// Parse one session.jsonl.zstd into usage rows, memoized by
    /// (path, mtime, size) — unchanged sessions skip decompress + parse.
    private static func dshFileRows(_ file: URL) -> DshFileResult {
        if let stamp = fileStamp(file) {
            return cachedValue("dsh|\(file.path)", stamp: stamp) {
                parseDshFile(file)
            }
        }
        return parseDshFile(file)
    }

    private static func parseDshFile(_ file: URL) -> DshFileResult {
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        guard let data = decompressZstd(file) else {
            if diag { NSLog("[dsh] decompress failed: %@", file.path) }
            return DshFileResult()
        }
        guard let text = String(data: data, encoding: .utf8) else { return DshFileResult() }
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
        var rows: [UsageCore.UsageRow] = []
        for event in usageEvents {
            guard let usage = event["usage"] as? JSON else { continue }
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
        return DshFileResult(rows: rows, events: usageEvents.count)
    }
}
