// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaLoopUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaLoopUI",
            targets: ["RegattaLoopUI"]
        ),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
    ],
    targets: [
        .target(
            name: "RegattaLoopUI",
            dependencies: ["RegattaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaLoopUITests",
            dependencies: ["RegattaLoopUI", "RegattaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
