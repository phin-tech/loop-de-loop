// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoopDeLoop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LoupedeckKit", targets: ["LoupedeckKit"]),
        .executable(name: "ldl", targets: ["ldl"]),
    ],
    targets: [
        .target(name: "LoupedeckKit"),
        .executableTarget(name: "ldl", dependencies: ["LoupedeckKit"]),
        .testTarget(name: "LoupedeckKitTests", dependencies: ["LoupedeckKit"]),
    ]
)
