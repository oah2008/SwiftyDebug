// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SwiftyDebug",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SwiftyDebug",
            targets: ["SwiftyDebug"]
        )
    ],
    targets: [
        .target(
            name: "SwiftyDebug",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "SwiftyDebugTests",
            dependencies: ["SwiftyDebug"],
            path: "Tests/SwiftyDebugTests"
        )
    ]
)
