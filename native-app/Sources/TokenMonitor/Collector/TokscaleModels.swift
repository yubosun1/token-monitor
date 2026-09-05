import Foundation

// MARK: - Lossy array decoding

/// Decodes an array element-wise so one malformed row cannot nullify an
/// entire scan. `JSONDecoder` decodes a whole array atomically — a single
/// bad element fails the whole decode — which `(try? ...) ?? []` at the
/// array level turned into "success with zero data"; the collector then
/// replaced last-known-good periods/graph days with zeros.
///
/// The raw array is captured as this value tree and each element is
/// re-decoded independently. Bad rows are skipped with one diag line each;
/// when a non-empty raw array yields no valid rows the decode throws, so
/// the caller treats the response as failed and keeps the last-known-good
/// snapshot (with backoff retry) instead of recording zeros.
private enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value"))
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let o): return o.mapValues(\.anyValue)
        case .array(let a): return a.map(\.anyValue)
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

private enum LossyArray {
    static func decode<T: Decodable>(_ type: T.Type, from raw: [JSONValue], context: String) throws -> [T] {
        var out: [T] = []
        for (i, value) in raw.enumerated() {
            // Re-serializing each element through JSONSerialization keeps the
            // per-field leniency of the element's own init(from:) while
            // isolating a bad row's failure to that row.
            guard let data = try? JSONSerialization.data(withJSONObject: value.anyValue) else {
                NSLog("[tokscale] %@ row %d skipped: not JSON-serializable", context, i)
                continue
            }
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                out.append(decoded)
            } else {
                NSLog("[tokscale] %@ row %d skipped: decode failed", context, i)
            }
        }
        if !raw.isEmpty && out.isEmpty {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "\(context): all \(raw.count) rows failed to decode"
            ))
        }
        return out
    }
}

// MARK: - tokscale CLI response models

/// One row of `tokscale --json --group-by client,session,model`.
struct TokscaleEntry: Decodable {
    let client: String?
    let mergedClients: [String]?
    let sessionId: String?
    let model: String?
    let provider: String?
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
    let reasoning: Double?
    let messageCount: Double?
    let cost: Double
    let startedAt: String?
    let lastUsedAt: String?
    let performance: TokscalePerformance?
    let projectId: String?
    let projectLabel: String?

    enum CodingKeys: String, CodingKey {
        case client, mergedClients, sessionId, model, provider
        case input, output, cacheRead, cacheWrite, reasoning, messageCount, cost
        case startedAt, lastUsedAt, performance, projectId, projectLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        mergedClients = try c.decodeIfPresent([String].self, forKey: .mergedClients)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        input = Self.number(try? c.decode(Double.self, forKey: .input))
        output = Self.number(try? c.decode(Double.self, forKey: .output))
        cacheRead = Self.number(try? c.decode(Double.self, forKey: .cacheRead))
        cacheWrite = Self.number(try? c.decode(Double.self, forKey: .cacheWrite))
        reasoning = (try? c.decode(Double.self, forKey: .reasoning)).map(Self.number)
        messageCount = (try? c.decode(Double.self, forKey: .messageCount)).map(Self.number)
        cost = Self.number(try? c.decode(Double.self, forKey: .cost))
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt)
        performance = try c.decodeIfPresent(TokscalePerformance.self, forKey: .performance)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        projectLabel = try c.decodeIfPresent(String.self, forKey: .projectLabel)
    }

    private static func number(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return value
    }
}

struct TokscalePerformance: Decodable {
    let msPer1KTokens: Double?
    let totalDurationMs: Double?
    let timedTokens: Double?
    let sampleCount: Double?
    let tokenCoverage: Double?
}

struct TokscaleResponse: Decodable {
    let groupBy: String?
    let entries: [TokscaleEntry]
    let totalInput: Double
    let totalOutput: Double
    let totalCacheRead: Double
    let totalCacheWrite: Double
    let totalMessages: Double
    let totalCost: Double

