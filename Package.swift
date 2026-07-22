// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TaskDeckForCodex",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "TaskDeckForCodex", targets: ["TaskDeckForCodex"])
    ],
    targets: [
        .target(name: "CodexCompanionCore"),
        .executableTarget(
            name: "TaskDeckForCodex",
            dependencies: ["CodexCompanionCore"],
            path: "Sources/CodexCompanion"
        ),
        .testTarget(
            name: "CodexCompanionCoreTests",
            dependencies: ["CodexCompanionCore"]
        )
    ]
)
