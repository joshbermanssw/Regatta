// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaCore",
            targets: ["RegattaCore"]
        ),
    ],
    targets: [
        .target(
            name: "RegattaCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaCoreTests",
            dependencies: ["RegattaCore"],
            resources: [ .copy("fake-agent.sh") ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
