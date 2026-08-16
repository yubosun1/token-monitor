import Foundation
import CryptoKit

/// SHA-256 credential fingerprint ("sha256:" hex prefix) used to key
/// per-account limit caches. Historically duplicated in
/// DeepseekBalance/OpencodeLimits; kept here as a single shared helper.
enum CredentialHash {
    static func key(_ parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}