// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "lifetrace",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lifetrace", targets: ["lifetrace"]),
    ],
    targets: [
        .target(name: "LifetraceCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "lifetrace", dependencies: ["LifetraceCore"]),
        .testTarget(name: "LifetraceCoreTests", dependencies: ["LifetraceCore"]),
    ]
)
