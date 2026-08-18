import Foundation

/// Persisted GUI settings. Mirrors the subset of the Electron app's
/// `settings.json` the native app still understands, with defaults matching
/// the user's chosen configuration (fresh start — no migration of history).
final class SettingsStore {
    static let shared = SettingsStore()

    /// In-process change notification (PLAN.md Phase 4): posted after every
    /// update with the changed keys, so the collector can coalesce a
    /// settings-change refresh and rebuild its timer when refreshMs moves.
    static let changedNotification = Notification.Name("TokenMonitor.settingsChanged")

    private let fileManager = FileManager.default
    let fileURL: URL
    private var values: [String: Any]
    private let lock = NSLock()

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Token Monitor", isDirectory: true)
        // The Electron app wrote settings.json in the same folder. The native
        // app owns a fresh file so the two can never fight over one document.
        fileURL = dir.appendingPathComponent("settings.native.json")
        values = Self.defaults()
        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.lock(); defer { lock.unlock() }
            values.merge(json) { _, new in new }
            migrateLegacyDefaultsIfNeeded()
            normalizeOrphanedSubscriptions()
        }
    }

    /// One-time migrations for settings whose defaults changed after the first
    /// native build. Each schema version changes only values that were absent
    /// from the older native configuration.
    private func migrateLegacyDefaultsIfNeeded() {
        let version = values["settingsSchemaVersion"] as? Int ?? 0
        guard version < 2 else { return }
        if version < 1, (values["heatmapMetric"] as? String) == "cost" {
            values["heatmapMetric"] = "tokens"
        }
        if version < 2 {
            for key in ["clients", "clientDisplayOrder", "limitProviders", "limitProviderOrder"] {
                values[key] = Self.appendingCSVValue(values[key] as? String ?? "", value: "kimi")
            }
        }
        values["settingsSchemaVersion"] = 2
        persist(values)
    }

    private static func appendingCSVValue(_ value: String, value item: String) -> String {
        var entries = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !entries.contains(item) else { return entries.joined(separator: ",") }
        entries.append(item)
        return entries.joined(separator: ",")
    }

    /// The pre-native format of `subscriptionsOrphaned` was a dict
    /// (`["hubUrl": "", "records": [...]]`); the renderer reads it as an array
    /// (`orphans.length`), so a persisted dict made the orphan notice render
    /// unconditionally. Normalize on every load — unlike the schema-version
    /// migration this is unconditional, because any pre-fix build can write the
    /// legacy shape back at any time.
    private func normalizeOrphanedSubscriptions() {
        guard let orphaned = values["subscriptionsOrphaned"], !(orphaned is [Any]) else { return }
        values["subscriptionsOrphaned"] = [Any]()
        persist(values)
    }

    static func defaults() -> [String: Any] {
        return [
            // Window
            "windowBehavior": "floating",
            "glassOpacity": 68,
            "glassBlur": 32,
            "systemGlass": true,
            "reduceMotion": "system",
            // Collectors
            "refreshMs": 15000,
            // Low-CPU collection: when a local source (e.g. an actively
            // appending dsh session) changes between refreshes, defer the
            // re-read for at least this many ms so re-decompression/parsing
            // happens at most once per window instead of on every tick.
            "adapterRecheckMs": 30000,
            "collectionIntervalMs": 300000,
            "clients": "claude,codex,opencode,kimi,workbuddy,proma,hanako,dsh",
            "clientDisplayOrder": "claude,codex,opencode,kimi,proma,workbuddy,hanako,dsh",
            "hiddenClients": "",
            "pinnedClients": "",
            "historyEnabled": true,
            "historyIntervalMs": 900000,
            "sessionUsageArchiveEnabled": true,
            "allTimeSince": "2024-01-01",
            "customModelPricing": [Any](),
            // Limits
            "limitsEnabled": true,
            "limitProviders": "deepseek,opencode,kimi",
            "limitProviderOrder": "deepseek,opencode,kimi",
            "homeLimitProviderOrder": "",
            "hiddenHomeLimitProviders": "",
            "homeLimitAccountCount": 3,
            "limitsRefreshMs": 300000,
            "showLimitSource": false,
            "maskLimitAccountEmails": false,
            "showLimitUsed": false,
            "opencodeLocalLimitsEnabled": false,
            // Subscriptions
            "subscriptions": [Any](),
            "subscriptionsOrphaned": [Any](),
            // UI
            "showLiveDot": true,
            "showToolIcons": true,
            "titleIconOnly": true,
            "showCompactTotalTokens": false,
            "compactTokenUnits": "western",
            "tokenRateMode": "speed",
            "heatmapMetric": "tokens",
            "homeActiveDaysWindow": "all",
            "showHomeLimitBars": false,
            "showHomeLimitProviderNames": false,
            "homeModuleOrder": "limits,tool,model,trends",
            "hiddenHomeModules": "tool",
            "viewDisplayOrder": "",
            "hiddenViews": "status",
            // Misc
            "deviceId": "macbook-pro-local",
            "language": "zh-CN",
            "currency": "USD",
            "currencyRates": [String: Any](),
            "startAtLogin": true,
            "windowToggleShortcut": "CommandOrControl+E",
            "serviceStatusRefreshMs": 60000,
            "windowBounds": NSNull(),
            "zoomFactor": 1,
            "trayContent": "icon",
            "showTrayIcon": true,
            "trayMode": true,
            "settingsInTitlebar": false
        ]
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    /// Shallow merge + persist; returns the merged settings. Posts
    /// changedNotification with the changed keys (empty patch → no post).
    @discardableResult
    func update(_ patch: [String: Any]) -> [String: Any] {
        lock.lock()
        values.merge(patch) { _, new in new }
        let merged = values
        lock.unlock()
        persist(merged)
        if !patch.isEmpty {
            NotificationCenter.default.post(
                name: Self.changedNotification,
                object: nil,
                userInfo: ["keys": Array(patch.keys)]
            )
        }
        return merged
    }

    private func persist(_ snapshot: [String: Any]) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[settings] persist failed: %@", String(describing: error))
        }
    }
}
