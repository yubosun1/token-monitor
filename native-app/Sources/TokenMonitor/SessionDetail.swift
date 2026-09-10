import Foundation

/// Session detail for the renderer popup — port of src/shared/sessionDetail.js
/// (plus sessionFiles.js) from the Electron app. Wire shape is unchanged:
///
///     { found, client, sessionId, period, exchanges: [...], totals: {...} }
///
/// consumed by src/electron/renderer/sessionDetail.js (exchangeRows) via the
/// session:getDetail bridge method. Transcript readers cover the local
/// adapters (proma/hanako/dsh) as well as the tokscale clients that have
/// transcript files (claude/codex).
enum SessionDetailCore {
    typealias JSON = [String: Any]

    // MARK: - Models

    struct Tokens {
        var input = 0.0
        var output = 0.0
        var cacheRead = 0.0
        var cacheWrite = 0.0
        var reasoning = 0.0
        var total: Double { input + output + cacheRead + cacheWrite }

        func json() -> JSON {
            return [
                "input": input, "output": output,
                "cacheRead": cacheRead, "cacheWrite": cacheWrite,
                "reasoning": reasoning, "total": total
            ]
        }
    }

    struct Turn {
        var timestampMs: Double = 0
        var tokens = Tokens()
        var tokensAvailable = true
        var tools: [String] = []
        var costEstimate = 0.0

        func json() -> JSON {
            return [
                "timestamp": UsageCore.isoFromMs(timestampMs),
                "tokens": tokens.json(),
                "tokensAvailable": tokensAvailable,
                "tools": tools,
                "costEstimate": costEstimate
            ]
        }
    }

    struct Exchange {
        var promptPreview = ""
        var startedAtMs: Double = 0
        var endedAtMs: Double = 0
        var tokens = Tokens()
        var turns: [Turn] = []
        var costEstimate = 0.0

        var turnCount: Int { turns.count }
        var tools: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for turn in turns {
                for tool in turn.tools where seen.insert(tool).inserted { out.append(tool) }
            }
            return out
        }
        var tokensAvailable: Bool { turns.allSatisfy { $0.tokensAvailable } }

