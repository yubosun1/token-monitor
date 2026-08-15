import Foundation

/// Pricing lookup policy (review-round fix): the collector passes the
/// policy explicitly per call instead of toggling a global mutable switch,
/// so concurrent callers can never affect each other.
enum PricingPolicy {
    /// Resolve from the in-memory/disk caches only; never spawn.
    case cacheOnly
    /// May spawn a pricing subprocess on a cache miss.
    case resolve
}

/// Spawns the bundled tokscale CLI (the same Rust binary the Electron app
/// shipped) and decodes its JSON output.
final class TokscaleRunner {
    static let shared = TokscaleRunner()

    private let lock = NSLock()
    private var pricingCache: [String: (pricing: TokscalePricing, fetchedAt: Date)] = [:]
    private let pricingCacheTTL: TimeInterval = 6 * 60 * 60

    /// Monotonic spawn counter (diag attribution: how many tokscale
    /// processes one refresh started).
    private var spawnCount = 0

    /// Live subprocess registry (PLAN.md Phase 4): the app terminates every
    /// in-flight scan on quit so no orphaned tokscale process survives.
    private var runningProcesses: [Process] = []

    // MARK: - Persistent pricing cache (PLAN.md Phase 3)

    /// Pricing lookups persist across launches so the first tick does not
    /// pay a cold `tokscale pricing` subprocess (measured ~5s, network) for
    /// every distinct model. The same 6h TTL as the in-memory cache applies;
    /// entries are re-validated lazily on lookup.
    private var pricingDiskURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Token Monitor", isDirectory: true)
            .appendingPathComponent("pricing-cache.json")
    }

    private struct DiskPricingEntry: Codable {
        let fetchedAtMs: Double
        let pricing: TokscalePricing
    }

    private func loadDiskPricingCache() {
        guard let data = try? Data(contentsOf: pricingDiskURL),
              let dict = try? JSONDecoder().decode([String: DiskPricingEntry].self, from: data) else { return }
        lock.lock()
        for (key, entry) in dict {
            pricingCache[key] = (entry.pricing, Date(timeIntervalSince1970: entry.fetchedAtMs / 1000))
        }
        lock.unlock()
        if PerfDiag.enabled && !dict.isEmpty {
            PerfDiag.log(String(format: "pricing cache loaded %d entries", dict.count))
        }
    }

    private func persistPricingCache() {
        lock.lock()
        var dict: [String: DiskPricingEntry] = [:]
        for (key, entry) in pricingCache {
            dict[key] = DiskPricingEntry(fetchedAtMs: entry.fetchedAt.timeIntervalSince1970 * 1000, pricing: entry.pricing)
        }
        lock.unlock()
        guard let data = try? JSONEncoder().encode(dict) else { return }
        do {
            let dir = pricingDiskURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: pricingDiskURL, options: .atomic)
        } catch {
            NSLog("[pricing] disk cache write failed: %@", String(describing: error))
        }
    }

    private func binaryURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "tokscale", withExtension: nil), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // Development fallback: vendored copy at the repo path.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/tokscale/tokscale")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    @discardableResult
    func run(_ args: [String], timeout: TimeInterval = 60) throws -> Result {
        guard let binary = binaryURL() else {
            throw CollectorError.tokscaleMissing
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        let started = Date()
        try process.run()
        lock.lock()
        runningProcesses.append(process)
        lock.unlock()
        defer {
            lock.lock()
            runningProcesses.removeAll { $0 === process }
            lock.unlock()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if PerfDiag.enabled {
            lock.lock()
            spawnCount += 1
            let n = spawnCount
            lock.unlock()
            PerfDiag.log(String(format: "tokscale spawn #%d pid=%d args=%@ wallMs=%.1f exit=%d",
                                n, process.processIdentifier, args.joined(separator: " "), elapsedMs, process.terminationStatus))
        }
        return Result(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    func usage(clients: [String], period: String, allTimeSince: String? = nil) throws -> [TokscaleEntry] {
        guard !clients.isEmpty else { return [] }
        var args = ["--json", "--client", clients.joined(separator: ","), "--group-by", "client,session,model"]
        switch period {
        case "today": args.append("--today")
        case "month": args.append("--month")
        case "allTime": args.append(contentsOf: ["--since", allTimeSince ?? "2024-01-01"])
        default: break
        }
        let result = try run(args)
        guard result.exitCode == 0 else {
            throw CollectorError.tokscaleFailed("exit \(result.exitCode): \(result.stderr)")
        }
        // tokscale prints non-JSON warnings before the object; skip to the first '{'.
        guard let start = result.stdout.firstIndex(of: "{") else { return [] }
        let jsonText = String(result.stdout[start...])
        let data = Data(jsonText.utf8)
        let response = try JSONDecoder().decode(TokscaleResponse.self, from: data)
        return response.entries
    }

    func graph(clients: [String]) throws -> TokscaleGraph {
        guard !clients.isEmpty else { return TokscaleGraph(meta: nil, summary: nil, timeMetrics: nil, contributions: []) }
        let result = try run(["graph", "--client", clients.joined(separator: ","), "--no-spinner"])
        guard result.exitCode == 0 else {
            throw CollectorError.tokscaleFailed("graph exit \(result.exitCode)")
        }
        guard let start = result.stdout.firstIndex(of: "{") else {
            return TokscaleGraph(meta: nil, summary: nil, timeMetrics: nil, contributions: [])
        }
        return try JSONDecoder().decode(TokscaleGraph.self, from: Data(String(result.stdout[start...]).utf8))
    }

    /// Cached pricing lookup: in-memory, then persistent disk cache (same
    /// 6h TTL as the JS side used), then one subprocess fetch. The policy
    /// decides whether a cache miss may spawn; cacheOnly returns nil on a
    /// miss and never spawns.
    func pricing(for modelId: String, policy: PricingPolicy = .resolve) -> TokscalePricing? {
        if pricingCache.isEmpty { loadDiskPricingCache() }
        let key = modelId.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        if let cached = pricingCache[key], Date().timeIntervalSince(cached.fetchedAt) < pricingCacheTTL {
            lock.unlock()
            return cached.pricing
        }
        lock.unlock()
        if policy == .cacheOnly { return nil }
        guard let fetched = fetchPricing(modelId) else { return nil }
        lock.lock()
        pricingCache[key] = (fetched, Date())
        lock.unlock()
        persistPricingCache()
        return fetched
    }

    private func fetchPricing(_ modelId: String) -> TokscalePricing? {
        guard let result = try? run(["pricing", modelId, "--json", "--no-spinner"], timeout: 15),
              result.exitCode == 0,
              let start = result.stdout.firstIndex(of: "{") else { return nil }
        return try? JSONDecoder().decode(TokscalePricing.self, from: Data(String(result.stdout[start...]).utf8))
    }

    /// Terminate every in-flight tokscale subprocess (app termination path).
    func terminateAll() {
        lock.lock()
        let processes = runningProcesses
        lock.unlock()
        for process in processes {
            process.terminate()
        }
    }
}

enum CollectorError: LocalizedError {
    case tokscaleMissing
    case tokscaleFailed(String)

    var errorDescription: String? {
        switch self {
        case .tokscaleMissing: return "tokscale binary not found in app bundle"
        case .tokscaleFailed(let detail): return "tokscale failed: \(detail)"
        }
    }
}
