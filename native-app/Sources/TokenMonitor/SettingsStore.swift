import Foundation

/// Persisted GUI settings. Mirrors the subset of the Electron app's
/// `settings.json` the native app still understands, with defaults matching
/// the user's chosen configuration (fresh start — no migration of history).
final class SettingsStore {
    static let shared = SettingsStore()

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
        }
    }

    static func defaults() -> [String: Any] {
        return [
            // Window
            "windowBehavior": "floating",
            "alwaysOnTop": true,
            // Fixed default appearance (no theme switching in the native app)
            "glassOpacity": 68,
            "glassBlur": 32,
            "systemGlass": true,
            "windowsBackdrop": "acrylic",
            "reduceMotion": "system",
            // Collectors
            "refreshMs": 15000,
            "collectionIntervalMs": 300000,
            "clients": "claude,codex,opencode,workbuddy,proma,hanako,dsh",
            "clientDisplayOrder": "claude,codex,opencode,proma,workbuddy,hanako,dsh",
            "hiddenClients": "",
            "pinnedClients": "",
            "projectsEnabled": true,
            "historyEnabled": true,
            "historyIntervalMs": 900000,
            "sessionUsageArchiveEnabled": true,
            "archivedClientUsage": ["version": 1, "clients": [String: Any]()],
            "allTimeSince": "2024-01-01",
            "customModelPricing": [Any](),
            // Limits
            "limitsEnabled": true,
            "limitProviders": "deepseek,opencode",
            "limitProviderOrder": "deepseek,opencode",
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
            "subscriptionsOrphaned": ["hubUrl": "", "records": [Any]()],
            "subscriptionsCacheHub": "",
            // UI
            "showLiveDot": true,
            "showToolIcons": true,
            "titleIconOnly": true,
            "showCompactTotalTokens": false,
            "compactTokenUnits": "western",
            "tokenRateMode": "speed",
            "heatmapMetric": "cost",
            "homeActiveDaysWindow": "all",
            "showHomeLimitBars": false,
            "showHomeLimitProviderNames": false,
            "homeModuleOrder": "limits,tool,device,model,trends",
            "hiddenHomeModules": "device",
            "viewDisplayOrder": "",
            "hiddenViews": "device",
            "lastViewState": ["period": "today", "breakdown": "tool"],
            // Misc
            "deviceId": "macbook-pro-local",
            "language": "auto",
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
            "settingsInTitlebar": false,
            "dashboardFlat": false
        ]
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    /// Shallow merge + persist; returns the merged settings.
    @discardableResult
    func update(_ patch: [String: Any]) -> [String: Any] {
        lock.lock()
        values.merge(patch) { _, new in new }
        let merged = values
        lock.unlock()
        persist(merged)
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
