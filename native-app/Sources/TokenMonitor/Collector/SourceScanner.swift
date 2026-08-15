import Foundation
import CryptoKit

/// Data-source fingerprints (PLAN.md Phase 3): per-client file sets with
/// size + mtime, hashed into a stable signature. When a client's signature
/// is unchanged, its cached rows/period/history contributions are still
/// valid and nothing is re-read or re-computed.
///
/// The fingerprint is polled on every collector tick; that poll is also the
/// low-frequency reconciliation pass, so lost file-event notifications can
/// never leave stale data for longer than one refresh interval.
enum SourceScanner {
    struct FileStamp: Hashable {
        let path: String
        let size: Int64
        let mtimeMs: Double
    }

    struct Fingerprint {
        let files: [FileStamp]
        let signature: String
        var isEmpty: Bool { files.isEmpty }
    }

    // MARK: - Roots

    /// File roots for the local adapter clients (matches Adapters readers).
    static func adapterRoots(_ client: String) -> [String] {
        let home = NSHomeDirectory()
        switch client {
        case "proma": return [home + "/.proma/agent-sessions"]
        case "hanako": return [
            home + "/.hanako/agents/hanako/sessions",
            home + "/.hanako/agents/hanako/activity"
        ]
        case "dsh": return [home + "/.dsh/sessions"]
        default: return []
        }
    }

    /// File roots the vendored tokscale scanner reads for a client
    /// (from `tokscale clients --json`): sessionsPath + additional/headless
    /// roots. Workbuddy scans ~/.workbuddy/projects (session JSONL), not
    /// the whole 27k-file application tree.
    static func tokscaleRoots(_ client: String) -> [String] {
        let home = NSHomeDirectory()
        var roots: [String]
        switch client {
        case "claude":
            roots = [home + "/.claude/projects", home + "/.claude/transcripts"]
        case "codex":
            roots = [home + "/.codex/sessions"]
        case "opencode":
            roots = [home + "/.local/share/opencode/storage/message"]
        case "workbuddy":
            roots = [home + "/.workbuddy/projects", home + "/.workbuddy/sessions"]
        default:
            roots = []
        }
        // Headless-captured sessions are merged by tokscale for every client.
        roots += [
            home + "/.config/tokscale/headless",
            home + "/Library/Application Support/tokscale/headless"
        ]
        return roots
    }

    /// Whether a file participates in a client's fingerprint. Adapter
    /// clients mirror their readers exactly (jsonl / session.jsonl.zstd);
    /// tokscale clients include every regular file under their (small)
    /// data roots, which is a conservative superset of what the scanner
    /// consumes.
    static func included(_ client: String, path: String) -> Bool {
        switch client {
        case "proma", "hanako":
            return path.hasSuffix(".jsonl")
        case "dsh":
            return path.hasSuffix("session.jsonl.zstd")
        default:
            return true
        }
    }

    // MARK: - Fingerprinting

    /// Walk the roots, stat each regular file (no content I/O), and hash
    /// the sorted (path, size, mtime) list. Missing roots contribute
    /// nothing; an empty fingerprint means "no source files at all".
    static func fingerprint(client: String, roots: [String]) -> Fingerprint {
        var stamps: [FileStamp] = []
        for root in roots {
            let url = URL(fileURLWithPath: root)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else { continue }
                guard included(client, path: file.path) else { continue }
                stamps.append(FileStamp(
                    path: file.path,
                    size: Int64(size),
                    mtimeMs: (mtime.timeIntervalSince1970 * 1000).rounded()
                ))
            }
        }
        stamps.sort { $0.path < $1.path }
        return Fingerprint(files: stamps, signature: Self.signature(of: stamps))
    }

    private static func signature(of stamps: [FileStamp]) -> String {
        var digest = SHA256()
        for stamp in stamps {
            var line = stamp.path + "\u{0}" + String(stamp.size) + "\u{0}"
                + String(format: "%.3f", stamp.mtimeMs) + "\n"
            digest.update(data: Data(line.utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

