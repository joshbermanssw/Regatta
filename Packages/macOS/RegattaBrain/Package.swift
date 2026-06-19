// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaBrain",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaBrain",
            targets: ["RegattaBrain"]
        ),
    ],
    targets: [
        .target(
            name: "RegattaBrain",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaBrainTests",
            dependencies: ["RegattaBrain"],
            resources: [
                .copy("fake-claude.sh"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
