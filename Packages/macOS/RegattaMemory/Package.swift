// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaMemory",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaMemory",
            targets: ["RegattaMemory"]
        ),
    ],
    targets: [
        .target(
            name: "RegattaMemory",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaMemoryTests",
            dependencies: ["RegattaMemory"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
