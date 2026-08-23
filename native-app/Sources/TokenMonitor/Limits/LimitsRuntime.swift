import Foundation

/// Limits refresh loop: polls the enabled providers (deepseek, opencode, kimi) at
/// limitsRefreshMs and keeps the summary the stats frames embed. Ports the
/// LimitsRuntime role of src/shared/deviceRuntime.js, trimmed to three
/// providers and local mode.
final class LimitsRuntime {
    static let shared = LimitsRuntime()

    typealias JSON = [String: Any]

    private let core = BridgeCore.shared
    private let queue = DispatchQueue(label: "limits", qos: .utility)
    private let lock = NSLock()
    private var timer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var currentSummary: JSON = ["providers": [Any](), "updatedAt": NSNull(), "refreshMs": 300000]
    private var refreshing = false
    private var hasActiveWindows = true

    func start() {
        rebuildTimer()
        // limitsRefreshMs changes take effect without a restart (PLAN.md
        // Phase 4: the timer used to capture the interval at launch only).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self, let keys = note.userInfo?["keys"] as? [String],
                  keys.contains("limitsRefreshMs") else { return }
            DispatchQueue.main.async { [weak self] in self?.rebuildTimer() }
        }
        // First refresh shortly after launch so the Home limits module has
        // data without waiting a full interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh()
        }
    }

    func setHasActiveWindows(_ hasActive: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard hasActiveWindows != hasActive else { return }
        hasActiveWindows = hasActive
        rebuildTimer()
        if hasActive {
            refreshNow()
        }
    }

    private func rebuildTimer() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        let interval = refreshInterval()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshInterval() -> TimeInterval {
        if !hasActiveWindows {
            // When hidden, throttle limits polling to 10 minutes (600s)
            return 600.0
        }
        // Tolerant numeric read (Int/Double/String), same reason as the
        // collector timer: in-process updates may store Swift Ints.
        let raw = UsageCore.doubleValue(core.settings.snapshot()["limitsRefreshMs"])
        let ms = raw > 0 ? raw : 300000
        return max(30.0, ms / 1000.0)
    }

    func summary() -> JSON {
        lock.lock(); defer { lock.unlock() }
        return currentSummary
    }

    func refreshNow() {
        refresh()
    }

    private func refresh() {
        queue.async { [weak self] in
            self?.performRefresh()
        }
    }

    private func performRefresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let settings = core.settings.snapshot()
        guard settings["limitsEnabled"] as? Bool ?? true else { return }
        let enabled = (settings["limitProviders"] as? String ?? "deepseek,opencode,kimi")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        var providers: [Any] = []
        for provider in enabled {
            switch provider {
            case "deepseek":
                providers.append(DeepseekBalance.fetchLimits(nowMs: nowMs))
            case "opencode":
                let profiles = CredentialStore.shared.opencodeProfiles()
                    .filter { $0.enabled && (!$0.cookie.isEmpty || !$0.apiKey.isEmpty) }
                let profileList = profiles.map { OpencodeLimits.Profile(name: $0.name, cookie: $0.cookie, apiKey: $0.apiKey, enabled: $0.enabled) }
                // Async fetch on this queue via a semaphore bridge.
                let semaphore = DispatchSemaphore(value: 0)
                var fetched: [[String: Any]] = []
                Task {
                    fetched = await OpencodeLimits.fetchProviders(
                        profiles: profileList,
                        nowMs: nowMs,
                        opencodeLocalLimitsEnabled: settings["opencodeLocalLimitsEnabled"] as? Bool ?? false
                    )
                    semaphore.signal()
                }
                semaphore.wait()
                providers.append(contentsOf: fetched)
            case "kimi":
                let semaphore = DispatchSemaphore(value: 0)
                var fetched: JSON = [:]
                Task {
                    fetched = await KimiLimits.fetchLimits(
                        apiKey: CredentialStore.shared.kimiApiKey(),
                        webAccessToken: CredentialStore.shared.kimiWebAccessToken(),
                        nowMs: nowMs
                    )
                    semaphore.signal()
                }
                semaphore.wait()
                providers.append(fetched)
            default:
                break
            }
        }

        let updatedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(nowMs) / 1000))
        let next: JSON = [
            "providers": providers,
            "updatedAt": updatedAt,
            "refreshMs": settings["limitsRefreshMs"] as? Double ?? 300000
        ]
        lock.lock()
        currentSummary = next
        lock.unlock()

        if ProcessInfo.processInfo.environment["TOKEN_MONITOR_DIAG"] != nil {
            for provider in providers {
                let dict = provider as? [String: Any] ?? [:]
                let name = dict["provider"] as? String ?? "?"
                let status = dict["status"] as? String ?? "?"
                let windows = (dict["windows"] as? [Any] ?? []).count
                let balance = dict["balance"] as? [String: Any]
                NSLog("[diag] limits provider %@ status=%@ windows=%d balance=%.4f", name, status, windows,
                      balance?["amount"] as? Double ?? 0)
            }
        }

        // Re-emit the stats frame so the renderer sees fresh limits without
        // waiting for the next usage tick.
        Collector.shared.reemitStats()
    }
}
