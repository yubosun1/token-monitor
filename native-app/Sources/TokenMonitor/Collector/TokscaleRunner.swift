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
        let drained = Self.drainOutput(process: process, outPipe: outPipe, errPipe: errPipe, timeout: timeout)
        timeoutWorkItem.cancel()
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        let stdout = drained.stdout
        let stderr = drained.stderr

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

    /// Drains one spawned subprocess's pipes with a hard wall-clock budget.
    /// `timeout` matches the SIGTERM deadline `run` already armed; the short
    /// `grace` lets the pipes finish draining after a SIGTERM before the
    /// drain is declared stuck. On expiry the process is SIGKILLed — the
    /// negative-pid form covers a process group the child heads (wrapper
    /// shells put background jobs in the shell's group), so grandchildren
    /// that inherited a pipe write end die with it — and the read ends are
    /// closed so the drain handlers observe EOF. The call therefore always
    /// returns within `timeout + 2 * grace`, even when a grandchild keeps
    /// the pipes open forever (fork/exec fd-inheritance trap); the output
    /// may be partial on the expiry path.
    static func drainOutput(process: Process, outPipe: Pipe, errPipe: Pipe,
                            timeout: TimeInterval, grace: TimeInterval = 2) -> (stdout: String, stderr: String) {
        // The handlers append on their own queue while the caller reads the
        // snapshot, so the boxes carry their own lock. A semaphore per pipe
        // is signaled exactly once at EOF (or read error); unlike a
        // DispatchGroup it tolerates being signaled from a handler that
        // raced the close on the timeout path.
        final class PipeBox {
            private let lock = NSLock()
            private var storage = Data()
            func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
            func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return storage }
        }
        let outBox = PipeBox()
        let errBox = PipeBox()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        func startDrain(_ handle: FileHandle, into box: PipeBox, done: DispatchSemaphore) {
            // Drain stdout and stderr concurrently. A plain sequential read
            // can deadlock: if the child fills the stderr pipe buffer
            // (~64KB) while stdout is still being read, it blocks writing
            // and never closes stdout. The raw read() keeps the handler
            // exception-free even after the timeout path closes the handle
            // from another thread (FileHandle read APIs raise instead).
            handle.readabilityHandler = { h in
                var buffer = [UInt8](repeating: 0, count: 65536)
                let count = read(h.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    box.append(Data(buffer[0..<count]))
                } else if count < 0, errno == EINTR {
                    // Interrupted syscall; the ready event is re-armed.
                } else {
                    // EOF, or EBADF after the timeout path closed the
                    // handle: nothing more will arrive.
                    h.readabilityHandler = nil
                    done.signal()
                }
            }
        }
        startDrain(outHandle, into: outBox, done: outDone)
        startDrain(errHandle, into: errBox, done: errDone)

        // Wait for both pipes to reach EOF, bounded by the SIGTERM deadline
        // plus the drain grace.
        let killDeadline = DispatchTime.now() + timeout + grace
        let outStuck = outDone.wait(timeout: killDeadline) == .timedOut
        let errStuck = errDone.wait(timeout: killDeadline) == .timedOut
        if outStuck || errStuck {
            // Re-assert SIGTERM (the timer may have lagged), then hard-kill.
            process.terminate()
            kill(-process.processIdentifier, SIGKILL)
            kill(process.processIdentifier, SIGKILL)
            // Close the read ends so the handlers observe EOF/EBADF and the
            // second wait below completes. If a grandchild still holds the
            // pipes this wait expires, keeping the total budget bounded.
            try? outHandle.close()
            try? errHandle.close()
            _ = outDone.wait(timeout: .now() + grace)
            _ = errDone.wait(timeout: .now() + grace)
        }
        process.waitUntilExit()
        return (String(data: outBox.snapshot(), encoding: .utf8) ?? "",
                String(data: errBox.snapshot(), encoding: .utf8) ?? "")
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

    /// Cleans up stale Antigravity sync locks left by killed/crashed
    /// tokscale processes. A lock whose recorded holder pid is still alive
    /// is never removed, mtime and force notwithstanding; the age fallback
    /// only applies to locks that carry no pid information at all.
    @discardableResult
    static func cleanupStaleAntigravityLocks(home: String = NSHomeDirectory(), force: Bool = false) -> Int {
        let fm = FileManager.default
        var cleaned = 0
        let now = Date().timeIntervalSince1970
        for path in antigravityLockPaths(home: home) {
            guard fm.fileExists(atPath: path) else { continue }
            // The lock records its holder's pid as the first whitespace
            // token where tokscale wrote one.
            var recordedPID: Int32?
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let parts = content.split(whereSeparator: \.isWhitespace)
                if let first = parts.first, let pid = Int32(first), pid > 0 {
                    recordedPID = pid
                }
            }
            if let pid = recordedPID, isProcessAlive(pid) {
                continue
            }
            var isStale = false
            if recordedPID != nil {
                // The recorded holder is gone.
                isStale = true
            } else if force {
                isStale = true
            } else if let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      now - mtime.timeIntervalSince1970 > 30.0 {
                // No pid recorded (older format): age is the only signal.
                isStale = true
            }
            if isStale {
                try? fm.removeItem(atPath: path)
                cleaned += 1
            }
        }
        return cleaned
    }

    /// Whether a process with this pid exists right now. EPERM also counts
    /// as alive: the process exists even when it belongs to another user.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Whether a sync failure message indicates a STALE lock left behind by
    /// a dead process (worth a forced cleanup) rather than live contention
    /// such as SQLite's "database is locked", which must never trigger lock
    /// deletion.
    static func isStaleLockError(_ stderr: String) -> Bool {
        guard !stderr.contains("database is locked") else { return false }
        return stderr.contains("sync lock")
            || stderr.contains("stale lock")
            || stderr.contains("lock file")
            || stderr.contains("already exists")
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
                if Self.isStaleLockError(result.stderr) {
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