        func json() -> JSON {
            return [
                "promptPreview": promptPreview,
                "startedAt": UsageCore.isoFromMs(startedAtMs),
                "endedAt": UsageCore.isoFromMs(endedAtMs),
                "turnCount": turnCount,
                "tools": tools,
                "tokens": tokens.json(),
                "tokensAvailable": tokensAvailable,
                "costEstimate": costEstimate,
                "turns": turns.map { $0.json() }
            ]
        }
    }

    struct Event {
        enum Kind { case prompt, turn }
        var kind: Kind
        var timestampMs: Double
        var text = ""
        var tokens = Tokens()
        var tools: [String] = []
        var cost: Double?
    }

    // MARK: - Shared helpers (ports of sessionDetail.js)

    private static func num(_ value: Any?) -> Double {
        guard let value else { return 0 }
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return 0
    }

    /// Drop the verbose "[Image: source: /long/path.png]" references Claude
    /// emits as separate duplicate messages, keep short "[Image #N]" markers.
    private static func cleanPromptText(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "\\[Image:[^\\]]*\\]",
            with: "", options: .regularExpression
        )
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Slash-command blocks, interrupt notices and other harness-injected user
    /// lines are not real prompts — skip them so their turns attach to the
    /// actual prompt (same convention as the Electron version).
    private static func isSyntheticClaudePrompt(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if text.hasPrefix("[Request interrupted") { return true }
        if text.hasPrefix("Base directory for this skill:") { return true }
        let synthetic = text.range(
            of: "^</?(command-name|command-message|command-args|local-command-stdout|local-command-caveat|bash-input|bash-stdout|bash-stderr|system-reminder)\\b",
            options: .regularExpression
        )
        return synthetic != nil
    }

    private static func isToolResultBlock(_ part: Any?) -> Bool {
        guard let part = part as? JSON else { return false }
        return (part["type"] as? String) == "tool_result"
    }

    private static func blockType(_ part: Any?) -> String? {
        return (part as? JSON)?["type"] as? String
    }

    private static func blockText(_ part: Any?) -> String {
        return (part as? JSON)?["text"] as? String ?? ""
    }

    /// Prompt text from a Claude-style message.content (string or block array).
    /// Returns nil when the content is not a real prompt boundary.
    private static func claudePromptText(_ content: Any?) -> String? {
        if let string = content as? String {
            if isSyntheticClaudePrompt(string) { return nil }
            let cleaned = cleanPromptText(string)
            return cleaned.isEmpty ? nil : cleaned
        }
        guard let array = content as? [Any] else { return nil }
        if array.contains(where: isToolResultBlock) { return nil }
        let rawTexts = array.compactMap { part -> String? in
            guard blockType(part) == "text" else { return nil }
            let text = blockText(part)
            return isSyntheticClaudePrompt(text) ? nil : text
        }
        let joined = rawTexts.map(cleanPromptText).filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
        let hasImage = array.contains { part in
            (part as? JSON)?["type"] as? String == "image"
        }
        return hasImage ? "[image]" : nil
    }

    /// Codex's IDE extension prepends an editor-context block; the real prompt
    /// follows the "## My request for Codex:" marker.
    private static func codexPromptText(_ raw: String) -> String {
        let text = String(raw)
        let marker = "## My request for Codex:"
        if let range = text.range(of: marker) {
            return cleanPromptText(String(text[range.upperBound...]))
        }
        return cleanPromptText(text)
    }

    private static func uniqueTools(_ tools: [String]) -> [String] {
        var seen = Set<String>()
        return tools.filter { seen.insert($0).inserted }
    }

    // MARK: - Transcript parsers

    /// Claude transcript (also used for proma, which writes the same JSONL
    /// shape with timestamps in `_createdAt` milliseconds).
    private static func parseClaudeTranscript(_ text: String, timestampKey: String, timestampIsMs: Bool) -> [Event] {
        var events: [Event] = []
        var seenLineUuids = Set<String>()
        var turnByMessageId: [String: Int] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
            if let uuid = obj["uuid"] as? String {
                if seenLineUuids.contains(uuid) { continue }
                seenLineUuids.insert(uuid)
            }
            let message = obj["message"] as? JSON ?? JSON()
            let type = obj["type"] as? String ?? ""
            let timestamp: Double = timestampIsMs
                ? num(obj[timestampKey])
                : UsageCore.timestampMs(obj[timestampKey])

            if type == "assistant" {
                guard let usage = message["usage"] as? JSON else { continue }
                let tools = (message["content"] as? [Any])?.compactMap { part -> String? in
                    guard let part = part as? JSON, (part["type"] as? String) == "tool_use" else { return nil }
                    return part["name"] as? String
                } ?? []
                let id = message["id"] as? String
                if let id, let existing = turnByMessageId[id] {
                    // Content-block split: same reply repeated per block with
                    // the same message.id — merge tool names, count usage once.
                    events[existing].tools = uniqueTools(events[existing].tools + tools)
                    continue
                }
                var event = Event(kind: .turn, timestampMs: timestamp)
                event.tokens = Tokens(
                    input: num(usage["input_tokens"] ?? usage["inputTokens"]),
                    output: num(usage["output_tokens"] ?? usage["outputTokens"]),
                    cacheRead: num(usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"]),
                    cacheWrite: num(usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"]),
                    reasoning: 0
                )
                event.tools = uniqueTools(tools)
                if let id {
                    turnByMessageId[id] = events.count
                }
                events.append(event)
            } else if type == "user" {
                guard let promptText = claudePromptText(message["content"]) else { continue }
                events.append(Event(kind: .prompt, timestampMs: timestamp, text: promptText))
            }
        }
        return events
    }

    private static func codexToolName(_ payload: JSON) -> String {
        return (payload["name"] as? String)
            ?? (payload["tool_name"] as? String)
            ?? (payload["tool"] as? String)
            ?? ""
    }

    /// Codex session JSONL (rollout files under ~/.codex/sessions).
    private static func parseCodexTranscript(_ text: String) -> [Event] {
        var events: [Event] = []
        var pendingTools: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
            let payload = obj["payload"] as? JSON ?? JSON()
            let type = obj["type"] as? String ?? ""
            let pType = payload["type"] as? String ?? ""

            if type == "response_item",
               pType == "function_call" || pType == "custom_tool_call" || pType == "tool_search_call" {
                let name = codexToolName(payload)
                if !name.isEmpty { pendingTools.append(name) }
            } else if type == "event_msg", pType == "mcp_tool_call_end" {
                let name = codexToolName(payload)
                if !name.isEmpty { pendingTools.append(name) }
            } else if type == "event_msg", pType == "user_message" {
                let text = codexPromptText((payload["message"] as? String) ?? (payload["text"] as? String) ?? "")
                let imageCount = ((payload["images"] as? [Any])?.count ?? 0)
                    + ((payload["local_images"] as? [Any])?.count ?? 0)
                let marker = imageCount > 1 ? "[\\(imageCount) images]" : (imageCount == 1 ? "[image]" : "")
                let label = [marker, text].filter { !$0.isEmpty }.joined(separator: " ")
                if !label.isEmpty {
                    events.append(Event(kind: .prompt, timestampMs: UsageCore.timestampMs(obj["timestamp"]), text: label))
                }
            } else if type == "event_msg", pType == "token_count" {
                guard let usage = (payload["info"] as? JSON)?["last_token_usage"] as? JSON else { continue }
                // Codex follows OpenAI's convention: input_tokens INCLUDES
                // cached_input_tokens, output_tokens INCLUDES
                // reasoning_output_tokens. Make input disjoint from cache and
                // keep reasoning informational (in + out + cacheRead == total).
                let cacheRead = num(usage["cached_input_tokens"])
                let tokens = Tokens(
                    input: max(0, num(usage["input_tokens"]) - cacheRead),
                    output: num(usage["output_tokens"]),
                    cacheRead: cacheRead,
                    cacheWrite: 0,
                    reasoning: num(usage["reasoning_output_tokens"])
                )
                if tokens.total == 0 { pendingTools = []; continue }
                var event = Event(kind: .turn, timestampMs: UsageCore.timestampMs(obj["timestamp"]))
                event.tokens = tokens
                event.tools = uniqueTools(pendingTools)
                pendingTools = []
                events.append(event)
            }
        }
        return events
    }

    /// Hanako flat event log (~/.hanako/agents/hanako/{sessions,activity}):
    /// one `type: message` line per message with `message.role`.
    private static func parseHanakoTranscript(_ text: String) -> (events: [Event], hasRealCost: Bool) {
        var events: [Event] = []
        var hasRealCost = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
            guard (obj["type"] as? String) == "message" else { continue }
            let message = obj["message"] as? JSON ?? JSON()
            let role = message["role"] as? String ?? ""
            let timestamp = UsageCore.timestampMs(obj["timestamp"] ?? message["timestamp"])
            let content = message["content"] as? [Any] ?? []

            if role == "user" {
                let rawTexts = content.compactMap { part -> String? in
                    guard let part = part as? JSON else { return nil }
                    switch part["type"] as? String {
                    case "text": return part["text"] as? String
                    case "image": return "[image]"
                    default: return nil
                    }
                }
                let joined = rawTexts.map(cleanPromptText).filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    events.append(Event(kind: .prompt, timestampMs: timestamp, text: joined))
                }
            } else if role == "assistant" {
                guard let usage = message["usage"] as? JSON else { continue }
                var event = Event(kind: .turn, timestampMs: timestamp)
                event.tokens = Tokens(
                    input: num(usage["input"] ?? usage["input_tokens"]),
                    output: num(usage["output"] ?? usage["output_tokens"]),
                    cacheRead: num(usage["cacheRead"] ?? usage["cache_read_input_tokens"]),
                    cacheWrite: num(usage["cacheWrite"] ?? usage["cache_creation_input_tokens"]),
                    reasoning: 0
                )
                event.tools = uniqueTools(content.compactMap { part -> String? in
                    guard let part = part as? JSON, (part["type"] as? String) == "toolCall" else { return nil }
                    return part["name"] as? String
                })
                if let cost = (usage["cost"] as? JSON)?["total"] as? Double, cost > 0 {
                    event.cost = cost
                    hasRealCost = true
                }
                if event.tokens.total > 0 || event.cost != nil {
                    events.append(event)
                }
            }
        }
        return (events, hasRealCost)
    }

    /// DeepSeek Harness session log (~/.dsh/sessions/.../session[.v3].jsonl.zstd):
    /// envelope {type, seq, time, data}; user messages carry the message
    /// itself in `data`. v2 delivers assistant usage as assistant/chunk
    /// usage chunks (same source the collector aggregates); v3 delivers it
    /// on consolidated assistant/message records (`data.usage`).
    ///
    /// Prompts and turns interleave in log order: each turn's usage chunk
    /// follows the user message that prompted it, so a turn is emitted right
    /// where it occurs. (Collecting turns in a second pass and appending
    /// them after every prompt mis-attributed multi-turn sessions and made
    /// period filtering drop earlier prompts.)
    static func parseDshLog(_ text: String, format: Adapters.DshFormat = .v2) -> (events: [Event], hasRealCost: Bool) {
        var events: [Event] = []
        var seenSeq = Set<Int>()
        var pendingTools: [String: [String]] = [:]
        var headerCreatedAt = 0.0
        var lastTime = 0.0
        // A forked session's log is seeded with a byte-for-byte copy of its
        // parent's events up to `session.seedLength`; that shared prefix is
        // credited to the parent only, so it must be skipped here too, or a
        // fork shows more tokens (and the parent's prompts) than its own
        // count. seq is 0-indexed: the event AT seq == seedLength is the
        // fork's own first new event — skip strictly `seq < seedLength`.
        // Stays nil until a session record sets it: a torn header must not
        // zero out an otherwise-parseable transcript.
        var seedLength: Int?
        // v3 replaces seedLength with an `isSeeded` flag on the session
        // record plus a `session/end-seed` marker line (itself the last
        // seeded line) — which sits AFTER the seed prefix, so the boundary
        // must be pre-scanned before the interleaved main pass. A migrated
        // session (isSeeded = false) counts its converted history in full;
        // a torn log without the marker counts everything, same as v2.
        var skipBeforeSeq: Int?
        if format == .v3 {
            var isSeeded = false
            var endSeedSeq: Int?
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
                let type = obj["type"] as? String ?? ""
                if type == "session" {
                    isSeeded = obj["isSeeded"] as? Bool ?? false
                } else if type == "session/end-seed" {
                    endSeedSeq = obj["seq"] as? Int ?? 0
                }
            }
            skipBeforeSeq = (isSeeded && endSeedSeq != nil) ? endSeedSeq! + 1 : nil
        }

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
            let seq = obj["seq"] as? Int ?? 0
            let type = obj["type"] as? String ?? ""

            if type == "session" {
                if let createdAt = obj["createdAt"] { headerCreatedAt = UsageCore.timestampMs(createdAt) }
                seedLength = obj["seedLength"] as? Int
                continue
            }
            if type == "session/end-seed" { continue }
            let skip = format == .v3 ? skipBeforeSeq : seedLength
            if let seed = skip, seq < seed { continue }
            if seenSeq.contains(seq) { continue }
            seenSeq.insert(seq)
            let time = UsageCore.timestampMs(obj["time"])
            if time > lastTime { lastTime = time }
            let payload = obj["data"] as? JSON ?? JSON()

            switch type {
            case "user/message":
                // data IS the user message: {role, content, timestamp, source}
                // (v3 drops the role field; the envelope type already says it).
                let role = payload["role"] as? String ?? "user"
                guard role == "user" else { break }
                let content = payload["content"] as? [Any] ?? []
                let rawTexts = content.compactMap { part -> String? in
                    guard let part = part as? JSON else { return nil }
                    switch part["type"] as? String {
                    case "text":
                        let text = part["text"] as? String ?? ""
                        return isSyntheticClaudePrompt(text) ? nil : text
                    case "image": return "[image]"
                    default: return nil
                    }
                }
                let joined = rawTexts.map(cleanPromptText).filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    let ts = UsageCore.timestampMs(payload["timestamp"]) > 0
                        ? UsageCore.timestampMs(payload["timestamp"]) : time
                    events.append(Event(kind: .prompt, timestampMs: ts, text: joined))
                }
            case "tool/call":
                let turn = payload["turn"] as? Int ?? 0
                let step = payload["step"] as? Int ?? 0
                if let name = payload["name"] as? String, !name.isEmpty {
                    pendingTools["\(turn):\(step)", default: []].append(name)
                }
            case "assistant/chunk" where format == .v2:
                let chunk = payload["chunk"] as? JSON ?? JSON()
                let chunkType = chunk["type"] as? String ?? ""
                let turn = payload["turn"] as? Int ?? 0
                let step = payload["step"] as? Int ?? 0
                if chunkType == "usage", let usage = chunk["usage"] as? JSON {
                    // Use the usage chunk's own timestamp so a session
                    // spanning local midnight shows its turns on the day
                    // they happened (the popup's period filter keys off turn
                    // timestamps).
                    let eventTime = time
                    let createdAt = eventTime > 0 ? eventTime : (headerCreatedAt > 0 ? headerCreatedAt : lastTime)
                    var e = Event(kind: .turn, timestampMs: createdAt)
                    e.tokens = Tokens(
                        input: num(usage["inputTokens"]),
                        output: num(usage["outputTokens"]),
                        cacheRead: num(usage["cacheReadTokens"]),
                        cacheWrite: num(usage["cacheWriteTokens"]),
                        reasoning: num(usage["reasoningTokens"])
                    )
                    e.tools = uniqueTools(pendingTools["\(turn):\(step)"] ?? [])
                    events.append(e)
                }
            case "assistant/message" where format == .v3:
                guard let usage = payload["usage"] as? JSON else { break }
                let turn = payload["turn"] as? Int ?? 0
                let step = payload["step"] as? Int ?? 0
                // Same per-event timestamp rule as v2 (v3 has no
                // cacheWriteTokens — the provider never reported one).
                let eventTime = time
                let createdAt = eventTime > 0 ? eventTime : (headerCreatedAt > 0 ? headerCreatedAt : lastTime)
                var e = Event(kind: .turn, timestampMs: createdAt)
                e.tokens = Tokens(
                    input: num(usage["inputTokens"]),
                    output: num(usage["outputTokens"]),
                    cacheRead: num(usage["cacheReadTokens"]),
                    cacheWrite: num(usage["cacheWriteTokens"]),
                    reasoning: num(usage["reasoningTokens"])
                )
                e.tools = uniqueTools(pendingTools["\(turn):\(step)"] ?? [])
                events.append(e)
            default:
                break
            }
        }
        return (events, false)
    }

    // MARK: - Exchange grouping (ports)

    private static func newExchange(promptPreview: String, startedAtMs: Double) -> Exchange {
        var ex = Exchange()
        ex.promptPreview = promptPreview
        ex.startedAtMs = startedAtMs
        ex.endedAtMs = startedAtMs
        return ex
    }

    private static func groupEvents(_ events: [Event]) -> [Exchange] {
        // Exchanges are structs (value semantics): once appended, mutate the
        // element inside the array, never a local copy.
        var exchanges: [Exchange] = []
        for event in events {
            switch event.kind {
            case .prompt:
                exchanges.append(newExchange(promptPreview: event.text, startedAtMs: event.timestampMs))
            case .turn:
                if exchanges.isEmpty {
                    exchanges.append(newExchange(promptPreview: "", startedAtMs: event.timestampMs))
                }
                var turn = Turn()
                turn.timestampMs = event.timestampMs
                turn.tokens = event.tokens
                turn.tools = event.tools
                turn.costEstimate = num(event.cost)
                exchanges[exchanges.count - 1].turns.append(turn)
                exchanges[exchanges.count - 1].tokens.input += event.tokens.input
                exchanges[exchanges.count - 1].tokens.output += event.tokens.output
                exchanges[exchanges.count - 1].tokens.cacheRead += event.tokens.cacheRead
                exchanges[exchanges.count - 1].tokens.cacheWrite += event.tokens.cacheWrite
                exchanges[exchanges.count - 1].tokens.reasoning += event.tokens.reasoning
                if event.timestampMs > 0 {
                    if exchanges[exchanges.count - 1].startedAtMs == 0 || event.timestampMs < exchanges[exchanges.count - 1].startedAtMs {
                        exchanges[exchanges.count - 1].startedAtMs = event.timestampMs
                    }
                    if event.timestampMs > exchanges[exchanges.count - 1].endedAtMs {
                        exchanges[exchanges.count - 1].endedAtMs = event.timestampMs
                    }
                }
            }
        }
        return exchanges
    }

    private static func withinPeriod(_ timestampMs: Double, _ period: String, _ now: Date) -> Bool {
        if period == "total" { return true }
        if timestampMs <= 0 { return false }
        let date = Date(timeIntervalSince1970: timestampMs / 1000)
        let calendar = Calendar.current
        if period == "today" {
            return calendar.isDate(date, inSameDayAs: now)
        }
        if period == "month" {
            let comps = calendar.dateComponents([.year, .month], from: date)
            let nowComps = calendar.dateComponents([.year, .month], from: now)
            return comps.year == nowComps.year && comps.month == nowComps.month
        }
        return true // allTime / anything else keeps every turn
    }

    private static func filterExchangesByPeriod(_ exchanges: [Exchange], _ period: String, _ now: Date) -> [Exchange] {
        var result: [Exchange] = []
        for ex in exchanges {
            let turns = ex.turns.filter { withinPeriod($0.timestampMs, period, now) }
            if turns.isEmpty { continue }
            var next = newExchange(promptPreview: ex.promptPreview, startedAtMs: ex.startedAtMs)
            next.turns = turns
            for turn in turns {
                next.tokens.input += turn.tokens.input
                next.tokens.output += turn.tokens.output
                next.tokens.cacheRead += turn.tokens.cacheRead
                next.tokens.cacheWrite += turn.tokens.cacheWrite
                next.tokens.reasoning += turn.tokens.reasoning
            }
            next.startedAtMs = turns.reduce(0) { (minMs, t) in
                if t.timestampMs <= 0 { return minMs }
                return minMs == 0 || t.timestampMs < minMs ? t.timestampMs : minMs
            }
            next.endedAtMs = turns.reduce(0) { max($0, $1.timestampMs) }
            result.append(next)
        }
        return result
    }

    /// Proportional cost split for transcript clients (claude/codex/proma/
    /// hanako-without-real-costs/dsh) — port of distributeCost.
    private static func distributeCost(_ exchanges: inout [Exchange], _ sessionCost: Double) {
        let cost = num(sessionCost)
        let grandTotal = exchanges.reduce(0.0) { $0 + $1.tokens.total }
        for i in 0..<exchanges.count {
            let exCost = grandTotal > 0 ? cost * (exchanges[i].tokens.total / grandTotal) : 0
            exchanges[i].costEstimate = exCost
            for j in 0..<exchanges[i].turns.count {
                exchanges[i].turns[j].costEstimate = grandTotal > 0
                    ? cost * (exchanges[i].turns[j].tokens.total / grandTotal) : 0
            }
        }
    }

    /// Sum per exchange rather than splitting proportionally for clients with real costs.
    private static func sumRealCost(_ exchanges: inout [Exchange]) {
        for i in 0..<exchanges.count {
            var cost = 0.0
            for turn in exchanges[i].turns { cost += num(turn.costEstimate) }
            exchanges[i].costEstimate = cost
        }
    }

    private static func totalsOf(_ exchanges: [Exchange], _ costUsd: Double) -> JSON {
        let totalTokens = exchanges.reduce(0.0) { $0 + $1.tokens.total }
        let turnCount = exchanges.reduce(0) { $0 + $1.turns.count }
        return [
            "totalTokens": totalTokens,
            "costUsd": costUsd,
            "exchangeCount": exchanges.count,
            "turnCount": turnCount
        ]
    }

    private static func notFound(client: String, sessionId: String, period: String, sessionCost: Double) -> JSON {
        return [
            "found": false,
            "client": client,
            "sessionId": sessionId,
            "period": period,
            "exchanges": [Any](),
            "totals": totalsOf([], sessionCost)
        ]
    }

    static func finish(events: [Event], hasRealCost: Bool, client: String, sessionId: String,
                       period: String, sessionCost: Double, now: Date) -> JSON {
        var grouped = filterExchangesByPeriod(groupEvents(events), period, now)
        let filteredCost: Double
        if hasRealCost {
            sumRealCost(&grouped)
            filteredCost = grouped.reduce(0.0) { $0 + num($1.costEstimate) }
        } else {
            distributeCost(&grouped, sessionCost)
            filteredCost = sessionCost
        }
        return [
            "found": true,
            "client": client,
            "sessionId": sessionId,
            "period": period,
            "exchanges": grouped.map { $0.json() },
            "totals": totalsOf(grouped, filteredCost)
        ]
    }

    // MARK: - File resolution (ports of sessionFiles.js)

    private static func findSessionFile(root: String, sessionId: String) -> String? {
        let wanted = "\(sessionId).jsonl"
        let url = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return nil }
        for case let file as URL in enumerator {
            if file.lastPathComponent == wanted {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue {
                    return file.path
                }
            }
        }
        return nil
    }

    private static func codexSessionFile(_ home: String, _ sessionId: String) -> String? {
        let id = String(sessionId)
        guard let match = id.range(
            of: "^rollout-(\\d{4})-(\\d{2})-(\\d{2})T",
            options: .regularExpression
        ) else { return nil }
        let year = String(id[id.index(match.lowerBound, offsetBy: 8)..<id.index(match.lowerBound, offsetBy: 12)])
        let month = String(id[id.index(match.lowerBound, offsetBy: 13)..<id.index(match.lowerBound, offsetBy: 15)])
        let day = String(id[id.index(match.lowerBound, offsetBy: 16)..<id.index(match.lowerBound, offsetBy: 18)])
        let path = "\(home)/.codex/sessions/\(year)/\(month)/\(day)/\(id).jsonl"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            return path
        }
        return nil
    }

    /// sessionId without the "<hash>" suffix the adapters append
    /// ("<filename>@<sha256-of-root-prefix-12>").
    private static func adapterFileName(_ sessionId: String) -> String {
        let id = String(sessionId)
        if let at = id.lastIndex(of: "@") {
            let name = String(id[..<at])
            if !name.isEmpty { return name }
        }
        return id
    }

    private static func resolveSessionFile(client: String, sessionId: String, home: String) -> String? {
        let id = String(sessionId)
        guard !id.isEmpty else { return nil }
        switch client {
        case "claude":
            if let path = findSessionFile(root: "\(home)/.claude/projects", sessionId: id) { return path }
            return findSessionFile(root: "\(home)/.claude/transcripts", sessionId: id)
        case "codex":
            if let path = codexSessionFile(home, id) { return path }
            return findSessionFile(root: "\(home)/.codex/sessions", sessionId: id)
        case "proma":
            let name = adapterFileName(id)
            let path = "\(home)/.proma/agent-sessions/\(name).jsonl"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { return path }
            return nil
        case "hanako":
            let name = adapterFileName(id)
            for root in Adapters.hanakoRoots {
                if let path = findSessionFile(root: root, sessionId: name) { return path }
            }
            return nil
        default:
            return nil
        }
    }

    private static func resolveDshSessionFile(home: String, sessionId: String) -> URL? {
        let id = String(sessionId)
        guard !id.isEmpty else { return nil }
        let root = URL(fileURLWithPath: "\(home)/.dsh/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var v2File: URL?
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            guard name == "session.jsonl.zstd" || name == "session.v3.jsonl.zstd",
                  file.deletingLastPathComponent().lastPathComponent == id else { continue }
            // A migrated session keeps its frozen v2 log next to the live
            // v3 one; the v3 file holds the same history plus new events.
            if name == "session.v3.jsonl.zstd" { return file }
            v2File = file
        }
        return v2File
    }

    static func readAntigravitySessionBreakdown(sessionId: String, period: String, now: Date = Date()) -> JSON? {
        let home = NSHomeDirectory()
        let cleanId: String
        if let atIdx = sessionId.firstIndex(of: "@") {
            cleanId = String(sessionId[..<atIdx])
        } else {
            cleanId = sessionId
        }
        guard !cleanId.isEmpty else { return nil }

        var roots = [
            home + "/.config/tokscale/antigravity-cache/sessions",
            home + "/Library/Application Support/tokscale/antigravity-cache/sessions"
        ]
        if let env = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"], !env.isEmpty {
            roots.append(env + "/antigravity-cache/sessions")
        }

        var targetFile: URL?
        let fm = FileManager.default
        for root in roots {
            guard let files = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // Cache files are named "<sessionId>.jsonl" or
                // "<sessionId>-<hash>.jsonl"; a substring match let a
                // shorter session id capture a lookalike file (e.g. "abc"
                // matched "abc2.jsonl"), so match the whole stem exactly.
                let stem = file.deletingPathExtension().lastPathComponent
                if stem == cleanId || stem.hasPrefix(cleanId + "-") {
                    targetFile = file
                    break
                }
            }
            if targetFile != nil { break }
        }

        guard let file = targetFile, let data = try? Data(contentsOf: file) else { return nil }

        struct ModelAcc {
            var input = 0.0
            var output = 0.0
            var cacheRead = 0.0
            var cacheWrite = 0.0
            var reasoning = 0.0
            var messages = 0
            var cost = 0.0
        }

        var modelMap: [String: ModelAcc] = [:]
        var minStart = 0.0
        var maxUsed = 0.0

        for obj in Adapters.parseJsonlLines(data) {
            guard (obj["type"] as? String) == "usage" else { continue }
            let rawModel = (obj["modelId"] as? String) ?? (obj["model_id"] as? String) ?? (obj["model"] as? String) ?? "gemini-3.7-flash"
            let modelId = UsageCore.normalizeModelName(rawModel) ?? "gemini-3.7-flash"
            let inTk = UsageCore.doubleValue(obj["input"] ?? obj["inputTokens"] ?? obj["input_tokens"])
            let outTk = UsageCore.doubleValue(obj["output"] ?? obj["outputTokens"] ?? obj["output_tokens"])
            let crTk = UsageCore.doubleValue(obj["cacheRead"] ?? obj["cacheReadTokens"] ?? obj["cache_read"] ?? obj["cache_read_tokens"])
            let cwTk = UsageCore.doubleValue(obj["cacheWrite"] ?? obj["cacheWriteTokens"] ?? obj["cache_write"] ?? obj["cache_write_tokens"])
            let reTk = UsageCore.doubleValue(obj["reasoning"] ?? obj["reasoningTokens"] ?? obj["reasoning_tokens"])
            let ts = obj["timestamp"] != nil && !(obj["timestamp"] is NSNull) ? UsageCore.timestampMs(obj["timestamp"]) : 0

            // Same period gate as the transcript paths: undated records
            // (ts == 0) fall out of today/month but stay for allTime/total.
            guard withinPeriod(ts, period, now) else { continue }

            if ts > 0 {
                if minStart == 0 || ts < minStart { minStart = ts }
                if ts > maxUsed { maxUsed = ts }
            }

            var acc = modelMap[modelId] ?? ModelAcc()
            acc.input += inTk
            acc.output += outTk
            acc.cacheRead += crTk
            acc.cacheWrite += cwTk
            acc.reasoning += reTk
            acc.messages += 1
            modelMap[modelId] = acc
        }

        guard !modelMap.isEmpty else { return nil }

        var totalInput = 0.0
        var totalOutput = 0.0
        var totalCacheRead = 0.0
        var totalCacheWrite = 0.0
        var totalReasoning = 0.0
        var totalMessages = 0
        var totalCost = 0.0

        var models: [JSON] = []
        for (mId, acc) in modelMap {
            let mTotal = acc.input + acc.output + acc.cacheRead + acc.cacheWrite
            totalInput += acc.input
            totalOutput += acc.output
            totalCacheRead += acc.cacheRead
            totalCacheWrite += acc.cacheWrite
            totalReasoning += acc.reasoning
            totalMessages += acc.messages
            totalCost += acc.cost

            models.append([
                "modelId": mId,
                "provider": "google",
                "totalTokens": Int(mTotal.rounded()),
                "inputTokens": Int(acc.input.rounded()),
                "outputTokens": Int(acc.output.rounded()),
                "cacheReadTokens": Int(acc.cacheRead.rounded()),
                "cacheWriteTokens": Int(acc.cacheWrite.rounded()),
                "reasoningTokens": Int(acc.reasoning.rounded()),
                "messageCount": acc.messages,
                "costUsd": acc.cost
            ])
        }

        models.sort { ($0["totalTokens"] as? Int ?? 0) > ($1["totalTokens"] as? Int ?? 0) }

        let totalSessionTokens = totalInput + totalOutput + totalCacheRead + totalCacheWrite
        let totalPrompt = totalInput + totalCacheRead + totalCacheWrite
        let cacheHitRate = totalPrompt > 0 ? (totalCacheRead / totalPrompt * 100.0) : 0.0

        for i in 0..<models.count {
            let mTokens = Double(models[i]["totalTokens"] as? Int ?? 0)
            let pct = totalSessionTokens > 0 ? (mTokens / totalSessionTokens * 100.0) : 0.0
            models[i]["percent"] = (pct * 10).rounded() / 10.0
            let inTk = Double(models[i]["inputTokens"] as? Int ?? 0)
            let crTk = Double(models[i]["cacheReadTokens"] as? Int ?? 0)
            let cwTk = Double(models[i]["cacheWriteTokens"] as? Int ?? 0)
            let mTotalPrompt = inTk + crTk + cwTk
            let mCacheHitRate = mTotalPrompt > 0 ? (crTk / mTotalPrompt * 100.0) : 0.0
            models[i]["cacheHitRate"] = (mCacheHitRate * 10).rounded() / 10.0
        }

        return [
            "found": true,
            "client": "antigravity",
            "sessionId": sessionId,
            "period": period,
            "totalTokens": Int(totalSessionTokens.rounded()),
            "costUsd": totalCost,
            "messageCount": totalMessages,
            "startedAt": minStart > 0 ? UsageCore.isoFromMs(minStart) : "",
            "lastUsedAt": maxUsed > 0 ? UsageCore.isoFromMs(maxUsed) : "",
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

    // MARK: - Kimi Live Session Breakdown

    static func readKimiSessionBreakdown(sessionId: String, period: String = "total", now: Date = Date()) -> JSON? {
        let cleanId = sessionId.replacingOccurrences(of: "@.*$", with: "", options: .regularExpression)
        for root in Adapters.kimiRoots {
            let sessionDirs = Adapters.findKimiSessionDirs(at: root)
            for sDir in sessionDirs {
                let name = sDir.lastPathComponent
                // Exact name (or the "session_<id>" layout) only: a
                // substring match let a shorter session id claim a
                // lookalike dir ("abc" matched "abc2").
                if name == sessionId || name == cleanId || name == "session_" + cleanId {
                    let rows = Adapters.parseKimiSessionDir(sDir)
                    guard !rows.isEmpty else { continue }
                    return buildModelBreakdownFromRows(client: "kimi", sessionId: sessionId, period: period, rows: rows, now: now)
                }
            }
        }
        return nil
    }

    private static func buildModelBreakdownFromRows(client: String, sessionId: String, period: String, rows: [UsageCore.UsageRow], now: Date = Date()) -> JSON? {
        var totalTokens: Double = 0
        var totalInput: Double = 0
        var totalOutput: Double = 0
        var totalCacheRead: Double = 0
        var totalCacheWrite: Double = 0
        var totalReasoning: Double = 0
        var totalCost: Double = 0
        var totalMessages: Int = 0
        var minStart: Double = 0
        var maxUsed: Double = 0

        struct ModelAccumulator {
            var totalTokens: Double = 0
            var inputTokens: Double = 0
            var outputTokens: Double = 0
            var cacheReadTokens: Double = 0
            var cacheWriteTokens: Double = 0
            var reasoningTokens: Double = 0
            var costUsd: Double = 0
            var messageCount: Int = 0
        }

        var modelMap: [String: ModelAccumulator] = [:]
        for r in rows {
            // Same period gate as the transcript paths: undated rows
            // (startedAt == 0) fall out of today/month but stay for
            // allTime/total.
            guard withinPeriod(r.startedAt, period, now) else { continue }
            let modelId = UsageCore.normalizeModelName(r.model ?? "") ?? "unknown"
            let inTk = r.input
            let outTk = r.output
            let crTk = r.cacheRead
            let cwTk = r.cacheWrite
            let rzTk = r.reasoning
            let cost = r.cost
            let msgs = Int(r.messageCount)
            let mTokens = inTk + outTk + crTk + cwTk

            totalTokens += mTokens
            totalInput += inTk
            totalOutput += outTk
            totalCacheRead += crTk
            totalCacheWrite += cwTk
            totalReasoning += rzTk
            totalCost += cost
            totalMessages += msgs

            if r.startedAt > 0 && (minStart == 0 || r.startedAt < minStart) { minStart = r.startedAt }
            if r.lastUsedAt > 0 && r.lastUsedAt > maxUsed { maxUsed = r.lastUsedAt }

            var acc = modelMap[modelId] ?? ModelAccumulator()
            acc.totalTokens += mTokens
            acc.inputTokens += inTk
            acc.outputTokens += outTk
            acc.cacheReadTokens += crTk
            acc.cacheWriteTokens += cwTk
            acc.reasoningTokens += rzTk
            acc.costUsd += cost
            acc.messageCount += msgs
            modelMap[modelId] = acc
        }

        guard !modelMap.isEmpty else { return nil }

        var models: [[String: Any]] = []
        for (mId, acc) in modelMap {
            let mTotalInput = acc.inputTokens + acc.cacheReadTokens + acc.cacheWriteTokens
            let mCacheHitRate = mTotalInput > 0 ? (acc.cacheReadTokens / mTotalInput * 100.0) : 0.0
            models.append([
                "modelId": mId,
                "totalTokens": Int(acc.totalTokens.rounded()),
                "percent": 0.0,
                "inputTokens": Int(acc.inputTokens.rounded()),
                "outputTokens": Int(acc.outputTokens.rounded()),
                "cacheReadTokens": Int(acc.cacheReadTokens.rounded()),
                "cacheWriteTokens": Int(acc.cacheWriteTokens.rounded()),
                "reasoningTokens": Int(acc.reasoningTokens.rounded()),
                "costUsd": acc.costUsd,
                "cacheHitRate": (mCacheHitRate * 10).rounded() / 10.0,
                "messageCount": acc.messageCount
            ])
        }

        models.sort { ($0["totalTokens"] as? Int ?? 0) > ($1["totalTokens"] as? Int ?? 0) }
        for i in 0..<models.count {
            let mTokens = Double(models[i]["totalTokens"] as? Int ?? 0)
            let pct = totalTokens > 0 ? (mTokens / totalTokens * 100.0) : 0.0
            models[i]["percent"] = (pct * 10).rounded() / 10.0
        }

        let totalPrompt = totalInput + totalCacheRead + totalCacheWrite
        let cacheHitRate = totalPrompt > 0 ? (totalCacheRead / totalPrompt * 100.0) : 0.0

        return [
            "found": true,
            "client": client,
            "sessionId": sessionId,
            "period": period,
            "totalTokens": Int(totalTokens.rounded()),
            "costUsd": totalCost,
            "messageCount": totalMessages,
            "startedAt": minStart > 0 ? UsageCore.isoFromMs(minStart) : "",
            "lastUsedAt": maxUsed > 0 ? UsageCore.isoFromMs(maxUsed) : "",
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

    // MARK: - Entry point

    static func read(client: String, sessionId: String, period: String, sessionCost: Double,
                     startDate: String = "", endDate: String = "") -> JSON {
        let normalizedClient = client.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedPeriod = period.isEmpty ? "total" : period

        // 1. Check persistent SQLite ledger first (covers all clients with historical & recorded sessions)
        if let breakdown = HistoryLedger.shared.querySessionModelBreakdown(
            client: normalizedClient,
            sessionId: sessionId,
            period: normalizedPeriod,
            startDate: startDate,
            endDate: endDate
        ) {
            return breakdown
        }

        // 2. Client-specific live / file fallbacks
        if normalizedClient == "antigravity" {
            if let breakdown = readAntigravitySessionBreakdown(sessionId: sessionId, period: normalizedPeriod) {
                return breakdown
            }
        }
        if normalizedClient == "kimi" {
            if let breakdown = readKimiSessionBreakdown(sessionId: sessionId, period: normalizedPeriod) {
                return breakdown
            }
        }

        let home = NSHomeDirectory()
        let now = Date()

        switch normalizedClient {
        case "claude", "codex", "proma", "hanako":
            guard let path = resolveSessionFile(client: normalizedClient, sessionId: sessionId, home: home) else {
                return notFound(client: normalizedClient, sessionId: sessionId, period: normalizedPeriod, sessionCost: sessionCost)
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return notFound(client: normalizedClient, sessionId: sessionId, period: normalizedPeriod, sessionCost: sessionCost)
            }
            let result: (events: [Event], hasRealCost: Bool)
            switch normalizedClient {
            case "claude":
                result = (parseClaudeTranscript(text, timestampKey: "timestamp", timestampIsMs: false), false)
            case "proma":
                result = (parseClaudeTranscript(text, timestampKey: "_createdAt", timestampIsMs: true), false)
            case "hanako":
                result = parseHanakoTranscript(text)
            default:
                result = (parseCodexTranscript(text), false)
            }
            return finish(events: result.events, hasRealCost: result.hasRealCost,
                          client: normalizedClient, sessionId: sessionId,
                          period: normalizedPeriod, sessionCost: sessionCost, now: now)

        case "dsh":
            guard let file = resolveDshSessionFile(home: home, sessionId: sessionId),
                  let data = Adapters.decompressZstd(file),
                  let text = String(data: data, encoding: .utf8) else {
                return notFound(client: normalizedClient, sessionId: sessionId, period: normalizedPeriod, sessionCost: sessionCost)
            }
            let result = parseDshLog(text, format: Adapters.dshFormat(of: file))
            return finish(events: result.events, hasRealCost: result.hasRealCost,
                          client: normalizedClient, sessionId: sessionId,
                          period: normalizedPeriod, sessionCost: sessionCost, now: now)

        default:
            return notFound(client: normalizedClient, sessionId: sessionId, period: normalizedPeriod, sessionCost: sessionCost)
        }
    }
}
