// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RegattaGitHub",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RegattaGitHub",
            targets: ["RegattaGitHub"]
        ),
    ],
    targets: [
        .target(
            name: "RegattaGitHub",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "RegattaGitHubTests",
            dependencies: ["RegattaGitHub"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
