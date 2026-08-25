import Foundation
import SQLite3

/// SQLite-backed persistent ledger for token usage history and session records.
///
/// Ensures historical usage (tokens, costs, message counts, active time) is
/// preserved even when:
///  1. The user deletes chat transcripts / session files from disk;
///  2. An AI tool/client is uninstalled and its data directory is removed;
///  3. Token Monitor restarts or is updated.
///
/// Active sessions are upserted with MAX / latest fields to prevent double counting.
final class HistoryLedger {
    static let shared = HistoryLedger()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let dbURL: URL

    // In-memory query caches to prevent repeated full-table allocations on every tick
    private var isDirty = true
    private var cachedPeriods: (today: [String: Any], month: [String: Any], allTime: [String: Any])?
    private var cachedPeriodsKey = ""
    private var cachedHistoryDays: [HistoryCore.Day]?
    private var cachedHistoryDaysKey = ""

    // MARK: - Lifecycle

    init(dbURL: URL? = nil) {
        if let dbURL {
            self.dbURL = dbURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("Token Monitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dbURL = dir.appendingPathComponent("ledger.db")
        }
        openDatabase()
        createTablesIfNeeded()
    }

    deinit {
        lock.lock()
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
        lock.unlock()
    }

    private func openDatabase() {
        lock.lock()
        defer { lock.unlock() }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let path = dbURL.path
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            NSLog("[HistoryLedger] Failed to open SQLite database at %@: %s", path, sqlite3_errmsg(db))
            return
        }
        // Enable WAL mode for high concurrency, non-blocking reads/writes, and robustness.
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -2000;", nil, nil, nil) // Bound SQLite page cache to 2MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
    }

    private func createTablesIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let createSessionLedgerSQL = """
        CREATE TABLE IF NOT EXISTS session_ledger (
            session_id TEXT NOT NULL,
            client TEXT NOT NULL,
            date TEXT NOT NULL,
            model_id TEXT NOT NULL,
            provider TEXT NOT NULL DEFAULT '',
            input_tokens REAL NOT NULL DEFAULT 0,
            output_tokens REAL NOT NULL DEFAULT 0,
            cache_read_tokens REAL NOT NULL DEFAULT 0,
            cache_write_tokens REAL NOT NULL DEFAULT 0,
            reasoning_tokens REAL NOT NULL DEFAULT 0,
            message_count REAL NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0.0,
            started_at_ms REAL NOT NULL DEFAULT 0.0,
            last_used_at_ms REAL NOT NULL DEFAULT 0.0,
            project_id TEXT NOT NULL DEFAULT '',
            project_label TEXT NOT NULL DEFAULT '',
            timed_tokens REAL NOT NULL DEFAULT 0,
            timed_duration_ms REAL NOT NULL DEFAULT 0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (session_id, client, date, model_id)
        );
        CREATE INDEX IF NOT EXISTS idx_session_date ON session_ledger(date);
        CREATE INDEX IF NOT EXISTS idx_session_client ON session_ledger(client);
        CREATE INDEX IF NOT EXISTS idx_session_model ON session_ledger(model_id);
        """

        let createDailyLedgerSQL = """
        CREATE TABLE IF NOT EXISTS daily_history_ledger (
            date TEXT NOT NULL,
            client TEXT NOT NULL,
            model_id TEXT NOT NULL,
            tokens REAL NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0.0,
            messages REAL NOT NULL DEFAULT 0.0,
            active_time_ms REAL NOT NULL DEFAULT 0.0,
            updated_at_ms REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (date, client, model_id)
        );
        CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_history_ledger(date);
        CREATE INDEX IF NOT EXISTS idx_daily_client ON daily_history_ledger(client);
        """

