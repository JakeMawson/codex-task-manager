// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexTaskManager",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "CodexTaskManager", targets: ["CodexTaskManager"]),
        .executable(name: "CodexTaskManagerLauncher", targets: ["CodexTaskManagerLauncher"]),
        .executable(name: "CodexTaskManagerBenchmark", targets: ["CodexTaskManagerBenchmark"]),
    ],
    targets: [
        .target(
            name: "CodexTaskManagerKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexTaskManager",
            dependencies: ["CodexTaskManagerKit"]
        ),
        .executableTarget(
            name: "CodexTaskManagerLauncher",
            dependencies: ["IndependentAppLaunch"]
        ),
        .target(name: "IndependentAppLaunch"),
        .executableTarget(
            name: "CodexTaskManagerBenchmark",
            dependencies: ["CodexTaskManagerKit"],
            path: "Benchmarks/CodexTaskManagerBenchmark"
        ),
        .testTarget(
            name: "CodexTaskManagerKitTests",
            dependencies: ["CodexTaskManagerKit"]
        ),
    ]
)
