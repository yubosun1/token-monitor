import Foundation

/// Pricing lookup policy (review-round fix): the collector passes the
/// policy explicitly per call instead of toggling a global mutable switch,
/// so concurrent callers can never affect each other.
enum PricingPolicy {
    /// Resolve from the in-memory/disk caches only; never spawn. A stale
    /// last-known-good value is still preferable to dropping a cost to zero.
    case cacheOnly
    /// May spawn a pricing subprocess on a cache miss.
    case resolve
    /// Explicit user action: refresh even a still-fresh cached price.
    case forceRefresh
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
    func run(_ args: [String], timeout: TimeInterval = 60, pricingCacheOnly: Bool = false) throws -> Result {
        guard let binary = binaryURL() else {
            throw CollectorError.tokscaleMissing
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var processEnvironment = ProcessInfo.processInfo.environment
        if pricingCacheOnly {
            // A usage scan must never wait on the remote pricing catalogs.
            // The scanner still calculates costs from tokscale's local cache.
            processEnvironment["TOKSCALE_PRICING_CACHE_ONLY"] = "1"
        }
        process.environment = processEnvironment

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
        // Drain stdout and stderr concurrently. Reading them sequentially can
        // deadlock: if the child fills the stderr pipe buffer (~64KB) while
        // stdout is still being read, it blocks writing and never closes
        // stdout, so the sequential reader waits until the timeout kills it.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        final class PipeBox { var data = Data() }
        let outBox = PipeBox()
        let errBox = PipeBox()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = outHandle.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errHandle.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.wait()
        try? outHandle.close()
        try? errHandle.close()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: errBox.data, encoding: .utf8) ?? ""

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

    private static let clientAliases: [String: [String]] = [
        "antigravity": ["antigravity-cli"]
    ]

    /// Expands umbrella client names to include their sub-source IDs that
    /// tokscale tracks under separate client filters (e.g. antigravity-cli).
    static func expandClientFilter(_ clients: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for client in clients {
            let trimmed = client.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
            for alias in clientAliases[trimmed] ?? [] {
                if seen.insert(alias).inserted {
                    ordered.append(alias)
                }
            }
        }
        return ordered
    }

    /// Known lock paths for Antigravity sync operations.
    static func antigravityLockPaths(home: String = NSHomeDirectory()) -> [String] {
        var dirs = [
            home + "/.config/tokscale/antigravity-cache",
            home + "/Library/Application Support/tokscale/antigravity-cache"
        ]
        if let env = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"], !env.isEmpty {
            dirs.append(env + "/antigravity-cache")
        }
        var paths: [String] = []
        for dir in dirs {
            paths.append(dir + "/sync.lock")
            paths.append(dir + "/sync.os.lock")
            paths.append(dir + ".lock")
        }
        return paths
    }