        if sqlite3_exec(db, createSessionLedgerSQL, nil, nil, nil) != SQLITE_OK {
            NSLog("[HistoryLedger] Failed to create session_ledger table: %s", sqlite3_errmsg(db))
        }
        if sqlite3_exec(db, createDailyLedgerSQL, nil, nil, nil) != SQLITE_OK {
            NSLog("[HistoryLedger] Failed to create daily_history_ledger table: %s", sqlite3_errmsg(db))
        }
    }

    // MARK: - Upsert Records

    /// Records a batch of UsageRows from local adapters or tokscale scans.
    func recordUsageRows(_ rows: [UsageCore.UsageRow], defaultClient: String? = nil, now: Date = Date()) {
        guard !rows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        isDirty = true
        let nowMs = now.timeIntervalSince1970 * 1000
        let sql = """
        INSERT INTO session_ledger (
            session_id, client, date, model_id, provider,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
            message_count, cost_usd, started_at_ms, last_used_at_ms, project_id, project_label,
            timed_tokens, timed_duration_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, client, date, model_id) DO UPDATE SET
            provider = CASE WHEN excluded.provider != '' THEN excluded.provider ELSE session_ledger.provider END,
            input_tokens = excluded.input_tokens,
            output_tokens = excluded.output_tokens,
            cache_read_tokens = excluded.cache_read_tokens,
            cache_write_tokens = excluded.cache_write_tokens,
            reasoning_tokens = excluded.reasoning_tokens,
            message_count = excluded.message_count,
            cost_usd = CASE WHEN excluded.cost_usd > 0 THEN excluded.cost_usd ELSE session_ledger.cost_usd END,
            started_at_ms = CASE WHEN session_ledger.started_at_ms > 0 THEN session_ledger.started_at_ms ELSE excluded.started_at_ms END,
            last_used_at_ms = MAX(session_ledger.last_used_at_ms, excluded.last_used_at_ms),
            project_id = CASE WHEN excluded.project_id != '' THEN excluded.project_id ELSE session_ledger.project_id END,
            project_label = CASE WHEN excluded.project_label != '' THEN excluded.project_label ELSE session_ledger.project_label END,
            timed_tokens = excluded.timed_tokens,
            timed_duration_ms = excluded.timed_duration_ms,
            updated_at_ms = excluded.updated_at_ms;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryLedger] prepare failed: %s", sqlite3_errmsg(db))
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        for row in rows {
            autoreleasepool {
                let client = UsageCore.normalizeClientName(row.client ?? defaultClient ?? "") ?? defaultClient ?? "unknown"
                let sessionId = (row.sessionId?.trimmingCharacters(in: .whitespaces).isEmpty == false) ? row.sessionId! : "unnamed-session"
                let modelId = UsageCore.normalizeModelName(row.model ?? "") ?? "unknown"
                let provider = UsageCore.normalizeProviderName(row.provider ?? "") ?? ""

                let dateKey: String
                if row.lastUsedAt > 0 {
                    dateKey = DateFormatUtil.dayKey(Date(timeIntervalSince1970: row.lastUsedAt / 1000))
                } else if row.startedAt > 0 {
                    dateKey = DateFormatUtil.dayKey(Date(timeIntervalSince1970: row.startedAt / 1000))
                } else {
                    dateKey = ""
                }

                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (client as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (dateKey as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (modelId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (provider as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 6, row.input)
                sqlite3_bind_double(stmt, 7, row.output)
                sqlite3_bind_double(stmt, 8, row.cacheRead)
                sqlite3_bind_double(stmt, 9, row.cacheWrite)
                sqlite3_bind_double(stmt, 10, row.reasoning)
                sqlite3_bind_double(stmt, 11, row.messageCount)
                sqlite3_bind_double(stmt, 12, row.cost)
                sqlite3_bind_double(stmt, 13, row.startedAt)
                sqlite3_bind_double(stmt, 14, row.lastUsedAt)
                sqlite3_bind_text(stmt, 15, (row.projectId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 16, (row.projectLabel as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 17, row.performance?.timedTokens ?? 0)
                sqlite3_bind_double(stmt, 18, row.performance?.totalDurationMs ?? 0)
                sqlite3_bind_double(stmt, 19, nowMs)

                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Records daily history contributions (e.g. from local adapters or tokscale graph).
    func recordHistoryContributions(_ contributions: [Adapters.HistoryContribution], now: Date = Date()) {
        guard !contributions.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        isDirty = true
        let nowMs = now.timeIntervalSince1970 * 1000
        let sql = """
        INSERT INTO daily_history_ledger (
            date, client, model_id, tokens, cost_usd, messages, active_time_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(date, client, model_id) DO UPDATE SET
            tokens = MAX(daily_history_ledger.tokens, excluded.tokens),
            cost_usd = CASE WHEN excluded.cost_usd > 0 THEN excluded.cost_usd ELSE MAX(daily_history_ledger.cost_usd, excluded.cost_usd) END,
            messages = MAX(daily_history_ledger.messages, excluded.messages),
            active_time_ms = MAX(daily_history_ledger.active_time_ms, excluded.active_time_ms),
            updated_at_ms = excluded.updated_at_ms;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryLedger] prepare failed: %s", sqlite3_errmsg(db))
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        for c in contributions {
            autoreleasepool {
                let client = UsageCore.normalizeClientName(c.client) ?? c.client
                let modelId = UsageCore.normalizeModelName(c.modelId) ?? c.modelId
                let tokens = Double(c.input + c.output + c.cacheRead + c.cacheWrite)

                sqlite3_bind_text(stmt, 1, (c.date as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (client as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (modelId as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 4, tokens)
                sqlite3_bind_double(stmt, 5, c.cost)
                sqlite3_bind_double(stmt, 6, Double(c.messages))
                sqlite3_bind_double(stmt, 7, c.activeTimeMs)
                sqlite3_bind_double(stmt, 8, nowMs)

                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Records parsed Tokscale graph days into the daily history ledger.
    func recordTokscaleDays(_ days: [HistoryCore.Day], now: Date = Date()) {
        guard !days.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        isDirty = true
        let nowMs = now.timeIntervalSince1970 * 1000
        let sql = """
        INSERT INTO daily_history_ledger (
            date, client, model_id, tokens, cost_usd, messages, active_time_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(date, client, model_id) DO UPDATE SET
            tokens = MAX(daily_history_ledger.tokens, excluded.tokens),
            cost_usd = CASE WHEN excluded.cost_usd > 0 THEN excluded.cost_usd ELSE MAX(daily_history_ledger.cost_usd, excluded.cost_usd) END,
            messages = MAX(daily_history_ledger.messages, excluded.messages),
            active_time_ms = MAX(daily_history_ledger.active_time_ms, excluded.active_time_ms),
            updated_at_ms = excluded.updated_at_ms;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryLedger] prepare failed: %s", sqlite3_errmsg(db))
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        for day in days {
            autoreleasepool {
                if day.perClient.isEmpty && day.perModel.isEmpty {
                    sqlite3_bind_text(stmt, 1, (day.date as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, ("unknown" as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, ("unknown" as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(stmt, 4, day.tokens)
                    sqlite3_bind_double(stmt, 5, day.cost)
                    sqlite3_bind_double(stmt, 6, day.messages)
                    sqlite3_bind_double(stmt, 7, day.activeTimeMs)
                    sqlite3_bind_double(stmt, 8, nowMs)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                } else if day.perClient.isEmpty {
                    for (model, mStats) in day.perModel {
                        sqlite3_bind_text(stmt, 1, (day.date as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, ("unknown" as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 3, (model as NSString).utf8String, -1, nil)
                        sqlite3_bind_double(stmt, 4, mStats.tokens)
                        sqlite3_bind_double(stmt, 5, mStats.cost)
                        sqlite3_bind_double(stmt, 6, day.messages)
                        sqlite3_bind_double(stmt, 7, day.activeTimeMs)
                        sqlite3_bind_double(stmt, 8, nowMs)
                        sqlite3_step(stmt)
                        sqlite3_reset(stmt)
                    }
                } else if day.perModel.isEmpty {
                    for (client, cStats) in day.perClient {
                        sqlite3_bind_text(stmt, 1, (day.date as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (client as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 3, ("unknown" as NSString).utf8String, -1, nil)
                        sqlite3_bind_double(stmt, 4, cStats.tokens)
                        sqlite3_bind_double(stmt, 5, cStats.cost)
                        sqlite3_bind_double(stmt, 6, cStats.messages)
                        sqlite3_bind_double(stmt, 7, day.activeTimeMs)
                        sqlite3_bind_double(stmt, 8, nowMs)
                        sqlite3_step(stmt)
                        sqlite3_reset(stmt)
                    }
                } else {
                    let activePerModel = day.activeTimeMs / Double(day.perModel.count)
                    for (client, cStats) in day.perClient {
                        for (model, mStats) in day.perModel {
                            let tokens = mStats.tokens > 0 ? mStats.tokens : cStats.tokens
                            let cost = mStats.cost > 0 ? mStats.cost : cStats.cost
                            let messages = cStats.messages

                            sqlite3_bind_text(stmt, 1, (day.date as NSString).utf8String, -1, nil)
                            sqlite3_bind_text(stmt, 2, (client as NSString).utf8String, -1, nil)
                            sqlite3_bind_text(stmt, 3, (model as NSString).utf8String, -1, nil)
                            sqlite3_bind_double(stmt, 4, tokens)
                            sqlite3_bind_double(stmt, 5, cost)
                            sqlite3_bind_double(stmt, 6, messages)
                            sqlite3_bind_double(stmt, 7, activePerModel)
                            sqlite3_bind_double(stmt, 8, nowMs)

                            sqlite3_step(stmt)
                            sqlite3_reset(stmt)
                        }
                    }
                }
            }
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    // MARK: - Query & Aggregation

    /// Reads all session rows matching the client list and date filter.
    func querySessionRows(clients: [String]? = nil, dateExact: String? = nil, datePrefix: String? = nil, dateMin: String? = nil, includeUndated: Bool = false) -> [UsageCore.UsageRow] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        var whereClauses: [String] = []
        if let clients, !clients.isEmpty {
            let escaped = clients.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            whereClauses.append("client IN (\(escaped))")
        }

        var dateConditions: [String] = []
        if let dateExact {
            dateConditions.append("date = '\(dateExact.replacingOccurrences(of: "'", with: "''"))'")
        }
        if let datePrefix {
            dateConditions.append("date LIKE '\(datePrefix.replacingOccurrences(of: "'", with: "''"))%'")
        }
        if let dateMin {
            dateConditions.append("date >= '\(dateMin.replacingOccurrences(of: "'", with: "''"))'")
        }
        if includeUndated {
            dateConditions.append("date = ''")
        }

        if !dateConditions.isEmpty {
            whereClauses.append("(" + dateConditions.joined(separator: " OR ") + ")")
        }

        let whereSQL = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")
        let sql = """
        SELECT session_id, client, date, model_id, provider,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
               message_count, cost_usd, started_at_ms, last_used_at_ms, project_id, project_label,
               timed_tokens, timed_duration_ms
        FROM session_ledger
        \(whereSQL);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryLedger] query failed: %s", sqlite3_errmsg(db))
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [UsageCore.UsageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                let sessionId = String(cString: sqlite3_column_text(stmt, 0))
                let client = String(cString: sqlite3_column_text(stmt, 1))
                let modelId = String(cString: sqlite3_column_text(stmt, 3))
                let provider = String(cString: sqlite3_column_text(stmt, 4))
                let input = sqlite3_column_double(stmt, 5)
                let output = sqlite3_column_double(stmt, 6)
                let cacheRead = sqlite3_column_double(stmt, 7)
                let cacheWrite = sqlite3_column_double(stmt, 8)
                let reasoning = sqlite3_column_double(stmt, 9)
                let messageCount = sqlite3_column_double(stmt, 10)
                let cost = sqlite3_column_double(stmt, 11)
                let startedAt = sqlite3_column_double(stmt, 12)
                let lastUsedAt = sqlite3_column_double(stmt, 13)
                let projectId = String(cString: sqlite3_column_text(stmt, 14))
                let projectLabel = String(cString: sqlite3_column_text(stmt, 15))
                let timedTokens = sqlite3_column_double(stmt, 16)
                let timedDurationMs = sqlite3_column_double(stmt, 17)

                let performance: TokscalePerformance? = timedDurationMs > 0 ? TokscalePerformance(
                    msPer1KTokens: timedTokens > 0 ? (timedDurationMs / (timedTokens / 1000.0)) : nil,
                    totalDurationMs: timedDurationMs,
                    timedTokens: timedTokens,
                    sampleCount: nil,
                    tokenCoverage: nil
                ) : nil

                results.append(UsageCore.UsageRow(
                    client: client,
                    sessionId: sessionId,
                    model: modelId,
                    provider: provider,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: reasoning,
                    messageCount: messageCount,
                    cost: cost,
                    startedAt: startedAt,
                    lastUsedAt: lastUsedAt,
                    projectId: projectId,
                    projectLabel: projectLabel,
                    performance: performance
                ))
            }
        }
        return results
    }

    /// Queries the detailed per-model token breakdown for a specific session across its lifetime or period.
    func querySessionModelBreakdown(client: String, sessionId: String, period: String = "total") -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !sessionId.isEmpty else { return nil }

        let escapedClient = client.replacingOccurrences(of: "'", with: "''")
        let escapedSessionId = sessionId.replacingOccurrences(of: "'", with: "''")
        let baseSessionId: String
        if let atIdx = sessionId.firstIndex(of: "@") {
            baseSessionId = String(sessionId[..<atIdx]).replacingOccurrences(of: "'", with: "''")
        } else {
            baseSessionId = escapedSessionId
        }

        var whereClauses: [String] = []
        if !escapedClient.isEmpty {
            whereClauses.append("client = '\(escapedClient)'")
        }
        whereClauses.append("(session_id = '\(escapedSessionId)' OR session_id = '\(baseSessionId)' OR session_id LIKE '\(baseSessionId)@%')")

        let whereSQL = "WHERE " + whereClauses.joined(separator: " AND ")
        let sql = """
        SELECT model_id, provider,
               SUM(input_tokens) AS in_tk,
               SUM(output_tokens) AS out_tk,
               SUM(cache_read_tokens) AS cr_tk,
               SUM(cache_write_tokens) AS cw_tk,
               SUM(reasoning_tokens) AS re_tk,
               SUM(message_count) AS msg_cnt,
               SUM(cost_usd) AS cost,
               MIN(started_at_ms) AS min_start,
               MAX(last_used_at_ms) AS max_used,
               MIN(project_id) AS pid,
               MIN(project_label) AS plabel
        FROM session_ledger
        \(whereSQL)
        GROUP BY model_id
        ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens) + SUM(cache_write_tokens)) DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[HistoryLedger] querySessionModelBreakdown failed: %s", sqlite3_errmsg(db))
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var models: [[String: Any]] = []
        var totalInput = 0.0
        var totalOutput = 0.0
        var totalCacheRead = 0.0
        var totalCacheWrite = 0.0
        var totalReasoning = 0.0
        var totalMessages = 0.0
        var totalCost = 0.0
        var overallMinStart = 0.0
        var overallMaxUsed = 0.0
        var projectId = ""
        var projectLabel = ""

        while sqlite3_step(stmt) == SQLITE_ROW {
            let modelId = String(cString: sqlite3_column_text(stmt, 0))
            let provider = sqlite3_column_text(stmt, 1) != nil ? String(cString: sqlite3_column_text(stmt, 1)) : ""
            let input = sqlite3_column_double(stmt, 2)
            let output = sqlite3_column_double(stmt, 3)
            let cacheRead = sqlite3_column_double(stmt, 4)
            let cacheWrite = sqlite3_column_double(stmt, 5)
            let reasoning = sqlite3_column_double(stmt, 6)
            let messageCount = sqlite3_column_double(stmt, 7)
            let cost = sqlite3_column_double(stmt, 8)
            let minStart = sqlite3_column_double(stmt, 9)
            let maxUsed = sqlite3_column_double(stmt, 10)
            if projectId.isEmpty, let p = sqlite3_column_text(stmt, 11) { projectId = String(cString: p) }
            if projectLabel.isEmpty, let pl = sqlite3_column_text(stmt, 12) { projectLabel = String(cString: pl) }

            let modelTokens = input + output + cacheRead + cacheWrite

            totalInput += input
            totalOutput += output
            totalCacheRead += cacheRead
            totalCacheWrite += cacheWrite
            totalReasoning += reasoning
            totalMessages += messageCount
            totalCost += cost
            if minStart > 0 && (overallMinStart == 0 || minStart < overallMinStart) { overallMinStart = minStart }
            if maxUsed > overallMaxUsed { overallMaxUsed = maxUsed }

            models.append([
                "modelId": modelId,
                "provider": provider,
                "totalTokens": Int(modelTokens.rounded()),
                "inputTokens": Int(input.rounded()),
                "outputTokens": Int(output.rounded()),
                "cacheReadTokens": Int(cacheRead.rounded()),
                "cacheWriteTokens": Int(cacheWrite.rounded()),
                "reasoningTokens": Int(reasoning.rounded()),
                "messageCount": Int(messageCount.rounded()),
                "costUsd": cost
            ])
        }

        guard !models.isEmpty else { return nil }

        let totalSessionTokens = totalInput + totalOutput + totalCacheRead + totalCacheWrite
        let totalPrompt = totalInput + totalCacheRead + totalCacheWrite
        let cacheHitRate = (totalPrompt > 0) ? (totalCacheRead / totalPrompt * 100.0) : 0.0

        for i in 0..<models.count {
            let mTokens = Double(models[i]["totalTokens"] as? Int ?? 0)
            let pct = totalSessionTokens > 0 ? (mTokens / totalSessionTokens * 100.0) : 0.0
            models[i]["percent"] = (pct * 10).rounded() / 10.0
            let inTk = Double(models[i]["inputTokens"] as? Int ?? 0)
            let crTk = Double(models[i]["cacheReadTokens"] as? Int ?? 0)
            let cwTk = Double(models[i]["cacheWriteTokens"] as? Int ?? 0)
            let mTotalPrompt = inTk + crTk + cwTk
            let mCacheHitRate = (mTotalPrompt > 0) ? (crTk / mTotalPrompt * 100.0) : 0.0
            models[i]["cacheHitRate"] = (mCacheHitRate * 10).rounded() / 10.0
        }

        return [
            "found": true,
            "client": client,
            "sessionId": sessionId,
            "period": period,
            "totalTokens": Int(totalSessionTokens.rounded()),
            "costUsd": totalCost,
            "messageCount": Int(totalMessages.rounded()),
            "startedAt": overallMinStart > 0 ? UsageCore.isoFromMs(overallMinStart) : "",
            "lastUsedAt": overallMaxUsed > 0 ? UsageCore.isoFromMs(overallMaxUsed) : "",
            "projectId": projectId,
            "projectLabel": projectLabel,
            "models": models,
            "totals": [
                "inputTokens": Int(totalInput.rounded()),
                "outputTokens": Int(totalOutput.rounded()),
                "cacheReadTokens": Int(totalCacheRead.rounded()),
                "cacheWriteTokens": Int(totalCacheWrite.rounded()),
                "reasoningTokens": Int(totalReasoning.rounded()),
                "cacheHitRate": (cacheHitRate * 10).rounded() / 10.0
            ]
        ]
    }

    /// Fetches all aggregated periods (today, month, allTime) from the persistent ledger.
    func fetchPeriods(clients: [String], now: Date, allTimeSince: Double) -> (today: [String: Any], month: [String: Any], allTime: [String: Any]) {
        let dayKey = DateFormatUtil.dayKey(now)
        let monthKey = DateFormatUtil.monthKey(now)
        let allTimeSinceKey = DateFormatUtil.dayKey(Date(timeIntervalSince1970: allTimeSince / 1000))
        let cacheKey = "\(clients.sorted().joined(separator: ","))|\(dayKey)|\(monthKey)|\(allTimeSinceKey)"

        lock.lock()
        if !isDirty, cachedPeriodsKey == cacheKey, let cached = cachedPeriods {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let todayRows = querySessionRows(clients: clients, dateExact: dayKey, includeUndated: false)
        let monthRows = querySessionRows(clients: clients, datePrefix: monthKey, includeUndated: false)
        let allTimeRows = querySessionRows(clients: clients, dateMin: allTimeSinceKey, includeUndated: true)

        let todayPeriod = UsageCore.extractPeriod(entries: todayRows)
        let monthPeriod = UsageCore.extractPeriod(entries: monthRows)
        let allTimePeriod = UsageCore.extractPeriod(entries: allTimeRows)

        let result = (today: todayPeriod, month: monthPeriod, allTime: allTimePeriod)

        lock.lock()
        cachedPeriods = result
        cachedPeriodsKey = cacheKey
        isDirty = false
        lock.unlock()

        return result
    }

    /// Fetches usage for any arbitrary custom time range (e.g. startDate to endDate).
    func fetchCustomPeriod(clients: [String]? = nil, startDate: String, endDate: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return UsageCore.emptyPeriod() }

        var whereClauses: [String] = [
            "date >= '\(startDate.replacingOccurrences(of: "'", with: "''"))'",
            "date <= '\(endDate.replacingOccurrences(of: "'", with: "''"))'"
        ]
        if let clients, !clients.isEmpty {
            let escaped = clients.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            whereClauses.append("client IN (\(escaped))")
        }

        let whereSQL = "WHERE " + whereClauses.joined(separator: " AND ")
        let sql = """
        SELECT session_id, client, date, model_id, provider,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
               message_count, cost_usd, started_at_ms, last_used_at_ms, project_id, project_label,
               timed_tokens, timed_duration_ms
        FROM session_ledger
        \(whereSQL);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return UsageCore.emptyPeriod() }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageCore.UsageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                let sessionId = String(cString: sqlite3_column_text(stmt, 0))
                let client = String(cString: sqlite3_column_text(stmt, 1))
                let modelId = String(cString: sqlite3_column_text(stmt, 3))
                let provider = String(cString: sqlite3_column_text(stmt, 4))
                let input = sqlite3_column_double(stmt, 5)
                let output = sqlite3_column_double(stmt, 6)
                let cacheRead = sqlite3_column_double(stmt, 7)
                let cacheWrite = sqlite3_column_double(stmt, 8)
                let reasoning = sqlite3_column_double(stmt, 9)
                let messageCount = sqlite3_column_double(stmt, 10)
                let cost = sqlite3_column_double(stmt, 11)
                let startedAt = sqlite3_column_double(stmt, 12)
                let lastUsedAt = sqlite3_column_double(stmt, 13)
                let projectId = String(cString: sqlite3_column_text(stmt, 14))
                let projectLabel = String(cString: sqlite3_column_text(stmt, 15))
                let timedTokens = sqlite3_column_double(stmt, 16)
                let timedDurationMs = sqlite3_column_double(stmt, 17)

                let performance: TokscalePerformance? = timedDurationMs > 0 ? TokscalePerformance(
                    msPer1KTokens: timedTokens > 0 ? (timedDurationMs / (timedTokens / 1000.0)) : nil,
                    totalDurationMs: timedDurationMs,
                    timedTokens: timedTokens,
                    sampleCount: nil,
                    tokenCoverage: nil
                ) : nil

                rows.append(UsageCore.UsageRow(
                    client: client,
                    sessionId: sessionId,
                    model: modelId,
                    provider: provider,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: reasoning,
                    messageCount: messageCount,
                    cost: cost,
                    startedAt: startedAt,
                    lastUsedAt: lastUsedAt,
                    projectId: projectId,
                    projectLabel: projectLabel,
                    performance: performance
                ))
            }
        }
        return UsageCore.extractPeriod(entries: rows)
    }

    /// Fetches all historical days for trends and activity heatmaps.
    func fetchHistoryDays(clients: [String]? = nil) -> [HistoryCore.Day] {
        let cacheKey = clients?.sorted().joined(separator: ",") ?? "*"

        lock.lock()
        if !isDirty, cachedHistoryDaysKey == cacheKey, let cached = cachedHistoryDays {
            lock.unlock()
            return cached
        }
        guard let db else {
            lock.unlock()
            return []
        }

        var whereSQL = ""
        if let clients, !clients.isEmpty {
            let escaped = clients.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            whereSQL = "WHERE client IN (\(escaped))"
        }

        let sql = """
        SELECT date, client, model_id, tokens, cost_usd, messages, active_time_ms
        FROM daily_history_ledger
        \(whereSQL)
        ORDER BY date ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            lock.unlock()
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var dayMap: [String: HistoryCore.Day] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                let date = String(cString: sqlite3_column_text(stmt, 0))
                let client = String(cString: sqlite3_column_text(stmt, 1))
                let modelId = String(cString: sqlite3_column_text(stmt, 2))
                let tokens = sqlite3_column_double(stmt, 3)
                let cost = sqlite3_column_double(stmt, 4)
                let messages = sqlite3_column_double(stmt, 5)
                let activeTimeMs = sqlite3_column_double(stmt, 6)

                var day = dayMap[date] ?? HistoryCore.Day(date: date)
                day.tokens += tokens
                day.cost += cost
                day.messages += messages
                day.activeTimeMs = max(day.activeTimeMs, activeTimeMs)

                var pc = day.perClient[client] ?? (0, 0, 0)
                pc.tokens += tokens
                pc.cost += cost
                pc.messages += messages
                day.perClient[client] = pc

                var pm = day.perModel[modelId] ?? (0, 0)
                pm.tokens += tokens
                pm.cost += cost
                day.perModel[modelId] = pm

                dayMap[date] = day
            }
        }

        let result = dayMap.values.sorted { $0.date < $1.date }
        cachedHistoryDays = result
        cachedHistoryDaysKey = cacheKey
        lock.unlock()
        return result
    }

    /// Merges live scanned days with persisted ledger days (taking the max per client/model to ensure deleted sessions are preserved and live growth is captured).
    static func mergeDays(liveDays: [HistoryCore.Day], ledgerDays: [HistoryCore.Day]) -> [HistoryCore.Day] {
        var dayMap: [String: HistoryCore.Day] = [:]
        for d in ledgerDays {
            dayMap[d.date] = d
        }
        for live in liveDays {
            if var existing = dayMap[live.date] {
                existing.tokens = max(existing.tokens, live.tokens)
                existing.cost = max(existing.cost, live.cost)
                existing.messages = max(existing.messages, live.messages)
                existing.activeTimeMs = max(existing.activeTimeMs, live.activeTimeMs)

                for (client, cStats) in live.perClient {
                    let prev = existing.perClient[client] ?? (0, 0, 0)
                    existing.perClient[client] = (
                        max(prev.tokens, cStats.tokens),
                        max(prev.cost, cStats.cost),
                        max(prev.messages, cStats.messages)
                    )
                }

                for (model, mStats) in live.perModel {
                    let prev = existing.perModel[model] ?? (0, 0)
                    existing.perModel[model] = (
                        max(prev.tokens, mStats.tokens),
                        max(prev.cost, mStats.cost)
                    )
                }
                dayMap[live.date] = existing
            } else {
                dayMap[live.date] = live
            }
        }
        return dayMap.values.sorted { $0.date < $1.date }
    }
}
