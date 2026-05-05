// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rocky",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Rocky", targets: ["Rocky"]),
        .library(name: "RockyKit", targets: ["RockyKit"]),
        .library(name: "Telemetry", targets: ["Telemetry"]),
        .library(name: "SidecarHost", targets: ["SidecarHost"]),
        .library(name: "RobotLink", targets: ["RobotLink"]),
        .library(name: "Vision", targets: ["Vision"]),
    ],
    targets: [
        .executableTarget(
            name: "Rocky",
            dependencies: ["RockyKit", "Telemetry", "SidecarHost", "RobotLink", "Vision"],
            path: "Sources/Rocky"
        ),
        .target(
            name: "RockyKit",
            path: "Sources/RockyKit"
        ),
        .target(
            name: "Telemetry",
            dependencies: ["RockyKit"],
            path: "Sources/Telemetry"
        ),
        .target(
            name: "SidecarHost",
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/SidecarHost"
        ),
        .target(
            name: "RobotLink",
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/RobotLink"
        ),
        .target(
            name: "Vision",
            dependencies: ["RockyKit", "Telemetry", "SidecarHost", "RobotLink"],
            path: "Sources/Vision"
        ),
        .testTarget(
            name: "RockyKitTests",
            dependencies: ["RockyKit"],
            path: "Tests/RockyKitTests"
        ),
        .testTarget(
            name: "RobotLinkTests",
            dependencies: ["RobotLink", "RockyKit"],
            path: "Tests/RobotLinkTests"
        ),
        .testTarget(
            name: "SidecarHostTests",
            dependencies: ["SidecarHost"],
            path: "Tests/SidecarHostTests"
        ),
        .testTarget(
            name: "VisionTests",
            dependencies: ["Vision", "SidecarHost", "Telemetry", "RockyKit"],
            path: "Tests/VisionTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
