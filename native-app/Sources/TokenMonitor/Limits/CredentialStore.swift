import Foundation

/// Port of src/shared/credentialStore.js (the subset the native app keeps):
/// raw credentials in ~/Library/Application Support/Token Monitor/
/// credentials.json with restrictive permissions. The native app reads the
/// same file the Electron version wrote, so existing keys keep working.
final class CredentialStore {
    static let shared = CredentialStore()

    let fileURL: URL
    private let lock = NSLock()

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Token Monitor", isDirectory: true)
        self.init(fileURL: dir.appendingPathComponent("credentials.json"))
    }

    /// Test seam: fixture checks redirect the store into a sandbox directory.
    init(fileURL: URL) {
        self.fileURL = fileURL
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
            // Write to a temp file and chmod it to 0600 BEFORE the atomic
            // rename: a post-rename chmod leaves the credentials file at the
            // umask default (0644) during the rename window.
            let tempURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try data.write(to: tempURL)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            } catch {
                NSLog("[credentials] chmod 0600 failed, keeping previous file: %@", String(describing: error))
                return
            }
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            // replaceItemAt keeps the replaced file's attributes on some
            // filesystems, so re-lock the final file after the rename. The
            // fresh-file case is already covered by the pre-rename chmod.
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                NSLog("[credentials] post-rename chmod 0600 failed: %@", String(describing: error))
            }
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

    // MARK: - Kimi

    private func storedKimiCredential(_ field: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let document = readDocument()
        let providers = (document["credentials"] as? [String: Any] ?? [:])["providers"] as? [String: Any] ?? [:]
        return (providers["kimi"] as? [String: Any] ?? [:])[field] as? String ?? ""
    }

    private func setKimiCredential(_ field: String, value: String) {
        update { document in
            var credentials = document["credentials"] as? [String: Any] ?? [:]
            var providers = credentials["providers"] as? [String: Any] ?? [:]
            var kimi = providers["kimi"] as? [String: Any] ?? [:]
            kimi[field] = value
            providers["kimi"] = kimi
            credentials["providers"] = providers
            document["credentials"] = credentials
        }
    }

    func kimiApiKey() -> String {
        let stored = KimiLimits.normalizedAPIKey(storedKimiCredential("apiKey"))
        if !stored.isEmpty { return stored }
        let environment = KimiLimits.normalizedAPIKey(ProcessInfo.processInfo.environment["KIMI_CODE_API_KEY"] ?? "")
        if !environment.isEmpty { return environment }
        return installedKimiCodeAccessToken()
    }

    func kimiApiKeySource() -> String {
        if !KimiLimits.normalizedAPIKey(storedKimiCredential("apiKey")).isEmpty { return "settings" }
        if !KimiLimits.normalizedAPIKey(ProcessInfo.processInfo.environment["KIMI_CODE_API_KEY"] ?? "").isEmpty { return "env" }
        return installedKimiCodeAccessToken().isEmpty ? "" : "cli"
    }

    func kimiWebAccessToken() -> String {
        let stored = KimiLimits.normalizedWebAccessToken(storedKimiCredential("webAccessToken"))
        if !stored.isEmpty { return stored }
        for name in ["KIMI_AUTH_TOKEN", "KIMI_MANUAL_COOKIE"] {
            let token = KimiLimits.normalizedWebAccessToken(ProcessInfo.processInfo.environment[name] ?? "")
            if !token.isEmpty { return token }
        }
        return ""
    }

    func kimiWebAccessTokenSource() -> String {
        if !KimiLimits.normalizedWebAccessToken(storedKimiCredential("webAccessToken")).isEmpty { return "settings" }
        for name in ["KIMI_AUTH_TOKEN", "KIMI_MANUAL_COOKIE"] {
            if !KimiLimits.normalizedWebAccessToken(ProcessInfo.processInfo.environment[name] ?? "").isEmpty { return "env" }
        }
        return ""
    }

    func setKimiApiKey(_ key: String) {
        setKimiCredential("apiKey", value: KimiLimits.normalizedAPIKey(key))
    }

    func setKimiWebAccessToken(_ token: String) {
        setKimiCredential("webAccessToken", value: KimiLimits.normalizedWebAccessToken(token))
    }

    private func installedKimiCodeAccessToken() -> String {
        let credentialsURL = URL(fileURLWithPath: SourceScanner.kimiCodeHome(), isDirectory: true)
            .appendingPathComponent("credentials/kimi-code.json")
        return Self.kimiCodeAccessToken(at: credentialsURL)
    }

    /// Kimi Code persists its OAuth access token here after `kimi login`.
    /// It is only used as a local fallback for the Kimi Code quota endpoint;
    /// an explicitly saved API key or environment variable still takes priority.
    static func kimiCodeAccessToken(at credentialsURL: URL, now: Date = Date()) -> String {
        guard let data = try? Data(contentsOf: credentialsURL),
              let credentials = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawToken = credentials["access_token"] as? String else {
            return ""
        }
        let token = KimiLimits.normalizedAPIKey(rawToken)
        guard !token.isEmpty, !KimiLimits.isJWTExpired(token, at: now) else { return "" }
        return token
    }
}
