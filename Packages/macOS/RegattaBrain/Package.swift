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
    dependencies: [
        .package(path: "../RegattaCore"),
    ],
    targets: [
        .target(
            name: "RegattaBrain",
            dependencies: [
                .product(name: "RegattaCore", package: "RegattaCore"),
            ],
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
                .copy("fake-judge.sh"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
