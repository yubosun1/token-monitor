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
        // Split into a library + thin executable so the fixture checker can
        // exercise the aggregation code without linking the app entry point.
        // -enable-testing is debug-only: the Release app build is unaffected.
        .target(
            name: "TokenMonitorCore",
            dependencies: ["CZstd"],
            path: "Sources/TokenMonitor",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ],
            linkerSettings: [
                .unsafeFlags([vendorZstdLib])
            ]
        ),
        .executableTarget(
            name: "TokenMonitor",
            dependencies: ["TokenMonitorCore"],
            path: "Sources/TokenMonitorMain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TokenMonitorFixtureCheck",
            dependencies: ["TokenMonitorCore"],
            path: "Tests/TokenMonitorFixtureCheck",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
