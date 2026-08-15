import Foundation

/// Port of src/shared/credentialStore.js (the subset the native app keeps):
/// raw credentials in ~/Library/Application Support/Token Monitor/
/// credentials.json with restrictive permissions. The native app reads the
/// same file the Electron version wrote, so existing keys keep working.
final class CredentialStore {
    static let shared = CredentialStore()

    let fileURL: URL
    private let lock = NSLock()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Token Monitor", isDirectory: true)
        fileURL = dir.appendingPathComponent("credentials.json")
    }

    private func readDocument() -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["version": 1, "credentials": [String: Any]()]
        }
        return json
    }

    private func writeDocument(_ document: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("[credentials] write failed: %@", String(describing: error))
        }
    }

    /// Mutate the document inside the lock; returns the new document.
    private func update(_ mutate: (inout [String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var document = readDocument()
        mutate(&document)
        writeDocument(document)
    }

    // MARK: - DeepSeek

    func deepseekApiKey() -> String {
        // Explicit stored key wins; env fallback mirrors deepseekToken().
        lock.lock()
        defer { lock.unlock() }
        let document = readDocument()
        let providers = (document["credentials"] as? [String: Any] ?? [:])["providers"] as? [String: Any] ?? [:]
        let stored = ((providers["deepseek"] as? [String: Any] ?? [:])["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty { return stored }
        for name in ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"] {
            let env = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces) ?? ""
            if !env.isEmpty { return env }
        }
        return ""
    }

    func setDeepseekApiKey(_ key: String) {
        update { document in
            var credentials = document["credentials"] as? [String: Any] ?? [:]
            var providers = credentials["providers"] as? [String: Any] ?? [:]
            var deepseek = providers["deepseek"] as? [String: Any] ?? [:]
            deepseek["apiKey"] = key.trimmingCharacters(in: .whitespaces)
            providers["deepseek"] = deepseek
            credentials["providers"] = providers
            document["credentials"] = credentials
        }
    }

    // MARK: - OpenCode profiles

    struct OpenCodeProfile {
        let name: String
        let cookie: String
        let apiKey: String
        let enabled: Bool
    }

    func opencodeProfiles() -> [OpenCodeProfile] {
        lock.lock()
        defer { lock.unlock() }
        let document = readDocument()
        let providers = (document["credentials"] as? [String: Any] ?? [:])["providers"] as? [String: Any] ?? [:]
        let profiles = (providers["opencode"] as? [String: Any] ?? [:])["profiles"] as? [String: Any] ?? [:]
        return profiles.compactMap { (name, value) in
            guard let profile = value as? [String: Any] else { return nil }
            return OpenCodeProfile(
                name: name,
                cookie: profile["cookie"] as? String ?? "",
                apiKey: profile["apiKey"] as? String ?? "",
                enabled: profile["enabled"] as? Bool ?? true
            )
        }.sorted { $0.name < $1.name }
    }

    private func mutateProfiles(_ mutate: (inout [String: Any]) -> Void) {
        update { document in
            var credentials = document["credentials"] as? [String: Any] ?? [:]
            var providers = credentials["providers"] as? [String: Any] ?? [:]
            var opencode = providers["opencode"] as? [String: Any] ?? [:]
            var profiles = opencode["profiles"] as? [String: Any] ?? [:]
            mutate(&profiles)
            opencode["profiles"] = profiles
            providers["opencode"] = opencode
            credentials["providers"] = providers
            document["credentials"] = credentials
        }
    }

    func saveOpencodeProfile(name: String, cookie: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateProfiles { profiles in
            let existing = profiles[trimmed] as? [String: Any] ?? [:]
            var next = existing
            next["cookie"] = cookie.trimmingCharacters(in: .whitespaces)
            next["enabled"] = true
            profiles[trimmed] = next
        }
    }

    func setOpencodeProfileApiKey(name: String, apiKey: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateProfiles { profiles in
            guard var profile = profiles[trimmed] as? [String: Any] else { return }
            profile["apiKey"] = apiKey.trimmingCharacters(in: .whitespaces)
            profiles[trimmed] = profile
        }
    }

    func deleteOpencodeProfile(name: String) {
        mutateProfiles { profiles in
            profiles.removeValue(forKey: name)
        }
    }

    func renameOpencodeProfile(oldName: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, oldName != trimmed else { return }
        mutateProfiles { profiles in
            if let value = profiles.removeValue(forKey: oldName) {
                profiles[trimmed] = value
            }
        }
    }

    func setOpencodeProfileEnabled(name: String, enabled: Bool) {
        mutateProfiles { profiles in
            if var profile = profiles[name] as? [String: Any] {
                profile["enabled"] = enabled
                profiles[name] = profile
            }
        }
    }

    func clearOpencode() {
        update { document in
            var credentials = document["credentials"] as? [String: Any] ?? [:]
            var providers = credentials["providers"] as? [String: Any] ?? [:]
            providers.removeValue(forKey: "opencode")
            credentials["providers"] = providers
            document["credentials"] = credentials
        }
    }
}
