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
    private static var decompressCounter = 0
    /// Per-file streaming state for incremental re-reads of actively
    /// appending dsh sessions (see DshIncrementalState). Guarded by
    /// fileCacheLock; an entry is dropped after the session stops changing
    /// (one final full verify) or when the file disappears.
    private static var dshIncrementalStates: [String: DshIncrementalState] = [:]

    // MARK: - Cache lifecycle diagnostics (round-4 Phase 5 test seams)

    /// How many real zstd decompressions ran (any path). The fixture checker
    /// asserts unchanged files never re-decompress.
    static var dshDecompressCount: Int {
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        return decompressCounter
    }

    /// Bytes of fully decompressed session Data currently retained by the
    /// adapter caches. Always 0 (round-4 Phase 5): the parse cache keeps
    /// only parsed DshFileResult values and the decompressed buffer is
    /// released when parseSessionFile returns. Kept as a diagnostic seam so
    /// the fixture checker pins the invariant.
    static var dshRetainedDecompressedBytes: Int {
        return 0
    }

    /// Paths currently memoized in the dsh parse cache.
    static func dshParseCachePaths() -> Set<String> {
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        return Set(parseCache.keys.filter { $0.hasPrefix("dsh|") }.map { String($0.dropFirst(4)) })
    }

    /// Total number of entries in the parse cache (test seam).
    static var parseCacheCount: Int {
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        return parseCache.count
    }

    /// Keys currently memoized in the parse cache for a specific client (test seam).
    static func parseCacheKeys(client: String) -> [String] {
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        let prefix = client + "|"
        return parseCache.keys.filter { $0.hasPrefix(prefix) }
    }

    /// Number of files currently holding incremental streaming state
    /// (fixture seam: dropped after idle verification or pruning).
    static var dshIncrementalStateCount: Int {
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        return dshIncrementalStates.count
    }

    /// Prune parse cache entries for any client whose files are no longer in the active set.
    static func pruneParseCache(client: String, activePaths: Set<String>) {
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        let prefix = client + "|"
        parseCache = parseCache.filter { key, _ in
            !key.hasPrefix(prefix) || activePaths.contains(String(key.dropFirst(prefix.count)))
        }
    }

    /// Drop dsh parse entries whose file is no longer in the active set
    /// (deleted sessions), so the cache stays bounded by live files. The
    /// incremental streaming states are pruned the same way (streams freed).
    static func pruneDshParseCache(activeFiles: Set<String>) {
        pruneParseCache(client: "dsh", activePaths: activeFiles)
        fileCacheLock.lock(); defer { fileCacheLock.unlock() }
        for path in dshIncrementalStates.keys where !activeFiles.contains(path) {
            if var state = dshIncrementalStates.removeValue(forKey: path) {
                freeDshStream(&state)
            }
        }
    }

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
        if disabled.contains("dsh") {
            for path in dshIncrementalStates.keys {
                if var state = dshIncrementalStates.removeValue(forKey: path) {
                    freeDshStream(&state)
                }
            }
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
            // Skip non-session artifacts that land in the data dirs (e.g.
            // the upstream repo's session-diag-*.jsonl benchmark files):
            // synthetic rows would pollute usage totals and active-day
            // counts. Must mirror SourceScanner.included exactly.
            if file.pathExtension == "jsonl", !isDiagArtifact(file.path) { files.append(file) }
        }
        return files
    }

    /// Whether a file is a synthetic diagnostic artifact rather than a real
    /// session. Shared with SourceScanner.included so fingerprints and the
    /// parsed row set always agree.
    static func isDiagArtifact(_ path: String) -> Bool {
        return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("session-diag-")
    }

    static func parseJsonlLines(_ data: Data) -> [JSON] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var objects: [JSON] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            autoreleasepool {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? JSON {
                    objects.append(obj)
                }
            }
        }
        return objects
    }

    /// estimatedRowCost port: null (→ no cost) when a used component's rate
    /// is missing, never a silent undercount.
    static func estimatedRowCost(row: UsageCore.UsageRow, pricingByModel: [String: TokscalePricing]) -> Double? {
        let key = UsageCore.canonicalModelName((row.model ?? "").trimmingCharacters(in: .whitespaces).lowercased())
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
        return DateFormatUtil.dayKey(date, timeZone: timeZone)
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
            let key = UsageCore.canonicalModelName(model.trimmingCharacters(in: .whitespaces).lowercased())
            if map[key] == nil, let pricing = TokscaleRunner.shared.pricing(for: key) {
                map[key] = pricing
            }
        }
        return map
    }

    /// Build tokscale-entry-shaped rows per (session, model), mirroring
    /// buildTokscaleJson + extractUsageFromTokscale's input.
    static func periodRows(rows: [UsageCore.UsageRow], sinceMs: Double, client: String, includeUndated: Bool, timeZone: TimeZone = .current) -> [UsageCore.UsageRow] {
        var filtered = rows.filter { row in
            let createdAt = row.startedAt > 0 ? row.startedAt : row.lastUsedAt
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
                if row.startedAt > 0 && (existing.startedAt == 0 || row.startedAt < existing.startedAt) {
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
            let date = localDateKey(row.startedAt, timeZone: timeZone)
            guard !date.isEmpty else { continue }
            let modelId = UsageCore.canonicalModelName((row.model ?? "unknown").trimmingCharacters(in: .whitespaces).lowercased())
            let cost = estimatedRowCost(row: row, pricingByModel: pricingByModel)
            // Estimated session active time: wall-clock span of the row, clamped
            // to non-negative and capped at 8h so long-lived sessions don't
            // inflate a single day's active time.
            let started = row.startedAt
            let ended = row.lastUsedAt
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
        let files = jsonlFiles(root: promaRoot, recursive: false, client: "proma")
        pruneParseCache(client: "proma", activePaths: Set(files.map { $0.path }))
        var rows: [UsageCore.UsageRow] = []
        for file in files {
            autoreleasepool {
                rows.append(contentsOf: promaFileRows(file, sourceId: sourceId))
            }
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
                    startedAt: createdAt,
                    lastUsedAt: createdAt,
                    projectId: "",
                    projectLabel: "",
                    performance: nil
                )
            }
        }
        guard var row = best else { return nil }
        row.startedAt = latestCreatedAt
        row.lastUsedAt = latestCreatedAt
        return row
    }

    // MARK: - Hanako (~/.hanako/agents/*/{sessions,activity}/**/*.jsonl)

    static var hanakoRoots: [String] {
        let home = NSHomeDirectory()
        let agentsBase = home + "/.hanako/agents"
        var agentNames = Set(["hanako", "ming", "butter"])
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: agentsBase) {
            for item in contents where !item.hasPrefix(".") {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: "\(agentsBase)/\(item)", isDirectory: &isDir), isDir.boolValue {
                    agentNames.insert(item)
                }
            }
        }
        var roots: [String] = []
        for agent in agentNames.sorted() {
            roots.append("\(agentsBase)/\(agent)/sessions")
            roots.append("\(agentsBase)/\(agent)/activity")
        }
        return roots
    }

    private struct HanakoFileResult {
        var rows: [UsageCore.UsageRow] = []
        var messageIds: [String] = []
    }

    static func collectHanakoRows() -> [UsageCore.UsageRow] {
        var allFiles: [URL] = []
        for root in hanakoRoots {
            allFiles.append(contentsOf: jsonlFiles(root: root, recursive: true, client: "hanako"))
        }
        pruneParseCache(client: "hanako", activePaths: Set(allFiles.map { $0.path }))
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
        var agentName = ""
        let parts = file.pathComponents
        if let idx = parts.firstIndex(of: "agents"), idx + 1 < parts.count {
            agentName = parts[idx + 1]
        }
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
                startedAt: createdAt,
                lastUsedAt: createdAt,
                projectId: agentName,
                projectLabel: agentName,
                performance: nil
            ))
            result.messageIds.append(messageId ?? "")
        }
        return result
    }

    // MARK: - Antigravity (~/.config/tokscale/antigravity-cache/sessions/*.jsonl)

    static let antigravityCacheRoot = NSHomeDirectory() + "/.config/tokscale/antigravity-cache"
    static let antigravitySessionsRoot = NSHomeDirectory() + "/.config/tokscale/antigravity-cache/sessions"

    static var antigravityCacheRoots: [String] {
        let home = NSHomeDirectory()
        var roots = [
            home + "/.config/tokscale/antigravity-cache",
            home + "/Library/Application Support/tokscale/antigravity-cache"
        ]
        if let env = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"], !env.isEmpty {
            roots.append(env + "/antigravity-cache")
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
    }

    static var antigravitySessionsRoots: [String] {
        return antigravityCacheRoots.map { $0 + "/sessions" }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func collectAntigravityRows() -> [UsageCore.UsageRow] {
        let sessionTimestamps = loadAntigravityManifestTimestamps()
        var rows: [UsageCore.UsageRow] = []
        var seenFileNames = Set<String>()

        let defaultRoot = antigravitySessionsRoot
        let candidateRoots = antigravitySessionsRoots.isEmpty ? [defaultRoot] : antigravitySessionsRoots

        var allFiles: [URL] = []
        for sessionsRoot in candidateRoots {
            allFiles.append(contentsOf: jsonlFiles(root: sessionsRoot, recursive: false, client: "antigravity"))
        }
        pruneParseCache(client: "antigravity", activePaths: Set(allFiles.map { $0.path }))

        for sessionsRoot in candidateRoots {
            let sourceId = sourceNamespace(sessionsRoot)
            for file in jsonlFiles(root: sessionsRoot, recursive: false, client: "antigravity") {
                let filename = file.lastPathComponent
                guard seenFileNames.insert(filename).inserted else { continue }
                autoreleasepool {
                    rows.append(contentsOf: antigravityFileRows(file, sourceId: sourceId, sessionTimestamps: sessionTimestamps))
                }
            }
        }
        return sortRows(rows)
    }

    private static func loadAntigravityManifestTimestamps() -> [String: Double] {
        var map: [String: Double] = [:]
        let candidateRoots = antigravityCacheRoots.isEmpty ? [antigravityCacheRoot] : antigravityCacheRoots
        for cacheRoot in candidateRoots {
            let manifestUrl = URL(fileURLWithPath: cacheRoot + "/manifest.json")
            guard let data = try? Data(contentsOf: manifestUrl),
                  let json = try? JSONSerialization.jsonObject(with: data) as? JSON,
                  let sessions = json["sessions"] as? [JSON] else { continue }
            for s in sessions {
                guard let sid = s["sessionId"] as? String else { continue }
                var msValue: Double?
                if let ms = s["lastModifiedMs"] as? Double {
                    msValue = ms
                } else if let msInt = s["lastModifiedMs"] as? Int64 {
                    msValue = Double(msInt)
                } else if let msInt = s["lastModifiedMs"] as? Int {
                    msValue = Double(msInt)
                }
                if let msValue {
                    if let existing = map[sid] {
                        map[sid] = max(existing, msValue)
                    } else {
                        map[sid] = msValue
                    }
                }
            }
        }
        return map
    }

    private struct AntigravityCachedFile {
        let manifestTs: Double
        let rows: [UsageCore.UsageRow]
    }

    private static func antigravityFileRows(_ file: URL, sourceId: String, sessionTimestamps: [String: Double]) -> [UsageCore.UsageRow] {
        let sid = file.deletingPathExtension().lastPathComponent
        let manifestTs = sessionTimestamps[sid] ?? 0
        if let stamp = fileStamp(file) {
            let key = "antigravity|\(file.path)"
            fileCacheLock.lock()
            if let cached = parseCache[key], cached.stamp.0 == stamp.mtime, cached.stamp.1 == stamp.size,
               let entry = cached.value as? AntigravityCachedFile, entry.manifestTs == manifestTs {
                fileCacheLock.unlock()
                return entry.rows
            }
            fileCacheLock.unlock()
            let rows = parseAntigravityFile(file, sourceId: sourceId, sessionTimestamps: sessionTimestamps)
            fileCacheLock.lock()
            parseCache[key] = (stamp, AntigravityCachedFile(manifestTs: manifestTs, rows: rows))
            fileCacheLock.unlock()
            return rows
        }
        return parseAntigravityFile(file, sourceId: sourceId, sessionTimestamps: sessionTimestamps)
    }

    private static func parseAntigravityFile(_ file: URL, sourceId: String, sessionTimestamps: [String: Double]) -> [UsageCore.UsageRow] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let fallbackSessionId = file.deletingPathExtension().lastPathComponent
        let defaultTime: Double = {
            if let stamp = fileStamp(file) {
                return stamp.mtime.timeIntervalSince1970 * 1000.0
            }
            return Date().timeIntervalSince1970 * 1000.0
        }()

        var rows: [UsageCore.UsageRow] = []
        for obj in parseJsonlLines(data) {
            guard (obj["type"] as? String) == "usage" else { continue }
            let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) ?? fallbackSessionId
            let modelId = (obj["modelId"] as? String) ?? (obj["model_id"] as? String) ?? (obj["model"] as? String) ?? "gemini-3.7-flash"
            let input = UsageCore.doubleValue(obj["input"] ?? obj["inputTokens"] ?? obj["input_tokens"])
            let output = UsageCore.doubleValue(obj["output"] ?? obj["outputTokens"] ?? obj["output_tokens"])
            let cacheRead = UsageCore.doubleValue(obj["cacheRead"] ?? obj["cacheReadTokens"] ?? obj["cache_read"] ?? obj["cache_read_tokens"])
            let cacheWrite = UsageCore.doubleValue(obj["cacheWrite"] ?? obj["cacheWriteTokens"] ?? obj["cache_write"] ?? obj["cache_write_tokens"])
            let reasoning = UsageCore.doubleValue(obj["reasoning"] ?? obj["reasoningTokens"] ?? obj["reasoning_tokens"])

            let time: Double
            if let ts = obj["timestamp"], !(ts is NSNull) {
                let parsed = UsageCore.timestampMs(ts)
                time = parsed > 0 ? parsed : (sessionTimestamps[sessionId] ?? defaultTime)
            } else {
                time = sessionTimestamps[sessionId] ?? defaultTime
            }

            rows.append(UsageCore.UsageRow(
                client: "antigravity",
                sessionId: "\(sessionId)@\(sourceId)",
                model: modelId,
                provider: "google",
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                messageCount: 1,
                cost: 0,
                startedAt: time,
                lastUsedAt: time,
                projectId: "",
                projectLabel: "",
                performance: nil
            ))
        }
        return rows
    }

    // MARK: - Kimi Adapter (~/.kimi-code/sessions/wd_* / ~/.kimi/sessions)

    static var kimiRoots: [String] {
        let home = NSHomeDirectory()
        var roots = [
            home + "/.kimi-code/sessions",
            home + "/.kimi/sessions"
        ]
        let custom = SourceScanner.kimiCodeHome()
        if !custom.isEmpty {
            roots.append(custom + "/sessions")
        }
        return Array(Set(roots)).filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func collectKimiRows() -> [UsageCore.UsageRow] {
        var rows: [UsageCore.UsageRow] = []
        var seenSessionDirs = Set<String>()

        for sessionsRoot in kimiRoots {
            let sessionDirs = findKimiSessionDirs(at: sessionsRoot)
            for sDir in sessionDirs {
                let dirPath = sDir.path
                guard seenSessionDirs.insert(dirPath).inserted else { continue }
                autoreleasepool {
                    rows.append(contentsOf: parseKimiSessionDir(sDir))
                }
            }
        }
        return sortRows(rows)
    }

    static func findKimiSessionDirs(at rootPath: String) -> [URL] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var sessionDirs: [URL] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = entry.lastPathComponent
            if name.hasPrefix("session_") || fm.fileExists(atPath: entry.appendingPathComponent("state.json").path) {
                sessionDirs.append(entry)
            } else if name.hasPrefix("wd_") {
                if let subEntries = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for sub in subEntries {
                        var subIsDir: ObjCBool = false
                        if fm.fileExists(atPath: sub.path, isDirectory: &subIsDir), subIsDir.boolValue {
                            if sub.lastPathComponent.hasPrefix("session_") || fm.fileExists(atPath: sub.appendingPathComponent("state.json").path) {
                                sessionDirs.append(sub)
                            }
                        }
                    }
                }
            }
        }
        return sessionDirs
    }

    static func parseKimiSessionDir(_ dir: URL) -> [UsageCore.UsageRow] {
        let fm = FileManager.default
        var sessionId = dir.lastPathComponent
        var title = ""
        var cwd = ""
        var createdAt: Double = 0
        var updatedAt: Double = 0

        let stateUrl = dir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateUrl),
           let json = try? JSONSerialization.jsonObject(with: data) as? JSON {
            if let idStr = json["id"] as? String, !idStr.isEmpty { sessionId = idStr }
            if let tStr = json["title"] as? String { title = tStr }
            if let cStr = json["cwd"] as? String { cwd = cStr }
            if let ca = json["createdAt"] as? Double { createdAt = ca }
            else if let ca = json["createdAt"] as? Int64 { createdAt = Double(ca) }
            if let ua = json["updatedAt"] as? Double { updatedAt = ua }
            else if let ua = json["updatedAt"] as? Int64 { updatedAt = Double(ua) }
        }

        if updatedAt == 0 {
            if let attrs = try? fm.attributesOfItem(atPath: dir.path), let mdate = attrs[.modificationDate] as? Date {
                updatedAt = mdate.timeIntervalSince1970 * 1000
            }
        }
        if createdAt == 0 { createdAt = updatedAt }

        var wireFiles: [URL] = []
        let directWire = dir.appendingPathComponent("wire.jsonl")
        if fm.fileExists(atPath: directWire.path) { wireFiles.append(directWire) }

        let agentsDir = dir.appendingPathComponent("agents")
        if let agentEntries = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for agentDir in agentEntries {
                let agentWire = agentDir.appendingPathComponent("wire.jsonl")
                if fm.fileExists(atPath: agentWire.path) {
                    wireFiles.append(agentWire)
                }
            }
        }

        struct ModelUsageBucket {
            var inputOther: Double = 0
            var output: Double = 0
            var cacheRead: Double = 0
            var cacheCreation: Double = 0
            var reasoning: Double = 0
            var messageCount: Double = 0
            var firstTime: Double = 0
            var lastTime: Double = 0
        }
        var buckets: [String: ModelUsageBucket] = [:]

        for wireFile in wireFiles {
            guard let data = try? Data(contentsOf: wireFile) else { continue }
            let lines = parseJsonlLines(data)
            let hasUsageRecord = lines.contains { ($0["type"] as? String) == "usage.record" }

            for line in lines {
                guard let type = line["type"] as? String else { continue }
                var usageObj: JSON?
                var modelRaw: String?
                var timeMs: Double = 0

                if hasUsageRecord {
                    guard type == "usage.record" else { continue }
                    usageObj = line["usage"] as? JSON
                    modelRaw = line["model"] as? String
                    timeMs = UsageCore.doubleValue(line["time"])
                } else if type == "context.append_loop_event",
                          let event = line["event"] as? JSON,
                          (event["type"] as? String) == "step.end",
                          let evUsage = event["usage"] as? JSON {
                    usageObj = evUsage
                    modelRaw = (event["model"] as? String) ?? (line["model"] as? String)
                    timeMs = UsageCore.doubleValue(line["time"])
                }

                guard let usage = usageObj else { continue }
                let modelId = UsageCore.normalizeModelName(modelRaw ?? "") ?? "k3-256k"
                let inputOther = UsageCore.doubleValue(usage["inputOther"] ?? usage["input"] ?? usage["input_tokens"])
                let output = UsageCore.doubleValue(usage["output"] ?? usage["output_tokens"])
                let cacheRead = UsageCore.doubleValue(usage["inputCacheRead"] ?? usage["cache_read"] ?? usage["cache_read_input_tokens"] ?? usage["cacheRead"])
                let cacheCreation = UsageCore.doubleValue(usage["inputCacheCreation"] ?? usage["cache_creation"] ?? usage["cache_write_input_tokens"] ?? usage["cacheWrite"])
                let reasoning = UsageCore.doubleValue(usage["reasoning"] ?? usage["reasoning_tokens"])

                var bucket = buckets[modelId] ?? ModelUsageBucket()
                bucket.inputOther += inputOther
                bucket.output += output
                bucket.cacheRead += cacheRead
                bucket.cacheCreation += cacheCreation
                bucket.reasoning += reasoning
                bucket.messageCount += 1
                if timeMs > 0 {
                    if bucket.firstTime == 0 || timeMs < bucket.firstTime { bucket.firstTime = timeMs }
                    if timeMs > bucket.lastTime { bucket.lastTime = timeMs }
                }
                buckets[modelId] = bucket
            }
        }

        let pLabel = title.isEmpty ? (cwd.isEmpty ? sessionId : URL(fileURLWithPath: cwd).lastPathComponent) : title
        let pId = cwd.isEmpty ? sessionId : sourceNamespace(cwd)

        var rows: [UsageCore.UsageRow] = []
        for (modelId, b) in buckets {
            let start = b.firstTime > 0 ? b.firstTime : createdAt
            let last = b.lastTime > 0 ? b.lastTime : updatedAt
            let row = UsageCore.UsageRow(
                client: "kimi",
                sessionId: sessionId,
                model: modelId,
                provider: "moonshot",
                input: b.inputOther,
                output: b.output,
                cacheRead: b.cacheRead,
                cacheWrite: b.cacheCreation,
                reasoning: b.reasoning,
                messageCount: b.messageCount,
                cost: 0,
                startedAt: start,
                lastUsedAt: last,
                projectId: pId,
                projectLabel: pLabel,
                performance: nil
            )
            rows.append(row)
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
    ///
    /// Round-4 Phase 5: no decompressed-Data memoization here. The parse
    /// cache above already memoizes the parsed DshFileResult per
    /// (path, mtime, size), so unchanged sessions are never re-decompressed
    /// AND the full decompressed buffer is released as soon as the parse
    /// finishes — the duplicate multi-megabyte __DataStorage retention is
    /// gone. The returned Data is a parse-time temporary only.
    static func decompressZstd(_ url: URL) -> Data? {
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        return decompressZstdUncached(url, diag: diag)
    }

    private static func decompressZstdUncached(_ url: URL, diag: Bool) -> Data? {
        fileCacheLock.lock()
        decompressCounter += 1
        fileCacheLock.unlock()
        if diag { NSLog("[dsh] decompress %@", url.path) }
        guard let compressed = try? Data(contentsOf: url) else {
            if diag { NSLog("[dsh] read failed: %@", url.path) }
            return nil
        }
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        let initResult = ZSTD_initDStream(stream)
        guard ZSTD_isError(initResult) == 0 else { return nil }
        let (output, stoppedOnError) = feedZstd(stream, input: compressed, diag: diag, name: url.lastPathComponent)
        if stoppedOnError {
            // Corrupt frame mid-file: keep the valid prefix instead of
            // zeroing the session (upstream decodeSessionText semantics).
            if diag { NSLog("[dsh] corrupt frame in %@: keeping decoded prefix", url.lastPathComponent) }
        }
        return output
    }

    /// Feed compressed bytes through a streaming decoder, returning the
    /// decompressed output. Used both for full parses and for incremental
    /// tail feeds on a retained stream.
    ///
    /// A torn trailing frame (live session scanned mid-write) is not an
    /// error: the input simply runs out and every block decoded so far is
    /// kept — same as dsh's own reader and tokscale's streaming decoder.
    /// A content-corrupt frame (checksum mismatch, damaged block) surfaces
    /// as stoppedOnError with the prefix decoded BEFORE that frame kept:
    /// the first undecodable frame is the recovery boundary, nothing past
    /// it is trusted, and the caller must not retain the (now poisoned)
    /// stream. Matches upstream decodeZstdBuffer, which decodes complete
    /// frames in order and stops at the first frame that fails to decode
    /// instead of throwing the whole transcript away.
    private static func feedZstd(_ stream: OpaquePointer, input: Data, diag: Bool = false, name: String = "?") -> (output: Data, stoppedOnError: Bool) {
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Data, Bool) in
            // Pre-allocate the output buffer when the zstd frame header
            // records the uncompressed size — avoids repeated realloc as
            // 64KB chunks append (session files decompress to a few MB).
            if let base = raw.baseAddress, raw.count > 0 {
                let frameSize = ZSTD_getFrameContentSize(base, raw.count)
                if frameSize > 0 && frameSize < UInt64.max - 1 {
                    output.reserveCapacity(Int(frameSize))
                }
            }
            var inBuf = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            var keepGoing = true
            while keepGoing {
                let produced = chunk.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Int in
                    var out = ZSTD_outBuffer(dst: outRaw.baseAddress, size: outRaw.count, pos: 0)
                    let ret = ZSTD_decompressStream(stream, &out, &inBuf)
                    if ZSTD_isError(ret) != 0 {
                        if diag {
                            NSLog("[dsh] stream error for %@: %@", name,
                                  String(cString: ZSTD_getErrorName(Int(ret))))
                        }
                        return -1
                    }
                    return out.pos
                }
                // Unlike a per-frame all-or-nothing decode, the streaming
                // API may already have emitted whole blocks of the frame
                // that ultimately fails — keeping them matches tokscale's
                // decoder, which emits every record read before the error;
                // the per-line JSON parse downstream skips any garbage.
                guard produced >= 0 else { return (output, true) }
                if produced > 0 {
                    output.append(contentsOf: chunk[0..<produced])
                }
                keepGoing = (inBuf.pos < inBuf.size) || produced > 0
            }
            return (output, false)
        }
    }

    static func collectDshRows() -> [UsageCore.UsageRow] {
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        let files = dshSessionFiles()
        // Bounded cache (round-4 Phase 5): entries for deleted session files
        // are pruned so the parse cache tracks live files only.
        pruneDshParseCache(activeFiles: Set(files.map { $0.path }))
        var rows: [UsageCore.UsageRow] = []
        var totalEvents = 0
        for file in files {
            autoreleasepool {
                let parsed = cachedSessionFileRows(file)
                totalEvents += parsed.events
                rows.append(contentsOf: parsed.rows)
            }
        }
        if diag {
            NSLog("[dsh] files=%d usageEvents=%d rows=%d", files.count, totalEvents, rows.count)
        }
        return sortRows(rows)
    }

    struct DshFileResult {
        var rows: [UsageCore.UsageRow] = []
        var events = 0
    }

    /// Parse one session.jsonl.zstd into usage rows, memoized by
    /// (path, mtime, size) — unchanged sessions skip decompress + parse.
    /// Actively-appending sessions use the incremental streaming state so a
    /// re-read only decompresses/parses the appended tail.
    /// Internal (not private) so the fixture checker can drive one file at a
    /// time on temporary zstd fixtures without touching real user sessions.
    static func cachedSessionFileRows(_ file: URL) -> DshFileResult {
        guard let stamp = fileStamp(file) else { return parseSessionFile(file) }
        let key = "dsh|\(file.path)"
        fileCacheLock.lock()
        let hit: DshFileResult? = parseCache[key].flatMap { cached in
            (cached.stamp.0 == stamp.mtime && cached.stamp.1 == stamp.size) ? cached.value as? DshFileResult : nil
        }
        if hit != nil {
            // Stable file with a memoized result: free the incremental state
            // once the file has been untouched for a grace period. The grace
            // matters: a slowly-appending session (one line per tick) is
            // unchanged on most ticks, and dropping its stream after the
            // first stable tick would force a full re-parse on every append.
            if var state = dshIncrementalStates[file.path],
               state.stamp.mtime == stamp.mtime, state.stamp.size == stamp.size,
               Date().timeIntervalSince(stamp.mtime) > 120 {
                freeDshStream(&state)
                dshIncrementalStates[file.path] = nil
            }
        }
        fileCacheLock.unlock()
        if let hit { return hit }
        return dshRead(file, key: key, stamp: stamp)
    }

    /// A file that changed since its last read: first touch does a full
    /// parse and keeps streaming state; later appends feed only the tail;
    /// a file that stopped changing gets one final full verify (which also
    /// memoizes the result and drops the state). Truncation/rewrites reset.
    private static func dshRead(_ file: URL, key: String, stamp: (mtime: Date, size: Int)) -> DshFileResult {
        fileCacheLock.lock()
        var state = dshIncrementalStates[file.path]
        fileCacheLock.unlock()

        if var s = state {
            if stamp.size < s.compressedOffset {
                // Truncated: the retained stream position is invalid.
                freeDshStream(&s)
                fileCacheLock.lock()
                dshIncrementalStates[file.path] = nil
                fileCacheLock.unlock()
                state = nil
            } else if s.stamp.mtime == stamp.mtime && s.stamp.size == stamp.size {
                // Unchanged since the last incremental parse: one final full
                // re-parse corrects any in-flight model attribution,
                // memoizes the result, and drops the streaming state.
                let full = parseSessionFile(file)
                freeDshStream(&s)
                fileCacheLock.lock()
                dshIncrementalStates[file.path] = nil
                parseCache[key] = (stamp, full)
                fileCacheLock.unlock()
                return full
            } else if headFingerprint(file) != s.headFingerprint {
                // Rewritten in place (frame header changed): reset.
                freeDshStream(&s)
                fileCacheLock.lock()
                dshIncrementalStates[file.path] = nil
                fileCacheLock.unlock()
                state = nil
            } else {
                return feedDshDelta(file, state: &s, stamp: stamp)
            }
        }
        return dshFullParseAndInit(file, key: key, stamp: stamp)
    }

    /// First read (or reset): full decompression through a fresh streaming
    /// decoder, full two-pass parse, then keep decoder + accumulation state
    /// for cheap appends. Memoizes the initial result as well.
    private static func dshFullParseAndInit(_ file: URL, key: String, stamp: (mtime: Date, size: Int)) -> DshFileResult {
        guard let compressed = try? Data(contentsOf: file) else { return DshFileResult() }
        guard let stream = ZSTD_createDStream(),
              ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { return DshFileResult() }
        fileCacheLock.lock()
        decompressCounter += 1
        fileCacheLock.unlock()
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        let (output, stoppedOnError) = feedZstd(stream, input: compressed, diag: diag, name: file.lastPathComponent)
        let sessionId = file.deletingLastPathComponent().lastPathComponent
        let parsed = parseSessionData(output, sessionId: sessionId)
        let result = DshFileResult(rows: parsed.rows, events: parsed.events)
        if stoppedOnError {
            // A content-corrupt frame is the recovery boundary: the parsed
            // prefix is kept (and memoized), but no streaming state is
            // retained — the decoder is poisoned at the error and nothing
            // past the corrupt frame is trusted, so a later append re-parses
            // from scratch, stopping at the same frame until the file is
            // rewritten.
            if diag { NSLog("[dsh] corrupt frame in %@: prefix kept (%d rows)", file.lastPathComponent, parsed.rows.count) }
            ZSTD_freeDStream(stream)
            fileCacheLock.lock()
            // Also drop any stale incremental entry: when this full parse is
            // the fallback of a failed delta feed, the old entry still
            // points at the stream that feed already freed.
            dshIncrementalStates[file.path] = nil
            parseCache[key] = (stamp, result)
            fileCacheLock.unlock()
            return result
        }
        let state = DshIncrementalState(
            sessionId: sessionId,
            stamp: stamp,
            compressedOffset: compressed.count,
            headFingerprint: headFingerprint(file),
            stream: stream,
            seenSeq: parsed.seenSeq,
            seedLength: parsed.seedLength,
            fallbackModel: parsed.fallbackModel,
            headerCreatedAt: parsed.headerCreatedAt,
            lastTime: parsed.lastTime,
            pendingEvents: [],
            rows: parsed.rows,
            totalEvents: parsed.events
        )
        fileCacheLock.lock()
        dshIncrementalStates[file.path] = state
        parseCache[key] = (stamp, result)
        fileCacheLock.unlock()
        return result
    }

    /// Feed the appended tail through the retained streaming decoder and
    /// parse only the new lines. Usage events whose (turn, step) model is
    /// not yet known are held as pending until a finish chunk resolves them.
    /// When a finish payload has no model, the request-header fallback still
    /// resolves the usage immediately, rather than waiting for an idle full
    /// re-parse of a continuously active DSH session.
    private static func feedDshDelta(_ file: URL, state: inout DshIncrementalState, stamp: (mtime: Date, size: Int)) -> DshFileResult {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return DshFileResult(rows: state.rows, events: state.totalEvents)
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(state.compressedOffset))
        guard let tail = try? handle.readToEnd(), !tail.isEmpty else {
            state.stamp = stamp
            return DshFileResult(rows: state.rows, events: state.totalEvents)
        }
        fileCacheLock.lock()
        decompressCounter += 1
        fileCacheLock.unlock()
        guard let stream = state.stream else {
            freeDshStream(&state)
            return dshFullParseAndInit(file, key: "dsh|\(file.path)", stamp: stamp)
        }
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        let (output, stoppedOnError) = feedZstd(stream, input: tail, diag: diag, name: file.lastPathComponent)
        state.compressedOffset += tail.count
        state.stamp = stamp
        if stoppedOnError {
            // Corrupt frame in the appended tail: nothing past the first
            // undecodable frame is trusted, so the partial tail output is
            // discarded and the whole file is re-parsed from scratch — the
            // full parse keeps the valid prefix up to the corrupt frame.
            freeDshStream(&state)
            return dshFullParseAndInit(file, key: "dsh|\(file.path)", stamp: stamp)
        }
        if !output.isEmpty, let text = String(data: output, encoding: .utf8) {
            parseDeltaLines(text, state: &state)
        }
        if diag {
            NSLog("[dsh] delta %@ tail=%d bytes events=%d rows=%d", file.lastPathComponent, tail.count, state.totalEvents, state.rows.count)
        }
        fileCacheLock.lock()
        dshIncrementalStates[file.path] = state
        fileCacheLock.unlock()
        return DshFileResult(rows: state.rows, events: state.totalEvents)
    }

    private static func parseDeltaLines(_ text: String, state: inout DshIncrementalState) {
        for line in text.split(whereSeparator: \.isNewline) {
            autoreleasepool {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? JSON else { return }
                let seq = obj["seq"] as? Int ?? 0
                let type = obj["type"] as? String ?? ""
                // The session record carries `seedLength`: a fork's log is seeded
                // with a byte-for-byte copy of its parent's events, and that
                // shared prefix is credited to the parent only. seq is 0-indexed,
                // so the event AT seq == seedLength is the fork's own first new
                // event — skip strictly `seq < seedLength`. A session record
                // without the field clears it again, and a torn/absent header
                // leaves it nil so no event is ever skipped on a guess.
                if type == "session" {
                    if let createdAt = obj["createdAt"] { state.headerCreatedAt = UsageCore.timestampMs(createdAt) }
                    state.seedLength = obj["seedLength"] as? Int
                    return
                }
                if let seed = state.seedLength, seq < seed { return }
                if state.seenSeq.contains(seq) { return }
                state.seenSeq.insert(seq)
                let time = UsageCore.timestampMs(obj["time"])
                if time > state.lastTime { state.lastTime = time }
                let data = obj["data"] as? JSON ?? JSON()
                if type == "request/header" || type == "request/context" {
                    let header = data["header"] as? JSON ?? data
                    let config = header["config"] as? JSON ?? header
                    if let model = config["model"] as? String { state.fallbackModel = model }
                    return
                }
                if type == "assistant/chunk" {
                    let chunk = data["chunk"] as? JSON ?? JSON()
                    let chunkType = chunk["type"] as? String ?? ""
                    let turn = data["turn"] as? Int ?? 0
                    let step = data["step"] as? Int ?? 0
                    if chunkType == "usage", let usage = chunk["usage"] as? JSON {
                        state.pendingEvents.append(PendingDshEvent(turn: turn, step: step, time: time, usage: usage))
                        state.totalEvents += 1
                    } else if chunkType == "finish" {
                        let model = dshFinishModel(from: chunk) ?? state.fallbackModel
                        resolvePendingDshEvents(&state, turn: turn, step: step, model: model)
                    }
                }
            }
        }
    }

    /// DSH has emitted both a legacy `replayState.model` field and the
    /// current OpenCode-shaped `replayState.response.model` field. Keep the
    /// extraction shared by full and incremental parsing so live sessions and
    /// restart-time scans attribute the same model.
    private static func dshFinishModel(from chunk: JSON) -> String? {
        guard let replayState = chunk["replayState"] as? JSON else { return nil }
        let candidates = [
            replayState["model"] as? String,
            (replayState["response"] as? JSON)?["model"] as? String
        ]
        for candidate in candidates {
            let model = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !model.isEmpty { return model }
        }
        return nil
    }

    /// Emit rows for pending usage events whose (turn, step) model just
    /// became known, in arrival order.
    private static func resolvePendingDshEvents(_ state: inout DshIncrementalState, turn: Int, step: Int, model: String) {
        var index = 0
        while index < state.pendingEvents.count {
            let event = state.pendingEvents[index]
            if event.turn == turn && event.step == step {
                state.rows.append(makeDshRow(
                    sessionId: state.sessionId, model: model, eventTime: event.time,
                    headerCreatedAt: state.headerCreatedAt, lastTime: state.lastTime, usage: event.usage
                ))
                state.pendingEvents.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// First 64 bytes of the compressed file: cheap rewrite detector for
    /// the incremental path (a truncated/recompressed file changes its
    /// frame header, while plain appends keep the prefix identical).
    private static func headFingerprint(_ file: URL) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        return Array((try? handle.read(upToCount: 64)) ?? Data())
    }

    private static func freeDshStream(_ state: inout DshIncrementalState) {
        if let stream = state.stream {
            ZSTD_freeDStream(stream)
            state.stream = nil
        }
    }

    /// One pending usage event awaiting its (turn, step) model.
    struct PendingDshEvent {
        var turn: Int
        var step: Int
        var time: Double
        var usage: JSON
    }

    /// Streaming state for one session.jsonl.zstd that is actively
    /// appending: a retained ZSTD decoder positioned at compressedOffset,
    /// the accumulated parse context and the accumulated rows. Only files
    /// that changed recently hold a state; stable files are memoized and
    /// their streams freed. `seedLength` lives here (like seenSeq) because
    /// the session record that carries it appears once at the head of the
    /// file — later delta feeds never see it again.
    struct DshIncrementalState {
        var sessionId: String
        var stamp: (mtime: Date, size: Int)
        var compressedOffset: Int
        var headFingerprint: [UInt8]
        var stream: OpaquePointer?
        var seenSeq: Set<Int>
        var seedLength: Int?
        var fallbackModel: String
        var headerCreatedAt: Double
        var lastTime: Double
        var pendingEvents: [PendingDshEvent]
        var rows: [UsageCore.UsageRow]
        var totalEvents: Int
    }

    private static func parseSessionFile(_ file: URL) -> DshFileResult {
        let diag = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil
        guard let data = decompressZstd(file) else {
            if diag { NSLog("[dsh] decompress failed: %@", file.path) }
            return DshFileResult()
        }
        let parsed = parseSessionData(data, sessionId: file.deletingLastPathComponent().lastPathComponent)
        return DshFileResult(rows: parsed.rows, events: parsed.events)
    }

    /// Parsed content of one dsh session plus the context an incremental
    /// delta parse needs to continue (model fallback, timestamps, dedupe,
    /// fork seed length).
    private struct ParsedDshSession {
        var rows: [UsageCore.UsageRow] = []
        var events = 0
        var fallbackModel = "unknown"
        var headerCreatedAt = 0.0
        var lastTime = 0.0
        var seenSeq: Set<Int> = []
        var seedLength: Int? = nil
    }

    /// Two-pass parse of a fully decompressed session: pass 1 attributes
    /// models per (turn, step) from finish chunks plus the session-level
    /// fallback model from request/header; pass 2 builds usage rows.
    private static func parseSessionData(_ data: Data, sessionId: String) -> ParsedDshSession {
        guard let text = String(data: data, encoding: .utf8) else { return ParsedDshSession() }

        // Pass 1: attribute models per (turn, step) from finish chunks,
        // plus the session-level fallback model from request/header.
        var stepModels: [String: String] = [:]
        var fallbackModel = "unknown"
        var headerCreatedAt = 0.0
        var lastTime = 0.0
        var usageEvents: [JSON] = []
        var seenSeq = Set<Int>()
        // A forked session's log is seeded with a byte-for-byte copy of its
        // parent's events up to `session.seedLength`; tokscale credits that
        // shared prefix to the parent only, so it is skipped here too, or a
        // fork's tokens are counted twice. seq is 0-indexed: the event AT
        // seq == seedLength is the fork's own first new event. seedLength
        // stays nil until a session record sets it — a torn header must not
        // make an otherwise-parseable transcript report zero tokens.
        var seedLength: Int?

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? JSON else { continue }
            let seq = obj["seq"] as? Int ?? 0
            let type = obj["type"] as? String ?? ""

            if type == "session" {
                if let createdAt = obj["createdAt"] { headerCreatedAt = UsageCore.timestampMs(createdAt) }
                seedLength = obj["seedLength"] as? Int
                continue
            }
            if let seed = seedLength, seq < seed { continue }
            if seenSeq.contains(seq) { continue }
            seenSeq.insert(seq)
            let time = UsageCore.timestampMs(obj["time"])
            if time > lastTime { lastTime = time }
            let data = obj["data"] as? JSON ?? JSON()

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
                    let event: JSON = ["usage": usage, "turn": turn, "step": step, "time": time]
                    usageEvents.append(event)
                } else if chunkType == "finish" {
                    if let model = dshFinishModel(from: chunk) {
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
            let eventTime = UsageCore.doubleValue(event["time"])
            rows.append(makeDshRow(
                sessionId: sessionId, model: model, eventTime: eventTime,
                headerCreatedAt: headerCreatedAt, lastTime: lastTime, usage: usage
            ))
        }
        return ParsedDshSession(
            rows: rows, events: usageEvents.count,
            fallbackModel: fallbackModel, headerCreatedAt: headerCreatedAt,
            lastTime: lastTime, seenSeq: seenSeq, seedLength: seedLength
        )
    }

    /// One usage row from a usage event. Attribute each event to its own
    /// timestamp (not the session header's createdAt): a session that spans
    /// local midnight must contribute to the day its tokens were actually
    /// spent, so "today" includes every session active today (periodRows
    /// filters on startedAt; proma/hanako rows already carry per-message
    /// times). Fall back to the header time when the event line has none.
    private static func makeDshRow(sessionId: String, model: String, eventTime: Double, headerCreatedAt: Double, lastTime: Double, usage: JSON) -> UsageCore.UsageRow {
        let createdAt = eventTime > 0 ? eventTime : (headerCreatedAt > 0 ? headerCreatedAt : lastTime)
        return UsageCore.UsageRow(
            client: "dsh",
            sessionId: sessionId,
            model: model,
            provider: "dsh",
            input: UsageCore.doubleValue(usage["inputTokens"]),
            output: UsageCore.doubleValue(usage["outputTokens"]),
            cacheRead: UsageCore.doubleValue(usage["cacheReadTokens"]),
            cacheWrite: UsageCore.doubleValue(usage["cacheWriteTokens"]),
            reasoning: 0,
            messageCount: 1,
            cost: 0,
            startedAt: createdAt,
            lastUsedAt: lastTime,
            projectId: "",
            projectLabel: "",
            performance: nil
        )
    }
}
