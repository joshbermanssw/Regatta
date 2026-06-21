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
            dependencies: ["RegattaFleet", "RegattaGitHub"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
