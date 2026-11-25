// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoopDeLoop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LoupedeckKit", targets: ["LoupedeckKit"]),
        .library(name: "LoopCore", targets: ["LoopCore"]),
        .executable(name: "ldl", targets: ["ldl"]),
        .executable(name: "loopctl", targets: ["loopctl"]),
    ],
    targets: [
        // Device driver: serial protocol, input events, drawing.
        .target(name: "LoupedeckKit"),
        // App logic shared by the menu-bar app and the CLI: config, actions, rendering, engine.
        .target(name: "LoopCore", dependencies: ["LoupedeckKit"]),
        // Direct-to-hardware debug tool.
        .executableTarget(name: "ldl", dependencies: ["LoupedeckKit"]),
        // CLI that talks to the running app.
        .executableTarget(name: "loopctl", dependencies: ["LoopCore"]),
        .testTarget(name: "LoupedeckKitTests", dependencies: ["LoupedeckKit"]),
        .testTarget(name: "LoopCoreTests", dependencies: ["LoopCore"]),
    ]
)
