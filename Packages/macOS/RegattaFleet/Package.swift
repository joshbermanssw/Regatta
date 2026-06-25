// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaFleet",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaFleet",
            targets: ["RegattaFleet"]
        ),
    ],
    dependencies: [
        .package(path: "../RegattaGitHub"),
        // Test-only: the end-to-end pipeline integration test drives the real
        // RegattaCore orchestrator (RegattaOrchestrator + ProcessPaneBridge +
        // RegattaWorktreeManager + RegattaGitDiffProbe) — the live seams the app's
        // OrchestratorWorkerSpawner wraps — so the test exercises the real spawn →
        // run → commit → diff path with a scripted fake-agent process (never the
        // real CLI). RegattaCore has no dependencies, so this adds no cycle.
        .package(path: "../RegattaCore"),
    ],
    targets: [
        .target(
            name: "RegattaFleet",
            dependencies: ["RegattaGitHub"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaFleetTests",
            dependencies: ["RegattaFleet", "RegattaGitHub", "RegattaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
