// swift-tools-version:6.0
import PackageDescription
import Foundation

// Vendored zstd: static archive + header under Vendor/zstd, so the app has no
// Homebrew dependency at build or runtime (used for DeepSeek Harness
// session.jsonl.zstd transcripts).
let vendorZstdLib = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/zstd/lib/libzstd.a")
    .path

let package = Package(
    name: "TokenMonitor",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CZstd",
            path: "Vendor/zstd",
            sources: ["dummy.c"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "TokenMonitor",
            dependencies: ["CZstd"],
            path: "Sources/TokenMonitor",
            // v5 language mode keeps AppKit/WKWebView delegate conformance
            // friction-free; the app is single-threaded UI + a few timers.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([vendorZstdLib])
            ]
        )
    ]
)
