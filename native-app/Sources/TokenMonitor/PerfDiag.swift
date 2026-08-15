import Foundation
import Darwin

/// Performance diagnostics for the optimization plan (PLAN.md Phase 0).
/// Compiled into every build but inert unless TOKEN_MONITOR_DIAG=1 is set at
/// launch, so Release runs without the variable produce no periodic logging.
///
/// Provides:
///  - low-overhead wall-clock phase timing emitted as [perf] NSLog lines
///    (PLAN.md Phase 0 accepts timing in place of os_signpost),
///  - self-reported CPU (getrusage deltas) and physical footprint
///    (task_info) marks, for environments where external ps/top sampling
///    is unavailable,
///  - stable fixture dumps of the assembled stats frames so runs before/after
///    an optimization can be compared automatically.
enum PerfDiag {
    static let enabled = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil

    /// Wall-clock span; logs elapsed milliseconds on end() when diagnostics
    /// are enabled. (PLAN.md Phase 0 allows low-overhead timing in place of
    /// os_signpost; the signpost macros are not importable into Swift from
    /// this SDK, so the [perf] lines are the measurement artifact.)
    struct Span {
        let name: String
        private let startTime: Date

        init(name: String) {
            self.name = name
            self.startTime = Date()
        }

        func end() {
            let ms = Date().timeIntervalSince(startTime) * 1000
            log(String(format: "phase %@: %.1f ms", name, ms))
        }
    }

    static func span(_ name: String) -> Span { Span(name: name) }

    static func log(_ message: String) {
        guard enabled else { return }
        NSLog("[perf] %@", message)
    }

    // MARK: - Self-reported CPU / footprint

    /// The external ps/top sampling used for baselines is unavailable in
    /// some restricted environments, so the app reports its own rusage
    /// deltas at measurement points (diag mode only). Cross-process
    /// attribution stays with the spawn wall-time lines in TokscaleRunner.
    private static var lastRusage: rusage?

    static func cpuMark(_ label: String) {
        guard enabled else { return }
        var current = rusage()
        getrusage(RUSAGE_SELF, &current)
        if let previous = lastRusage {
            let user = Self.delta(previous.ru_utime, current.ru_utime)
            let sys = Self.delta(previous.ru_stime, current.ru_stime)
            log(String(format: "cpu %@: user=%.2fs sys=%.2fs total=%.2fs", label, user, sys, user + sys))
        }
        lastRusage = current
    }

    private static func delta(_ from: timeval, _ to: timeval) -> Double {
        Double(to.tv_sec - from.tv_sec) + Double(to.tv_usec - from.tv_usec) / 1_000_000
    }

    /// Physical footprint of this process via task_info (works without the
    /// external footprint tool and reports at tick granularity).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    static func footprintMark(_ label: String) {
        guard enabled else { return }
        log(String(format: "footprint %@: %.1f MB", label, footprintMB()))
    }

    // MARK: - Fixture dumps

    /// Directory for stats fixture dumps. TOKEN_MONITOR_DIAG_DIR overrides the
    /// default location (Application Support/Token Monitor/diag) so automated
    /// runs can direct dumps anywhere.
    static var dumpDir: URL {
        if let raw = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Token Monitor", isDirectory: true)
            .appendingPathComponent("diag", isDirectory: true)
    }

    /// Atomically write one JSON dump file (diag mode only).
    static func dump(_ json: [String: Any], name: String) {
        guard enabled else { return }
        do {
            try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dumpDir.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("[diag] dump failed: %@", String(describing: error))
        }
    }
}