    enum CodingKeys: String, CodingKey {
        case groupBy, entries, totalInput, totalOutput, totalCacheRead
        case totalCacheWrite, totalMessages, totalCost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupBy = try c.decodeIfPresent(String.self, forKey: .groupBy)
        // Element-wise decode: one corrupt entry must not silently empty the
        // scan (the old (try? ...) ?? [] turned any bad row into "success
        // with zero data"). An array that is non-empty but all-bad throws,
        // so usage() surfaces the failure and the collector keeps the
        // last-known-good period with a retry backoff.
        let rawEntries = (try? c.decode([JSONValue].self, forKey: .entries)) ?? []
        entries = try LossyArray.decode(TokscaleEntry.self, from: rawEntries, context: "usage")
        totalInput = (try? c.decode(Double.self, forKey: .totalInput)) ?? 0
        totalOutput = (try? c.decode(Double.self, forKey: .totalOutput)) ?? 0
        totalCacheRead = (try? c.decode(Double.self, forKey: .totalCacheRead)) ?? 0
        totalCacheWrite = (try? c.decode(Double.self, forKey: .totalCacheWrite)) ?? 0
        totalMessages = (try? c.decode(Double.self, forKey: .totalMessages)) ?? 0
        totalCost = (try? c.decode(Double.self, forKey: .totalCost)) ?? 0
    }
}

/// `tokscale graph --no-spinner` output.
struct TokscaleGraph: Decodable {
    struct Totals: Decodable {
        let tokens: Double?
        let cost: Double?
        let messages: Double?
    }
    struct Breakdown: Decodable {
        let input: Double?
        let output: Double?
        let cacheRead: Double?
        let cacheWrite: Double?
        let reasoning: Double?
    }
    struct ClientContribution: Decodable {
        let client: String?
        let modelId: String?
        let providerId: String?
        let tokens: Breakdown?
        let cost: Double?
        let messages: Double?
    }
    struct Contribution: Decodable {
        let date: String
        let totals: Totals?
        let intensity: Int?
        let tokenBreakdown: Breakdown?
        let clients: [ClientContribution]?
        let activeTimeMs: Double?

        enum CodingKeys: String, CodingKey {
            case date, totals, intensity, tokenBreakdown, clients, activeTimeMs, active_time_ms
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            totals = try c.decodeIfPresent(Totals.self, forKey: .totals)
            intensity = try c.decodeIfPresent(Int.self, forKey: .intensity)
            tokenBreakdown = try c.decodeIfPresent(Breakdown.self, forKey: .tokenBreakdown)
            clients = try c.decodeIfPresent([ClientContribution].self, forKey: .clients)
            activeTimeMs = try c.decodeIfPresent(Double.self, forKey: .activeTimeMs)
                ?? c.decodeIfPresent(Double.self, forKey: .active_time_ms)
        }
    }
    struct TimeMetrics: Decodable {
        let totalActiveTimeMs: Double?
    }
    struct Meta: Decodable {
        let generatedAt: String?
        let version: String?
    }
    struct Summary: Decodable {
        let totalTokens: Double?
        let totalCost: Double?
        let totalDays: Double?
        let activeDays: Double?
    }

    let meta: Meta?
    let summary: Summary?
    let timeMetrics: TimeMetrics?
    let contributions: [Contribution]

    enum CodingKeys: String, CodingKey { case meta, summary, contributions, timeMetrics, time_metrics }

    init(meta: Meta?, summary: Summary?, timeMetrics: TimeMetrics?, contributions: [Contribution]) {
        self.meta = meta
        self.summary = summary
        self.timeMetrics = timeMetrics
        self.contributions = contributions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decodeIfPresent(Meta.self, forKey: .meta)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        timeMetrics = try c.decodeIfPresent(TimeMetrics.self, forKey: .timeMetrics)
            ?? c.decodeIfPresent(TimeMetrics.self, forKey: .time_metrics)
        // Element-wise decode (see LossyArray): a single corrupt contribution
        // day must not empty the whole graph. An all-bad array throws so
        // scanTokscaleGraph keeps last-known-good days instead of zeroing
        // the history merge.
        let rawContributions = (try? c.decode([JSONValue].self, forKey: .contributions)) ?? []
        contributions = try LossyArray.decode(Contribution.self, from: rawContributions, context: "graph")
    }
}

/// `tokscale pricing <model> --json --no-spinner` output. Codable so the
/// 6h-TTL cache can persist across launches (Phase 3: pricing lookups no
/// longer pay a ~5s cold subprocess+network spawn on every first tick).
struct TokscalePricing: Codable {
    struct Pricing: Codable {
        let inputCostPerToken: Double?
        let outputCostPerToken: Double?
        let cacheReadInputTokenCost: Double?
        let cacheCreationInputTokenCost: Double?
    }
    let modelId: String?
    let matchedKey: String?
    let source: String?
    let pricing: Pricing?
}