    /// Cleans up stale Antigravity sync locks left by killed/crashed tokscale processes.
    @discardableResult
    static func cleanupStaleAntigravityLocks(home: String = NSHomeDirectory(), force: Bool = false) -> Int {
        let fm = FileManager.default
        var cleaned = 0
        let now = Date().timeIntervalSince1970
        for path in antigravityLockPaths(home: home) {
            guard fm.fileExists(atPath: path) else { continue }
            if force {
                try? fm.removeItem(atPath: path)
                cleaned += 1
                continue
            }
            var isStale = false
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let parts = content.split(whereSeparator: \.isWhitespace)
                if let first = parts.first, let pid = Int32(first) {
                    if pid > 0 && kill(pid, 0) != 0 && errno == ESRCH {
                        isStale = true
                    }
                }
            }
            if !isStale {
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date,
                   now - mtime.timeIntervalSince1970 > 30.0 {
                    isStale = true
                }
            }
            if isStale {
                try? fm.removeItem(atPath: path)
                cleaned += 1
            }
        }
        return cleaned
    }

    /// Whether Antigravity IDE native session roots are present on disk.
    static func antigravityDataPresent(home: String = NSHomeDirectory()) -> Bool {
        let roots = [
            "antigravity", "antigravity-ide", "antigravity-backup", "antigravity-cli"
        ].map { home + "/.gemini/" + $0 } + [
            home + "/Library/Application Support/Antigravity",
            home + "/.config/tokscale/antigravity-cache",
            home + "/Library/Application Support/tokscale/antigravity-cache"
        ]
        return roots.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Runs `tokscale antigravity sync` to synchronize language server sessions across workspaces.
    @discardableResult
    func syncAntigravity(home: String? = nil, timeout: TimeInterval = 30) -> Bool {
        let targetHome = home ?? NSHomeDirectory()
        Self.cleanupStaleAntigravityLocks(home: targetHome, force: false)
        var args = ["antigravity", "sync"]
        if let home, !home.isEmpty {
            args.append(contentsOf: ["--home", home])
        }
        do {
            let result = try run(args, timeout: timeout)
            if result.exitCode != 0 {
                if result.stderr.contains("sync lock") || result.stderr.contains("already exists") || result.stderr.contains("lock") {
                    Self.cleanupStaleAntigravityLocks(home: targetHome, force: true)
                    if let retry = try? run(args, timeout: timeout), retry.exitCode == 0 {
                        return true
                    }
                }
                NSLog("[antigravity] sync exited %d: %@", result.exitCode, result.stderr)
                return false
            }
            return true
        } catch {
            NSLog("[antigravity] sync failed: %@", String(describing: error))
            return false
        }
    }

    func usage(clients: [String], period: String, allTimeSince: String? = nil) throws -> [TokscaleEntry] {
        let expanded = Self.expandClientFilter(clients)
        guard !expanded.isEmpty else { return [] }
        var args = ["--json", "--client", expanded.joined(separator: ","), "--group-by", "client,session,model"]
        switch period {
        case "today": args.append("--today")
        case "month": args.append("--month")
        case "allTime": args.append(contentsOf: ["--since", allTimeSince ?? "2024-01-01"])
        default: break
        }
        let result = try run(args, pricingCacheOnly: true)
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
        let expanded = Self.expandClientFilter(clients)
        guard !expanded.isEmpty else { return TokscaleGraph(meta: nil, summary: nil, timeMetrics: nil, contributions: []) }
        let result = try run(["graph", "--client", expanded.joined(separator: ","), "--no-spinner"], pricingCacheOnly: true)
        guard result.exitCode == 0 else {
            throw CollectorError.tokscaleFailed("graph exit \(result.exitCode)")
        }
        guard let start = result.stdout.firstIndex(of: "{") else {
            return TokscaleGraph(meta: nil, summary: nil, timeMetrics: nil, contributions: [])
        }
        return try JSONDecoder().decode(TokscaleGraph.self, from: Data(String(result.stdout[start...]).utf8))
    }

    /// Cached pricing lookup. Routine collection reads the last known price
    /// without network I/O; an explicit refresh can bypass its TTL.
    func pricing(for modelId: String, policy: PricingPolicy = .cacheOnly) -> TokscalePricing? {
        if pricingCache.isEmpty { loadDiskPricingCache() }
        let key = modelId.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        let cached = pricingCache[key]
        lock.unlock()

        if let cached {
            switch policy {
            case .cacheOnly:
                return cached.pricing
            case .resolve:
                if Date().timeIntervalSince(cached.fetchedAt) < pricingCacheTTL {
                    return cached.pricing
                }
            case .forceRefresh:
                break
            }
        }
        if case .cacheOnly = policy { return nil }
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

    /// One deliberately bounded online request, made only from a user-driven
    /// refresh. It lets tokscale update its own catalog cache once; all normal
    /// period and graph scans then use that cache without touching the network.
    @discardableResult
    func refreshUsagePricing(clients: [String]) -> Bool {
        let expanded = Self.expandClientFilter(clients)
        guard !expanded.isEmpty else { return true }
        let args = [
            "--json", "--client", expanded.joined(separator: ","),
            "--group-by", "client,model", "--today", "--no-spinner"
        ]
        do {
            let result = try run(args, timeout: 15)
            guard result.exitCode == 0 else {
                NSLog("[pricing] manual tokscale refresh failed: exit %d: %@", result.exitCode, result.stderr)
                return false
            }
            return true
        } catch {
            NSLog("[pricing] manual tokscale refresh failed: %@", String(describing: error))
            return false
        }
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
