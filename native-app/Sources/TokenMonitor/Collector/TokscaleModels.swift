import Foundation

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
        entries = (try? c.decode([TokscaleEntry].self, forKey: .entries)) ?? []
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
        contributions = (try? c.decode([Contribution].self, forKey: .contributions)) ?? []
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
