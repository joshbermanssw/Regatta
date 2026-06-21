// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaPersistence",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaPersistence",
            targets: ["RegattaPersistence"]
        ),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
        .package(path: "../RegattaGitHub"),
        .package(path: "../RegattaFleet"),
        .package(path: "../RegattaMemory"),
    ],
    targets: [
        .target(
            name: "RegattaPersistence",
            dependencies: [
                "RegattaCore",
                "RegattaGitHub",
                "RegattaFleet",
                "RegattaMemory",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaPersistenceTests",
            dependencies: [
                "RegattaPersistence",
                "RegattaCore",
                "RegattaGitHub",
                "RegattaFleet",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
