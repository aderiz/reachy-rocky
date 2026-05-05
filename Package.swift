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
        .library(name: "Voice", targets: ["Voice"]),
        .library(name: "Cognition", targets: ["Cognition"]),
    ],
    targets: [
        .executableTarget(
            name: "Rocky",
            dependencies: ["RockyKit", "Telemetry", "SidecarHost", "RobotLink", "Vision", "Voice", "Cognition"],
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
        .target(
            name: "Voice",
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/Voice"
        ),
        .target(
            name: "Cognition",
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/Cognition"
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
        .testTarget(
            name: "VoiceTests",
            dependencies: ["Voice", "Telemetry", "RockyKit"],
            path: "Tests/VoiceTests"
        ),
        .testTarget(
            name: "CognitionTests",
            dependencies: ["Cognition", "Telemetry", "RockyKit"],
            path: "Tests/CognitionTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
