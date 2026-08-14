import Foundation

/// Port of src/electron/serviceStatus.js: fetches each provider's
/// statuspage.io summary JSON and maps it to the exact provider wire shape the
/// renderer's status view consumes (id/label/pageUrl/status/indicator/
/// description/checkedAt/updatedAt/componentIssues/incidentTitle/
/// incidentCount/maintenanceCount). Successful checks are cached for 60s;
/// failed checks only 10s so a transient network blip recovers quickly.
final class ServiceStatusRuntime {
    static let shared = ServiceStatusRuntime()

    private struct Provider {
        let id: String
        let label: String
        let pageUrl: String
        let summaryUrl: String
    }

    private static let providers: [Provider] = [
        Provider(id: "claude", label: "Claude",
                 pageUrl: "https://status.claude.com",
                 summaryUrl: "https://status.claude.com/api/v2/summary.json"),
        Provider(id: "openai", label: "OpenAI",
                 pageUrl: "https://status.openai.com",
                 summaryUrl: "https://status.openai.com/api/v2/summary.json"),
        Provider(id: "cursor", label: "Cursor",
                 pageUrl: "https://status.cursor.com",
                 summaryUrl: "https://status.cursor.com/api/v2/summary.json"),
        // The official status.deepseek.com page only serves HTML to browsers;
        // fetch the Atlassian-hosted mirror like the Electron version did.
        Provider(id: "deepseek", label: "DeepSeek",
                 pageUrl: "https://status.deepseek.com",
                 summaryUrl: "https://deepseek.statuspage.io/api/v2/summary.json")
    ]

    private let lock = NSLock()
    private var cache: [String: Any]?
    private var cacheKey = ""
    private var cacheUntil = 0.0
    private let cacheMs = 60_000.0
    private let errorCacheMs = 10_000.0
    private let timeoutMs = 5_000.0
    private let userAgent = "TokenMonitor/0.44.0-native (+https://github.com/Javis603/token-monitor)"

    /// Synchronous fetch; the bridge routes serviceStatus:get to a background
    /// queue so this never blocks the main thread.
    func status(force: Bool, providerIds: [String]?) -> [String: Any] {
        let wanted = Self.providers.filter { provider in
            guard let providerIds else { return true }
            return providerIds.contains(provider.id)
        }
        guard !wanted.isEmpty else {
            return ["checkedAt": isoNow(), "providers": [Any](), "refreshMs": 60000]
        }
        let key = wanted.map { $0.id }.sorted().joined(separator: ",")
        let now = Date()

        lock.lock()
        let cached = cache
        let cachedKey = cacheKey
        let cachedUntil = cacheUntil
        lock.unlock()
        if !force, let cached, cachedKey == key, now.timeIntervalSince1970 * 1000 < cachedUntil {
            return cached
        }

        let checkedAt = isoNow()
        let results = wanted.map { provider in
            fetch(provider: provider, checkedAt: checkedAt)
        }
        let anyError = results.contains { $0["error"] != nil }
        let payload: [String: Any] = ["checkedAt": checkedAt, "providers": results, "refreshMs": 60000]
        lock.lock()
        cache = payload
        cacheKey = key
        cacheUntil = now.timeIntervalSince1970 * 1000 + (anyError ? errorCacheMs : cacheMs)
        lock.unlock()
        return payload
    }

    // MARK: - Fetching

    private func fetch(provider: Provider, checkedAt: String) -> [String: Any] {
        guard let url = URL(string: provider.summaryUrl) else {
            return summarize(provider: provider, payload: nil, checkedAt: checkedAt, errorMessage: "Unable to check status")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutMs / 1000
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var result: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error {
                result = self.summarize(provider: provider, payload: nil, checkedAt: checkedAt,
                                        errorMessage: error.localizedDescription)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = self.summarize(provider: provider, payload: nil, checkedAt: checkedAt,
                                        errorMessage: "Unable to check status")
                return
            }
            result = self.summarize(provider: provider, payload: json, checkedAt: checkedAt, errorMessage: nil)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeoutMs / 1000)
        if result == nil { task.cancel() }
        return result ?? summarize(provider: provider, payload: nil, checkedAt: checkedAt,
                                   errorMessage: "Request timed out")
    }

    // MARK: - Mapping (port of summarizeStatuspageProvider)

    private func summarize(provider: Provider, payload: [String: Any]?, checkedAt: String, errorMessage: String?) -> [String: Any] {
        var base: [String: Any] = [
            "id": provider.id, "label": provider.label, "pageUrl": provider.pageUrl,
            "status": "unknown", "indicator": "unknown",
            "description": "Unable to check status",
            "checkedAt": checkedAt, "updatedAt": "",
            "componentIssues": [Any](), "incidentTitle": "",
            "incidentCount": 0, "maintenanceCount": 0
        ]
        if let errorMessage {
            base["error"] = errorMessage
            return base
        }
        guard let payload, let status = payload["status"] as? [String: Any] else { return base }

        let indicator = normalize(String(describing: status["indicator"] ?? "unknown"))
        let tone: String
        switch indicator {
        case "none": tone = "ok"
        case "minor": tone = "degraded"
        case "major", "critical": tone = "outage"
        default: tone = "unknown"
        }

        let components = payload["components"] as? [[String: Any]] ?? []
        let issues = components.compactMap { component -> [String: Any]? in
            let componentStatus = normalize(String(describing: component["status"] ?? ""))
            if componentStatus.isEmpty || componentStatus == "operational" || componentStatus == "under_maintenance" {
                return nil
            }
            return [
                "name": String(describing: component["name"] ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines),
                "status": componentStatus
            ]
        }

        let incidents = activeItems(payload["incidents"], inactive: ["resolved", "completed", "postmortem"])
        let maintenances = activeItems(payload["scheduled_maintenances"], inactive: ["completed", "canceled"])
        let page = payload["page"] as? [String: Any]
        let updatedAt = String(describing: (page?["updated_at"] ?? status["updated_at"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var description = String(describing: status["description"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { description = "Unknown" }

        return [
            "id": provider.id, "label": provider.label, "pageUrl": provider.pageUrl,
            "status": tone, "indicator": indicator,
            "description": description,
            "checkedAt": checkedAt, "updatedAt": updatedAt,
            "componentIssues": issues,
            "incidentTitle": incidents.first.map { String(describing: ($0["name"] ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "",
            "incidentCount": incidents.count,
            "maintenanceCount": maintenances.count
        ]
    }

    private func normalize(_ value: String) -> String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func activeItems(_ value: Any?, inactive: Set<String>) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.filter { item in
            let status = normalize(String(describing: item["status"] ?? ""))
            return !status.isEmpty && !inactive.contains(status)
        }
    }

    private func isoNow() -> String {
        return ISO8601DateFormatter().string(from: Date())
    }
}
